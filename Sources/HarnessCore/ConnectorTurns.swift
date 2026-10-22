// Connectors in a turn (docs/plans/2026-10-15-connettori-mcp.md §4):
//
// - which connectors a turn gets: the bot's list, enabled ones only, each on
//   or off by the conversation's switch or else the bot's default;
// - a grant per turn: a random token the proxies carry back, naming the bot,
//   the thread and exactly those connectors. A bot cannot reach a connector
//   it was not given by guessing an id;
// - `/api/internal/mcp-connectors/<id>/tools|call`, where the proxies land;
// - for an engine that runs the tool loop itself, a `ConnectorGateway`
//   instead of proxies: the same connectors, called in-process.
import Foundation

struct ConnectorGrant {
    /// The header a proxy carries its grant in.
    static let header = "x-connector-grant"

    var botId: String
    var threadId: String
    var connectorIds: Set<String>
    var created: Date
}

extension Harness {
    /// §4.3, without the engine check: the connectors this bot has switched
    /// on for this conversation (`task` nil in a room: the defaults).
    static func activeConnectors(bot: JSONObject, task: JSONObject?, registry: MCPConnectors) -> [MCPConnectorSpec] {
        let overrides = task?["connectors"]?.object
        var seen = Set<String>()
        return (bot["connectors"]?.array ?? []).compactMap { entry in
            guard let id = entry["id"]?.string, seen.insert(id).inserted,
                  let record = registry.connector(id), record["enabled"]?.bool != false else { return nil }
            let on = overrides?[id]?.bool ?? entry["defaultOn"]?.bool ?? true
            return on ? registry.spec(id) : nil
        }
    }

    /// What a turn on `instance` mounts. Empty when the engine cannot take
    /// connectors or none is on — and then nothing about the turn changes.
    func mountConnectors(bot: JSONObject, task: JSONObject?, threadId: String, mount: ConnectorMount) -> [MountedConnector] {
        guard mount == .mcp, let botId = bot["id"]?.string else { return [] }
        let specs = Self.activeConnectors(bot: bot, task: task, registry: mcpConnectors)
        guard !specs.isEmpty else { return [] }
        let grant = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        // a grant outlives its turn only when the turn never settled (a dispatch
        // that failed): a day is long enough for any turn
        let stale = Date().addingTimeInterval(-86_400)
        connectorGrants = connectorGrants.filter { $0.value.created > stale }
        connectorGrants[grant] = ConnectorGrant(botId: botId, threadId: threadId, connectorIds: Set(specs.map(\.id)), created: Date())
        // a cold `npx` takes seconds: start the servers while the CLI boots
        for spec in specs {
            Task { @MainActor [weak self] in _ = try? await self?.mcpPool.tools(spec) }
        }
        let env: JSONObject = [
            "OMB_HARNESS_URL": .string(harnessURL), "OMB_COMMS_TOKEN": .string(commsToken), "OMB_CONNECTOR_GRANT": .string(grant),
        ]
        return specs.map { MountedConnector(name: $0.id, server: MCPServer(command: HelperCommand.executable, args: ["mcp-connector", $0.id], env: env)) }
    }

    /// The in-process side for `.inline` engines. Nil when the engine runs
    /// no tool loop, no connector is on, or the chosen model ignores
    /// client-side tools (a Hermes profile: §5.3).
    func connectorGateway(bot: JSONObject, task: JSONObject?, instance: ProviderInstance, model: String?) -> ConnectorGateway? {
        guard instance.adapter.capabilities.connectors == .inline else { return nil }
        if let model, instance.models.options.first(where: { $0.id == model })?.clientTools == false { return nil }
        let specs = Self.activeConnectors(bot: bot, task: task, registry: mcpConnectors)
        guard !specs.isEmpty else { return nil }
        for spec in specs {
            Task { @MainActor [weak self] in _ = try? await self?.mcpPool.tools(spec) }
        }
        return ConnectorGateway(specs: specs, pool: mcpPool)
    }

    /// A settled turn's proxies have nothing left to ask.
    func revokeConnectorGrants(threadId: String) {
        guard connectorGrants.values.contains(where: { $0.threadId == threadId }) else { return }
        connectorGrants = connectorGrants.filter { $0.value.threadId != threadId }
    }

