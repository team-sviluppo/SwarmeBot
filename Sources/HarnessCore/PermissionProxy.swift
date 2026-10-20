// The permission proxy — `server/permission-proxy.ts`, as a subcommand of
// the engine binary: `swarme-harness mcp-permission <socket>`.
//
// The CLI spawns it as an MCP stdio server for `--permission-prompt-tool`.
// Two tools, each forwarded to the turn's PermissionBroker over the socket:
//
//   approve   — called for any tool use the permission mode would deny; the
//               result is the --permission-prompt-tool JSON contract
//               ({behavior:"allow"|"deny", …});
//   ask_user  — the agent asks the human a question and waits; the answer
//               comes back verbatim.
//
// stdout is the MCP channel: nothing else may ever be printed on it.
import Foundation

public enum PermissionProxy {
    static let tools: JSON = [
        [
            "name": "approve",
            "description": "Ask the SwarmeBot user whether a tool use is allowed",
            "inputSchema": [
                "type": "object",
                "properties": ["tool_name": ["type": "string"], "input": ["type": "object"], "tool_use_id": ["type": "string"]],
                "required": ["tool_name", "input"],
            ],
        ],
        [
            "name": "ask_user",
            "description": "Ask the human who owns this bot a question and wait for their answer. Use whenever you need a decision, a preference, missing information, or sign-off before doing something consequential — do not guess on things the owner would want to decide. Returns their answer as text.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "The question, with enough context to answer at a glance"],
                    "choices": ["type": "array", "items": ["type": "string"], "description": "Optional 2-5 suggested answers, shown as one-tap buttons"],
                ],
                "required": ["question"],
            ],
        ],
    ]

    static let deadAnswer: JSON = ["behavior": "deny", "message": "SwarmeBot: permission broker unavailable — skip this action"]

    /// What goes back to the CLI for one answered call.
    static func resultText(isQuestion: Bool, arguments: JSON, answer: JSON) -> String {
        let message = answer["message"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        if isQuestion { return message ?? "No answer was given — use your best judgment." }
        if answer["behavior"]?.string == "allow" {
            var result: JSONObject = ["behavior": "allow", "updatedInput": arguments["input"] ?? .object(JSONObject())]
            // the CLI's own suggested rules, handed back so it stops asking at its layer
            let suggestions = arguments["permission_suggestions"]?.array ?? arguments["suggestions"]?.array
            if answer["always"]?.truthy == true, let suggestions { result["updatedPermissions"] = .array(suggestions) }
            return JSON.object(result).serialized()
        }
        return JSON.object(["behavior": "deny", "message": .string(message ?? "Denied from SwarmeBot")]).serialized()
    }

    public static func run(socketPath: String) -> Never {
        let state = State()
        let fd = connect(socketPath)
        state.fd = fd
        if fd < 0 { state.dead() } else {
            Thread.detachNewThread { state.readAnswers() }
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(0, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let message = try? JSON.parse(line) else { continue }
                // every call waits on a human: handle each on its own thread
                DispatchQueue.global().async { state.handle(message) }
            }
        }
        exit(0)
    }

    static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, Sys.streamSocket, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return -1 }
        Sys.noSigPipe(fd)
        return fd
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let outputLock = NSLock()
        var fd: Int32 = -1
        private var isDead = false
        private var waiting: [String: (JSON) -> Void] = [:]

        func send(_ message: JSON) {
            outputLock.lock()
            defer { outputLock.unlock() }
            FileHandle.standardOutput.write(Data((message.serialized() + "\n").utf8))
        }

        func dead() {
            lock.lock()
            isDead = true
            let all = waiting.values
            waiting.removeAll()
            lock.unlock()
            for resolve in all { resolve(PermissionProxy.deadAnswer) }
        }

        func readAnswers() {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let message = try? JSON.parse(line), message["t"]?.string == "answer",
                          let id = message["id"]?.string else { continue }
                    lock.lock()
                    let resolve = waiting.removeValue(forKey: id)
                    lock.unlock()
                    resolve?(message)
                }
            }
            dead()
        }

        /// Forward one ask and block until it is answered (or the broker dies).
        func ask(_ frame: JSON, id: String) -> JSON {
            let semaphore = DispatchSemaphore(value: 0)
            var answer = PermissionProxy.deadAnswer
            lock.lock()
            if isDead {
                lock.unlock()
                return answer
            }
            waiting[id] = { reply in
                answer = reply
                semaphore.signal()
            }
            lock.unlock()
            let bytes = Array((frame.serialized() + "\n").utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { Sys.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
                if written < 0 {
                    if errno == EINTR { continue }
                    dead()
                    break
                }
                offset += written
            }
            semaphore.wait()
            return answer
        }

        func handle(_ message: JSON) {
            let method = message["method"]?.string ?? ""
            let id = message["id"] ?? .null
            switch method {
            case "initialize":
                send(["jsonrpc": "2.0", "id": id, "result": [
                    "protocolVersion": message["params"]?["protocolVersion"] ?? "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "swarmebot-permissions", "version": "1"],
                ]])
            case "tools/list":
                send(["jsonrpc": "2.0", "id": id, "result": ["tools": PermissionProxy.tools]])
            case "tools/call":
                let name = message["params"]?["name"]?.string
                let arguments = message["params"]?["arguments"] ?? .object(JSONObject())
                let askId = UUID().uuidString.lowercased()
                let isQuestion = name == "ask_user"
                var frame: JSONObject = ["t": "ask", "id": .string(askId)]
                if isQuestion {
                    var input: JSONObject = ["question": arguments["question"] ?? .null]
                    if let choices = arguments["choices"] { input["choices"] = choices }
                    frame["kind"] = "question"
                    frame["tool"] = "ask_user"
                    frame["input"] = .object(input)
                } else {
                    if let tool = arguments["tool_name"] { frame["tool"] = tool }
                    if let input = arguments["input"] { frame["input"] = input }
                }
                let answer = ask(.object(frame), id: askId)
                let text = PermissionProxy.resultText(isQuestion: isQuestion, arguments: arguments, answer: answer)
                send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": .string(text)]]]])
            default:
                if method.hasPrefix("notifications/") { return }
                if !id.isNull {
                    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("method not found: \(method)")]])
                }
            }
        }
    }
}

/// Where the engine binary is, for the MCP helpers it hands to CLIs.
public enum HelperCommand {
    /// `OMB_HELPER_BIN` wins (tests run inside xctest, not the engine).
    nonisolated(unsafe) public static var executable: String = {
        if let override = ProcessInfo.processInfo.environment["OMB_HELPER_BIN"], !override.isEmpty { return override }
        return Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }()
}
