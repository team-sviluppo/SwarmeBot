// What the Cylon plugin's board routes answer (Plugins/Cylon/Engine/CylonBoards.swift), and the calls to them.
import CompanionCore
import Foundation
import SwarmeKit

/// A job that touches several repositories: tickets in the channels of their repositories, in order of priority.
struct CylonBoardWire: Decodable, Equatable, Identifiable {
    struct Item: Decodable, Equatable, Identifiable {
        struct Channel: Decodable, Equatable {
            var name: String?
            var follows: Bool
        }

        var id: String
        /// The repository's role in the project.
        var role: String
        var groupId: String
        var ticketId: String
        /// `cylon-spec` or `cylon-plan`: where its flow starts.
        var tag: String
        var title: String?
        /// `not-started`, `ready`, `running`, `waiting`, `failed`, `done`, `other-ticket`, `channel-missing`.
        var state: String
        var channel: Channel?
        /// The channel's own status, as its bar reads it.
        var flow: CylonStatus?
        var prUrl: String?

        /// The ticket on ClickUp.
        var url: URL? { URL(string: "https://app.clickup.com/t/\(ticketId)") }
        /// What the channel is working on instead, when it is another ticket.
        var otherTicket: String? { state == "other-ticket" ? flow?.pipeline?.ticketId : nil }
    }

    struct Summary: Decodable, Equatable {
        var total: Int
        var done: Int
        var prOpen: Int
        var running: Int
        var notStarted: Int
        var problems: Int
    }

    struct BusyBot: Decodable, Equatable, Identifiable {
        var botId: String
        var name: String?
        /// The channel it is working in; nil when it works in a chat of its own.
        var channel: String?
        var id: String { botId }
    }

    var id: String
    var projectId: String
    var title: String
    var parentUrl: String?
    var items: [Item]
    var summary: Summary
    var busyBots: [BusyBot]
}

/// A project as the board needs it: its name and the repositories (roles) a ticket can belong to.
struct CylonProject: Decodable, Identifiable, Hashable {
    struct Repo: Decodable, Hashable { var role: String }

    var id: String
    var name: String
    var repos: [Repo]?
}

extension CompanionClient {
    private struct BoardAnswer: Decodable { var board: CylonBoardWire }

    func cylonBoards(projectId: String) async throws -> [CylonBoardWire] {
        struct Answer: Decodable { var boards: [CylonBoardWire] }
        return try await pluginRequest("GET", "/api/cylon/boards", query: [URLQueryItem(name: "projectId", value: projectId)], as: Answer.self).boards
    }

    func createCylonBoard(projectId: String, title: String, parentUrl: String?) async throws -> CylonBoardWire {
        var body: [String: Any] = ["projectId": projectId, "title": title]
        if let parentUrl, !parentUrl.isEmpty { body["parentUrl"] = parentUrl }
        return try await pluginRequest("POST", "/api/cylon/boards", body: body, as: BoardAnswer.self).board
    }

    func updateCylonBoard(_ id: String, _ fields: [String: Any]) async throws -> CylonBoardWire {
        try await pluginRequest("PATCH", "/api/cylon/boards/\(id)", body: fields, as: BoardAnswer.self).board
    }

    func deleteCylonBoard(_ id: String) async throws {
        try await pluginRequest("DELETE", "/api/cylon/boards/\(id)")
    }

    func addCylonBoardItem(_ id: String, role: String, ticket: String, tag: String, title: String?, groupId: String?) async throws -> CylonBoardWire {
        var body: [String: Any] = ["role": role, "ticket": ticket, "tag": tag]
        if let title, !title.isEmpty { body["title"] = title }
        if let groupId { body["groupId"] = groupId }
        return try await pluginRequest("POST", "/api/cylon/boards/\(id)/items", body: body, as: BoardAnswer.self).board
    }

    func removeCylonBoardItem(_ id: String, item: String) async throws -> CylonBoardWire {
        try await pluginRequest("DELETE", "/api/cylon/boards/\(id)/items/\(item)", as: BoardAnswer.self).board
    }

    /// `item` nil starts the first ticket nobody has started, in the order of priority.
    func startCylonBoardItem(_ id: String, item: String?, replace: Bool) async throws -> CylonBoardWire {
        let path = item.map { "/api/cylon/boards/\(id)/items/\($0)/start" } ?? "/api/cylon/boards/\(id)/start-next"
        return try await pluginRequest("POST", path, body: ["replace": replace], as: BoardAnswer.self).board
    }
}

/// The order of a board's tickets after one is dragged.
enum CylonBoardOrder {
    /// `ids` with the one at `source` moved to `destination` (SwiftUI's `onMove` offsets: the position in the list before the move).
    static func moved(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        var out = ids
        let taken = source.sorted().map { out[$0] }
        for index in source.sorted(by: >) { out.remove(at: index) }
        let shift = source.filter { $0 < destination }.count
        out.insert(contentsOf: taken, at: min(max(destination - shift, 0), out.count))
        return out
    }
}

/// The channels a ticket of a repository can go to: those of the project that work on its role, and follow the flow.
@MainActor
enum CylonBoardChannels {
    static func candidates(rooms: [Room], projectId: String, role: String) -> [Room] {
        rooms.filter { room in
            let code = (room.plugins ?? [:]).pluginData("code")
            guard case .string(let project)? = code["projectId"], case .string(let works)? = code["role"] else { return false }
            return project == projectId && works == role && CylonAppPlugin.follows(room)
        }
    }
}
