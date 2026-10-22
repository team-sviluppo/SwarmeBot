// The stdio transport of the engine's MCP client (MCPClient lives in
// AgentCore): the server is a child process (CLIProcess, so it gets its own
// process group and killTree reaps whatever it spawned), one message per line.
import Foundation

@MainActor
final class MCPStdioTransport: MCPTransport {
    var onMessage: ((JSON) -> Void)?
    var onClose: ((String?) -> Void)?
    private let command: String
    private let args: [String]
    private let cwd: String?
    private let environment: [String: String]
    private let log: (String) -> Void
    private var process: CLIProcess?
    private var stderrTail = ""

    init(command: String, args: [String], cwd: String?, environment: [String: String], log: @escaping (String) -> Void) {
        self.command = command
        self.args = args
        self.cwd = cwd
        self.environment = environment
        self.log = log
    }

    func start() async throws {
        let process: CLIProcess
        do {
            process = try CLIProcess(cli: command, args: args, cwd: cwd, environment: environment)
        } catch let failure as SpawnFailure {
            throw MCPError(failure.message)
        }
        process.onLine = { [weak self] line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // a server that prints a banner on stdout breaks the protocol, but
            // dropping the line is kinder than dropping the connector
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let message = try? JSON.parse(trimmed) else {
                if !trimmed.isEmpty { self?.log("stdout (not JSON-RPC): \(trimmed.prefix(300))") }
                return
            }
            if case let .array(batch) = message { batch.forEach { self?.onMessage?($0) } } else { self?.onMessage?(message) }
        }
        process.onStderr = { [weak self] text in
            guard let self else { return }
            self.log(text)
            self.stderrTail = String((self.stderrTail + text).suffix(400))
        }
        process.onClose = { [weak self] code in
            guard let self else { return }
            let tail = self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            self.process = nil
            self.onClose?("il processo è terminato (\(code.map { "codice \($0)" } ?? "segnale"))" + (tail.isEmpty ? "" : ": \(tail.suffix(300))"))
        }
        self.process = process
        process.start()
    }

    func send(_ message: JSON) async throws {
        guard let process, !process.hasExited else { throw MCPError("il server del connettore non è in esecuzione") }
        process.write(message.serialized() + "\n")
    }

    func close() {
        guard let process else { return }
        self.process = nil
        process.closeStdin()
        process.killTree()
    }
}

extension MCPClient {
    public static func stdio(command: String, args: [String], cwd: String?, environment: [String: String],
                             log: @escaping (String) -> Void = { _ in }) -> MCPClient {
        MCPClient(transport: MCPStdioTransport(command: command, args: args, cwd: cwd, environment: environment, log: log))
    }
}
