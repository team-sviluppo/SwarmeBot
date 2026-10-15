// Connectors — MCP servers the user adds once and hands to bots
// (`/api/mcp-connectors*`, docs/plans/2026-10-15-connettori-mcp.md §6).
// Desktop only: the harness never sends a secret value back, only whether
// one is set.
import Foundation

public struct MCPConnector: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// "stdio" or "http".
    public var transport: String
    public var command: String?
    public var args: [String]?
    public var cwd: String?
    public var url: String?
    public var env: [String: MCPConnectorValue]?
    public var headers: [String: MCPConnectorValue]?
    public var enabled: Bool?
    public var tools: MCPToolFilter?
    public var toolTimeoutSeconds: Double?
    public var lastCheck: MCPConnectorCheck?

    public var isEnabled: Bool { enabled ?? true }
}

/// An env or header value: plain text, or a secret that is (or is not) set.
public enum MCPConnectorValue: Decodable, Hashable, Sendable {
    case plain(String)
    case secret(set: Bool)

    private struct Secret: Decodable {
        var secret: Bool
        var set: Bool?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .plain(text)
        } else {
            self = .secret(set: (try container.decode(Secret.self)).set ?? false)
        }
    }
}

public struct MCPToolFilter: Decodable, Hashable, Sendable {
    /// "all", "allow" or "deny".
    public var mode: String
    public var names: [String]
}

public struct MCPConnectorCheck: Decodable, Hashable, Sendable {
    public struct Server: Decodable, Hashable, Sendable {
        public var name: String?
        public var version: String?
    }

    public struct Tool: Decodable, Hashable, Identifiable, Sendable {
        public var name: String
        public var description: String?
        public var readOnly: Bool?
        /// Characters of name + description + schema: what a prompt pays.
        public var chars: Int?
        public var id: String { name }
    }

    public var at: String?
    public var ok: Bool
    public var error: String?
    public var server: Server?
    public var tools: [Tool]?
    public var schemaChars: Int?
}

/// What the settings sheet sends. Secrets travel only on the way in.
public struct MCPConnectorInput: Sendable {
    public struct Entry: Hashable, Identifiable, Sendable {
        /// Stable while the row is edited, so a keystroke keeps the focus.
        public let id = UUID()
        public var name: String
        public var value: String
        public var secret: Bool
        /// A stored secret the user did not retype: kept as it is.
        public var keepStored: Bool

        public init(name: String, value: String, secret: Bool, keepStored: Bool = false) {
            self.name = name
            self.value = value
            self.secret = secret
            self.keepStored = keepStored
        }
    }

    public var id: String
    public var name: String
    public var transport: String
    public var command: String
    public var args: [String]
    public var cwd: String
    public var url: String
    public var env: [Entry]
    public var headers: [Entry]
    public var enabled: Bool
    public var toolMode: String
    public var toolNames: [String]
    public var toolTimeoutSeconds: Double

    public init(id: String = "", name: String = "", transport: String = "stdio", command: String = "", args: [String] = [],
                cwd: String = "", url: String = "", env: [Entry] = [], headers: [Entry] = [], enabled: Bool = true,
                toolMode: String = "all", toolNames: [String] = [], toolTimeoutSeconds: Double = 120) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.cwd = cwd
        self.url = url
        self.env = env
        self.headers = headers
        self.enabled = enabled
        self.toolMode = toolMode
        self.toolNames = toolNames
        self.toolTimeoutSeconds = toolTimeoutSeconds
    }

    /// The form for an existing connector.
    public init(_ connector: MCPConnector) {
        func entries(_ map: [String: MCPConnectorValue]?) -> [Entry] {
            (map ?? [:]).sorted { $0.key < $1.key }.map { name, value in
                switch value {
                case let .plain(text): return Entry(name: name, value: text, secret: false)
                case let .secret(set): return Entry(name: name, value: "", secret: true, keepStored: set)
                }
            }
        }
        self.init(id: connector.id, name: connector.name, transport: connector.transport, command: connector.command ?? "",
                  args: connector.args ?? [], cwd: connector.cwd ?? "", url: connector.url ?? "",
                  env: entries(connector.env), headers: entries(connector.headers), enabled: connector.isEnabled,
                  toolMode: connector.tools?.mode ?? "all", toolNames: connector.tools?.names ?? [],
                  toolTimeoutSeconds: connector.toolTimeoutSeconds ?? 120)
    }

    var json: [String: Any] {
        func map(_ entries: [Entry]) -> [String: Any] {
            var out: [String: Any] = [:]
            for entry in entries {
                let name = entry.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                if entry.secret {
                    out[name] = entry.value.isEmpty ? ["secret": true] : ["secret": true, "value": entry.value]
                } else {
                    out[name] = entry.value
                }
            }
            return out
        }
        var body: [String: Any] = [
            "id": id, "name": name, "transport": transport, "enabled": enabled,
            "env": map(env), "headers": map(headers),
            "tools": ["mode": toolMode, "names": toolNames], "toolTimeoutSeconds": toolTimeoutSeconds,
        ]
        if transport == "stdio" {
            body["command"] = command
            body["args"] = args
            body["cwd"] = cwd
        } else {
            body["url"] = url
        }
        return body
    }
}

public struct MCPConnectorImport: Decodable, Sendable {
    public struct Skipped: Decodable, Hashable, Sendable {
        public var name: String?
        public var reason: String?
    }

    public var created: [MCPConnector]
    public var skipped: [Skipped]
}

struct MCPConnectorList: Decodable { var connectors: [MCPConnector] }
struct MCPConnectorResponse: Decodable { var connector: MCPConnector }

extension CompanionClient {
    public func mcpConnectors() async throws -> [MCPConnector] {
        try await send(try makeRequest("GET", "/api/mcp-connectors"), as: MCPConnectorList.self).connectors
    }

    @discardableResult
    public func createMCPConnector(_ input: MCPConnectorInput) async throws -> MCPConnector {
        try await send(try makeRequest("POST", "/api/mcp-connectors", body: input.json), as: MCPConnectorResponse.self).connector
    }

    @discardableResult
    public func updateMCPConnector(_ id: String, _ input: MCPConnectorInput) async throws -> MCPConnector {
        try await send(try makeRequest("PUT", "/api/mcp-connectors/\(id)", body: input.json), as: MCPConnectorResponse.self).connector
    }

    public func deleteMCPConnector(_ id: String) async throws {
        try await send(try makeRequest("DELETE", "/api/mcp-connectors/\(id)"))
    }

    /// Connects and lists the tools; a cold `npx` can take a while.
    @discardableResult
    public func testMCPConnector(_ id: String) async throws -> MCPConnector {
        var request = try makeRequest("POST", "/api/mcp-connectors/\(id)/test")
        request.timeoutInterval = 120
        return try await send(request, as: MCPConnectorResponse.self).connector
    }

    /// `{"mcpServers": {…}}` as Claude Desktop and `.mcp.json` write it.
    public func importMCPConnectors(_ config: [String: Any]) async throws -> MCPConnectorImport {
        try await send(try makeRequest("POST", "/api/mcp-connectors/import", body: config), as: MCPConnectorImport.self)
    }
}