    /// `/api/internal/mcp-connectors/<id>/tools` (GET) and `/call` (POST).
    /// The caller already passed the boot-token check.
    func connectorInternalRoute(_ request: HTTPRequest, body: JSONObject) async -> HTTPResponse {
        let parts = request.path.dropFirst("/api/internal/mcp-connectors/".count).split(separator: "/").map(String.init)
        guard parts.count == 2 else { return .error(404, "not found") }
        let id = parts[0]
        guard let grant = connectorGrants[request.header(ConnectorGrant.header) ?? ""], grant.connectorIds.contains(id) else {
            return .error(403, "this turn was not given the connector \(id)")
        }
        guard let record = mcpConnectors.connector(id), record["enabled"]?.bool != false, let spec = mcpConnectors.spec(id) else {
            return .error(404, "the connector \(id) is no longer available")
        }
        switch (request.method, parts[1]) {
        case ("GET", "tools"):
            do {
                return .json(200, ["tools": .array(try await mcpPool.tools(spec))])
            } catch {
                return .error(502, "\(spec.name): \(Self.scrub(error.localizedDescription, spec))")
            }
        case ("POST", "call"):
            let name = body["name"]?.string ?? ""
            guard !name.isEmpty else { return .error(400, "name required") }
            do {
                return .json(200, try await mcpPool.call(spec, tool: name, arguments: body["arguments"] ?? .object(JSONObject())))
            } catch {
                // the model reads this: a tool error, not a broken protocol
                let text = "\(spec.name) · \(name): \(Self.scrub(error.localizedDescription, spec))"
                return .json(200, ["content": [["type": "text", "text": .string(text)]], "isError": true])
            }
        default:
            return .error(404, "not found")
        }
    }

    static func scrub(_ text: String, _ spec: MCPConnectorSpec) -> String {
        var out = Redact.text(text)
        for secret in spec.secretValues where secret.count >= 4 { out = out.replacingOccurrences(of: secret, with: "«redacted»") }
        return String(out.prefix(500))
    }
}

/// One turn's connectors, called in-process by an engine that runs its own
/// tool loop (docs/plans/2026-10-15-connettori-mcp.md §5).
@MainActor
public final class ConnectorGateway {
    public typealias Tool = ChatTool

    public struct Result: Sendable {
        public var text: String
        public var ok: Bool

        public init(text: String, ok: Bool) {
            self.text = text
            self.ok = ok
        }
    }

    /// What one result may put in the model's context (§5.2).
    public static let maxResultCharacters = 40_000

    let specs: [MCPConnectorSpec]
    private let pool: MCPConnectorPool

    init(specs: [MCPConnectorSpec], pool: MCPConnectorPool) {
        self.specs = specs
        self.pool = pool
    }

    public var connectorNames: [String] { specs.map(\.name) }

    /// Every tool of every connector; a connector that cannot be reached
    /// is left out and named in `failures`, the turn goes on without it.
    public func tools() async -> (tools: [Tool], failures: [String]) {
        var tools: [Tool] = []
        var failures: [String] = []
        for spec in specs {
            do {
                for tool in try await pool.tools(spec) {
                    guard let name = tool["name"]?.string else { continue }
                    tools.append(Tool(connectorId: spec.id, connectorName: spec.name, name: name,
                                      description: tool["description"]?.string ?? "",
                                      inputSchema: tool["inputSchema"] ?? ["type": "object", "properties": .object(JSONObject())]))
                }
            } catch {
                failures.append("\(spec.name): \(Harness.scrub(error.localizedDescription, spec))")
            }
        }
        return (tools, failures)
    }

    public func call(connectorId: String, tool: String, arguments: JSON) async -> Result {
        guard let spec = specs.first(where: { $0.id == connectorId }) else {
            return Result(text: "connector \(connectorId) is not available in this turn", ok: false)
        }
        do {
            let result = try await pool.call(spec, tool: tool, arguments: arguments)
            return Result(text: Self.text(of: result), ok: result["isError"]?.bool != true)
        } catch is CancellationError {
            return Result(text: "interrupted", ok: false)
        } catch {
            return Result(text: "\(spec.name) · \(tool): \(Harness.scrub(error.localizedDescription, spec))", ok: false)
        }
    }

    /// An MCP result as the text a chat model reads: the text parts, else
    /// the structured content; pictures and binaries become a note.
    static func text(of result: JSON) -> String {
        var parts: [String] = []
        for item in result["content"]?.array ?? [] {
            switch item["type"]?.string {
            case "text": if let text = item["text"]?.string { parts.append(text) }
            case "image": parts.append("[immagine dal connettore omessa]")
            case "audio": parts.append("[audio dal connettore omesso]")
            case "resource":
                if let text = item["resource"]?["text"]?.string { parts.append(text) } else { parts.append("[risorsa \(item["resource"]?["uri"]?.string ?? "") omessa]") }
            case "resource_link": parts.append("[link: \(item["uri"]?.string ?? "")]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"], !structured.isNull { parts.append(structured.serialized()) }
        let text = parts.joined(separator: "\n")
        guard text.count > maxResultCharacters else { return text.isEmpty ? "(nessun risultato)" : text }
        return String(text.prefix(maxResultCharacters)) + "\n…troncato (\(text.count) caratteri in tutto)"
    }
}
