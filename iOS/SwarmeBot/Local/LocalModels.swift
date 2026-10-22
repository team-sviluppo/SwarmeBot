// The phone's own bots (plan §4, D5): private to this phone, never synced.
// A bot is an OpenAI-compatible endpoint, Gemma on the phone, or Apple's
// on-device model; its chat and its connectors live here and in the Keychain.
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

struct EndpointConfig: Codable, Hashable, Sendable {
    /// Up to and including `/v1`.
    var baseUrl: String
    var model: String
    /// Extra headers on every request; values are not secrets (the key is
    /// in the Keychain).
    var headers: [String: String] = [:]
    /// Send images as `image_url` parts: only the user knows whether the
    /// model behind a compatible API can see.
    var images: Bool = false
}

struct LocalBot: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: LocalBotKind
    var endpoint: EndpointConfig?
    /// The system prompt; empty means none.
    var instructions: String = ""
    var connectorIds: [String] = []
    /// The Hermes session the chat continues, once one was named.
    var sessionId: String?
    var createdAt: Date
    var color: String = "#1084FE"

    var apiKeyAccount: String { "bot.\(id).apiKey" }
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
    var botId: String
    var role: Role
    var text: String
    var at: Date
    /// Images the user attached, as files in the app's attachments folder.
    var images: [String] = []
    var tool: LocalToolCall?
    /// A reply cut short by stop or by the app going away.
    var interrupted: Bool = false
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
