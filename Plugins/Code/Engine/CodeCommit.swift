// Commit, push and pull request, run by the engine as processes — no agent, no terminal —
// (`POST /api/threads/:tid/git/commit`). Where the folder is, which on a server is not the Mac.
import Foundation
import HarnessCore

@MainActor
enum CodeCommit {
    enum Mode: String {
        /// Commit and stop.
        case commit
        /// Commit, then push the current branch (with `-u` when it has no upstream yet).
        case push
        /// Make a new branch, commit on it, push it.
        case newBranch = "push-new-branch"
        /// Commit, push, and open a pull request with `gh`.
        case pullRequest = "pr"
    }

    struct Request {
        var message: String
        /// Paths to take (absolute, or relative to the repo's root); nil takes every change.
        var files: [String]?
        var mode: Mode
        var branch: String?
        var prTitle: String?
        var prBody: String?
    }

    @MainActor private static var running: Set<String> = []

    static func parse(_ body: JSONObject) throws -> Request {
        guard let message = body["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            throw HTTPError(400, "message is required")
        }
        guard let mode = Mode(rawValue: body["mode"]?.string ?? "commit") else {
            throw HTTPError(400, "mode must be commit, push, push-new-branch or pr")
        }
        var files: [String]?
        if let list = body["files"] {
            guard let array = list.array, array.allSatisfy({ $0.string != nil }) else { throw HTTPError(400, "files must be a list of paths") }
            files = array.compactMap(\.string)
            if files?.isEmpty == true { throw HTTPError(400, "no file is selected") }
        }
        let branch = body["branch"]?.string?.trimmingCharacters(in: .whitespaces)
        if mode == .newBranch, branch?.isEmpty != false { throw HTTPError(400, "branch is required to push to a new branch") }
        return Request(message: message, files: files, mode: mode, branch: branch, prTitle: body["prTitle"]?.string, prBody: body["prBody"]?.string)
    }

    /// The title and the body of a pull request from a commit message: its subject, and the rest.
    static func pullRequestText(_ request: Request) -> (title: String, body: String) {
        let lines = request.message.components(separatedBy: "\n")
        let title = request.prTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? lines[0]
        let body = request.prBody ?? lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body)
    }

    static func run(folder: String, request: Request) async throws -> JSON {
        guard let state = await ThreadGit.inspect(folder: folder) else { throw HTTPError(400, "not a git repository") }
        let root = state.root
        guard running.insert(root).inserted else { throw HTTPError(409, "a commit is already running in this repository") }
        defer { running.remove(root) }
        guard !state.changes.isEmpty else { throw HTTPError(400, "nothing to commit") }

        var paths: [String]?
        if let files = request.files {
            paths = try files.map {
                guard let rel = GitDiff.relative($0, root: root) else { throw HTTPError(400, "\($0) is outside the repository") }
                return rel
            }
        }
        if request.mode == .pullRequest, (await CLIProcess.run("gh", ["--version"], environment: GitRun.environment, cwd: root, timeout: 8))?.ok != true {
            throw HTTPError(400, "the GitHub CLI (gh) is not installed on this machine: install it and run `gh auth login`")
        }
        if request.mode == .newBranch, let name = request.branch { try await ThreadGit.createBranch(folder: folder, name: name) }

        // stage what was chosen (deletions included), then commit only that
        let add = await GitRun.git(["add", "-A", "--"] + (paths ?? ["."]), in: root, timeout: 60)
        guard let add else { throw HTTPError(500, "git add did not complete") }
        guard add.ok else { throw HTTPError(409, GitRun.said(add)) }
        // a failing hook says why in its own output, and that is what the person needs to read
        let commit = await GitRun.git(["commit", "-m", request.message] + (paths.map { ["--"] + $0 } ?? []), in: root, timeout: 180)
        guard let commit else { throw HTTPError(500, "git commit did not complete") }
        guard commit.ok else { throw HTTPError(409, GitRun.said(commit)) }
        let sha = await GitRun.text(["rev-parse", "--short", "HEAD"], in: root) ?? ""

        var result: JSONObject = ["ok": true, "commit": .string(sha)]
        var branch = await GitRun.text(["symbolic-ref", "--short", "-q", "HEAD"], in: root) ?? ""
        result["branch"] = .string(branch)
        result["pushed"] = false
        if request.mode != .commit {
            guard !branch.isEmpty else { throw HTTPError(409, "committed \(sha), but a detached HEAD cannot be pushed") }
            do { try await push(root: root, branch: branch) } catch let error as HTTPError {
                throw HTTPError(error.status, "committed \(sha), but the push failed: \(error.message)")
            }
            result["pushed"] = true
        }
        if request.mode == .pullRequest {
            let text = pullRequestText(request)
            let created = await CLIProcess.run("gh", ["pr", "create", "--title", text.title, "--body", text.body], environment: GitRun.environment, cwd: root, timeout: 90)
            guard let created, created.ok else {
                throw HTTPError(409, "committed \(sha) and pushed \(branch), but the pull request failed: \(created.map(GitRun.said) ?? "gh did not complete")")
            }
            result["prUrl"] = created.stdout.split(separator: "\n").last(where: { $0.hasPrefix("http") }).map { .string(String($0)) } ?? .null
        }
        branch = await GitRun.text(["symbolic-ref", "--short", "-q", "HEAD"], in: root) ?? branch
        result["git"] = await ThreadGit.wire(folder: folder)
        return .object(result)
    }

    /// `git push`, with `-u origin <branch>` for a branch that has no upstream yet.
    static func push(root: String, branch: String) async throws {
        let hasUpstream = (await GitRun.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root))?.ok == true
        var args = ["push"]
        if !hasUpstream {
            guard let remote = await GitRun.text(["remote"], in: root)?.split(separator: "\n").first.map(String.init) else {
                throw HTTPError(409, "this repository has no remote to push to")
            }
            args += ["-u", remote, branch]
        }
        guard let output = await GitRun.git(args, in: root, timeout: 180) else { throw HTTPError(504, "git push did not complete") }
        guard output.ok else { throw HTTPError(409, GitRun.said(output)) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
