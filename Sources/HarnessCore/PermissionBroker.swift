// The permission broker — `createPermissionBroker` in `server/drivers/claude.ts`.
//
// A headless run that hits a permission its mode doesn't cover should
// neither stall silently nor be blanket-denied: it should ask the user. The
// broker is a unix-socket server, one per turn; the permission proxy (an MCP
// server the CLI spawns: `swarme-harness mcp-permission <socket>`) forwards
// each ask over it as `{"t":"ask",…}` and waits for `{"t":"answer",…}`.
//
// Rules kept from the Node engine, each one a fixed bug:
// - an unanswered permission denies after the timeout with a keep-moving
//   note; an unanswered question answers "use your best judgment";
// - a duplicate ask id is denied before either ask becomes visible;
// - after close() every ask — pending or new, on a connection that is still
//   open — gets a system answer and never a card (the "zombie card", #211).
import CryptoKit
import Foundation

public struct BrokerAsk: Sendable {
    public enum Kind: String, Sendable { case permission, question }
    public var id: String
    public var kind: Kind
    public var tool: String
    public var input: JSON
}

/// The socket side: accept and read on a private queue, hand complete lines
/// to the main actor in order. Never closes a connection itself — the main
/// actor does, so an fd cannot be reused while an answer is on its way to it.
final class BrokerSocket: @unchecked Sendable {
    enum Event {
        case opened(Int32)
        case line(Int32, String)
        case ended(Int32)
    }

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "swarmebot.permission-broker")
    private var acceptSource: DispatchSourceRead?
    private var readers: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]

    init() {
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    func listen(on fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        acceptSource = source
        source.resume()
    }

    private func acceptOne(_ listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        _ = fcntl(client, F_SETNOSIGPIPE, 1)
        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.readFrom(client) }
        readers[client] = (source, Data())
        continuation.yield(.opened(client))
        source.resume()
    }

    private func readFrom(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0, var entry = readers[fd] else {
            readers.removeValue(forKey: fd)?.source.cancel()
            continuation.yield(.ended(fd))
            return
        }
        entry.buffer.append(contentsOf: chunk[0..<count])
        while let newline = entry.buffer.firstIndex(of: 0x0A) {
            continuation.yield(.line(fd, String(decoding: entry.buffer[entry.buffer.startIndex..<newline], as: UTF8.self)))
            entry.buffer.removeSubrange(entry.buffer.startIndex...newline)
        }
        readers[fd] = entry
    }

    /// Stop accepting; open connections keep being read.
    func stopAccepting() {
        queue.async { [self] in
            acceptSource?.cancel()
            acceptSource = nil
        }
    }

    func finish() {
        queue.async { [self] in
            acceptSource?.cancel()
            acceptSource = nil
            for (fd, entry) in readers {
                entry.source.cancel()
                continuation.yield(.ended(fd))
            }
            readers.removeAll()
            continuation.finish()
        }
    }
}

@MainActor
public final class PermissionBroker {
    public static let denyTimeoutNote = "SwarmeBot: nobody answered this permission request in time. Skip this action and finish what you can without it."
    public static let questionTimeoutNote = "SwarmeBot: nobody answered in time. Use your best judgment and continue."
    public static let duplicateAskNote = "SwarmeBot: duplicate ask id — skipping this request."

    public let socketPath: String
    private let timeout: TimeInterval
    private let onAsk: (BrokerAsk) -> Void
    private let onResolve: (BrokerAsk, String, String) -> Void
    private let io = BrokerSocket()
    private var open: Set<Int32> = []
    private var pending: [String: (ask: BrokerAsk, fd: Int32, timer: Task<Void, Never>)] = [:]
    private var closed = false

