// Mixed channels (HarnessCore/MixedRooms.swift): a channel hosted on one
// engine, or on the phone, with guests from other engines. The host asks a
// guest's engine for its turn; that engine keeps a mirror of the channel.
import Foundation

/// A member of a channel that lives on another engine.
public struct RoomGuest: Codable, Hashable, Sendable {
    /// The engine, as its host knows it (`PUT /api/peer-engines`).
    public var peerId: String
    public var botId: String
    public var name: String
    public var color: String
    public var title: String?

    public init(peerId: String, botId: String, name: String, color: String, title: String? = nil) {
        self.peerId = peerId
        self.botId = botId
        self.name = name
        self.color = color
        self.title = title
    }

    /// Its id among the room's members (`defaultResponder`, `busyBotId`, `from.botId`).
    public var memberId: String { "peer:\(peerId):\(botId)" }

    var body: [String: Any] {
        var out: [String: Any] = ["peerId": peerId, "botId": botId, "name": name, "color": color]
        if let title, !title.isEmpty { out["title"] = title }
        return out
    }
}

/// What a mirror room knows of the channel it copies.
public struct GuestOf: Codable, Hashable, Sendable {
    public var conversationId: String
    /// The device hosting it: a client hides the mirrors of its own channels.
    public var deviceId: String?
    public var hostName: String?
}

/// One message of the host's conversation, as a guest turn carries it.
public struct GuestMessage: Sendable {
    public var id: String
    public var isUser: Bool
    public var name: String
    public var color: String?
    public var text: String
    /// The guest engine's id for its own reply (`messageId` of an earlier turn).
    public var ref: String?

    public init(id: String, isUser: Bool, name: String, color: String? = nil, text: String, ref: String? = nil) {
        self.id = id
        self.isUser = isUser
        self.name = name
        self.color = color
        self.text = text
        self.ref = ref
    }

    var body: [String: Any] {
        var out: [String: Any] = ["id": id, "role": isUser ? "user" : "bot", "name": name, "text": text]
        if let color { out["color"] = color }
        if let ref { out["ref"] = ref }
        return out
    }
}

public enum GuestTurnResult: Sendable {
    case reply(text: String, messageId: String?)
    /// The bot is in another conversation: skipped this round.
    case busy
}

private struct GuestTurnBody: Decodable {
    var text: String?
    var messageId: String?
}

extension CompanionClient {
    /// One of this engine's bots speaks in a channel hosted elsewhere; answers
    /// when its turn is over, so it may take as long as a room turn may.
    public func guestTurn(conversationId: String, name: String, botId: String, roster: [String], userName: String,
                          hostName: String, messages: [GuestMessage]) async throws -> GuestTurnResult {
        var request = try makeRequest("POST", "/api/guest-turns", body: [
            "conversationId": conversationId, "name": name, "botId": botId, "roster": roster, "userName": userName,
            "hostName": hostName, "messages": messages.map(\.body),
        ])
        request.timeoutInterval = 60 * 60
        do {
            let body = try await send(request, as: GuestTurnBody.self)
            return .reply(text: body.text ?? "", messageId: body.messageId)
        } catch let APIError.status(code, _) where code == 409 {
            return .busy
        }
    }

    public func interruptGuestTurn(conversationId: String) async throws {
        try await send(try makeRequest("POST", "/api/guest-turns/interrupt", body: ["conversationId": conversationId]))
    }

    /// The engines whose bots may be guests in this engine's rooms, replaced
    /// as a whole. Kept in the engine's memory only: hand them over again
    /// whenever it starts.
    public func setPeerEngines(name: String, engines: [(id: String, name: String, url: String, token: String)]) async throws {
        try await send(try makeRequest("PUT", "/api/peer-engines", body: [
            "name": name, "engines": engines.map { ["id": $0.id, "name": $0.name, "url": $0.url, "token": $0.token] },
        ]))
    }
}
