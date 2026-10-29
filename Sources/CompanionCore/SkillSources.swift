// Skill sources — GitHub folders of skills that the engine keeps installed
// (`/api/skill-sources*`, docs/contract/http-sse.md). Desktop only.
import Foundation

/// Where a skill comes from, when a GitHub source keeps it.
public struct SkillOrigin: Decodable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The commit installed, shortened.
    public var sha: String
}

public struct SkillSource: Decodable, Hashable, Identifiable, Sendable {
    public struct Assign: Decodable, Hashable, Sendable {
        public var all: Bool
        public var botIds: [String]
    }

    public struct Requires: Decodable, Hashable, Sendable {
        public var commands: [String]
        public var connectors: [String]
    }

    public struct Installed: Decodable, Hashable, Sendable {
        public struct Entry: Decodable, Hashable, Sendable {
            public var name: String
            /// False when the skill's folder went missing since.
            public var present: Bool
        }

        public var sha: String
        public var shortSha: String
        public var at: Double
        public var skills: [Entry]
    }

    public struct Updated: Decodable, Hashable, Sendable {
        public var added: [String]
        public var changed: [String]
        public var removed: [String]

        public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }
    }

    /// What the last run found.
    public struct Last: Decodable, Hashable, Sendable {
        public var checkedAt: Double
        public var ok: Bool
        public var error: String?
        public var unchanged: Bool?
        public var held: Bool?
        public var rolledBack: Bool?
        public var updated: Updated?
        public var conflicts: [String]?
    }

    /// Something the skills need that this engine does not have.
    public struct Missing: Decodable, Hashable, Sendable, Identifiable {
        /// `command` or `connector`.
        public var kind: String
        public var name: String
        public var id: String { kind + ":" + name }
    }

    public var id: String
    public var name: String
    /// `owner/name`.
    public var repo: String
    /// The folder inside the repository; empty is its root.
    public var path: String
    public var ref: String
    /// The vault secret that holds the token.
    public var secret: String?
    public var secretPresent: Bool?
    public var enabled: Bool
    public var assign: Assign
    public var requires: Requires
    public var installed: Installed?
    public var previousSha: String?
    public var canRollback: Bool
    public var held: Bool
    public var syncing: Bool
    public var missing: [Missing]
    public var last: Last?
}

struct SkillSourceList: Decodable { var sources: [SkillSource] }
struct SkillSourceResponse: Decodable { var source: SkillSource }

extension CompanionClient {
    public func skillSources() async throws -> [SkillSource] {
        try await send(try makeRequest("GET", "/api/skill-sources"), as: SkillSourceList.self).sources
    }

    @discardableResult
    public func addSkillSource(_ fields: [String: Any]) async throws -> SkillSource {
        try await send(try makeRequest("POST", "/api/skill-sources", body: fields), as: SkillSourceResponse.self).source
    }

    @discardableResult
    public func updateSkillSource(_ id: String, _ fields: [String: Any]) async throws -> SkillSource {
        try await send(try makeRequest("PATCH", "/api/skill-sources/\(id)", body: fields), as: SkillSourceResponse.self).source
    }

    public func deleteSkillSource(_ id: String) async throws {
        try await send(try makeRequest("DELETE", "/api/skill-sources/\(id)"))
    }

    /// Looks for a newer commit and installs it; a failure is in the answer's `last`.
    @discardableResult
    public func syncSkillSource(_ id: String, force: Bool) async throws -> SkillSource {
        var request = try makeRequest("POST", "/api/skill-sources/\(id)/update", body: ["force": force])
        request.timeoutInterval = 240
        return try await send(request, as: SkillSourceResponse.self).source
    }

    @discardableResult
    public func rollbackSkillSource(_ id: String) async throws -> SkillSource {
        try await send(try makeRequest("POST", "/api/skill-sources/\(id)/rollback", body: [:]), as: SkillSourceResponse.self).source
    }
}
