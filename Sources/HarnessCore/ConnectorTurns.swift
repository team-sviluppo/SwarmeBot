// Connectors in a turn (docs/plans/2026-10-15-connettori-mcp.md §4):
//
// - which connectors a turn gets: the bot's list, enabled ones only, each on
//   or off by the conversation's switch or else the bot's default;
// - a grant per turn: a random token the proxies carry back, naming the bot,
//   the thread and exactly those connectors. A bot cannot reach a connector
//   it was not given by guessing an id;
// - `/api/internal/mcp-connectors/<id>/tools|call`, where the proxies land.
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
