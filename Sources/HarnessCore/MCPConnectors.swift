// Connectors: the MCP servers the user adds once and hands to bots
// (docs/plans/2026-10-15-connettori-mcp.md).
//
// Two files in the data dir:
//
// - `mcp-connectors.json` — the definitions, records as JSON objects so a
//   field this build does not know survives every write;
// - `mcp-connector-secrets.json` (0600) — `{id: {env: {NAME: value},
//   headers: {Name: value}, oauth: {access, refresh, expiresAt, clientSecret,
//   registeredSecret}}}`. A secret value is never in the first file, never
//   in an API answer and never in a log.
//
// An env or header value in a definition is either a plain string or
// `{"secret": true}`, which points at the second file.
import Foundation

public struct MCPConnectorSpec: Equatable, Sendable {
    public enum Transport: String, Sendable { case stdio, http }

    public var id: String
    public var name: String
    public var transport: Transport
    public var command: String
    public var args: [String]
    public var cwd: String?
    public var env: [String: String]
    public var url: URL?
    public var headers: [String: String]
    public var toolTimeout: TimeInterval
    /// `tools.mode` and `tools.names`: which tools bots get to see.
    public var toolMode: String
    public var toolNames: Set<String>

    public func allows(tool name: String) -> Bool {
        switch toolMode {
        case "allow": return toolNames.contains(name)
        case "deny": return !toolNames.contains(name)
        default: return true
        }
    }

    /// The connector logs in with OAuth (phase 4): the engine adds the bearer token.
    public var oauth = false

    /// Every secret this spec carries, for scrubbing logs.
    var secretValues: [String] = []
}

public struct MCPConnectorInvalid: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor
public final class MCPConnectors {
    public private(set) var connectors: [JSONObject] = []
    private var secrets: [String: JSONObject] = [:]
    private let paths: DataPaths

    static let idPattern = #"^[a-z][a-z0-9_]{1,23}$"#
    /// Mount names the engine already uses, or keeps for itself (`import` is a route).
    static let reservedIds: Set<String> = ["agents", "computer", "ogb", "swarme", "import"]
    static let maxConnectors = 100
    static let defaultToolTimeout = 120.0

    public init(paths: DataPaths) {
        self.paths = paths
        connectors = FileIO.readJSON(file)?.array?.compactMap(\.object) ?? []
        for (id, value) in FileIO.readJSON(secretsFile)?.object ?? JSONObject() {
            if let object = value.object { secrets[id] = object }
        }
    }

    var file: URL { paths.root.appendingPathComponent("mcp-connectors.json") }
    var secretsFile: URL { paths.root.appendingPathComponent("mcp-connector-secrets.json") }

    public func connector(_ id: String) -> JSONObject? { connectors.first { $0["id"]?.string == id } }

    // MARK: Reading out

    /// The record as the API shows it: secrets become `{secret: true, set}`.
    public func wire(_ connector: JSONObject) -> JSON {
        var out = connector
        let id = connector["id"]?.string ?? ""
        for kind in ["env", "headers"] {
            guard let map = connector[kind]?.object else { continue }
            var shown = JSONObject()
            for (name, value) in map {
                if value["secret"]?.bool == true {
                    let set = secrets[id]?[kind]?[name]?.string?.isEmpty == false
                    shown[name] = ["secret": true, "set": .bool(set)]
                } else {
                    shown[name] = value
                }
            }
            out[kind] = .object(shown)
        }
        if var oauth = connector["oauth"]?.object, oauth["clientSecret"] != nil {
            oauth["clientSecret"] = ["secret": true, "set": .bool(secrets[id]?["oauth"]?["clientSecret"]?.string?.isEmpty == false)]
            out["oauth"] = .object(oauth)
        }
        if connector["auth"]?.string == "oauth" {
            let tokens = secrets[id]?["oauth"]
            let expiresAt = tokens?["expiresAt"]?.double
            let status: String
            if tokens?["access"]?.string == nil { status = "disconnected" }
            else if let expiresAt, expiresAt < Date().timeIntervalSince1970, tokens?["refresh"]?.string == nil { status = "expired" }
            else { status = "connected" }
            var state: JSONObject = ["status": .string(status)]
            if let expiresAt { state["expiresAt"] = .number(expiresAt) }
            out["oauthState"] = .object(state)
        }
        return .object(out)
    }

    public var wireList: JSON { .array(connectors.map(wire)) }

