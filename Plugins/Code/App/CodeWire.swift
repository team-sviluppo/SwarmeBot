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
    public var id: String { ref }
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

    func checkoutBranch(threadId: String, ref: String) async throws -> ThreadGitState {
        try await pluginRequest("POST", "/api/threads/\(threadId)/git/checkout", body: ["ref": ref], as: ThreadGitState.self)
    }
}
