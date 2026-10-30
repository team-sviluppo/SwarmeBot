// The pull request of a chat's branch, and what comes back after a push
// (docs/plans/2026-10-28-code-mode-t3.md, Parte 2 §7): its state and CI, the logs of the checks that
// failed, and the comments colleagues left. Run by the engine with `gh`, where the repository is, so
// it also works for a chat on a server; no agent is involved and nothing here writes to GitHub.
import Foundation
import HarnessCore

@MainActor
final class CodePullRequests {
    /// What `gh` is called by: tests point it at a script.
    nonisolated(unsafe) static var executable = "gh"
    static let ttl: TimeInterval = 15
    static let logLines = 120
    static let logBudget = 24_000
    static let commentBudget = 20_000

    private struct Cached {
        var at: Date
        var wire: JSON
    }

    private var cache: [String: Cached] = [:]

    static let fields = "number,url,title,state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefName,baseRefName,statusCheckRollup,comments,reviews,author"

    private static var environment: [String: String] {
        var env = GitRun.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        return env
    }

    /// Why `gh` could not be used, or nil when it can.
    private static func unavailable(root: String) async -> String? {
        guard (await CLIProcess.run(executable, ["--version"], environment: environment, cwd: root, timeout: 8))?.ok == true else {
            return "the GitHub CLI (gh) is not installed on this machine"
        }
        return nil
    }

    private static func signedOut(_ said: String) -> Bool {
        let text = said.lowercased()
        return text.contains("gh auth login") || text.contains("not logged in") || text.contains("authentication")
    }

    // MARK: state

    /// `{available, reason?, pr}`; `pr` is null for a branch with none. Kept for a few seconds, so that
    /// several windows watching the same repository ask GitHub once.
    func status(root: String, branch: String?, refresh: Bool) async throws -> JSON {
        guard let branch, !branch.isEmpty else { return ["available": true, "pr": .null] }
        let key = root + "\n" + branch
        if !refresh, let hit = cache[key], Date().timeIntervalSince(hit.at) < Self.ttl { return hit.wire }
        if let reason = await Self.unavailable(root: root) { return ["available": false, "reason": .string(reason), "pr": .null] }
        guard let output = await CLIProcess.run(Self.executable, ["pr", "view", "--json", Self.fields], environment: Self.environment, cwd: root, timeout: 25) else {
            throw HTTPError(504, "gh did not answer")
        }
        let wire: JSON
        if output.ok {
            wire = ["available": true, "pr": Self.pullRequest(from: try JSON.parse(Data(output.stdout.utf8)))]
        } else if GitRun.said(output).contains("no pull requests found") {
            wire = ["available": true, "pr": .null]
        } else if Self.signedOut(GitRun.said(output)) {
            wire = ["available": false, "reason": "gh is not signed in on this machine: run `gh auth login`", "pr": .null]
        } else {
            throw HTTPError(502, GitRun.said(output))
        }
        cache[key] = Cached(at: Date(), wire: wire)
        return wire
    }

    func forget(root: String) {
        for key in cache.keys where key.hasPrefix(root + "\n") { cache[key] = nil }
    }

    /// One check, as the app shows it: `success`, `failure`, `pending` or `skipped`.
    static func check(from item: JSON) -> JSON {
        var state = "pending"
        var name = item["name"]?.string ?? item["context"]?.string ?? ""
        if item["__typename"]?.string == "StatusContext" {
            switch (item["state"]?.string ?? "").uppercased() {
            case "SUCCESS": state = "success"
            case "FAILURE", "ERROR": state = "failure"
            default: state = "pending"
            }
        } else if (item["status"]?.string ?? "").uppercased() == "COMPLETED" {
            switch (item["conclusion"]?.string ?? "").uppercased() {
            case "SUCCESS": state = "success"
            case "NEUTRAL", "SKIPPED": state = "skipped"
            case "": state = "pending"
            default: state = "failure"   // FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE
            }
        }
        if name.isEmpty { name = "check" }
        var object: JSONObject = ["name": .string(name), "state": .string(state)]
        if let workflow = item["workflowName"]?.string, !workflow.isEmpty { object["workflow"] = .string(workflow) }
        if let url = item["detailsUrl"]?.string ?? item["targetUrl"]?.string, !url.isEmpty { object["url"] = .string(url) }
        return .object(object)
    }

