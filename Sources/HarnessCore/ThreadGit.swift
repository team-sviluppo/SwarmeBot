// The git state of a chat's folder, for "Code mode"
// (`GET /api/threads/:tid/git`): the active branch and the files with
// uncommitted changes.
//
// It lives on the engine because the folder does: on a server it is not on the
// Mac that shows the chat. Reads only, and `GIT_OPTIONAL_LOCKS=0` so that
// looking never takes the index lock away from the agent that is committing.
import Foundation

enum ThreadGit {
    static let maxChanges = 200

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
        guard let folder, let state = await inspect(folder: folder) else { return ["repo": false] }
        let changes: [JSON] = state.changes.map { change in
            let absolute = (state.root as NSString).appendingPathComponent(change.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: absolute))?[.size] as? NSNumber
            return ["path": .string(absolute), "name": .string((change.path as NSString).lastPathComponent),
                    "status": .string(change.status), "bytes": .number(size?.doubleValue ?? 0)]
        }
        return ["repo": true, "root": .string(state.root), "branch": .string(state.branch), "detached": .bool(state.detached),
                "changes": .array(changes)]
    }
}
