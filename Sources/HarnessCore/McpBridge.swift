// stdio bridges — `server/container-mcp.ts`, `vps-container-mcp.ts` and the
// piping half of `mcp-bridge.ts`.
//
// These processes define no computer tools. They keep the CLI's stdio
// attached to `cua-driver mcp` inside a container. A tools/call is refused
// while the person holds the desktop; everything else is forwarded as-is.
import Foundation

public enum McpBridge {
    static let refusal = "A person is driving this computer. Call computer_request_help and wait — do not queue actions."

    /// `swarme-harness mcp-container <docker|podman|container> <name> <socket>`
    public static func runContainer(_ args: [String]) -> Never {
        guard let runtime = args.first, ["docker", "podman", "container"].contains(runtime) else {
            FileHandle.standardError.write(Data("invalid Local VM runtime\n".utf8))
            exit(2)
        }
        guard args.count == 3,
              args[1].range(of: #"^[a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil,
              args[2].hasPrefix("/run/user/1000/") else {
            FileHandle.standardError.write(Data("invalid Local VM connection\n".utf8))
            exit(2)
        }
        let argv = LocalVM.cuaExecArgs(["mcp", "--socket", args[2]], container: args[1], interactive: true)
        run(command: EnvPath.which(runtime) ?? runtime, args: argv, label: "Cua Driver")
    }

    /// `swarme-harness mcp-vps <ssh-alias> <container>`
    public static func runVPS(_ args: [String]) -> Never {
        let alias = args.first ?? ""
        let container = args.count > 1 ? args[1] : ""
        let aliasOK = alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil
        let nameOK = container.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil
            || container.range(of: #"^[a-fA-F0-9]{12,64}$"#, options: .regularExpression) != nil
        guard aliasOK, nameOK else {
            FileHandle.standardError.write(Data("invalid VPS MCP connection\n".utf8))
            exit(2)
        }
        let argv = ["-H", "ssh://\(alias)"] + LocalVM.cuaExecArgs(["mcp", "--socket", LocalVM.socket], container: container, interactive: true)
        run(command: EnvPath.which("docker") ?? "docker", args: argv, label: "VPS Cua Driver")
    }

    private static func run(command: String, args: [String], label: String) -> Never {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do { try process.run() } catch {
            FileHandle.standardError.write(Data("could not connect to \(label): \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let controlURL = ProcessInfo.processInfo.environment["OMB_CONTROL_URL"] ?? ""
        let token = ProcessInfo.processInfo.environment["OMB_CONTROL_TOKEN"] ?? ""
        let gate = !controlURL.isEmpty && !token.isEmpty
        DispatchQueue.global().async {
            let source = output.fileHandleForReading
            while true {
                let data = source.availableData
                if data.isEmpty { break }
                FileHandle.standardOutput.write(data)
            }
        }
        var buffer = Data()
        let stdin = FileHandle.standardInput
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let text = String(decoding: line, as: UTF8.self)
                if gate, let message = try? JSON.parse(text), message["method"]?.string == "tools/call", held(controlURL, token) {
                    let id = message["id"] ?? .null
                    let reply: JSON = ["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": .string(refusal)]], "isError": true]]
                    FileHandle.standardOutput.write(Data((reply.serialized() + "\n").utf8))
                } else {
                    input.fileHandleForWriting.write(Data(text.utf8))
                    input.fileHandleForWriting.write(Data([0x0A]))
                }
            }
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    /// Open on failure, same posture as the Node control client.
    private static func held(_ url: String, _ token: String) -> Bool {
        guard let target = URL(string: url) else { return false }
        var request = URLRequest(url: target)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2
        let box = HeldBox()
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            let body = data.flatMap { try? JSON.parse(String(decoding: $0, as: UTF8.self)) }
            box.finish(body?["held"]?.bool == true)
        }
        task.resume()
        return box.wait()
    }
}

private final class HeldBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value = false
    func finish(_ held: Bool) { lock.lock(); value = held; lock.unlock(); semaphore.signal() }
    func wait() -> Bool {
        _ = semaphore.wait(timeout: .now() + 2)
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
