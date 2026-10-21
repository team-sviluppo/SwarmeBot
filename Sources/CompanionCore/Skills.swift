// Skills — instruction folders the user adds once and hands to bots
// (`/api/skills*`, docs/plans/2026-10-21-skill.md). Desktop only. The files
// travel in the request, so the same import works on a remote engine.
import Foundation

public struct Skill: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    /// Every file, relative to the skill's folder.
    public var files: [String]
    public var bytes: Int
    /// What `SKILL.md` costs a prompt.
    public var tokens: Int
    /// Ships something a bot could run, not only text to read.
    public var hasScripts: Bool
    public var updatedAt: Double
}

/// Where the engine keeps the skills.
public struct SkillsFolder: Decodable, Hashable, Sendable {
    public var folder: String
    public var defaultFolder: String
    /// The user moved it away from the default (a shared folder).
    public var custom: Bool
}

/// One file of a skill being imported.
public struct SkillFile: Hashable, Sendable {
    /// Relative to the skill's folder: `SKILL.md`, `scripts/run.py`.
    public var path: String
    public var data: Data
    public var executable: Bool

    public init(path: String, data: Data, executable: Bool) {
        self.path = path
        self.data = data
        self.executable = executable
    }
}

/// A skill handed to a bot, and whether new chats start with it on.
public struct BotSkill: Codable, Hashable, Sendable {
    public var id: String
    public var defaultOn: Bool

    public init(id: String, defaultOn: Bool) {
        self.id = id
        self.defaultOn = defaultOn
    }
}

struct SkillList: Decodable { var skills: [Skill] }
struct SkillResponse: Decodable { var skill: Skill }

extension CompanionClient {
    public func skills() async throws -> [Skill] {
        try await send(try makeRequest("GET", "/api/skills"), as: SkillList.self).skills
    }

    /// Creates the skill, or with `replace` swaps an existing one whole.
    @discardableResult
    public func addSkill(_ files: [SkillFile], replace: Bool) async throws -> Skill {
        let list = files.map { ["path": $0.path, "content": $0.data.base64EncodedString(), "executable": $0.executable] as [String: Any] }
        var request = try makeRequest("POST", "/api/skills", body: ["files": list, "replace": replace])
        request.timeoutInterval = 120
        return try await send(request, as: SkillResponse.self).skill
    }

    /// The skill and the text of its `SKILL.md`.
    public func skillContent(_ id: String) async throws -> (skill: Skill, content: String) {
        struct Answer: Decodable { var skill: Skill; var content: String }
        let answer = try await send(try makeRequest("GET", "/api/skills/\(id)"), as: Answer.self)
        return (answer.skill, answer.content)
    }

    @discardableResult
    public func updateSkill(_ id: String, content: String) async throws -> Skill {
        try await send(try makeRequest("PUT", "/api/skills/\(id)", body: ["content": content]), as: SkillResponse.self).skill
    }

    public func deleteSkill(_ id: String) async throws {
        try await send(try makeRequest("DELETE", "/api/skills/\(id)"))
    }

    public func skillsFolder() async throws -> SkillsFolder {
        try await send(try makeRequest("GET", "/api/skills-folder"), as: SkillsFolder.self)
    }

    /// Nil goes back to the engine's default folder.
    @discardableResult
    public func setSkillsFolder(_ path: String?) async throws -> SkillsFolder {
        try await send(try makeRequest("PUT", "/api/skills-folder", body: ["folder": path.map { $0 as Any } ?? NSNull()]), as: SkillsFolder.self)
    }

    /// Which skills a bot may use.
    @discardableResult
    public func setBotSkills(botId: String, _ skills: [BotSkill]) async throws -> Bot {
        let list = skills.map { ["id": $0.id, "defaultOn": $0.defaultOn] as [String: Any] }
        return try await send(try makeRequest("PATCH", "/api/bots/\(botId)", body: ["skills": list]), as: BotResponse.self).bot
    }

    /// Skill switches that differ from the bot's defaults, for one chat.
    public func setTaskSkills(botId: String, threadId: String, _ overrides: [String: Bool]) async throws {
        try await send(try makeRequest("PATCH", "/api/bots/\(botId)/tasks/\(threadId)", body: ["skills": overrides]))
    }
}
