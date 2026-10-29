// A review of a chat's changes by another bot (docs/plans/2026-10-28-code-mode-t3.md, Parte 2 §5).
//
// "Ask for a review from…" sends the diff to a second bot, ideally on a different model. It runs as a
// task of its own on that bot (its main chat stays as it was), at the depth of a peer's turn, so it
// cannot contact other bots in turn; the repository is linked to it read-only so that it can read the
// code around the change. The reply lands in the chat that was reviewed, as a message from the
// reviewer, and *Apply* hands it to the first bot.
import Foundation
import HarnessCore

@MainActor
final class CodeReviews {
    enum Status: String { case running, done, failed, cancelled }

    struct Run {
        var id: String
        var originThread: String
        var reviewerId: String
        var reviewerName: String
        var reviewerThread: String
        var branch: String?
        var status: Status
        var error: String?
        var messageId: String?
        var startedAt: Double
        var finishedAt: Double?

        var wire: JSON {
            var object: JSONObject = ["id": .string(id), "reviewerId": .string(reviewerId), "reviewerName": .string(reviewerName),
                                      "reviewerThread": .string(reviewerThread), "status": .string(status.rawValue), "startedAt": .number(startedAt)]
            if let branch { object["branch"] = .string(branch) }
            if let error { object["error"] = .string(error) }
            if let messageId { object["messageId"] = .string(messageId) }
            if let finishedAt { object["finishedAt"] = .number(finishedAt) }
            return .object(object)
        }
    }

    static let promptLimit = 60_000
    static let timeout: TimeInterval = 15 * 60

    /// By the chat that was reviewed: the running one, or else the last to finish (until the engine restarts).
    private(set) var runs: [String: Run] = [:]
    /// The reviewer's task thread → the repository it reads, for `beforeTurn`.
    private(set) var reading: [String: String] = [:]
    private var stoppers: [String: () -> Void] = [:]

    static let system = """
        This is a code review requested by the person you work for, on changes another bot made. You may \
        read any file of the repository and run commands that only read (git log, git show, grep). Do not \
        change anything: you are reviewing, not fixing.
        """

    static func prompt(root: String, branch: String?, files: [String], diff: String, truncated: Bool) -> String {
        var text = """
            [A person asks you for a code review of changes another bot made in a repository of this SwarmeBot workspace.]

            Review these changes as a careful colleague would: look for bugs, cases the code misses, security \
            problems, tests that are missing or now wrong, and anything that does not fit the code around it. \
            The repository is at \(root)\(branch.map { " (branch \($0))" } ?? ""): read the files the change touches \
            and what they call, not only the diff. Do not modify any file.

            Reply in markdown: one line with your verdict, then the findings by importance, each as \
            `path:line — the problem — what to do`. If there is nothing important, say so plainly. Do not praise \
            and do not retell the diff.

            Changed files:

            """
        text += files.map { "- \($0)" }.joined(separator: "\n")
        let shown = diff.count > promptLimit ? String(diff.prefix(promptLimit)) : diff
        text += "\n\nDiff:\n" + shown
        if truncated || diff.count > promptLimit { text += "\n[the diff is cut here: it is longer than this; read the rest in the repository with git diff]" }
        return text
    }

    /// What the reviewer reads: the uncommitted changes, and with none (after a push, say) what the branch
    /// holds beyond the branch it started from.
    static func material(root: String, changes: [String]) async throws -> (files: [String], diff: String, truncated: Bool, scope: String) {
        if !changes.isEmpty {
            let result = try await GitDiff.diff(root: root, path: nil)
            if !result.diff.isEmpty { return (changes, result.diff, result.truncated, "changes") }
        }
        for base in ["origin/HEAD", "origin/main", "origin/master", "main", "master"] {
            guard await GitRun.text(["rev-parse", "--verify", "-q", base + "^{commit}"], in: root) != nil else { continue }
            let range = base + "...HEAD"
            guard let names = await GitRun.text(["diff", "--name-only", range], in: root), !names.isEmpty,
                  let output = await GitRun.git(["diff", "--no-color", range], in: root, timeout: 30), output.ok else { continue }
            let cap = 400_000
            return (names.split(separator: "\n").map(String.init), String(output.stdout.prefix(cap)), output.stdout.count > cap, "branch")
        }
        throw HTTPError(400, "nothing to review: no uncommitted changes, and the branch holds nothing beyond its base")
    }

    /// The bot whose chat this is, if it is a bot's (not a channel's).
    static func ownerBotId(of threadId: String, harness: Harness) -> String? {
        harness.store.botByThread(threadId)?["id"]?.string
    }

    func status(of threadId: String) -> JSON {
        guard let run = runs[threadId] else { return ["review": .null] }
        return ["review": run.wire]
    }

