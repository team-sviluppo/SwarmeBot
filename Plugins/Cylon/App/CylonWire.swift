// What the Cylon plugin's engine routes answer (Plugins/Cylon/Engine), and the calls to them. Only this
// plugin knows these shapes: the core's client just offers `pluginRequest`.
import CompanionCore
import Foundation
import SwarmeKit

enum CylonPhaseKey {
    static let all = ["spec", "plan", "run", "review", "pull"]

    static func title(_ key: String) -> String {
        switch key {
        case "spec": return tr("Specifica")
        case "plan": return tr("Piano")
        case "run": return tr("Esecuzione")
        case "review": return tr("Revisione")
        case "pull": return tr("Pull request")
        default: return key
        }
    }

    /// The part of the channel's status line that names what the phase does.
    static func verb(_ key: String) -> String {
        switch key {
        case "spec": return tr("Specifica")
        case "plan": return tr("Pianifica")
        case "run": return tr("Esegui")
        case "review": return tr("Rivedi")
        case "pull": return tr("Apri la PR")
        default: return key
        }
    }
}

/// `GET /api/groups/:gid/cylon`: the channel's flow as the engine keeps it.
struct CylonStatus: Decodable, Equatable {
    struct Player: Decodable, Equatable {
        var botId: String
        var name: String?
        /// Whether the bot is a member of this channel.
        var member: Bool
        var skillOnEngine: Bool
        var skillOnBot: Bool
        /// Working in another conversation: the phase cannot go to it now. Absent from an older engine.
        var busy: Bool?
    }

    struct Phase: Decodable, Equatable, Identifiable {
        var key: String
        var skill: String
        var bot: Player?
        /// `pending`, `running`, `done`, `skipped`, `failed`; absent with no ticket.
        var state: String?
        var current: Bool?
        var canRun: Bool?
        var canSkip: Bool?
        var canMarkDone: Bool?
        /// What a click sends, when it can be known.
        var command: String?
        var note: String?
        var id: String { key }

        var isDone: Bool { state == "done" || state == "skipped" }
    }

    struct Pipeline: Decodable, Equatable {
        var ticketId: String
        var tag: String
        var specTicketId: String?
        var title: String?
        var slug: String?
        var prUrl: String?
        var finished: Bool
    }

    struct Source: Decodable, Equatable {
        var id: String
        var name: String?
        var ok: Bool?
        var installed: Bool
        var missing: [SkillSource.Missing]
    }

    var follow: Bool
    var busy: Bool
    var projectId: String?
    var pipeline: Pipeline?
    var phases: [Phase]
    var source: Source?

    var running: Bool { phases.contains { $0.state == "running" } }
    var current: Phase? { phases.first { $0.current == true } }
}

struct CylonProjectName: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
}

extension CompanionClient {
    func cylonStatus(groupId: String) async throws -> CylonStatus {
        try await pluginRequest("GET", "/api/groups/\(groupId)/cylon", as: CylonStatus.self)
    }

    func cylonStart(groupId: String, ticket: String, tag: String, title: String?, replace: Bool) async throws -> CylonStatus {
        var body: [String: Any] = ["ticket": ticket, "tag": tag, "replace": replace]
        if let title, !title.isEmpty { body["title"] = title }
        return try await pluginRequest("POST", "/api/groups/\(groupId)/cylon/start", body: body, as: CylonStatus.self)
    }

    func cylonReset(groupId: String) async throws -> CylonStatus {
        try await pluginRequest("DELETE", "/api/groups/\(groupId)/cylon", as: CylonStatus.self)
    }

    /// `action`: `run`, `skip` or `done`.
    func cylonPhase(groupId: String, phase: String, action: String, slug: String? = nil) async throws -> CylonStatus {
        let body: [String: Any] = slug.map { ["slug": $0] } ?? [:]
        return try await pluginRequest("POST", "/api/groups/\(groupId)/cylon/phases/\(phase)/\(action)", body: body, as: CylonStatus.self)
    }

    /// Project id → phase → bot id.
    func cylonRoles() async throws -> [String: [String: String]] {
        struct Answer: Decodable { var roles: [String: [String: String]] }
        return try await pluginRequest("GET", "/api/cylon/roles", as: Answer.self).roles
    }

    func setCylonRole(project: String, phase: String, botId: String?) async throws {
        let value: Any = botId.map { $0 as Any } ?? NSNull()
        try await pluginRequest("PUT", "/api/cylon/roles/\(project)", body: [phase: value])
    }

    func cylonSourceId() async throws -> String? {
        struct Answer: Decodable { var sourceId: String? }
        return try await pluginRequest("GET", "/api/cylon/settings", as: Answer.self).sourceId
    }

    func setCylonSource(_ id: String?) async throws {
        try await pluginRequest("PUT", "/api/cylon/settings", body: ["sourceId": id.map { $0 as Any } ?? NSNull()])
    }

    func cylonProjects() async throws -> [CylonProjectName] {
        struct Answer: Decodable { var projects: [CylonProjectName] }
        return try await pluginRequest("GET", "/api/projects", as: Answer.self).projects
    }
}
