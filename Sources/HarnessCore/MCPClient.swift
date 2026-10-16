// The engine's own MCP client, for connectors
// (docs/plans/2026-10-15-connettori-mcp.md §3.1).
//
// JSON-RPC 2.0 over one of two transports:
//
// - stdio: the server is a child process (CLIProcess, so it gets its own
//   process group and killTree reaps whatever it spawned), one message per line;
// - Streamable HTTP: every message is a POST; the answer is either one JSON
//   body or an SSE stream carrying it, and `Mcp-Session-Id` from the
//   initialize answer goes on every later request.
//
// The client only asks; the one server request it answers is `ping`. No
// roots, no sampling, no elicitation: a connector is a bag of tools.
import Foundation

public struct MCPError: LocalizedError, Sendable {
    public var message: String
    /// HTTP status, when the transport failed with one.
    public var status: Int?
    public var errorDescription: String? { message }

    public init(_ message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }

    /// The HTTP session the server handed out is gone: initialize again.
    var sessionExpired: Bool { status == 404 }
}

@MainActor
protocol MCPTransport: AnyObject {
    /// Every message from the server, in order.
    var onMessage: ((JSON) -> Void)? { get set }
    /// The transport is gone for good; the text says why when it is known.
    var onClose: ((String?) -> Void)? { get set }
    func start() async throws
    func send(_ message: JSON) async throws
    func close()
}

// MARK: - stdio

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

// MARK: - Streamable HTTP

@MainActor
final class MCPHTTPTransport: MCPTransport {
    var onMessage: ((JSON) -> Void)?
    var onClose: ((String?) -> Void)?
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private(set) var sessionId: String?
    var protocolVersion: String?
    private var readers: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    init(url: URL, headers: [String: String], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    func start() async throws {}

    /// Forget the session: the next initialize gets a new one.
    func resetSession() {
        sessionId = nil
        protocolVersion = nil
    }

    func send(_ message: JSON) async throws {
        guard !closed else { throw MCPError("connessione chiusa") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = message.data

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError("risposta HTTP non valida") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !id.isEmpty { sessionId = id }
        guard (200...299).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 300 { break }
            }
            throw Self.failure(http.statusCode, String(decoding: body, as: UTF8.self), hadSession: sessionId != nil)
        }
        // 202: a notification or a response we sent was accepted, nothing to read
        if http.statusCode == 202 { return }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.hasPrefix("text/event-stream") {
            // read in the background: the stream may outlive the answer we wait for
            let key = UUID()
            readers[key] = Task { @MainActor [weak self] in
                await self?.readEvents(bytes)
                self?.readers[key] = nil
            }
            return
        }
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        guard !data.isEmpty else { return }
        guard let parsed = try? JSON.parse(data) else { throw MCPError("il server ha risposto con un corpo che non è JSON") }
        if case let .array(batch) = parsed { batch.forEach { onMessage?($0) } } else { onMessage?(parsed) }
    }

    private func readEvents(_ bytes: URLSession.AsyncBytes) async {
        var data: [String] = []
        do {
            for try await raw in bytes.lines {
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                if line.isEmpty {
                    dispatch(data)
                    data = []
                } else if line.hasPrefix("data:") {
                    var value = line.dropFirst(5)
                    if value.hasPrefix(" ") { value = value.dropFirst() }
                    data.append(String(value))
                }
                // `event:`, `id:` and comments carry nothing a tool call needs
            }
            dispatch(data)
        } catch {
            // the stream broke off: an answer still owed times out on its own
        }
    }

    private func dispatch(_ lines: [String]) {
        guard !lines.isEmpty, let message = try? JSON.parse(lines.joined(separator: "\n")) else { return }
        if case let .array(batch) = message { batch.forEach { onMessage?($0) } } else { onMessage?(message) }
    }

    static func failure(_ status: Int, _ body: String, hadSession: Bool) -> MCPError {
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(Redact.text(String(detail.prefix(200))))"
        switch status {
        case 401, 403: return MCPError("il server ha rifiutato le credenziali (HTTP \(status))\(suffix)", status: status)
        case 404 where hadSession: return MCPError("sessione MCP scaduta (HTTP 404)", status: 404)
        default: return MCPError("HTTP \(status)\(suffix)", status: status)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        readers.values.forEach { $0.cancel() }
        readers = [:]
        // ending the session is a courtesy: the server may not support it
        if let sessionId {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 5
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
            let session = self.session
            Task.detached { _ = try? await session.data(for: request) }
        }
    }
}

// MARK: - Client

@MainActor
public final class MCPClient {
    public struct ServerInfo: Sendable {
        public var name: String
        public var version: String
        public var protocolVersion: String
        public var instructions: String?
    }

    static let protocolVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let transport: MCPTransport
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    public private(set) var server: ServerInfo?
    public private(set) var closed = false
    /// Why the transport went away, once it has.
    public private(set) var closeReason: String?
    /// `notifications/tools/list_changed`.
    public var onToolsChanged: (() -> Void)?
    public var onClose: ((String?) -> Void)?

    init(transport: MCPTransport) {
        self.transport = transport
        transport.onMessage = { [weak self] message in self?.receive(message) }
        transport.onClose = { [weak self] reason in self?.transportClosed(reason) }
    }

