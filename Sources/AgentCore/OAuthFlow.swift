// The protocol half of OAuth for HTTP connectors, as the MCP authorization
// spec lays it out (docs/plans/2026-10-15-connettori-mcp.md, phase 4):
//
// 1. discovery — the server's 401 names its protected-resource metadata
//    (RFC 9728), which names the authorization server, whose own metadata
//    (RFC 8414, or OpenID's) gives the endpoints. A server from before that
//    spec is its own authorization server, at /authorize /token /register;
// 2. a client — registered on the fly (RFC 7591) as a public client;
// 3. the login — authorization code with PKCE (S256) and `resource` (RFC 8707);
// 4. tokens — exchanged and refreshed at the token endpoint.
//
// No storage and no callback here: the engine (`MCPOAuth`) keeps tokens in
// the connectors' secrets file and gets the browser back on its loopback;
// the iOS app keeps them in the Keychain and gets it back from
// ASWebAuthenticationSession.
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

public struct OAuthEndpoints: Sendable, Equatable {
    public var issuer: String
    public var authorization: String
    public var token: String
    public var registration: String?

    public init(issuer: String, authorization: String, token: String, registration: String?) {
        self.issuer = issuer
        self.authorization = authorization
        self.token = token
        self.registration = registration
    }
}

public struct OAuthDiscovery: Sendable, Equatable {
    public var endpoints: OAuthEndpoints
    public var resource: String
    public var scope: String?
}

public struct OAuthTokens: Sendable, Equatable {
    public var access: String
    public var refresh: String?
    public var expiresIn: TimeInterval?
}

public enum OAuthFlow {
    // MARK: Discovery

    public static func discover(_ serverURL: URL, session: URLSession) async throws -> OAuthDiscovery {
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
            return OAuthDiscovery(endpoints: OAuthEndpoints(issuer: metadata["issuer"]?.string ?? issuer, authorization: authorization, token: token,
                                                            registration: metadata["registration_endpoint"]?.string),
                                  resource: resource, scope: scope)
        }
        // the 2025-03-26 fallback: the server is its own authorization server
        return OAuthDiscovery(endpoints: OAuthEndpoints(issuer: issuerOrigin, authorization: "\(issuerOrigin)/authorize", token: "\(issuerOrigin)/token",
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

    // MARK: Client and login

    /// RFC 7591, as a public client.
    public static func register(_ endpoint: String, redirect: String, scope: String?, session: URLSession) async throws -> (clientId: String, clientSecret: String?) {
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

    /// The URL to open in the browser: authorization code, PKCE S256, `resource`.
    public static func authorizationURL(_ discovery: OAuthDiscovery, clientId: String, redirect: String, state: String,
                                        verifier: String, scope: String?) throws -> URL {
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
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        guard let url = components.url else { throw MCPOAuthError("URL di autorizzazione non valido") }
        return url
    }

    // MARK: Tokens

    /// A form POST to the token endpoint: code exchange or refresh.
    public static func tokenRequest(_ endpoint: String, _ form: [String: String], session: URLSession) async throws -> OAuthTokens {
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
        return OAuthTokens(access: access, refresh: json?["refresh_token"]?.string,
                           expiresIn: json?["expires_in"]?.double ?? json?["expires_in"]?.string.flatMap(Double.init))
    }

    // MARK: Helpers

    public static func origin(_ url: URL) -> String {
        var out = "\(url.scheme ?? "https")://\(url.host ?? "")"
        if let port = url.port { out += ":\(port)" }
        return out
    }

    /// RFC 8707's resource: scheme and host lower-case, no fragment, no trailing slash.
    public static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        var out = components.string ?? url.absoluteString
        if out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// `name="value"` out of a WWW-Authenticate header.
    public static func parameter(_ name: String, in header: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|[\s,])"# + name + #"="([^"]*)""#),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        let value = String(header[range])
        return value.isEmpty ? nil : value
    }

    public static func randomToken(_ bytes: Int) -> String {
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
        return base64url(data)
    }

    public static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}
