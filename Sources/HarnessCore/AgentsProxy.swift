// The agents MCP server — `server/drivers/agents-proxy.ts`, as a subcommand
// of the engine binary: `swarme-harness mcp-agents`.
//
// Mounted in a bot's CLI for a person's turn, it gives the bot its peers:
//
//   list_bots()                         the other bots, their model, busy or not
//   ask_bot(bot_id, message)            run a turn on that bot, return its reply
//   delegate_bot(bot_id, message, why?) queue a handoff that runs after this turn
//
// Every call goes back to the harness (`/api/internal/*`, boot token), which
// owns turns, approvals and the one-hop limit. All state arrives in the env:
// OMB_HARNESS_URL, OMB_BOT_ID, OMB_THREAD_ID, OMB_COMMS_TOKEN, OMB_TURN_DEPTH.
// stdout is the MCP channel: nothing else may be printed on it.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AgentsProxy {
    static let tools: JSON = [
        [
            "name": "list_bots",
            "description": "List the other bots (agents) in this SwarmeBot workspace you can message, with their model and whether they're busy. Call this before ask_bot to discover who's available.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "ask_bot",
            "description": "Send a message to another bot in this workspace and wait for its reply. Use it to delegate a subtask to a specialist bot or ask a peer a question. The other bot runs a full turn under its own model and permissions; the reply is returned to you as text. Returns promptly with a note if that bot is busy.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bot_id": ["type": "string", "description": "The target bot's id (from list_bots)."],
                    "message": ["type": "string", "description": "What to say / ask the bot."],
                ],
                "required": ["bot_id", "message"],
            ],
        ],
        [
            "name": "delegate_bot",
            "description": "Hand a task to another bot ASYNCHRONOUSLY: returns immediately and the peer runs after your current turn finishes. Use this when you want to keep working or hand off a long-running subtask without waiting. The user sees the peer's reply as its own turn; you do NOT receive the reply inline.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "bot_id": ["type": "string", "description": "The target bot's id (from list_bots)."],
                    "message": ["type": "string", "description": "What the peer should do / answer."],
                    "reason": ["type": "string", "description": "Optional one-line reason for the delegation (shown to the user as a chip)."],
                ],
                "required": ["bot_id", "message"],
            ],
        ],
    ]

    struct Env {
        var harness: String
        var botId: String
        var threadId: String
        var token: String
        var depth: Int

        init(_ env: [String: String]) {
            harness = env["OMB_HARNESS_URL"] ?? "http://127.0.0.1:8799"
            botId = env["OMB_BOT_ID"] ?? ""
            threadId = env["OMB_THREAD_ID"] ?? ""
            token = env["OMB_COMMS_TOKEN"] ?? ""
            depth = Int(env["OMB_TURN_DEPTH"] ?? "0") ?? 0
        }
    }

    struct CallError: Error { let message: String }

    /// One loopback call; ask_bot can take minutes, so no short timeout.
    static func api(_ env: Env, _ path: String, body: JSON? = nil) throws -> JSON {
        guard let url = URL(string: env.harness + path) else { throw CallError(message: "invalid harness URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(env.token)", forHTTPHeaderField: "authorization")
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
        guard (200...299).contains(status) else { throw CallError(message: json["error"].flatMap(Harness.text) ?? "HTTP \(status)") }
        return json
    }

    static func call(_ env: Env, _ name: String, _ args: JSON) throws -> (text: String, isError: Bool) {
        let string = { (key: String) in (args[key].flatMap(Harness.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch name {
        case "list_bots":
            let response = try api(env, "/api/internal/agents?self=\(env.botId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")
            let bots = response["bots"]?.array ?? []
            if bots.isEmpty { return ("No other bots in this workspace yet.", false) }
            let lines = bots.map { bot -> String in
                let role = bot["title"]?.string.map { " — \($0)" } ?? ""
                let about = bot["description"].flatMap(Harness.text).map { " (\($0.prefix(120)))" } ?? ""
                let model = bot["model"].flatMap(Harness.text) ?? "undefined"
                return "- \(bot["name"].flatMap(Harness.text) ?? "")\(role)\(about) [id: \(bot["id"].flatMap(Harness.text) ?? ""), model: \(model)\(bot["busy"]?.truthy == true ? ", busy" : "")]"
            }
            return ("Other bots you can message with ask_bot:\n\(lines.joined(separator: "\n"))", false)
        case "ask_bot":
            let to = string("bot_id"), message = string("message")
            if to.isEmpty || message.isEmpty { return ("ask_bot needs bot_id and message.", true) }
            let response = try api(env, "/api/internal/ask-bot", body: [
                "fromBotId": .string(env.botId), "fromThreadId": .string(env.threadId), "toBotId": .string(to),
                "message": .string(message), "depth": .number(Double(env.depth)),
            ])
            if response["busy"]?.truthy == true { return ("That bot is busy right now — try again after it finishes.", false) }
            if let error = response["error"], error.truthy { return ("Couldn't reach that bot: \(Harness.text(error) ?? "")", true) }
            return ("\(response["botName"].flatMap(Harness.text) ?? "Bot") replied:\n\(response["text"].flatMap(Harness.text) ?? "(no reply)")", false)
        case "delegate_bot":
            let to = string("bot_id"), message = string("message")
            let reason = args["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if to.isEmpty || message.isEmpty { return ("delegate_bot needs bot_id and message.", true) }
            var body: JSONObject = ["fromBotId": .string(env.botId), "fromThreadId": .string(env.threadId), "toBotId": .string(to),
                                    "message": .string(message), "depth": .number(Double(env.depth))]
            if !reason.isEmpty { body["reason"] = .string(reason) }
            let response = try api(env, "/api/internal/delegate-bot", body: .object(body))
            if let error = response["error"], error.truthy { return ("Couldn't queue the delegation: \(Harness.text(error) ?? "")", true) }
            return (response["message"]?.string ?? "Delegation queued.", false)
        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        let env = Env(environment)
        let output = NSLock()
        let send = { (message: JSON) in
            output.lock()
            FileHandle.standardOutput.write(Data((message.serialized() + "\n").utf8))
            output.unlock()
        }
        let names = (tools.array ?? []).compactMap { $0["name"]?.string }
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let message = try? JSON.parse(line),
                  let method = message["method"]?.string else { continue }
            let id = message["id"] ?? .null
            switch method {
            case "initialize":
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": message["params"]?["protocolVersion"] ?? "2024-11-05",
                    "capabilities": ["tools": [:]], "serverInfo": ["name": "opengrokbot-agents", "version": "0.1.0"],
                ]])
            case "notifications/initialized", "notifications/cancelled":
                continue
            case "ping":
                send(["jsonrpc": "2.0", "id": id, "result": [:]])
            case "tools/list":
                send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
            case "tools/call":
                let name = message["params"]?["name"]?.string ?? ""
                guard names.contains(name) else {
                    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": .string("Unknown tool: \(name)")]])
                    continue
                }
                let args = message["params"]?["arguments"] ?? .object(JSONObject())
                // ask_bot waits minutes: never block the next request on it
                DispatchQueue.global().async {
                    let result: (text: String, isError: Bool)
                    do { result = try call(env, name, args) } catch { result = ((error as? CallError)?.message ?? error.localizedDescription, true) }
                    send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": .string(result.text)]], "isError": .bool(result.isError)]])
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
