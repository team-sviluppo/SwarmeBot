// The diff of a changed file (`GET /api/threads/:tid/git/diff?path=`): what a commit
// would take, against HEAD, so staged and unstaged edits read as one.
import Foundation
import HarnessCore

enum GitDiff {
    static let maxBytes = 400_000
    static let maxUntracked = 40

    struct Result: Equatable {
        var path: String?
        var diff: String
        var truncated: Bool
        var binary: Bool
    }

    /// A path the client sent (absolute, as `changes` gives it, or relative to the repo's root)
    /// as a path relative to the root; nil when it points outside the repository.
    static func relative(_ path: String, root: String) -> String? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let realRoot = ThreadGit.canonical(root)
        let absolute = path.hasPrefix("/") ? path : (realRoot as NSString).appendingPathComponent(path)
        // the file may not exist (a deleted one): resolve its folder and keep the name
        let folder = ThreadGit.canonical((absolute as NSString).deletingLastPathComponent)
        let resolved = (folder as NSString).appendingPathComponent((absolute as NSString).lastPathComponent)
        guard resolved.hasPrefix(realRoot + "/") else { return nil }
        let rel = String(resolved.dropFirst(realRoot.count + 1))
        return rel.split(separator: "/").contains("..") ? nil : rel
    }

    /// One file's diff, or with `path` nil the whole working tree's.
    @MainActor
    static func diff(root: String, path: String?) async throws -> Result {
        if let path {
            guard let rel = relative(path, root: root) else { throw HTTPError(400, "path is outside the repository") }
            return try await single(root: root, relative: rel)
        }
        var text = try await tracked(root: root, relative: nil)
        var binary = false
        let untracked = await GitRun.text(["ls-files", "-z", "--others", "--exclude-standard"], in: root) ?? ""
        for name in untracked.split(separator: "\0").prefix(maxUntracked).map(String.init) where text.utf8.count < maxBytes {
            let one = await added(root: root, relative: name)
            text += one
            if one.contains("Binary files") { binary = true }
        }
        let cut = truncate(text)
        return Result(path: nil, diff: cut.text, truncated: cut.truncated, binary: binary && cut.text.isEmpty)
    }

    @MainActor
    private static func single(root: String, relative rel: String) async throws -> Result {
        // a git that does not answer is an error, not "no changes"
        guard let known = await GitRun.git(["ls-files", "--error-unmatch", "--", rel], in: root, timeout: 20) else {
            throw HTTPError(504, "git did not answer in time")
        }
        let text = known.ok ? try await tracked(root: root, relative: rel) : await added(root: root, relative: rel)
        let binary = text.hasPrefix("Binary files") || text.contains("\nBinary files ") || text.contains("GIT binary patch")
        if binary { return Result(path: rel, diff: "", truncated: false, binary: true) }
        let cut = truncate(text)
        return Result(path: rel, diff: cut.text, truncated: cut.truncated, binary: false)
    }

    /// Against HEAD; in a repository with no commit yet, what is staged.
    @MainActor
    private static func tracked(root: String, relative rel: String?) async throws -> String {
        let hasHead = (await GitRun.git(["rev-parse", "--verify", "--quiet", "HEAD"], in: root))?.ok == true
        var args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv"] + (hasHead ? ["HEAD"] : ["--cached"])
        if let rel { args += ["--", rel] }
        guard let output = await GitRun.git(args, in: root, timeout: 20) else { throw HTTPError(504, "git did not answer in time") }
        guard output.ok else { throw HTTPError(409, GitRun.said(output)) }
        return output.stdout
    }

    /// A file git does not know yet, as all added lines (`--no-index` exits 1 when files differ).
    @MainActor
    private static func added(root: String, relative rel: String) async -> String {
        let output = await GitRun.git(["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", rel], in: root, timeout: 20)
        return output?.stdout ?? ""
    }

    static func truncate(_ text: String) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        // cut on a line, not in the middle of a character
        let head = String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self)
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        return (lines.joined(separator: "\n") + "\n", true)
    }
}