    /// The pull request as the app reads it: the checks folded into one state, the comments counted.
    static func pullRequest(from raw: JSON) -> JSON {
        let checks = (raw["statusCheckRollup"]?.array ?? []).map(check(from:))
        func count(_ state: String) -> Int { checks.filter { $0["state"]?.string == state }.count }
        let failed = count("failure"), pending = count("pending"), passed = count("success")
        let overall = checks.isEmpty ? "none" : failed > 0 ? "failure" : pending > 0 ? "pending" : "success"
        let reviews = (raw["reviews"]?.array ?? []).filter { !($0["body"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var object: JSONObject = [
            "number": raw["number"] ?? .null, "url": raw["url"] ?? .null, "title": raw["title"] ?? .null,
            "state": .string((raw["state"]?.string ?? "OPEN").lowercased()), "draft": .bool(raw["isDraft"]?.bool ?? false),
            "base": raw["baseRefName"] ?? .null, "head": raw["headRefName"] ?? .null,
            "checks": ["state": .string(overall), "total": .number(Double(checks.count)), "passed": .number(Double(passed)),
                       "failed": .number(Double(failed)), "pending": .number(Double(pending)), "items": .array(checks)],
            "comments": .number(Double((raw["comments"]?.array?.count ?? 0) + reviews.count)),
        ]
        if let merge = raw["mergeStateStatus"]?.string, !merge.isEmpty { object["merge"] = .string(merge.lowercased()) }
        if let mergeable = raw["mergeable"]?.string, !mergeable.isEmpty { object["mergeable"] = .string(mergeable.lowercased()) }
        if let decision = raw["reviewDecision"]?.string, !decision.isEmpty { object["reviewDecision"] = .string(decision.lowercased()) }
        if let author = raw["author"]?["login"]?.string { object["author"] = .string(author) }
        return .object(object)
    }

    // MARK: CI

    /// The run a check belongs to: `…/actions/runs/123/job/456`.
    static func runId(from url: String) -> String? {
        guard let range = url.range(of: #"/actions/runs/(\d+)"#, options: .regularExpression) else { return nil }
        return String(url[range].dropFirst("/actions/runs/".count))
    }

    /// The end of a log: what failed is at the bottom.
    static func tail(_ log: String, lines: Int? = nil) -> String {
        let lines = lines ?? logLines
        let all = log.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = all.suffix(lines).joined(separator: "\n")
        return (all.count > lines ? "[… \(all.count - lines) earlier lines left out]\n" : "") + kept
    }

    /// The message that asks the first bot to fix the CI, with the logs of what failed.
    static func ciMessage(number: Int?, title: String?, failures: [(name: String, url: String?, log: String?)]) -> String {
        var text = "The CI of the pull request\(number.map { " #\($0)" } ?? "")\(title.map { " (\($0))" } ?? "") failed. These are the checks that failed, with the end of their logs:\n"
        var budget = logBudget
        for failure in failures {
            var block = "\n### \(failure.name)\(failure.url.map { " — \($0)" } ?? "")\n"
            if let log = failure.log, !log.isEmpty {
                let shown = log.count > budget ? "[…]\n" + String(log.suffix(max(budget, 0))) : log
                block += "```\n" + shown + "\n```\n"
            } else {
                block += "(no log available for this check: open the link)\n"
            }
            budget -= block.count
            text += block
            if budget <= 0 { text += "\n[more failed checks left out: the message is long enough]\n"; break }
        }
        return text + "\nFind the cause, fix it in the working folder, and tell me what you changed."
    }

    func ciFailures(root: String, branch: String?) async throws -> JSON {
        guard case let .object(state) = try await status(root: root, branch: branch, refresh: true), state["available"]?.bool == true else {
            throw HTTPError(400, "the GitHub CLI is not available on this machine")
        }
        guard let pr = state["pr"], !pr.isNull else { throw HTTPError(404, "this branch has no pull request") }
        let failed = (pr["checks"]?["items"]?.array ?? []).filter { $0["state"]?.string == "failure" }
        guard !failed.isEmpty else { throw HTTPError(404, "no check failed") }
        // a run holds several jobs: its failed log is fetched once
        var logs: [String: String] = [:]
        var failures: [(name: String, url: String?, log: String?)] = []
        for check in failed {
            let name = [check["workflow"]?.string, check["name"]?.string].compactMap { $0 }.joined(separator: " / ")
            let url = check["url"]?.string
            var log: String?
            if let url, let run = Self.runId(from: url) {
                if logs[run] == nil {
                    let output = await CLIProcess.run(Self.executable, ["run", "view", run, "--log-failed"], environment: Self.environment, cwd: root, timeout: 90)
                    logs[run] = output?.ok == true ? Self.tail(output?.stdout ?? "") : ""
                }
                log = logs[run]
            }
            failures.append((name, url, log))
        }
        let message = Self.ciMessage(number: pr["number"]?.int, title: pr["title"]?.string, failures: failures)
        return ["message": .string(message), "checks": .number(Double(failures.count))]
    }

    // MARK: comments

    static let threadsQuery = "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved isOutdated path line comments(first:20){nodes{author{login} body}}}}}}}"

    private static func clip(_ text: String, _ limit: Int = 1500) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    /// Discussion comments, reviews with something to say, and the open conversations on the code.
    static func commentsMessage(number: Int?, title: String?, comments: [JSON], reviews: [JSON], threads: [JSON]) -> (text: String, count: Int) {
        var lines: [String] = []
        for review in reviews {
            let body = clip(review["body"]?.string ?? "")
            guard !body.isEmpty else { continue }
            let verdict = (review["state"]?.string ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
            lines.append("- @\(review["author"]?["login"]?.string ?? "someone") (review\(verdict.isEmpty || verdict == "commented" ? "" : ", \(verdict)")): \(body)")
        }
        for thread in threads where thread["isResolved"]?.bool != true {
            let first = thread["comments"]?["nodes"]?.array ?? []
            let said = first.map { "@\($0["author"]?["login"]?.string ?? "someone"): \(clip($0["body"]?.string ?? "", 800))" }.joined(separator: " → ")
            guard !said.isEmpty else { continue }
            let place = thread["path"]?.string.map { path in "\(path)\(thread["line"]?.int.map { ":\($0)" } ?? "")" } ?? "the code"
            lines.append("- on \(place)\(thread["isOutdated"]?.bool == true ? " (the code has changed since)" : ""): \(said)")
        }
        for comment in comments {
            let body = clip(comment["body"]?.string ?? "")
            guard !body.isEmpty else { continue }
            lines.append("- @\(comment["author"]?["login"]?.string ?? "someone") (comment): \(body)")
        }
        guard !lines.isEmpty else { return ("", 0) }
        var kept: [String] = []
        var size = 0
        for line in lines {
            size += line.count + 1
            if size > commentBudget { kept.append("- [more comments left out: the message is long enough]"); break }
            kept.append(line)
        }
        let text = "Colleagues left comments on the pull request\(number.map { " #\($0)" } ?? "")\(title.map { " (\($0))" } ?? ""):\n\n"
            + kept.joined(separator: "\n")
            + "\n\nGo through them: fix what is right, and tell me what you would not change and why."
        return (text, lines.count)
    }

    func comments(root: String, branch: String?) async throws -> JSON {
        guard case let .object(state) = try await status(root: root, branch: branch, refresh: true), state["available"]?.bool == true else {
            throw HTTPError(400, "the GitHub CLI is not available on this machine")
        }
        guard let pr = state["pr"], !pr.isNull, let number = pr["number"]?.int else { throw HTTPError(404, "this branch has no pull request") }
        func fetch(_ args: [String]) async -> JSON? {
            guard let output = await CLIProcess.run(Self.executable, args, environment: Self.environment, cwd: root, timeout: 30), output.ok else { return nil }
            return try? JSON.parse(Data(output.stdout.utf8))
        }
        guard let discussion = await fetch(["pr", "view", String(number), "--json", "comments,reviews"]) else { throw HTTPError(502, "could not read the pull request's comments") }
        let threads = await fetch(["api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-F", "number=\(number)", "-f", "query=\(Self.threadsQuery)"])
        let nodes = threads?["data"]?["repository"]?["pullRequest"]?["reviewThreads"]?["nodes"]?.array ?? []
        let result = Self.commentsMessage(number: number, title: pr["title"]?.string, comments: discussion["comments"]?.array ?? [],
                                          reviews: discussion["reviews"]?.array ?? [], threads: nodes)
        guard result.count > 0 else { throw HTTPError(404, "no comments to import") }
        return ["message": .string(result.text), "count": .number(Double(result.count))]
    }
}
