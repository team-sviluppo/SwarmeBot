// OAuth for HTTP connectors (docs/plans/2026-10-15-connettori-mcp.md, phase 4),
// as the MCP authorization spec lays it out; discovery, registration, PKCE and
// the token requests are `OAuthFlow` (AgentCore), this is the engine's half:
//
// 1. discovery — the server's 401 names its protected-resource metadata
//    (RFC 9728), which names the authorization server, whose own metadata
//    (RFC 8414, or OpenID's) gives the endpoints. A server from before that
//    spec is its own authorization server, at /authorize /token /register;
// 2. a client — registered on the fly (RFC 7591) as a public client, unless
//    the user typed a client id;
// 3. the login — authorization code with PKCE (S256) and `resource`
//    (RFC 8707), in the user's browser, back to the engine's loopback
//    callback `/oauth/mcp/callback`;
// 4. tokens — kept in the connectors' secrets file, refreshed before they
//    expire and once more on a 401.
//
// The engine holds the tokens: a bot's CLI never sees one, and changing
// harness never means logging in again.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
public final class MCPOAuth {
    typealias Endpoints = OAuthEndpoints
    typealias Tokens = OAuthTokens

    struct Pending {
        var connectorId: String
        var verifier: String
        var redirectUri: String
        var clientId: String
        var clientSecret: String?
        var endpoints: Endpoints
        var resource: String
        var created: Date
    }

    static let callbackPath = "/oauth/mcp/callback"
    /// A login left open longer than this is forgotten.
    static let pendingLifetime: TimeInterval = 600
    /// Refresh this long before the access token says it expires — or a
    /// quarter of its life, for tokens that live less than four minutes.
    static let refreshMargin: TimeInterval = 60

    private let registry: MCPConnectors
    private let session: URLSession
    private var pending: [String: Pending] = [:]
    private var refreshing: [String: Task<String, Error>] = [:]
    /// The engine's base URL, for the redirect: it moves with the port.
    var baseURL: () -> String

    init(registry: MCPConnectors, session: URLSession = .shared, baseURL: @escaping () -> String) {
        self.registry = registry
        self.session = session
        self.baseURL = baseURL
    }

    /// On `localhost`, not `127.0.0.1`: some providers (Meta) refuse an IP
    /// address among an app's domains and redirects.
    var redirectUri: String {
        baseURL().replacingOccurrences(of: "://127.0.0.1:", with: "://localhost:") + Self.callbackPath
    }

