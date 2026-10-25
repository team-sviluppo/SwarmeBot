// The vault's MCP server — `swarme-harness mcp-secrets`
// (docs/plans/2026-10-25-vault.md V8).
//
// One tool, `run_with_secrets`. The helper holds no value: it passes the
// command to `/api/internal/secrets/run` with the turn's grant, and the
// engine runs it with the secrets in its environment and answers with the
// output masked. Env: OMB_HARNESS_URL, OMB_COMMS_TOKEN, OMB_SECRETS_GRANT,
// OMB_SECRETS_NAMES (names only, for the schema). stdout is the MCP channel.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SecretsProxy {
    struct Env {
        var harness: String
        var token: String
        var grant: String
        var names: [String]

        init(_ env: [String: String]) {
            harness = env["OMB_HARNESS_URL"] ?? "http://127.0.0.1:8799"
            token = env["OMB_COMMS_TOKEN"] ?? ""
            grant = env["OMB_SECRETS_GRANT"] ?? ""
            names = (env["OMB_SECRETS_NAMES"] ?? "").split(separator: ",").map(String.init)
        }
    }

    struct CallError: Error { let message: String }

    static func tool(_ names: [String]) -> JSON {
        [
            "name": .string(VaultTool.toolName),
            "description": .string("Run a shell command (`sh -c`, in this chat's folder) with secrets from the user's SwarmeBot vault set as environment variables. Reference them as $NAME in the command; never print them. stdout and stderr come back with every secret value masked. Not interactive: stdin is closed. Secrets available: \(names.joined(separator: ", "))."),
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command, e.g. `git push origin main` or `hf download org/model`."],
                    "secrets": ["type": "array", "items": ["type": "string", "enum": .strings(names)],
                                "description": "The secrets this command needs."],
                    "timeout_sec": ["type": "integer", "minimum": 1, "maximum": .number(Double(VaultTool.maxSeconds)),
                                    "description": "Stop the command after this many seconds (default 600)."],
                ],
                "required": ["command", "secrets"],
            ],
        ]
    }

    static func api(_ env: Env, body: JSON, timeout: TimeInterval) throws -> JSON {
        guard let url = URL(string: env.harness + "/api/internal/secrets/run") else { throw CallError(message: "invalid harness URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.httpBody = body.data
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(env.token)", forHTTPHeaderField: "authorization")
        request.setValue(env.grant, forHTTPHeaderField: SecretsGrant.header)
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

    /// The engine's answer as the text the model reads.
    static func text(_ result: JSON) -> (text: String, isError: Bool) {
        let code = result["exitCode"]?.double.map { Int($0) }
        var lines = [code.map { "exit code: \($0)" } ?? "exit code: none (killed)"]
        if result["timedOut"]?.bool == true { lines.append("the command timed out and was stopped") }
        if result["truncated"]?.bool == true { lines.append("(output truncated: only the end is shown)") }
        let stdout = result["stdout"]?.string ?? "", stderr = result["stderr"]?.string ?? ""
        if !stdout.isEmpty { lines.append("--- stdout ---\n\(stdout)") }
        if !stderr.isEmpty { lines.append("--- stderr ---\n\(stderr)") }
        return (lines.joined(separator: "\n"), code != 0)
    }

    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        let env = Env(environment)
        let output = NSLock()
        let send = { (message: JSON) in
            output.lock()
            FileHandle.standardOutput.write(Data((message.serialized() + "\n").utf8))
            output.unlock()
        }
        // a command still running when stdin closes gets to answer first
        let inFlight = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let message = try? JSON.parse(line),
                  let method = message["method"]?.string else { continue }
            let id = message["id"] ?? .null
            switch method {
            case "initialize":
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                    "capabilities": ["tools": [:]], "serverInfo": ["name": .string(VaultTool.serverName), "version": "1"],
                ]])
            case "notifications/initialized", "notifications/cancelled":
                continue
            case "ping":
                send(["jsonrpc": "2.0", "id": id, "result": [:]])
            case "tools/list":
                send(["jsonrpc": "2.0", "id": id, "result": ["tools": [tool(env.names)]]])
            case "tools/call":
                let params = message["params"] ?? .null
                let arguments = params["arguments"] ?? .object(JSONObject())
                inFlight.enter()
                DispatchQueue.global().async {
                    defer { inFlight.leave() }
                    var result: JSON
                    if params["name"]?.string != VaultTool.toolName {
                        result = ["content": [["type": "text", "text": .string("unknown tool \(params["name"]?.string ?? "")")]], "isError": true]
                    } else {
                        let seconds = min(max(arguments["timeout_sec"]?.double ?? 600, 1), Double(VaultTool.maxSeconds))
                        let body: JSON = ["command": arguments["command"] ?? "", "secrets": arguments["secrets"] ?? .array([]),
                                          "timeout_sec": .number(seconds)]
                        do {
                            let answer = text(try api(env, body: body, timeout: seconds + 30))
                            result = ["content": [["type": "text", "text": .string(answer.text)]], "isError": .bool(answer.isError)]
                        } catch {
                            let text = (error as? CallError)?.message ?? error.localizedDescription
                            result = ["content": [["type": "text", "text": .string(text)]], "isError": true]
                        }
                    }
                    send(["jsonrpc": "2.0", "id": id, "result": result])
                }
            default:
                if message["id"] != nil {
                    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found: \(method)")]])
                }
            }
        }
        inFlight.wait()
        exit(0)
    }
}