    public static func stdio(command: String, args: [String], cwd: String?, environment: [String: String],
                             log: @escaping (String) -> Void = { _ in }) -> MCPClient {
        MCPClient(transport: MCPStdioTransport(command: command, args: args, cwd: cwd, environment: environment, log: log))
    }

    public static func http(url: URL, headers: [String: String], session: URLSession = .shared) -> MCPClient {
        MCPClient(transport: MCPHTTPTransport(url: url, headers: headers, session: session))
    }

    /// Start the transport and run the initialize handshake.
    @discardableResult
    public func connect(timeout: TimeInterval) async throws -> ServerInfo {
        try await transport.start()
        return try await initialize(timeout: timeout)
    }

    private func initialize(timeout: TimeInterval) async throws -> ServerInfo {
        let result = try await request("initialize", [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object(JSONObject()),
            "clientInfo": ["name": "SwarmeBot", "version": "1"],
        ], timeout: timeout, retryExpiredSession: false)
        let version = result["protocolVersion"]?.string ?? Self.protocolVersion
        guard Self.supportedVersions.contains(version) else {
            throw MCPError("il server parla una versione MCP non supportata (\(version))")
        }
        (transport as? MCPHTTPTransport)?.protocolVersion = version
        let info = ServerInfo(
            name: result["serverInfo"]?["name"]?.string ?? "",
            version: result["serverInfo"]?["version"]?.string ?? "",
            protocolVersion: version,
            instructions: result["instructions"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        )
        server = info
        try await notify("notifications/initialized")
        return info
    }

    /// Every tool the server lists, following `nextCursor`.
    public func listTools(timeout: TimeInterval) async throws -> [JSON] {
        var tools: [JSON] = []
        var cursor: String?
        // a server that hands back the same cursor forever must not hang the engine
        for _ in 0..<50 {
            var params = JSONObject()
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await request("tools/list", .object(params), timeout: timeout)
            tools += page["tools"]?.array ?? []
            guard let next = page["nextCursor"]?.string, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return tools
    }

    /// `tools/call`: the result object as the server sent it (`content`,
    /// `isError`, `structuredContent`).
    public func callTool(_ name: String, arguments: JSON, timeout: TimeInterval) async throws -> JSON {
        let args: JSON = arguments.object != nil ? arguments : .object(JSONObject())
        return try await request("tools/call", ["name": .string(name), "arguments": args], timeout: timeout)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        transport.close()
        failPending(MCPError("connessione chiusa"))
    }

    // MARK: JSON-RPC

    func request(_ method: String, _ params: JSON, timeout: TimeInterval, retryExpiredSession: Bool = true) async throws -> JSON {
        do {
            return try await rawRequest(method, params, timeout: timeout)
        } catch let error as MCPError where error.sessionExpired && retryExpiredSession {
            // the HTTP server forgot us (restart, eviction): new session, once
            guard let http = transport as? MCPHTTPTransport else { throw error }
            http.resetSession()
            _ = try await initialize(timeout: min(timeout, 30))
            return try await rawRequest(method, params, timeout: timeout)
        }
    }

    private func rawRequest(_ method: String, _ params: JSON, timeout: TimeInterval) async throws -> JSON {
        guard !closed else { throw MCPError(closeReason.map { "connettore non disponibile: \($0)" } ?? "connessione chiusa") }
        let id = nextId
        nextId += 1
        let message: JSON = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSON, Error>) in
                pending[id] = continuation
                Task { @MainActor [weak self] in
                    do {
                        try await self?.transport.send(message)
                    } catch {
                        self?.settle(id, .failure(error))
                    }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                    guard let self, self.pending[id] != nil else { return }
                    self.cancelRemote(id, reason: "timeout")
                    self.settle(id, .failure(MCPError("\(method): nessuna risposta in \(Int(timeout)) s")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pending[id] != nil else { return }
                self.cancelRemote(id, reason: "interrupted")
                self.settle(id, .failure(CancellationError()))
            }
        }
    }

    private func notify(_ method: String, _ params: JSON? = nil) async throws {
        var message: JSONObject = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        try await transport.send(.object(message))
    }

    private func cancelRemote(_ id: Int, reason: String) {
        Task { @MainActor [weak self] in
            try? await self?.notify("notifications/cancelled", ["requestId": .number(Double(id)), "reason": .string(reason)])
        }
    }

    private func settle(_ id: Int, _ result: Result<JSON, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func receive(_ message: JSON) {
        let method = message["method"]?.string
        if let method {
            if let id = message["id"], !id.isNull {
                // a server request: we only know ping
                let reply: JSON = method == "ping"
                    ? ["jsonrpc": "2.0", "id": id, "result": .object(JSONObject())]
                    : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]]
                Task { @MainActor [weak self] in try? await self?.transport.send(reply) }
            } else if method == "notifications/tools/list_changed" {
                onToolsChanged?()
            }
            return
        }
        guard let id = message["id"]?.int else { return }
        if let error = message["error"], !error.isNull {
            let text = error["message"]?.string ?? "errore"
            settle(id, .failure(MCPError("\(text)\(error["code"]?.int.map { " (\($0))" } ?? "")")))
        } else {
            settle(id, .success(message["result"] ?? .null))
        }
    }

    private func transportClosed(_ reason: String?) {
        closeReason = reason
        closed = true
        failPending(MCPError(reason.map { "connettore non disponibile: \($0)" } ?? "connessione chiusa"))
        onClose?(reason)
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}