    /// The redirect a connector's login uses: the one typed for it — an HTTPS
    /// page that forwards to the engine's callback, for providers that refuse
    /// a loopback redirect once their app is published — or the engine's own.
    func redirectUri(for id: String) -> String {
        registry.connector(id)?["oauth"]?["redirectUri"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? redirectUri
    }

    // MARK: Login

    /// Discover, register if needed, and return the URL to open in the browser.
    public func start(_ id: String) async throws -> URL {
        guard let record = registry.connector(id), record["auth"]?.string == "oauth",
              let raw = record["url"]?.string, let serverURL = URL(string: raw) else {
            throw MCPOAuthError("questo connettore non usa OAuth")
        }
        let discovery = try await OAuthFlow.discover(serverURL, session: session)
        let redirect = redirectUri(for: id)
        var clientId = record["oauth"]?["clientId"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        var clientSecret = clientId != nil ? registry.oauthSecrets(id)["clientSecret"]?.string : nil
        if clientId == nil {
            // a client registered for this server and this redirect is reused
            let known = record["oauthClient"]
            if known?["issuer"]?.string == discovery.endpoints.issuer, known?["redirectUri"]?.string == redirect,
               let registered = known?["clientId"]?.string {
                clientId = registered
                clientSecret = registry.oauthSecrets(id)["registeredSecret"]?.string
            } else {
                guard let endpoint = discovery.endpoints.registration else {
                    throw MCPOAuthError("il server non permette la registrazione automatica: inserisci un Client ID nelle impostazioni del connettore (redirect: \(redirect))")
                }
                let registered: (clientId: String, clientSecret: String?)
                do {
                    registered = try await OAuthFlow.register(endpoint, redirect: redirect, scope: discovery.scope, session: session)
                } catch let error as MCPOAuthError {
                    // some providers (Meta) keep registration for clients they list:
                    // say what to do, not only what the server answered
                    let reason = error.message.hasSuffix(".") ? String(error.message.dropLast()) : error.message
                    throw MCPOAuthError("\(reason). Crea un'app presso il servizio, registra questo redirect e inserisci il suo Client ID in \"Client registrato a mano\" (redirect: \(redirect))")
                }
                clientId = registered.clientId
                clientSecret = registered.clientSecret
                registry.setOAuthClient(id, ["clientId": .string(registered.clientId), "issuer": .string(discovery.endpoints.issuer),
                                             "redirectUri": .string(redirect)])
                var secrets = registry.oauthSecrets(id)
                secrets["registeredSecret"] = registered.clientSecret.map(JSON.string)
                registry.setOAuthSecrets(id, secrets)
            }
        }
        guard let clientId else { throw MCPOAuthError("nessun client OAuth") }

        let verifier = OAuthFlow.randomToken(32)
        let state = OAuthFlow.randomToken(24)
        let cutoff = Date().addingTimeInterval(-Self.pendingLifetime)
        pending = pending.filter { $0.value.created > cutoff }
        pending[state] = Pending(connectorId: id, verifier: verifier, redirectUri: redirect, clientId: clientId, clientSecret: clientSecret,
                                 endpoints: discovery.endpoints, resource: discovery.resource, created: Date())
        let scope = record["oauth"]?["scope"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? discovery.scope
        return try OAuthFlow.authorizationURL(discovery, clientId: clientId, redirect: redirect, state: state, verifier: verifier, scope: scope)
    }

    /// The browser is back. Returns the connector id and a sentence for the page.
    public func complete(state: String, code: String?, error: String?) async -> (id: String?, ok: Bool, message: String) {
        guard let login = pending.removeValue(forKey: state), login.created > Date().addingTimeInterval(-Self.pendingLifetime) else {
            return (nil, false, "Questo accesso non è più valido: riprova da SwarmeBot.")
        }
        if let error { return (login.connectorId, false, "Il server ha rifiutato l'accesso (\(error)).") }
        guard let code, !code.isEmpty else { return (login.connectorId, false, "Il server non ha restituito un codice.") }
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": login.redirectUri,
                    "client_id": login.clientId, "code_verifier": login.verifier, "resource": login.resource]
        if let secret = login.clientSecret { form["client_secret"] = secret }
        do {
            let tokens = try await OAuthFlow.tokenRequest(login.endpoints.token, form, session: session)
            store(tokens, id: login.connectorId, endpoints: login.endpoints, clientId: login.clientId, resource: login.resource)
            return (login.connectorId, true, "Connesso. Puoi chiudere questa finestra e tornare a SwarmeBot.")
        } catch {
            return (login.connectorId, false, "Scambio del codice non riuscito: \(error.localizedDescription)")
        }
    }

    public func logout(_ id: String) {
        var secrets = registry.oauthSecrets(id)
        for key in ["access", "refresh", "expiresAt", "issuedAt"] { secrets[key] = nil }
        registry.setOAuthSecrets(id, secrets)
        var client = registry.connector(id)?["oauthClient"]?.object ?? JSONObject()
        client["tokenEndpoint"] = nil
        registry.setOAuthClient(id, client.isEmpty ? nil : client)
    }

    // MARK: Tokens

    /// The access token to send, refreshed when it is about to expire or
    /// when `force` (the server just said 401). Nil for a connector without OAuth.
    public func token(_ spec: MCPConnectorSpec, force: Bool = false) async throws -> String? {
        guard spec.oauth else { return nil }
        let secrets = registry.oauthSecrets(spec.id)
        guard let access = secrets["access"]?.string else {
            throw MCPOAuthError("accesso OAuth non effettuato: premi «Accedi» nelle impostazioni del connettore \(spec.name)")
        }
        let expiresAt = secrets["expiresAt"]?.double
        let issuedAt = secrets["issuedAt"]?.double ?? 0
        let margin = expiresAt.map { min(Self.refreshMargin, max(0, $0 - issuedAt) / 4) } ?? 0
        let fresh = expiresAt.map { $0 - Date().timeIntervalSince1970 > margin } ?? true
        if fresh, !force { return access }
        return try await refresh(spec)
    }

    private func refresh(_ spec: MCPConnectorSpec) async throws -> String {
        if let running = refreshing[spec.id] { return try await running.value }
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let secrets = self.registry.oauthSecrets(spec.id)
            let client = self.registry.connector(spec.id)?["oauthClient"]
            guard let refreshToken = secrets["refresh"]?.string, let endpoint = client?["tokenEndpoint"]?.string,
                  let clientId = client?["tokenClientId"]?.string else {
                throw MCPOAuthError("l'accesso OAuth a \(spec.name) è scaduto: premi «Accedi» nelle impostazioni del connettore")
            }
            var form = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId]
            if let resource = client?["resource"]?.string { form["resource"] = resource }
            if let secret = secrets["clientSecret"]?.string ?? secrets["registeredSecret"]?.string { form["client_secret"] = secret }
            do {
                let tokens = try await OAuthFlow.tokenRequest(endpoint, form, session: self.session)
                var updated = secrets
                updated["access"] = .string(tokens.access)
                if let newRefresh = tokens.refresh { updated["refresh"] = .string(newRefresh) }
                updated["expiresAt"] = tokens.expiresIn.map { .number(Date().addingTimeInterval($0).timeIntervalSince1970) }
                updated["issuedAt"] = .number(Date().timeIntervalSince1970)
                self.registry.setOAuthSecrets(spec.id, updated)
                return tokens.access
            } catch {
                // a refused refresh token is gone for good: log in again
                var cleared = secrets
                for key in ["access", "refresh", "expiresAt", "issuedAt"] { cleared[key] = nil }
                self.registry.setOAuthSecrets(spec.id, cleared)
                throw MCPOAuthError("l'accesso OAuth a \(spec.name) è scaduto (\(error.localizedDescription)): premi «Accedi» nelle impostazioni del connettore")
            }
        }
        refreshing[spec.id] = task
        defer { refreshing[spec.id] = nil }
        return try await task.value
    }

    private func store(_ tokens: Tokens, id: String, endpoints: Endpoints, clientId: String, resource: String) {
        var secrets = registry.oauthSecrets(id)
        secrets["access"] = .string(tokens.access)
        secrets["refresh"] = tokens.refresh.map(JSON.string)
        secrets["expiresAt"] = tokens.expiresIn.map { .number(Date().addingTimeInterval($0).timeIntervalSince1970) }
        secrets["issuedAt"] = .number(Date().timeIntervalSince1970)
        registry.setOAuthSecrets(id, secrets)
        var client = registry.connector(id)?["oauthClient"]?.object ?? JSONObject()
        client["issuer"] = .string(endpoints.issuer)
        client["tokenEndpoint"] = .string(endpoints.token)
        client["tokenClientId"] = .string(clientId)
        client["resource"] = .string(resource)
        registry.setOAuthClient(id, client)
    }
}