    /// What a client needs to connect: the record with its secrets filled in.
    public func spec(_ id: String) -> MCPConnectorSpec? {
        guard let record = connector(id) else { return nil }
        var secretValues: [String] = []
        func resolve(_ kind: String) -> [String: String] {
            var out: [String: String] = [:]
            for (name, value) in record[kind]?.object ?? JSONObject() {
                if value["secret"]?.bool == true {
                    if let secret = secrets[id]?[kind]?[name]?.string, !secret.isEmpty {
                        out[name] = secret
                        secretValues.append(secret)
                    }
                } else if let plain = value.string {
                    out[name] = plain
                }
            }
            return out
        }
        let env = resolve("env")
        let headers = resolve("headers")
        var spec = MCPConnectorSpec(
            id: id,
            name: record["name"]?.string ?? id,
            transport: MCPConnectorSpec.Transport(rawValue: record["transport"]?.string ?? "") ?? .stdio,
            command: record["command"]?.string ?? "",
            args: record["args"]?.array?.compactMap(\.string) ?? [],
            cwd: record["cwd"]?.string,
            env: env,
            url: record["url"]?.string.flatMap(URL.init(string:)),
            headers: headers,
            toolTimeout: record["toolTimeoutSeconds"]?.double ?? Self.defaultToolTimeout,
            toolMode: record["tools"]?["mode"]?.string ?? "all",
            toolNames: Set(record["tools"]?["names"]?.array?.compactMap(\.string) ?? [])
        )
        spec.oauth = record["auth"]?.string == "oauth"
        for key in ["access", "refresh", "clientSecret", "registeredSecret"] {
            if let value = secrets[id]?["oauth"]?[key]?.string { secretValues.append(value) }
        }
        spec.secretValues = secretValues
        return spec
    }

    // MARK: Changing