    /// `permissionSocketPath`: a readable prefix plus a digest of the full id,
    /// short enough for the 104-byte sun_path under a deep data dir.
    public static func socketPath(dataDir: URL, threadId: String) -> String {
        let prefix = String(threadId.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(4))
        let digest = SHA256.hash(data: Data(threadId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(4)
        return dataDir.appendingPathComponent("perm-\(prefix)\(digest).sock").path
    }

    static func systemEndedReply(_ kind: BrokerAsk.Kind) -> (behavior: String, message: String) {
        kind == .question ? ("answer", "SwarmeBot: the turn is ending — wrap up.") : ("deny", "SwarmeBot: the turn ended")
    }

    /// `askSummary`: the one line the card shows.
    public static func summary(_ ask: BrokerAsk) -> String {
        if let question = ask.input["question"]?.string { return String(question.prefix(300)) }
        if let command = ask.input["command"]?.string { return String(command.prefix(200)) }
        if let url = ask.input["url"]?.string { return String(url.prefix(200)) }
        let text = (ask.input.isNull ? JSON.object(JSONObject()) : ask.input).serialized()
        return text == "{}" ? ask.tool : String(text.prefix(200))
    }

    public init(socketPath: String, timeout: TimeInterval = 15 * 60,
                onAsk: @escaping (BrokerAsk) -> Void,
                onResolve: @escaping (_ ask: BrokerAsk, _ behavior: String, _ source: String) -> Void) {
        self.socketPath = socketPath
        self.timeout = timeout
        self.onAsk = onAsk
        self.onResolve = onResolve
        listen()
    }

    private func listen() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(socketPath.utf8)
        guard fd >= 0, bytes.count < capacity else {
            // fail-closed, but say why: every ask would otherwise time out unexplained
            FileHandle.standardError.write(Data("permission broker unavailable on \(socketPath): socket path unusable\n".utf8))
            if fd >= 0 { Darwin.close(fd) }
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            FileHandle.standardError.write(Data("permission broker unavailable on \(socketPath): \(String(cString: strerror(errno)))\n".utf8))
            Darwin.close(fd)
            return
        }
        chmod(socketPath, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        io.listen(on: fd)
        Task { @MainActor [weak self, io] in
            for await event in io.events {
                guard let self else { continue }
                switch event {
                case let .opened(client): self.open.insert(client)
                case let .line(client, line): self.handle(line, fd: client)
                case let .ended(client):
                    if self.open.remove(client) != nil { Darwin.close(client) }
                }
            }
        }
    }

    private func write(_ fd: Int32, _ message: JSON) {
        guard open.contains(fd) else { return }
        let bytes = Array((message.serialized() + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            offset += written
        }
    }

    private func answerFrame(_ id: String, _ behavior: String, _ message: String?) -> JSON {
        var frame: JSONObject = ["t": "answer", "id": .string(id), "behavior": .string(behavior)]
        if let message { frame["message"] = .string(message) }
        return .object(frame)
    }

    private func handle(_ line: String, fd: Int32) {
        guard let message = try? JSON.parse(line), message["t"]?.string == "ask" else { return }
        let askId: String = {
            switch message["id"] {
            case let .string(id)?: return id
            case let .number(n)?: return JSON.format(n)
            default: return newId()
            }
        }()
        let kind: BrokerAsk.Kind = message["kind"]?.string == "question" ? .question : .permission
        if closed {
            // terminal, and it beats every other rule: answer, never register
            let reply = Self.systemEndedReply(kind)
            write(fd, answerFrame(askId, reply.behavior, reply.message))
            return
        }
        if pending[askId] != nil {
            FileHandle.standardError.write(Data("permission broker on \(socketPath): duplicate ask id \(JSON.string(askId).serialized()) — denying\n".utf8))
            write(fd, answerFrame(askId, "deny", Self.duplicateAskNote))
            return
        }
        let ask = BrokerAsk(id: askId, kind: kind, tool: message["tool"]?.string ?? "tool", input: message["input"] ?? .object(JSONObject()))
        let timeout = timeout
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if kind == .question { self?.finish(askId, "answer", Self.questionTimeoutNote, source: "timeout") }
            else { self?.finish(askId, "deny", Self.denyTimeoutNote, source: "timeout") }
        }
        pending[askId] = (ask, fd, timer)
        onAsk(ask)
    }

    private func finish(_ askId: String, _ behavior: String, _ message: String?, source: String) {
        guard let entry = pending.removeValue(forKey: askId) else { return }
        entry.timer.cancel()
        write(entry.fd, answerFrame(askId, behavior, message))
        onResolve(entry.ask, behavior, source)
    }

    /// The user's answer. False when nothing is pending under that id, or the
    /// behavior does not fit the ask (an "answer" to a permission, say).
    public func answer(_ askId: String, behavior: String, message: String?) -> Bool {
        guard let entry = pending[askId] else { return false }
        if entry.ask.kind == .question ? behavior != "answer" : behavior == "answer" { return false }
        finish(askId, behavior, message, source: "user")
        return true
    }

    public func close() {
        guard !closed else { return }
        closed = true
        for (askId, entry) in pending {
            let reply = Self.systemEndedReply(entry.ask.kind)
            finish(askId, reply.behavior, reply.message, source: "system")
        }
        // stop accepting; connections already open stay answerable (closed branch)
        io.stopAccepting()
        unlink(socketPath)
    }

    /// Drop the open connections too — once the CLI tree is gone.
    public func shutdown() {
        close()
        io.finish()
    }
}
