// The connector MCP server — `swarme-harness mcp-connector <id>`
// (docs/plans/2026-10-15-connettori-mcp.md §4.1).
//
// What a CLI spawns in place of the real server. It answers `initialize`
// itself and passes `tools/list` and `tools/call` to the engine, whose pool
// holds the real connection, the secrets and the OAuth tokens. The id is on
// argv (no secret, and Codex shares one env across every server it mounts);
// the rest arrives in the env: OMB_HARNESS_URL, OMB_COMMS_TOKEN,
// OMB_CONNECTOR_GRANT. stdout is the MCP channel: nothing else may be printed on it.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ConnectorProxy {
    struct Env {
        var harness: String
        var token: String
        var grant: String

        init(_ env: [String: String]) {
            harness = env["OMB_HARNESS_URL"] ?? "http://127.0.0.1:8799"
            token = env["OMB_COMMS_TOKEN"] ?? ""
            grant = env["OMB_CONNECTOR_GRANT"] ?? ""
        }
    }

    struct CallError: Error { let message: String }

    /// One loopback call. A tool may run for the connector's whole timeout (≤ 900 s).
    static func api(_ env: Env, _ path: String, body: JSON? = nil) throws -> JSON {
        guard let url = URL(string: env.harness + path) else { throw CallError(message: "invalid harness URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 960
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(env.token)", forHTTPHeaderField: "authorization")
        request.setValue(env.grant, forHTTPHeaderField: ConnectorGrant.header)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body.data
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        URLSession.shared.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = result.2 { throw CallError(message: error.localizedDescription) }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        let json = result.0.flatMap { try? JSON.parse($0) } ?? .object(JSONObject())
        guard (200...299).contains(status) else { throw CallError(message: json["error"]?.string ?? "HTTP \(status)") }
        return json
    }

    public static func run(connector: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        let env = Env(environment)
        // ids are [a-z0-9_]: safe in a path as they are
        let base = "/api/internal/mcp-connectors/\(connector)"
        let output = NSLock()
        let send = { (message: JSON) in
            output.lock()
            FileHandle.standardOutput.write(Data((message.serialized() + "\n").utf8))
            output.unlock()
        }
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let message = try? JSON.parse(line),
                  let method = message["method"]?.string else { continue }
            let id = message["id"] ?? .null
            switch method {
            case "initialize":
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                    "capabilities": ["tools": [:]], "serverInfo": ["name": .string("swarmebot-\(connector)"), "version": "1"],
                ]])
            case "notifications/initialized", "notifications/cancelled":
                continue
            case "ping":
                send(["jsonrpc": "2.0", "id": id, "result": [:]])
            case "tools/list":
                // the first list may wait for a cold server: off the read loop
                DispatchQueue.global().async {
                    do {
                        let tools = try api(env, "\(base)/tools")["tools"] ?? .array([])
                        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
                    } catch {
                        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string((error as? CallError)?.message ?? error.localizedDescription)]])
                    }
                }
            case "tools/call":
                let params = message["params"] ?? .null
                let body: JSON = ["name": params["name"] ?? "", "arguments": params["arguments"] ?? .object(JSONObject())]
                DispatchQueue.global().async {
                    var result: JSON
                    do {
                        result = try api(env, "\(base)/call", body: body)
                    } catch {
                        let text = (error as? CallError)?.message ?? error.localizedDescription
                        result = ["content": [["type": "text", "text": .string(text)]], "isError": true]
                    }
                    send(["jsonrpc": "2.0", "id": id, "result": result])
                }
            default:
                if message["id"] != nil {
                    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found: \(method)")]])
                }
            }
        }
        exit(0)
    }
}
