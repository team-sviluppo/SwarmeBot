// OAuth for HTTP connectors (docs/plans/2026-10-15-connettori-mcp.md, phase 4),
// as the MCP authorization spec lays it out:
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
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MCPOAuthError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor
public final class MCPOAuth {
    struct Endpoints {
        var issuer: String
        var authorization: String
        var token: String
        var registration: String?
    }

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
        let discovery = try await Self.discover(serverURL, session: session)
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
                    registered = try await register(endpoint, redirect: redirect, scope: discovery.scope)
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

        let verifier = Self.randomToken(32)
        let state = Self.randomToken(24)
        let cutoff = Date().addingTimeInterval(-Self.pendingLifetime)
        pending = pending.filter { $0.value.created > cutoff }
        pending[state] = Pending(connectorId: id, verifier: verifier, redirectUri: redirect, clientId: clientId, clientSecret: clientSecret,
                                 endpoints: discovery.endpoints, resource: discovery.resource, created: Date())
        guard var components = URLComponents(string: discovery.endpoints.authorization) else { throw MCPOAuthError("endpoint di autorizzazione non valido") }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: discovery.resource),
        ]
        let scope = record["oauth"]?["scope"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? discovery.scope
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        guard let url = components.url else { throw MCPOAuthError("URL di autorizzazione non valido") }
        return url
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
            let tokens = try await tokenRequest(login.endpoints.token, form)
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
                let tokens = try await self.tokenRequest(endpoint, form)
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

    struct Tokens {
        var access: String
        var refresh: String?
        var expiresIn: TimeInterval?
    }

    private func tokenRequest(_ endpoint: String, _ form: [String: String]) async throws -> Tokens {
        guard let url = URL(string: endpoint) else { throw MCPOAuthError("endpoint dei token non valido") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSON.parse(data)
        guard (200...299).contains(status), let access = json?["access_token"]?.string, !access.isEmpty else {
            let reason = json?["error_description"]?.string ?? json?["error"]?.string ?? "HTTP \(status)"
            throw MCPOAuthError(reason)
        }
        return Tokens(access: access, refresh: json?["refresh_token"]?.string,
                      expiresIn: json?["expires_in"]?.double ?? json?["expires_in"]?.string.flatMap(Double.init))
    }

    private func register(_ endpoint: String, redirect: String, scope: String?) async throws -> (clientId: String, clientSecret: String?) {
        guard let url = URL(string: endpoint) else { throw MCPOAuthError("endpoint di registrazione non valido") }
        var body: JSONObject = [
            "client_name": "SwarmeBot", "redirect_uris": [.string(redirect)],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        if let scope { body["scope"] = .string(scope) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = JSON.object(body).data
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSON.parse(data)
        guard (200...299).contains(status), let clientId = json?["client_id"]?.string else {
            throw MCPOAuthError("registrazione del client non riuscita: \(json?["error_description"]?.string ?? json?["error"]?.string ?? "HTTP \(status)")")
        }
        return (clientId, json?["client_secret"]?.string)
    }

    // MARK: Discovery

    struct Discovery {
        var endpoints: Endpoints
        var resource: String
        var scope: String?
    }

    static func discover(_ serverURL: URL, session: URLSession) async throws -> Discovery {
        // the server's own answer to an unauthenticated request names its metadata
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = JSON.object(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": [
            "protocolVersion": .string(MCPClient.protocolVersion), "capabilities": .object(JSONObject()),
            "clientInfo": ["name": "SwarmeBot", "version": "1"],
        ]]).data
        var challenge = ""
        if let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse {
            challenge = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        }
        let origin = Self.origin(serverURL)
        var metadataURLs: [String] = []
        if let named = Self.parameter("resource_metadata", in: challenge) { metadataURLs.append(named) }
        let path = serverURL.path == "/" ? "" : serverURL.path
        metadataURLs += ["\(origin)/.well-known/oauth-protected-resource\(path)", "\(origin)/.well-known/oauth-protected-resource"]
        var resource = Self.canonical(serverURL)
        var issuer = origin
        var scope = Self.parameter("scope", in: challenge)
        for candidate in metadataURLs {
            guard let metadata = await getJSON(candidate, session: session), let server = metadata["authorization_servers"]?.array?.first?.string else { continue }
            issuer = server
            if let named = metadata["resource"]?.string, !named.isEmpty { resource = named }
            if scope == nil, let scopes = metadata["scopes_supported"]?.array?.compactMap(\.string), !scopes.isEmpty {
                scope = scopes.joined(separator: " ")
            }
            break
        }
        // RFC 8414 puts the issuer's path after the well-known segment
        guard let issuerURL = URL(string: issuer) else { throw MCPOAuthError("server di autorizzazione non valido: \(issuer)") }
        let issuerOrigin = Self.origin(issuerURL)
        let issuerPath = issuerURL.path == "/" ? "" : issuerURL.path
        var candidates = ["\(issuerOrigin)/.well-known/oauth-authorization-server\(issuerPath)",
                          "\(issuerOrigin)/.well-known/openid-configuration\(issuerPath)"]
        if !issuerPath.isEmpty { candidates.append("\(issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer)/.well-known/openid-configuration") }
        for candidate in candidates {
            guard let metadata = await getJSON(candidate, session: session),
                  let authorization = metadata["authorization_endpoint"]?.string, let token = metadata["token_endpoint"]?.string else { continue }
            return Discovery(endpoints: Endpoints(issuer: metadata["issuer"]?.string ?? issuer, authorization: authorization, token: token,
                                                  registration: metadata["registration_endpoint"]?.string),
                             resource: resource, scope: scope)
        }
        // the 2025-03-26 fallback: the server is its own authorization server
        return Discovery(endpoints: Endpoints(issuer: issuerOrigin, authorization: "\(issuerOrigin)/authorize", token: "\(issuerOrigin)/token",
                                              registration: "\(issuerOrigin)/register"),
                         resource: resource, scope: scope)
    }

    private static func getJSON(_ url: String, session: URLSession) async -> JSON? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else { return nil }
        return try? JSON.parse(data)
    }

    // MARK: Helpers

    static func origin(_ url: URL) -> String {
        var out = "\(url.scheme ?? "https")://\(url.host ?? "")"
        if let port = url.port { out += ":\(port)" }
        return out
    }

    /// RFC 8707's resource: scheme and host lower-case, no fragment, no trailing slash.
    static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        var out = components.string ?? url.absoluteString
        if out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// `name="value"` out of a WWW-Authenticate header.
    static func parameter(_ name: String, in header: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s,])"# + name + #"="([^"]*)""#),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        let value = String(header[range])
        return value.isEmpty ? nil : value
    }

    static func randomToken(_ bytes: Int) -> String {
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
        return base64url(data)
    }

    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}
