// The git state of a chat's folder, for "Code mode"
// (`GET /api/threads/:tid/git`): the active branch and the files with
// uncommitted changes.
//
// It lives on the engine because the folder does: on a server it is not on the
// Mac that shows the chat. Inspections use `GIT_OPTIONAL_LOCKS=0` so that
// looking never takes the index lock away from the agent that is committing.
import Foundation
import HarnessCore

enum ThreadGit {
    static let maxChanges = 200
    // Serialize checkout requests for the same repository across suspension points.
    @MainActor private static var switching: Set<String> = []

    @MainActor
    static func branches(folder: String) async throws -> [JSON] {
        let output = await CLIProcess.run("git", ["for-each-ref", "--sort=refname", "--format=%(refname)%09%(symref)", "refs/heads/", "refs/remotes/"],
                                          environment: gitEnvironment, cwd: folder, timeout: 8)
        guard let output, output.ok else { throw HTTPError(400, "could not list git branches") }
        return output.stdout.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1].isEmpty else { return nil }
            let ref = String(fields[0])
            let remote = ref.hasPrefix("refs/remotes/")
            let name = String(ref.dropFirst(remote ? "refs/remotes/".count : "refs/heads/".count))
            return ["ref": .string(ref), "name": .string(name), "remote": .bool(remote)]
        }
    }

    /// Whether a bot (or a routine) works in this repository: git must not move under it.
    @MainActor
    static func botWorking(in root: String, harness: Harness, threadId: String) -> Bool {
        let busyInRepo = harness.store.bots.contains { bot in
            guard Store.isBusy(bot), let tid = bot["threadId"]?.string,
                  let cwd = ThreadFiles.roots(harness.store, harness.paths, threadId: tid)?.first else { return false }
            let resolved = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path
            return resolved == root || resolved.hasPrefix(root + "/")
        }
        return busyInRepo || harness.routines?.isActiveThread(threadId) == true
    }

    private static var gitEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = EnvPath.augmented()
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        return env
    }

    @MainActor
    static func checkout(folder: String, ref: String) async throws {
        guard let state = await inspect(folder: folder) else { throw HTTPError(400, "not a git repository") }
        guard switching.insert(state.root).inserted else { throw HTTPError(409, "a checkout is already running") }
        defer { switching.remove(state.root) }
        let available = try await branches(folder: folder)
        guard let branch = available.first(where: { $0["ref"]?.string == ref }), let name = branch["name"]?.string else {
            throw HTTPError(400, "no such branch")
        }
        // No force, reset or stash: Git refuses when checkout would lose edits.
        var args = ["checkout", name, "--"]
        if branch["remote"]?.bool == true {
            let locals = await CLIProcess.run("git", ["for-each-ref", "--format=%(refname:short)%09%(upstream)", "refs/heads/"],
                                              environment: gitEnvironment, cwd: folder, timeout: 8)
            let tracking = locals?.stdout.split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                return fields.count == 2 && fields[1] == ref ? String(fields[0]) : nil
            }.first
            args = tracking.map { ["checkout", $0, "--"] } ?? ["checkout", "--track", ref, "--"]
        }
        guard let result = await CLIProcess.run("git", args, environment: gitEnvironment, cwd: folder, timeout: 30) else {
            throw HTTPError(500, "git checkout did not complete")
        }
        guard result.ok else { throw HTTPError(409, result.stderr.isEmpty ? result.stdout : result.stderr) }
    }

    struct Change: Equatable {
        var path: String
        /// `M` modified, `A` added, `D` deleted, `R` renamed, `?` untracked.
        var status: String
    }

    struct State {
        var root: String
        var branch: String
        var detached: Bool
        var changes: [Change]
    }

    /// The folder's state, or nil when it is not inside a git work tree (or
    /// git is not installed).
    @MainActor
    static func inspect(folder: String) async -> State? {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = EnvPath.augmented()
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        func git(_ args: [String]) async -> String? {
            guard let output = await CLIProcess.run("git", ["-c", "core.quotePath=false"] + args, environment: environment, cwd: folder, timeout: 8),
                  output.ok else { return nil }
            return output.stdout
        }
        guard let top = await git(["rev-parse", "--show-toplevel"]) else { return nil }
        let root = top.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        var branch = (await git(["symbolic-ref", "--short", "-q", "HEAD"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var detached = false
        if branch.isEmpty {
            detached = true
            branch = (await git(["rev-parse", "--short", "HEAD"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let status = await git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."]) ?? ""
        return State(root: root, branch: branch, detached: detached, changes: parseStatus(status))
    }

    /// `git status --porcelain=v1 -z`: `XY path\0`, and for a rename or copy
    /// the original path as one more entry. Paths are relative to the work
    /// tree's root, whatever the folder git ran in.
    static func parseStatus(_ output: String) -> [Change] {
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [Change] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            index += 1
            guard entry.count > 3 else { continue }
            let code = Array(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            if code.contains("R") || code.contains("C") { index += 1 }
            let status: String
            if code == ["?", "?"] { status = "?" }
            else if code.contains("D") { status = "D" }
            else if code.contains("R") || code.contains("C") { status = "R" }
            else if code.contains("A") { status = "A" }
            else { status = "M" }
            changes.append(Change(path: path, status: status))
            if changes.count == maxChanges { break }
        }
        return changes
    }

    /// The route's answer; the same wire for a folder that is not a repo.
    @MainActor
    static func wire(folder: String?) async -> JSON {
        guard let folder else { return ["repo": false] }
        guard let state = await inspect(folder: folder) else { return ["repo": false, "folder": .string(folder)] }
        let changes: [JSON] = state.changes.map { change in
            let absolute = (state.root as NSString).appendingPathComponent(change.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: absolute))?[.size] as? NSNumber
            return ["path": .string(absolute), "name": .string((change.path as NSString).lastPathComponent),
                    "status": .string(change.status), "bytes": .number(size?.doubleValue ?? 0)]
        }
        return ["repo": true, "folder": .string(folder), "root": .string(state.root), "branch": .string(state.branch), "detached": .bool(state.detached),
                "changes": .array(changes)]
    }
}
