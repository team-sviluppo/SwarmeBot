// What the Code plugin's engine routes answer (Plugins/Code/Engine), and the
// calls to them. Only this plugin knows these shapes: the core's client just
// offers `pluginRequest`.
import CompanionCore
import Foundation

/// The git state of a chat's folder (`GET /api/threads/:tid/git`), as
/// Code mode shows it. `repo == false` for a folder outside any work tree.
public struct ThreadGitState: Decodable, Hashable, Sendable {
    public var folder: String?
    public struct Change: Decodable, Hashable, Sendable, Identifiable {
        public var path: String
        public var name: String
        /// `M` modified, `A` added, `D` deleted, `R` renamed, `?` untracked.
        public var status: String
        public var bytes: Int

        public var id: String { path }
        /// A deleted file has nothing to open.
        public var exists: Bool { status != "D" }
        public var file: ReplyFile { ReplyFile(ref: path, path: path, name: name, bytes: bytes) }
    }

    public var repo: Bool
    public var root: String?
    /// The branch, or the short commit when `detached`.
    public var branch: String?
    public var detached: Bool?
    public var changes: [Change]

    public init(repo: Bool, root: String? = nil, branch: String? = nil, detached: Bool? = nil, changes: [Change] = []) {
        self.repo = repo
        self.root = root
        self.branch = branch
        self.detached = detached
        self.changes = changes
    }

    private enum CodingKeys: String, CodingKey { case repo, folder, root, branch, detached, changes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decodeIfPresent(Bool.self, forKey: .repo) ?? false
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        root = try container.decodeIfPresent(String.self, forKey: .root)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        detached = try container.decodeIfPresent(Bool.self, forKey: .detached)
        changes = try container.decodeIfPresent([Change].self, forKey: .changes) ?? []
    }
}

public struct GitBranch: Decodable, Hashable, Sendable, Identifiable {
    public var ref: String
    public var name: String
    public var remote: Bool
    /// When its last commit was made, in seconds; nil from an engine that does not say.
    public var date: Double?
    public var id: String { ref }
}

/// What continuing a chat in the agent's own CLI takes (`GET /api/threads/:tid/resume-command`).
public struct ResumeCommand: Decodable, Hashable, Sendable {
    public var supported: Bool
    public var tool: String?
    public var folder: String?
    /// A shell command line, to run where the engine runs.
    public var command: String?
    /// Why it cannot, when it cannot.
    public var reason: String?
}

extension CompanionClient {
    /// `GET /api/threads/:tid/git`: the branch and the uncommitted files of
    /// the chat's folder.
    func threadGit(threadId: String) async throws -> ThreadGitState {
        try await pluginRequest("GET", "/api/threads/\(threadId)/git", as: ThreadGitState.self)
    }

    func gitBranches(threadId: String) async throws -> [GitBranch] {
        struct Answer: Decodable { var branches: [GitBranch] }
        return try await pluginRequest("GET", "/api/threads/\(threadId)/git/branches", as: Answer.self).branches
    }

    func createBranch(threadId: String, name: String) async throws -> ThreadGitState {
        try await pluginRequest("POST", "/api/threads/\(threadId)/git/branch", body: ["name": name], as: ThreadGitState.self)
    }

    func resumeCommand(threadId: String) async throws -> ResumeCommand {
        try await pluginRequest("GET", "/api/threads/\(threadId)/resume-command", as: ResumeCommand.self)
    }

    func checkoutBranch(threadId: String, ref: String) async throws -> ThreadGitState {
        try await pluginRequest("POST", "/api/threads/\(threadId)/git/checkout", body: ["ref": ref], as: ThreadGitState.self)
    }
}

/// One file's changes (`GET /api/threads/:tid/git/diff?path=`).
public struct FileDiff: Decodable, Hashable, Sendable {
    public var path: String?
    public var diff: String
    public var truncated: Bool
    public var binary: Bool
}

/// A file the search found (`GET /api/threads/:tid/files?q=`): `path` is the engine's, absolute.
public struct CodeFile: Decodable, Hashable, Sendable, Identifiable {
    public var path: String
    public var relative: String
    public var name: String
    public var id: String { path }
}

public enum CommitMode: String, CaseIterable, Sendable {
    case commit
    case push
    case newBranch = "push-new-branch"
    case pullRequest = "pr"
}

/// What a commit did (`POST /api/threads/:tid/git/commit`).
public struct CommitResult: Decodable, Sendable {
    public var commit: String
    public var branch: String
    public var pushed: Bool
    public var prUrl: String?
    public var git: ThreadGitState?
}

/// The plugin's settings on an engine (`/api/code/settings`).
struct CodeSettingsWire: Decodable {
    struct Pick: Decodable, Equatable { var instanceId: String; var model: String }
    var commitModel: Pick?
}

extension CompanionClient {
    func gitDiff(threadId: String, path: String?) async throws -> FileDiff {
        let query = path.map { [URLQueryItem(name: "path", value: $0)] } ?? []
        return try await pluginRequest("GET", "/api/threads/\(threadId)/git/diff", query: query, as: FileDiff.self)
    }

    func searchFiles(threadId: String, query: String) async throws -> [CodeFile] {
        struct Answer: Decodable { var files: [CodeFile] }
        let items = query.isEmpty ? [] : [URLQueryItem(name: "q", value: query)]
        return try await pluginRequest("GET", "/api/threads/\(threadId)/files", query: items, as: Answer.self).files
    }

    func commitMessage(threadId: String) async throws -> String {
        struct Answer: Decodable { var message: String }
        var request = try await pluginRequest("POST", "/api/threads/\(threadId)/git/commit-message", body: [:], as: Answer.self)
        request.message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return request.message
    }

    func commit(threadId: String, message: String, files: [String]?, mode: CommitMode, branch: String?) async throws -> CommitResult {
        var body: [String: Any] = ["message": message, "mode": mode.rawValue]
        if let files { body["files"] = files }
        if let branch, mode == .newBranch { body["branch"] = branch }
        return try await pluginRequest("POST", "/api/threads/\(threadId)/git/commit", body: body, as: CommitResult.self)
    }

    func codeSettings() async throws -> CodeSettingsWire {
        try await pluginRequest("GET", "/api/code/settings", as: CodeSettingsWire.self)
    }

    func setCommitModel(_ pick: CodeSettingsWire.Pick?) async throws -> CodeSettingsWire {
        let value: Any = pick.map { ["instanceId": $0.instanceId, "model": $0.model] } ?? NSNull()
        return try await pluginRequest("PUT", "/api/code/settings", body: ["commitModel": value], as: CodeSettingsWire.self)
    }
}
