// The phone's own bots (plan §4, D5): private to this phone, never synced.
// A bot is an OpenAI-compatible endpoint, Gemma on the phone, or Apple's
// on-device model; its chat and its connectors live here and in the Keychain.
import CompanionCore
import Foundation

enum LocalBotKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// An OpenAI-compatible API (LiteLLM, vLLM, Hermes Agent, a hosted proxy).
    case endpoint
    /// Gemma on the phone, through MLX.
    case gemma
    /// Apple Foundation Models: chat only, no tools (D2).
    case apple

    var id: String { rawValue }

    /// Connectors can be offered to the model (D2: not to Apple's).
    var takesTools: Bool { self != .apple }
}

/// An OpenAI-compatible server (LiteLLM, vLLM, Hermes Agent, a hosted
/// proxy), set once in Impostazioni and chosen by any number of bots.
struct LocalServer: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Up to and including `/v1`.
    var baseUrl: String
    /// Extra headers on every request; values are not secrets (the key is
    /// in the Keychain).
    var headers: [String: String] = [:]
    var createdAt: Date

    var apiKeyAccount: String { "server.\(id).apiKey" }
}

/// What a bot on an OpenAI-compatible server uses of it.
struct EndpointConfig: Codable, Hashable, Sendable {
    /// The `LocalServer`; nil only on bots saved before there were servers.
    var serverId: String?
    var model: String
    /// Send images as `image_url` parts: only the user knows whether the
    /// model behind a compatible API can see.
    var images: Bool = false
    /// Before servers, a bot kept the address and headers itself (and its
    /// key in the Keychain); `LocalBots` moves them to a server at launch.
    var baseUrl: String?
    var headers: [String: String]?
}

struct LocalBot: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: LocalBotKind
    var endpoint: EndpointConfig?
    /// The system prompt; empty means none.
    var instructions: String = ""
    var connectorIds: [String] = []
    /// The Hermes session the first chat continues (later chats keep theirs in `chats`).
    var sessionId: String?
    var createdAt: Date
    /// A mascot palette name (older bots: a hex, shown as blue).
    var color: String = "blue"
    /// The mascot's shape, a `SwarmeSilhouetteData` id; nil on older bots.
    var silhouette: String?
    /// Every chat of this bot, newest first. Nil on bots saved before there
    /// were several: their one chat is keyed by the bot's id.
    var chats: [LocalChatSummary]?
    /// The chat shown; nil is the first one (keyed by the bot's id).
    var currentChat: String?
    /// A reply came while its chat was not on screen.
    var unread: Bool?

    /// Where a bot kept its key before servers.
    var apiKeyAccount: String { "bot.\(id).apiKey" }
    /// Where the shown chat's messages are kept (`LocalMessage.botId`).
    var currentChatKey: String { currentChat ?? id }
}

/// One of a bot's chats, as the chats list shows it.
struct LocalChatSummary: Codable, Hashable, Identifiable, Sendable {
    /// The messages' key; the first chat's is the bot's own id.
    var id: String
    var title: String
    var createdAt: Date
    /// The Hermes session this chat continues.
    var sessionId: String?
}

struct LocalToolCall: Codable, Hashable, Sendable {
    var name: String
    var ok: Bool?
    var input: String?
    var output: String?
}

struct LocalMessage: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case user, bot, tool, note }

    var id: String
    /// The chat this message belongs to (`LocalChatSummary.id`; the bot's id for its first chat).
    var botId: String
    var role: Role
    var text: String
    var at: Date
    /// Images the user attached, as files in the app's attachments folder.
    var images: [String] = []
    /// PDFs the user attached, as their text; nil on older messages.
    var documents: [AttachedDocument]?
    var tool: LocalToolCall?
    /// A reply cut short by stop or by the app going away.
    var interrupted: Bool = false
    /// In a channel, the member that wrote it: a phone bot's id, or a
    /// guest's `RoomGuest.memberId`.
    var from: String?
    /// A guest's reply: its engine's id for it, so the next turn there does
    /// not copy it twice (`ref`).
    var guestRef: String?
}

/// A channel on the phone: its bots, and guests from the paired servers (a
/// mixed channel). They answer one at a time, each with the channel's recent
/// conversation, as the engine's rooms do (Rooms.swift, MixedRooms.swift).
struct LocalRoom: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var memberIds: [String]
    /// Bots of the paired servers; `peerId` is the server's id on this phone.
    var guests: [RoomGuest]?
    /// "everyone" · "mentions" · "member" (`responderBotId`, else the first
    /// member); nil is "member", the engine's default.
    var responder: String?
    var responderBotId: String?
    var createdAt: Date
    /// A reply came while the channel was not on screen.
    var unread: Bool?

    /// Every member's id: the phone's bots, then the guests.
    var allMemberIds: [String] { memberIds + (guests ?? []).map(\.memberId) }

    /// Who answers a message without @mentions.
    var defaultResponders: [String] {
        let all = allMemberIds
        switch responder {
        case "everyone": return all
        case "mentions": return []
        default: return (responderBotId.flatMap { all.contains($0) ? $0 : nil } ?? all.first).map { [$0] } ?? []
        }
    }
}

/// An MCP server over HTTP (D3), with its secrets in the Keychain.
struct LocalConnector: Codable, Hashable, Identifiable, Sendable {
    enum Auth: String, Codable, Sendable { case none, headers, oauth }

    var id: String
    var name: String
    var url: String
    var auth: Auth
    /// Header names; their values are in the Keychain (`headersAccount`).
    var headerNames: [String] = []
    /// A client id typed by hand, for servers without dynamic registration.
    var oauthClientId: String?
    var createdAt: Date

    var headersAccount: String { "connector.\(id).headers" }
    var oauthAccount: String { "connector.\(id).oauth" }
}
