// `/api/mcp-connectors*` — the connectors' settings API
// (docs/plans/2026-10-15-connettori-mcp.md §6). Every change is broadcast as
// `{"kind": "mcpConnectors"}`; the app reloads the list.
import Foundation

@MainActor
enum MCPConnectorRoutes {
    static func respond(_ status: Int, _ value: JSON) -> RouteResult { .response(.json(status, value)) }
    static func fail(_ status: Int, _ message: String) -> RouteResult { .response(.error(status, message)) }

    static func handle(_ r: HTTPRequest, harness: Harness) async throws -> RouteResult? {
        let path = r.path
        if path == MCPOAuth.callbackPath, r.method == "GET" { return await oauthCallback(r, harness: harness) }
        guard path == "/api/mcp-connectors" || path.hasPrefix("/api/mcp-connectors/") else { return nil }
        let method = r.method
        // mutations must declare JSON, like every other dangerous route; the
        // body-less actions (test, login, logout) carry nothing a form could forge
        let bodyless = ["/test", "/oauth/start", "/oauth/logout"].contains(where: path.hasSuffix)
        if method != "GET", !r.isJSON, !(method == "DELETE" && r.body.isEmpty), !(method == "POST" && bodyless && r.body.isEmpty) {
            return fail(415, "content-type must be application/json")
        }
        let registry = harness.mcpConnectors

        if path == "/api/mcp-connectors" {
            if method == "GET" { return respond(200, ["connectors": registry.wireList]) }
            if method == "POST" {
                do {
                    let record = try registry.create(try r.json())
                    changed(harness)
                    return respond(201, ["connector": registry.wire(record)])
                } catch let error as MCPConnectorInvalid {
                    return fail(400, error.message)
                }
            }
            return nil
        }
        if path == "/api/mcp-connectors/import", method == "POST" {
            let existing = Set(registry.connectors.compactMap { $0["id"]?.string })
            let (bodies, skipped) = MCPConnectors.importBodies(.object(try r.json()), existingIds: existing)
            var created: [JSON] = []
            var rejected = skipped
            for body in bodies {
                do {
                    created.append(registry.wire(try registry.create(body)))
                } catch let error as MCPConnectorInvalid {
                    rejected.append(["name": body["name"] ?? .null, "reason": .string(error.message)])
                }
            }
            if !created.isEmpty { changed(harness) }
            return respond(200, ["created": .array(created), "skipped": .array(rejected)])
        }

        // where a provider must send the browser back, for apps that need it
        // registered by hand (no dynamic registration, or not for us)
        if path == "/api/mcp-connectors/oauth-redirect", method == "GET" {
            return respond(200, ["redirectUri": .string(harness.mcpOAuth.redirectUri)])
        }

        let rest = String(path.dropFirst("/api/mcp-connectors/".count))
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let id = parts.first, id.range(of: #"^[a-z0-9_]{1,24}$"#, options: .regularExpression) != nil else { return nil }

        if parts.count == 2, parts[1] == "test", method == "POST" {
            guard let spec = registry.spec(id) else { return fail(404, "no such connector") }
            let check = await probe(spec, previous: registry.connector(id)?["lastCheck"], pool: harness.mcpPool)
            registry.setLastCheck(id, check)
            // whatever the pool held was built from an older look at the server
            harness.mcpPool.invalidate(id)
            changed(harness)
            return respond(200, ["connector": registry.wire(registry.connector(id) ?? JSONObject())])
        }
        if parts.count == 3, parts[1] == "oauth", method == "POST" {
            guard registry.connector(id) != nil else { return fail(404, "no such connector") }
            switch parts[2] {
            case "start":
                do {
                    let url = try await harness.mcpOAuth.start(id)
                    return respond(200, ["authorizationUrl": .string(url.absoluteString), "redirectUri": .string(harness.mcpOAuth.redirectUri)])
                } catch {
                    return fail(400, error.localizedDescription)
                }
            case "logout":
                harness.mcpOAuth.logout(id)
                harness.mcpPool.invalidate(id)
                changed(harness)
                return respond(200, ["connector": registry.wire(registry.connector(id) ?? JSONObject())])
            default:
                return nil
            }
        }
        guard parts.count == 1 else { return nil }
        guard registry.connector(id) != nil else { return fail(404, "no such connector") }
        switch method {
        case "GET":
            return respond(200, ["connector": registry.wire(registry.connector(id)!)])
        case "PUT", "PATCH":
            do {
                guard let record = try registry.update(id, try r.json()) else { return fail(404, "no such connector") }
                harness.mcpPool.invalidate(id)
                changed(harness)
                return respond(200, ["connector": registry.wire(record)])
            } catch let error as MCPConnectorInvalid {
                return fail(400, error.message)
            }
        case "DELETE":
            _ = try registry.delete(id)
            harness.mcpPool.invalidate(id)
            harness.store.forgetConnector(id)
            changed(harness)
            return respond(200, ["ok": true])
        default:
            return nil
        }
    }

    /// Where the browser lands after the login: a page to close, and the
    /// connector tested straight away so Settings shows its tools.
    static func oauthCallback(_ r: HTTPRequest, harness: Harness) async -> RouteResult {
        let outcome = await harness.mcpOAuth.complete(state: r.query["state"] ?? "", code: r.query["code"],
                                                      error: r.query["error_description"] ?? r.query["error"])
        if let id = outcome.id {
            harness.mcpPool.invalidate(id)
            if outcome.ok, let spec = harness.mcpConnectors.spec(id) {
                let check = await probe(spec, previous: harness.mcpConnectors.connector(id)?["lastCheck"], pool: harness.mcpPool)
                harness.mcpConnectors.setLastCheck(id, check)
            }
            changed(harness)
        }
        let escaped = outcome.message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html><html lang="it"><head><meta charset="utf-8"><title>SwarmeBot</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0}
        p{max-width:28em;text-align:center;line-height:1.5}b{color:\(outcome.ok ? "#38D591" : "#FF5667")}</style></head>
        <body><p><b>\(outcome.ok ? "Fatto" : "Accesso non riuscito")</b><br>\(escaped)</p></body></html>
        """
        return .response(HTTPResponse(status: outcome.ok ? 200 : 400, headers: [("Content-Type", "text/html; charset=utf-8"),
                                                                            ("Cache-Control", "no-store")], body: Data(html.utf8)))
    }

    private static func changed(_ harness: Harness) {
        harness.broadcast(["kind": "mcpConnectors"])
    }

    /// Connect once, list the tools, measure what they would cost a prompt.
    static func probe(_ spec: MCPConnectorSpec, previous: JSON?, pool: MCPConnectorPool) async -> JSONObject {
        var check: JSONObject = ["at": .string(ISO8601DateFormatter().string(from: Date()))]
        do {
            let (server, tools) = try await pool.probe(spec)
            var total = 0
            let listed: [JSON] = tools.compactMap { tool in
                guard let name = tool["name"]?.string else { return nil }
                // what a model is sent: name, description, schema
                let chars = JSON.object(["name": .string(name), "description": tool["description"] ?? .null,
                                         "inputSchema": tool["inputSchema"] ?? .null]).serialized().count
                total += chars
                return [
                    "name": .string(name),
                    "description": .string(String((tool["description"]?.string ?? "").prefix(300))),
                    "readOnly": .bool(tool["annotations"]?["readOnlyHint"]?.bool == true),
                    "chars": .number(Double(chars)),
                ]
            }
            check["ok"] = true
            check["server"] = ["name": .string(server.name), "version": .string(server.version), "protocolVersion": .string(server.protocolVersion)]
            check["tools"] = .array(listed)
            check["schemaChars"] = .number(Double(total))
            check["error"] = .null
        } catch {
            check["ok"] = false
            var message = error.localizedDescription
            for secret in spec.secretValues where secret.count >= 4 { message = message.replacingOccurrences(of: secret, with: "«redacted»") }
            check["error"] = .string(String(Redact.text(message).prefix(500)))
            // keep the last good list: the tool filter still needs it
            check["tools"] = previous?["tools"] ?? .array([])
            check["schemaChars"] = previous?["schemaChars"] ?? .null
        }
        return check
    }
}
