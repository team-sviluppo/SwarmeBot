// `GET /api/events` — the one stream every client folds.
//
// Same framing and resume rules as the Node engine (contract §3): each frame
// is `id: <stream>:<seq>` + one `data:` line; the first frame of a connection
// is a `hello` with the cursor and whether the gap could be replayed from the
// last 500 frames; screen frames keep their slot in the buffer but never
// their pixels; a comment every 25 s keeps NATs from dropping the socket.
// Behind a proxy (the remote engine) the comment comes more often and the
// stream asks not to be buffered; a revoked device loses its streams.
import Foundation

@MainActor
public final class SSEHub {
    private struct Client {
        let writer: StreamWriter
        let screens: Bool
        let deviceId: String?
    }

    private struct Buffered {
        let seq: Int
        let kind: String
        let frame: String?
    }

    public let streamId = String(UUID().uuidString.lowercased().prefix(8))
    public private(set) var lastSeq = 0
    private var buffer: [Buffered] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private var keepalive: Task<Void, Never>?
    static let replayMax = 500
    /// Seconds between keepalive comments; read on every round.
    public var keepaliveSeconds: UInt64 = 25
    /// `X-Accel-Buffering: no` on the stream, for nginx-style proxies.
    public var proxyFriendly = false

    public init() {
        // a Task, not a Timer: under dispatchMain() the main run loop never
        // runs, so a scheduled Timer would never fire
        keepalive = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let seconds = self?.keepaliveSeconds ?? 25
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard let self else { return }
                for client in self.clients.values { client.writer.write(": keepalive\n\n") }
            }
        }
    }

    public func broadcast(_ payload: JSONObject) {
        lastSeq += 1
        let kind = payload["kind"]?.string ?? ""
        var body = payload
        body["seq"] = .number(Double(lastSeq))
        let frame = "id: \(streamId):\(lastSeq)\ndata: \(JSON.object(body).serialized())\n\n"
        buffer.append(Buffered(seq: lastSeq, kind: kind, frame: kind == "screen" ? nil : frame))
        if buffer.count > Self.replayMax { buffer.removeFirst(buffer.count - Self.replayMax) }
        for client in clients.values where kind != "screen" || client.screens {
            client.writer.write(frame)
        }
    }

    func cursorSeq(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == streamId, let seq = Int(parts[1]), seq >= 0 else { return nil }
        return seq
    }

    public func route(_ request: HTTPRequest) -> RouteResult {
        let screens = request.query["screens"] != "off"
        let since = cursorSeq(request.query["since"] ?? request.header("last-event-id"))
        let deviceId = request.deviceId
        var headers = [
            ("Content-Type", "text/event-stream"),
            ("Cache-Control", "no-cache"),
            ("Connection", "keep-alive"),
        ]
        if proxyFriendly { headers.append(("X-Accel-Buffering", "no")) }
        return .stream(headers: headers) { [weak self] writer in
            guard let self else { return }
            let resumed: Bool
            if let since, since <= self.lastSeq {
                resumed = self.buffer.isEmpty ? since == self.lastSeq : self.buffer[0].seq <= since + 1
            } else {
                resumed = false
            }
            let hello: JSON = ["kind": "hello", "cursor": .string("\(self.streamId):\(self.lastSeq)"), "resumed": .bool(resumed)]
            writer.write("data: \(hello.serialized())\n\n")
            if resumed, let since {
                for frame in self.buffer where frame.seq > since {
                    guard let text = frame.frame, frame.kind != "screen" || screens else { continue }
                    writer.write(text)
                }
            }
            let key = ObjectIdentifier(writer)
            self.clients[key] = Client(writer: writer, screens: screens, deviceId: deviceId)
            writer.onClose = { [weak self] in self?.clients.removeValue(forKey: key) }
        }
    }

    public var clientCount: Int { clients.count }

    /// A revoked device keeps no open stream.
    public func close(deviceId: String) {
        for client in clients.values where client.deviceId == deviceId { client.writer.close() }
    }
}