    /// Create from an API body. Returns the stored record.
    @discardableResult
    public func create(_ body: JSONObject) throws -> JSONObject {
        guard connectors.count < Self.maxConnectors else { throw MCPConnectorInvalid("al massimo \(Self.maxConnectors) connettori") }
        let id = body["id"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        guard id.range(of: Self.idPattern, options: .regularExpression) != nil else {
            throw MCPConnectorInvalid("id must be 2–24 characters: lowercase letters, digits and _, starting with a letter")
        }
        guard !Self.reservedIds.contains(id) else { throw MCPConnectorInvalid("id \(id) is reserved") }
        guard connector(id) == nil else { throw MCPConnectorInvalid("a connector with id \(id) already exists") }
        let (record, secretValues) = try Self.validate(body, id: id, previousSecrets: nil)
        var stamped = record
        stamped["createdAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        connectors.append(stamped)
        secrets[id] = secretValues
        try save()
        return stamped
    }

    /// Replace a definition. Secrets sent as `{secret: true}` without a
    /// value keep what is stored; names left out are dropped.
    @discardableResult
    public func update(_ id: String, _ body: JSONObject) throws -> JSONObject? {
        guard let index = connectors.firstIndex(where: { $0["id"]?.string == id }) else { return nil }
        var (record, secretValues) = try Self.validate(body, id: id, previousSecrets: secrets[id])
        let before = connectors[index]
        // another server, another client or no OAuth at all: the login was for something else
        let sameLogin = before["url"] == record["url"] && before["auth"] == record["auth"]
            && before["oauth"]?["clientId"] == record["oauth"]?["clientId"] && record["auth"]?.string == "oauth"
        if sameLogin, let previous = secrets[id]?["oauth"]?.object {
            var oauth = secretValues["oauth"]?.object ?? JSONObject()
            for key in ["access", "refresh", "expiresAt", "issuedAt", "registeredSecret"] where previous[key] != nil { oauth[key] = previous[key] }
            secretValues["oauth"] = .object(oauth)
        }
        // the definition is replaced whole; createdAt, lastCheck and unknown fields stay
        var merged = before
        for (key, value) in record { merged[key] = value }
        if !sameLogin { merged["oauthClient"] = nil }
        connectors[index] = merged
        secrets[id] = secretValues
        try save()
        return merged
    }

    public func delete(_ id: String) throws -> Bool {
        guard connector(id) != nil else { return false }
        connectors.removeAll { $0["id"]?.string == id }
        secrets[id] = nil
        try save()
        return true
    }

    // MARK: OAuth state (MCPOAuth.swift)

    func oauthSecrets(_ id: String) -> JSONObject { secrets[id]?["oauth"]?.object ?? JSONObject() }

    func setOAuthSecrets(_ id: String, _ values: JSONObject) {
        guard connector(id) != nil else { return }
        var entry = secrets[id] ?? JSONObject()
        entry["oauth"] = values.isEmpty ? Optional<JSON>.none : .object(values)
        secrets[id] = entry
        try? save()
    }

    /// What the engine learned about the login: client, issuer, token endpoint.
    func setOAuthClient(_ id: String, _ values: JSONObject?) {
        guard let index = connectors.firstIndex(where: { $0["id"]?.string == id }) else { return }
        connectors[index]["oauthClient"] = values.map(JSON.object)
        try? save()
    }

    /// The outcome of "Prova connessione".
    public func setLastCheck(_ id: String, _ check: JSONObject) {
        guard let index = connectors.firstIndex(where: { $0["id"]?.string == id }) else { return }
        connectors[index]["lastCheck"] = .object(check)
        try? save()
    }

    private func save() throws {
        try FileIO.writeAtomic(Data(JSON.array(connectors.map(JSON.object)).pretty().utf8), to: file)
        var out = JSONObject()
        for (id, value) in secrets.sorted(by: { $0.key < $1.key }) where !value.isEmpty { out[id] = .object(value) }
        try FileIO.writeAtomic(Data(JSON.object(out).pretty().utf8), to: secretsFile, mode: 0o600)
    }

    // MARK: Validation

    static let envName = #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#
    static let headerName = #"^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,128}$"#
    /// Headers the transport sets itself.
    static let reservedHeaders: Set<String> = ["content-type", "accept", "mcp-session-id", "mcp-protocol-version", "content-length", "host"]

    /// The record to store and the secrets that go with it.
    static func validate(_ body: JSONObject, id: String, previousSecrets: JSONObject?) throws -> (JSONObject, JSONObject) {
        var record = JSONObject()
        record["id"] = .string(id)
        let name = (body["name"]?.string ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw MCPConnectorInvalid("name must be 1–60 characters") }
        record["name"] = .string(name)

        guard let transport = body["transport"]?.string, ["stdio", "http"].contains(transport) else {
            throw MCPConnectorInvalid("transport must be stdio or http")
        }
        record["transport"] = .string(transport)
        if transport == "stdio" {
            let command = body["command"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !command.isEmpty, command.count <= 1024 else { throw MCPConnectorInvalid("command is required for a stdio connector") }
            record["command"] = .string(command)
            let args = body["args"]?.array ?? []
            guard args.count <= 100, args.allSatisfy({ ($0.string?.count ?? 5000) <= 4096 }) else {
                throw MCPConnectorInvalid("args must be a list of at most 100 strings")
            }
            record["args"] = .array(args)
            if let cwd = body["cwd"]?.string, !cwd.isEmpty {
                guard cwd.hasPrefix("/") || cwd.hasPrefix("~") else { throw MCPConnectorInvalid("cwd must be an absolute path") }
                record["cwd"] = .string((cwd as NSString).expandingTildeInPath)
            } else {
                record["cwd"] = .null
            }
            record["url"] = .null
        } else {
            let raw = body["url"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
                throw MCPConnectorInvalid("url must be an http(s) URL")
            }
            guard scheme == "https" || (scheme == "http" && isLocalHost(host)) else {
                throw MCPConnectorInvalid("url must be https (http only for this Mac or the local network)")
            }
            record["url"] = .string(raw)
            record["command"] = .null
            record["args"] = .array([])
            record["cwd"] = .null
        }

        var stored = JSONObject()
        for (kind, pattern) in [("env", envName), ("headers", headerName)] {
            var shown = JSONObject()
            var hidden = JSONObject()
            let map = body[kind]?.object ?? JSONObject()
            guard map.count <= 50 else { throw MCPConnectorInvalid("\(kind): at most 50 entries") }
            for (entryName, value) in map {
                guard entryName.range(of: pattern, options: .regularExpression) != nil else {
                    throw MCPConnectorInvalid("\(kind): invalid name \(entryName)")
                }
                if kind == "headers", reservedHeaders.contains(entryName.lowercased()) {
                    throw MCPConnectorInvalid("headers: \(entryName) is set by SwarmeBot itself")
                }
                if let plain = value.string {
                    try checkValue(plain, kind, entryName)
                    shown[entryName] = .string(plain)
                } else if value["secret"]?.bool == true {
                    if let secret = value["value"]?.string, !secret.isEmpty {
                        try checkValue(secret, kind, entryName)
                        hidden[entryName] = .string(secret)
                    } else if let kept = previousSecrets?[kind]?[entryName]?.string {
                        hidden[entryName] = .string(kept)
                    }
                    shown[entryName] = ["secret": true]
                } else {
                    throw MCPConnectorInvalid("\(kind).\(entryName) must be a string or {secret: true, value}")
                }
            }
            record[kind] = .object(shown)
            if !hidden.isEmpty { stored[kind] = .object(hidden) }
        }

        let auth = body["auth"]?.string ?? "none"
        guard ["none", "oauth"].contains(auth) else { throw MCPConnectorInvalid("auth must be none or oauth") }
        record["auth"] = .string(auth)
        if auth == "oauth" {
            guard transport == "http" else { throw MCPConnectorInvalid("OAuth needs an http connector") }
            if (body["headers"]?.object ?? JSONObject()).contains(where: { $0.key.lowercased() == "authorization" }) {
                throw MCPConnectorInvalid("headers: Authorization is set by the OAuth login")
            }
            var oauth = JSONObject()
            let clientId = body["oauth"]?["clientId"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            if !clientId.isEmpty {
                guard clientId.count <= 512 else { throw MCPConnectorInvalid("oauth.clientId too long") }
                oauth["clientId"] = .string(clientId)
            }
            let scope = body["oauth"]?["scope"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            if !scope.isEmpty {
                guard scope.count <= 1024, !scope.contains("\n") else { throw MCPConnectorInvalid("oauth.scope too long") }
                oauth["scope"] = .string(scope)
            }
            if let secret = body["oauth"]?["clientSecret"], secret["secret"]?.bool == true {
                let value = secret["value"]?.string ?? previousSecrets?["oauth"]?["clientSecret"]?.string ?? ""
                if !value.isEmpty {
                    try checkValue(value, "oauth", "clientSecret")
                    stored["oauth"] = ["clientSecret": .string(value)]
                }
                oauth["clientSecret"] = ["secret": true]
            }
            record["oauth"] = .object(oauth)
        } else {
            record["oauth"] = .null
        }

        let mode = body["tools"]?["mode"]?.string ?? "all"
        guard ["all", "allow", "deny"].contains(mode) else { throw MCPConnectorInvalid("tools.mode must be all, allow or deny") }
        let names = body["tools"]?["names"]?.array ?? []
        guard names.count <= 500, names.allSatisfy({ $0.string != nil }) else { throw MCPConnectorInvalid("tools.names must be a list of tool names") }
        record["tools"] = ["mode": .string(mode), "names": .strings(Array(Set(names.compactMap(\.string))).sorted())]

        let timeout = body["toolTimeoutSeconds"]?.double ?? defaultToolTimeout
        guard (5...900).contains(timeout) else { throw MCPConnectorInvalid("toolTimeoutSeconds must be 5–900") }
        record["toolTimeoutSeconds"] = .number(timeout.rounded())
        record["enabled"] = .bool(body["enabled"]?.bool ?? true)
        return (record, stored)
    }

    private static func checkValue(_ value: String, _ kind: String, _ name: String) throws {
        guard value.count <= 8192, !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            throw MCPConnectorInvalid("\(kind).\(name): value too long or with a line break")
        }
    }

    /// Loopback, `.local` and private IPv4: where plain http is acceptable.
    static func isLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(lower) || lower.hasSuffix(".local") { return true }
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    // MARK: Import

    /// `{"mcpServers": {...}}` (Claude Desktop, `.mcp.json`) or the bare map,
    /// as create bodies. Values whose name looks like a credential become secrets.
    public static func importBodies(_ json: JSON, existingIds: Set<String>) -> (bodies: [JSONObject], skipped: [JSON]) {
        let map = json["mcpServers"]?.object ?? json.object ?? JSONObject()
        var bodies: [JSONObject] = []
        var skipped: [JSON] = []
        var taken = existingIds.union(reservedIds)
        for (key, value) in map {
            guard let entry = value.object else {
                skipped.append(["name": .string(key), "reason": "not an object"])
                continue
            }
            let id = uniqueId(slug(key), taken: taken)
            taken.insert(id)
            var body: JSONObject = ["id": .string(id), "name": .string(String(key.prefix(60)))]
            let type = entry["type"]?.string?.lowercased() ?? ""
            let url = entry["url"]?.string ?? entry["serverUrl"]?.string
            if let command = entry["command"]?.string, !command.isEmpty, type.isEmpty || type == "stdio" {
                body["transport"] = "stdio"
                body["command"] = .string(command)
                body["args"] = entry["args"] ?? .array([])
                if let cwd = entry["cwd"]?.string { body["cwd"] = .string(cwd) }
            } else if let url, !url.isEmpty {
                if type == "sse" {
                    skipped.append(["name": .string(key), "reason": "il trasporto SSE legacy non è ancora supportato"])
                    continue
                }
                body["transport"] = "http"
                body["url"] = .string(url)
            } else {
                skipped.append(["name": .string(key), "reason": "né command né url"])
                continue
            }
            for kind in ["env", "headers"] {
                var out = JSONObject()
                for (name, raw) in entry[kind]?.object ?? JSONObject() {
                    guard let text = raw.string else { continue }
                    out[name] = looksSecret(name) ? ["secret": true, "value": .string(text)] : .string(text)
                }
                if !out.isEmpty { body[kind] = .object(out) }
            }
            bodies.append(body)
        }
        return (bodies, skipped)
    }

    static func looksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "AUTH", "COOKIE"].contains(where: upper.contains)
    }

    static func slug(_ name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") { out.unicodeScalars.append(scalar) } else if !out.hasSuffix("_") { out += "_" }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if out.first.map({ !$0.isLetter }) ?? true { out = "c_" + out }
        return String(out.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    static func uniqueId(_ base: String, taken: Set<String>) -> String {
        let root = base.count < 2 ? base + "_c" : base
        if !taken.contains(root) { return root }
        for n in 2...999 {
            let candidate = String(root.prefix(24 - String(n).count - 1)) + "_\(n)"
            if !taken.contains(candidate) { return candidate }
        }
        return root
    }
}

// MARK: - Pool

/// One live client per connector, shared by every bot and thread, closed
/// after a while unused (§3.2).
@MainActor
public final class MCPConnectorPool {
    private struct Entry {
        var client: MCPClient
        var spec: MCPConnectorSpec
        var tools: [JSON]?
        var lastUsed: Date
    }

    private var entries: [String: Entry] = [:]
    private var connecting: [String: Task<MCPClient, Error>] = [:]
    /// What every stdio server starts from, before its own env.
    let baseEnvironment: [String: String]
    private let logDir: URL
    private var reaper: Task<Void, Never>?
    var idleSeconds: TimeInterval = 600
    /// The bearer token for an OAuth connector; `true` forces a refresh (the
    /// server just answered 401). Nil result: the connector does not use OAuth.
    public var tokenProvider: ((MCPConnectorSpec, Bool) async throws -> String?)?

    public init(paths: DataPaths, environment: [String: String]) {
        var env = environment
        // a connector is somebody else's code: none of the workspace's keys,
        // none of the engine's own plumbing
        WorkspaceCredentials.strip(&env)
        for key in env.keys where key.hasPrefix("OMB_") || key.hasPrefix("OGB_") { env[key] = nil }
        env["PATH"] = EnvPath.augmented(environment)
        baseEnvironment = env
        logDir = paths.root.appendingPathComponent("logs/mcp", isDirectory: true)
    }

    /// The tools a connector offers bots: the server's list, filtered.
    public func tools(_ spec: MCPConnectorSpec) async throws -> [JSON] {
        try await withFreshLogin(spec) {
            let client = try await self.client(spec)
            if let cached = self.entries[spec.id]?.tools, self.entries[spec.id]?.client === client { return cached }
            let tools = try await client.listTools(timeout: 30).filter { spec.allows(tool: $0["name"]?.string ?? "") }
            if self.entries[spec.id]?.client === client { self.entries[spec.id]?.tools = tools }
            return tools
        }
    }

    /// An OAuth server that answers 401 gets one refreshed token and one more try.
    private func withFreshLogin<T>(_ spec: MCPConnectorSpec, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as MCPError where spec.oauth && error.status == 401 {
            invalidate(spec.id)
            _ = try await tokenProvider?(spec, true)
            return try await body()
        }
    }

    public func call(_ spec: MCPConnectorSpec, tool: String, arguments: JSON) async throws -> JSON {
        guard spec.allows(tool: tool) else { throw MCPError("lo strumento \(tool) è escluso dal filtro del connettore \(spec.name)") }
        return try await withFreshLogin(spec) {
            let client = try await self.client(spec)
            do {
                return try await client.callTool(tool, arguments: arguments, timeout: spec.toolTimeout)
            } catch let error as MCPError where client.closed && error.status == nil {
                // the server died under us: one fresh start, then the error stands
                self.invalidate(spec.id)
                return try await self.client(spec).callTool(tool, arguments: arguments, timeout: spec.toolTimeout)
            }
        }
    }

    /// Drop a connector's client (edited, deleted, broken).
    public func invalidate(_ id: String) {
        connecting[id]?.cancel()
        connecting[id] = nil
        entries.removeValue(forKey: id)?.client.close()
    }

    public func stopAll() {
        reaper?.cancel()
        reaper = nil
        for id in Array(entries.keys) + Array(connecting.keys) { invalidate(id) }
    }

    /// A one-off connection for "Prova connessione": the server's own list,
    /// unfiltered, so the user can choose what to keep.
    public func probe(_ spec: MCPConnectorSpec) async throws -> (server: MCPClient.ServerInfo, tools: [JSON]) {
        do {
            return try await probeOnce(spec, bearer: try await tokenProvider?(spec, false))
        } catch let error as MCPError where spec.oauth && error.status == 401 {
            return try await probeOnce(spec, bearer: try await tokenProvider?(spec, true))
        }
    }

    private func probeOnce(_ spec: MCPConnectorSpec, bearer: String?) async throws -> (server: MCPClient.ServerInfo, tools: [JSON]) {
        let client = makeClient(spec, bearer: bearer)
        defer { client.close() }
        let server = try await client.connect(timeout: spec.transport == .stdio ? 60 : 30)
        let tools = try await client.listTools(timeout: 30)
        return (server, tools)
    }

    private func client(_ spec: MCPConnectorSpec) async throws -> MCPClient {
        if let entry = entries[spec.id] {
            if entry.spec == spec, !entry.client.closed {
                entries[spec.id]?.lastUsed = Date()
                return entry.client
            }
            invalidate(spec.id)
        }
        if let pendingConnect = connecting[spec.id] { return try await pendingConnect.value }
        let task = Task { @MainActor [weak self] () throws -> MCPClient in
            guard let self else { throw CancellationError() }
            let client = self.makeClient(spec, bearer: try await self.tokenProvider?(spec, false))
            do {
                try await client.connect(timeout: spec.transport == .stdio ? 60 : 30)
            } catch {
                client.close()
                throw error
            }
            return client
        }
        connecting[spec.id] = task
        defer { if connecting[spec.id] == task { connecting[spec.id] = nil } }
        let client = try await task.value
        client.onToolsChanged = { [weak self] in self?.entries[spec.id]?.tools = nil }
        client.onClose = { [weak self] _ in
            guard let self, self.entries[spec.id]?.client === client else { return }
            self.entries[spec.id] = nil
        }
        entries[spec.id] = Entry(client: client, spec: spec, tools: nil, lastUsed: Date())
        startReaper()
        return client
    }

    func makeClient(_ spec: MCPConnectorSpec, bearer: String? = nil) -> MCPClient {
        switch spec.transport {
        case .stdio:
            var env = baseEnvironment
            for (key, value) in spec.env { env[key] = value }
            let log = logger(spec)
            return MCPClient.stdio(command: spec.command, args: spec.args, cwd: spec.cwd ?? NSHomeDirectory(), environment: env, log: log)
        case .http:
            var headers = spec.headers
            if let bearer { headers["Authorization"] = "Bearer \(bearer)" }
            return MCPClient.http(url: spec.url ?? URL(string: "https://invalid.invalid")!, headers: headers)
        }
    }

    /// stderr of a stdio server, secrets scrubbed, capped at 1 MB (one old file kept).
    private func logger(_ spec: MCPConnectorSpec) -> (String) -> Void {
        let file = logDir.appendingPathComponent("\(spec.id).log")
        let dir = logDir
        let secrets = spec.secretValues.filter { $0.count >= 4 }
        return { text in
            var line = Redact.text(text)
            for secret in secrets { line = line.replacingOccurrences(of: secret, with: "«redacted»") }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000 {
                let old = file.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: file, to: old)
            }
            FileIO.appendLine(line.trimmingCharacters(in: .newlines), to: file)
        }
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-self.idleSeconds)
                for (id, entry) in self.entries where entry.lastUsed < cutoff { self.invalidate(id) }
                if self.entries.isEmpty {
                    self.reaper = nil
                    return
                }
            }
        }
    }
}
