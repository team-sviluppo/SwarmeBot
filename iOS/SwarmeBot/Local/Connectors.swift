// MCP connectors over HTTP for the phone's bots (plan §4.6, D3): one
// AgentCore `MCPClient` per connector, kept while the app runs, with the
// headers or the OAuth token from the Keychain.
import AgentCore
import AuthenticationServices
import Foundation
import UIKit

/// What one turn may call: the bot's connectors.
@MainActor
final class ToolBox {
    struct Result {
        var text: String
        var ok: Bool
    }

    /// What one result may put in the model's context, as in the engine.
    static let maxResultCharacters = 40_000

    let connectors: [LocalConnector]
    private let pool: ConnectorPool

    init(connectors: [LocalConnector], pool: ConnectorPool) {
        self.connectors = connectors
        self.pool = pool
    }

    func tools() async -> (tools: [ChatTool], failures: [String]) {
        var tools: [ChatTool] = []
        var failures: [String] = []
        for connector in connectors {
            do {
                for tool in try await pool.tools(connector) {
                    tools.append(ChatTool(connectorId: connector.id, connectorName: connector.name,
                                          name: tool["name"]?.string ?? "", description: tool["description"]?.string ?? "",
                                          inputSchema: tool["inputSchema"] ?? ["type": "object", "properties": .object(JSONObject())]))
                }
            } catch {
                failures.append("\(connector.name): \(Redact.text(error.localizedDescription))")
            }
        }
        return (tools, failures)
    }

    func call(_ route: ChatTool?, arguments: String) async -> Result {
        guard let route, let connector = connectors.first(where: { $0.id == route.connectorId }) else {
            return Result(text: "Unknown tool.", ok: false)
        }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = trimmed.isEmpty ? .object(JSONObject()) : try? JSON.parse(trimmed), parsed.object != nil else {
            return Result(text: "The arguments are not a valid JSON object: \(trimmed.prefix(200))", ok: false)
        }
        return await call(connector, tool: route.name, arguments: parsed)
    }

    func call(_ connector: LocalConnector, tool: String, arguments: JSON) async -> Result {
        do {
            let result = try await pool.call(connector, tool: tool, arguments: arguments)
            return Result(text: MCPClient.resultText(result, limit: Self.maxResultCharacters), ok: result["isError"]?.bool != true)
        } catch is CancellationError {
            return Result(text: "interrupted", ok: false)
        } catch {
            return Result(text: "\(connector.name) · \(tool): \(Redact.text(error.localizedDescription))", ok: false)
        }
    }
}

@MainActor
final class ConnectorPool {
    private var clients: [String: MCPClient] = [:]
    private var toolCache: [String: [JSON]] = [:]
    let oauth = PhoneOAuth()

    func reset(_ id: String) {
        clients.removeValue(forKey: id)?.close()
        toolCache[id] = nil
    }

    private func headers(_ connector: LocalConnector, force: Bool = false) async throws -> [String: String] {
        switch connector.auth {
        case .none: return [:]
        case .headers: return ConnectorSecrets.headers(connector)
        case .oauth: return ["Authorization": "Bearer \(try await oauth.token(connector, force: force))"]
        }
    }

    private func client(_ connector: LocalConnector, force: Bool = false) async throws -> MCPClient {
        if !force, let known = clients[connector.id], !known.closed { return known }
        clients[connector.id]?.close()
        guard let url = URL(string: connector.url) else { throw MCPError(tr("Indirizzo del connettore non valido.")) }
        let client = MCPClient.http(url: url, headers: try await headers(connector, force: force))
        try await client.connect(timeout: 30)
        client.onToolsChanged = { [weak self] in self?.toolCache[connector.id] = nil }
        clients[connector.id] = client
        return client
    }

    /// Once more with a fresh token when the server says 401.
    private func withClient<T>(_ connector: LocalConnector, _ body: (MCPClient) async throws -> T) async throws -> T {
        do {
            return try await body(try await client(connector))
        } catch let error as MCPError where error.status == 401 && connector.auth == .oauth {
            return try await body(try await client(connector, force: true))
        }
    }

    func tools(_ connector: LocalConnector) async throws -> [JSON] {
        if let cached = toolCache[connector.id] { return cached }
        let tools = try await withClient(connector) { try await $0.listTools(timeout: 30) }
        toolCache[connector.id] = tools
        return tools
    }

    func call(_ connector: LocalConnector, tool: String, arguments: JSON) async throws -> JSON {
        try await withClient(connector) { try await $0.callTool(tool, arguments: arguments, timeout: 300) }
    }

    /// Connect and list: what Impostazioni › Connettori shows as the test.
    func test(_ connector: LocalConnector) async throws -> [String] {
        reset(connector.id)
        return try await tools(connector).compactMap { $0["name"]?.string }
    }
}

/// The values of a connector's headers, in the Keychain as one JSON object.
enum ConnectorSecrets {
    static func headers(_ connector: LocalConnector) -> [String: String] {
        guard let raw = Keychain.get(connector.headersAccount), let json = try? JSON.parse(raw), let object = json.object else { return [:] }
        var out: [String: String] = [:]
        for key in object.keys { if let value = object[key]?.string { out[key] = value } }
        return out
    }

    static func setHeaders(_ headers: [String: String], for connector: LocalConnector) throws {
        var object = JSONObject()
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { object[key] = .string(value) }
        try Keychain.set(JSON.object(object).serialized(), for: connector.headersAccount)
    }

    static func remove(_ connector: LocalConnector) {
        Keychain.remove(connector.headersAccount)
        Keychain.remove(connector.oauthAccount)
    }
}