    func start(harness: Harness, originThread: String, reviewerId: String, root: String, branch: String?,
               files: [String], diff: String, truncated: Bool) throws -> Run {
        if runs[originThread]?.status == .running { throw HTTPError(409, "a review of this chat is already running") }
        guard let reviewer = harness.store.bot(reviewerId) else { throw HTTPError(404, "no such bot") }
        let name = reviewer["name"]?.string ?? reviewerId
        if Self.ownerBotId(of: originThread, harness: harness) == reviewerId { throw HTTPError(400, "a bot cannot review its own chat: pick another one") }
        if Store.isBusy(reviewer) { throw HTTPError(409, "@\(name) is working right now") }
        guard let task = harness.store.createTask(reviewerId, title: "Review: \(branch ?? (root as NSString).lastPathComponent)", activate: false),
              let reviewerThread = task["threadId"]?.string else { throw HTTPError(500, "could not open a chat on @\(name)") }

        var run = Run(id: newId(), originThread: originThread, reviewerId: reviewerId, reviewerName: name, reviewerThread: reviewerThread,
                      branch: branch, status: .running, startedAt: nowMillis())
        runs[originThread] = run
        reading[reviewerThread] = root

        var text = ""
        var finished = false
        var unsubscribe: () -> Void = {}
        var timer: Task<Void, Never>?
        let finish: (Status, String?) -> Void = { [weak self] status, error in
            guard let self, !finished else { return }
            finished = true
            timer?.cancel()
            unsubscribe()
            self.stoppers[originThread] = nil
            self.reading[reviewerThread] = nil
            run.status = status
            run.error = error
            run.finishedAt = nowMillis()
            if status == .done {
                run.messageId = self.land(harness: harness, run: run, reviewer: reviewer, text: text)
            } else if status == .failed {
                harness.store.appendMessage(originThread, ["role": "bot", "kind": "activity",
                                                           "tool": ["name": .string("error: the review by @\(name) failed — \(String((error ?? "").prefix(140)))"), "ok": false]])
            }
            self.runs[originThread] = run
        }
        let adapter = harness.fleet.get(ModelSelection(json: reviewer["modelSelection"]).instanceId)?.adapter
        stoppers[originThread] = {
            finish(.cancelled, nil)
            Task { @MainActor in await adapter?.interruptTurn(threadId: reviewerThread) }
        }
        unsubscribe = harness.bus.subscribe { event in
            guard event.threadId == reviewerThread else { return }
            switch event.body {
            case let .textCompleted(reply): text += (text.isEmpty ? "" : "\n\n") + reply
            case let .runtimeError(message, _): finish(.failed, message)
            case let .turnCompleted(ok, _, _, _, _):
                if ok && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finish(.done, nil) }
                else { finish(.failed, ok ? "the reviewer finished without writing a review" : "the reviewer's turn did not finish") }
            default: break
            }
        }
        timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await adapter?.interruptTurn(threadId: reviewerThread)
            finish(.failed, "the review took longer than \(Int(Self.timeout / 60)) minutes")
        }
        do {
            try harness.startTurn(botId: reviewerId, text: Self.prompt(root: root, branch: branch, files: files, diff: diff, truncated: truncated),
                                  threadId: reviewerThread, options: Harness.TurnOptions(commsDepth: 1))
        } catch let error as Harness.TurnError {
            finish(.failed, error.message)
            runs[originThread] = nil
            throw HTTPError(error.status, error.message)
        } catch {
            finish(.failed, error.localizedDescription)
            runs[originThread] = nil
            throw HTTPError(500, error.localizedDescription)
        }
        return run
    }

    /// Stops a running review: the reviewer's turn is interrupted and nothing lands in the chat.
    func cancel(threadId: String) -> Bool {
        guard runs[threadId]?.status == .running, let stop = stoppers[threadId] else { return false }
        stop()
        return true
    }

    /// The reviewer's message in the chat that was reviewed.
    private func land(harness: Harness, run: Run, reviewer: JSONObject, text: String) -> String? {
        let from: JSON = ["botId": .string(run.reviewerId), "name": .string(run.reviewerName), "color": reviewer["color"] ?? .null]
        let message = harness.store.appendMessage(run.originThread, ["role": "bot", "kind": "text", "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                                                                     "from": from, "review": ["applied": false]])
        if let owner = Self.ownerBotId(of: run.originThread, harness: harness) { harness.store.patchBot(owner, ["unread": true]) }
        else if let group = harness.store.groupByThread(run.originThread)?["id"]?.string { harness.store.patchGroup(group, ["unread": true]) }
        return message["id"]?.string
    }

    /// *Apply* was pressed: the message is marked, so it is offered once.
    func markApplied(harness: Harness, threadId: String, messageId: String) throws {
        guard harness.store.messages(threadId).first(where: { $0["id"]?.string == messageId })?["review"] != nil else {
            throw HTTPError(404, "no such review")
        }
        _ = harness.store.patchMessage(threadId, messageId, ["review": ["applied": true]])
    }

    func stopAll() {
        for stop in Array(stoppers.values) { stop() }
    }
}