/// OAuth for the phone's connectors: AgentCore's `OAuthFlow` for discovery,
/// registration, PKCE and tokens; the browser is ASWebAuthenticationSession,
/// back on `swarmebot://oauth/callback`; tokens in the Keychain (plan §4.6).
@MainActor
final class PhoneOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let redirect = "swarmebot://oauth/callback"

    struct Tokens: Codable {
        var access: String
        var refresh: String?
        var expiresAt: Double?
        var issuedAt: Double
        var tokenEndpoint: String
        var clientId: String
        var clientSecret: String?
        var resource: String
    }

    private var refreshing: [String: Task<String, Error>] = [:]

    func tokens(_ connector: LocalConnector) -> Tokens? {
        Keychain.get(connector.oauthAccount).flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
    }

    private func store(_ tokens: Tokens, _ connector: LocalConnector) throws {
        let data = try JSONEncoder().encode(tokens)
        try Keychain.set(String(decoding: data, as: UTF8.self), for: connector.oauthAccount)
    }

    func logout(_ connector: LocalConnector) { Keychain.remove(connector.oauthAccount) }

    /// Discover, register if needed, log in in the browser, keep the tokens.
    func login(_ connector: LocalConnector, session: URLSession = .shared) async throws {
        guard let serverURL = URL(string: connector.url) else { throw MCPOAuthError(tr("Indirizzo del connettore non valido.")) }
        let discovery = try await OAuthFlow.discover(serverURL, session: session)
        var clientId = connector.oauthClientId.flatMap { $0.isEmpty ? nil : $0 }
        var clientSecret: String?
        if clientId == nil {
            guard let endpoint = discovery.endpoints.registration else {
                throw MCPOAuthError(tr("Il server non permette la registrazione automatica: inserisci un Client ID (redirect: %@).", Self.redirect))
            }
            let registered = try await OAuthFlow.register(endpoint, redirect: Self.redirect, scope: discovery.scope, session: session)
            clientId = registered.clientId
            clientSecret = registered.clientSecret
        }
        guard let clientId else { throw MCPOAuthError(tr("Nessun client OAuth.")) }
        let verifier = OAuthFlow.randomToken(32)
        let state = OAuthFlow.randomToken(24)
        let url = try OAuthFlow.authorizationURL(discovery, clientId: clientId, redirect: Self.redirect, state: state,
                                                 verifier: verifier, scope: discovery.scope)
        let callback = try await browser(url)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else { throw MCPOAuthError(tr("Questo accesso non è più valido: riprova.")) }
        if let error = items.first(where: { $0.name == "error" })?.value { throw MCPOAuthError(tr("Il server ha rifiutato l'accesso (%@).", error)) }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MCPOAuthError(tr("Il server non ha restituito un codice."))
        }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                    "client_id": clientId, "code_verifier": verifier, "resource": discovery.resource]
        if let clientSecret { form["client_secret"] = clientSecret }
        let tokens = try await OAuthFlow.tokenRequest(discovery.endpoints.token, form, session: session)
        let now = Date().timeIntervalSince1970
        try store(Tokens(access: tokens.access, refresh: tokens.refresh, expiresAt: tokens.expiresIn.map { now + $0 }, issuedAt: now,
                         tokenEndpoint: discovery.endpoints.token, clientId: clientId, clientSecret: clientSecret,
                         resource: discovery.resource), connector)
    }

    /// The access token, refreshed when it is about to expire or when `force`.
    func token(_ connector: LocalConnector, force: Bool = false) async throws -> String {
        guard let tokens = tokens(connector) else {
            throw MCPOAuthError(tr("Accesso OAuth non effettuato: premi «Accedi» nel connettore %@.", connector.name))
        }
        let margin = tokens.expiresAt.map { min(60, max(0, $0 - tokens.issuedAt) / 4) } ?? 0
        let fresh = tokens.expiresAt.map { $0 - Date().timeIntervalSince1970 > margin } ?? true
        if fresh, !force { return tokens.access }
        if let running = refreshing[connector.id] { return try await running.value }
        let task = Task { @MainActor () throws -> String in
            guard let refresh = tokens.refresh else {
                throw MCPOAuthError(tr("L'accesso OAuth a %@ è scaduto: premi «Accedi» nel connettore.", connector.name))
            }
            var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": tokens.clientId, "resource": tokens.resource]
            if let secret = tokens.clientSecret { form["client_secret"] = secret }
            do {
                let renewed = try await OAuthFlow.tokenRequest(tokens.tokenEndpoint, form, session: .shared)
                let now = Date().timeIntervalSince1970
                var updated = tokens
                updated.access = renewed.access
                if let newRefresh = renewed.refresh { updated.refresh = newRefresh }
                updated.expiresAt = renewed.expiresIn.map { now + $0 }
                updated.issuedAt = now
                try self.store(updated, connector)
                return renewed.access
            } catch {
                // a refused refresh token is gone for good: log in again
                self.logout(connector)
                throw MCPOAuthError(tr("L'accesso OAuth a %@ è scaduto: premi «Accedi» nel connettore.", connector.name))
            }
        }
        refreshing[connector.id] = task
        defer { refreshing[connector.id] = nil }
        return try await task.value
    }

    private func browser(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("swarmebot")) { callback, error in
                if let callback { continuation.resume(returning: callback) } else {
                    continuation.resume(throwing: error ?? MCPOAuthError(tr("Accesso annullato.")))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() { continuation.resume(throwing: MCPOAuthError(tr("Impossibile aprire la pagina di accesso."))) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
