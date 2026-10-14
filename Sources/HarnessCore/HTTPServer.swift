// A small HTTP/1.1 server on Network.framework, for loopback only.
//
// The harness API is JSON in, JSON out, plus one long-lived event stream —
// a few hundred lines of HTTP, not a framework. What it does carefully:
// requests split across packets, keep-alive, body limits enforced while
// reading, and the two gates every route sits behind in the Node engine:
// a loopback Host (DNS rebinding) and a loopback Origin when one is sent.
import Foundation
import Network

public struct HTTPRequest {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Lower-cased names.
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var contentType: String {
        (header("content-type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    public var isJSON: Bool { contentType == "application/json" }

    /// The body as a JSON object; empty body reads as `{}` like `readBody`.
    public func json() throws -> JSONObject {
        if body.isEmpty { return JSONObject() }
        guard let object = try JSON.parse(body).object else { throw HTTPError(400, "body must be a JSON object") }
        return object
    }
}

public struct HTTPError: Error {
    public var status: Int
    public var message: String
    public init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ value: JSON) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")], body: value.data)
    }

    public static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": .string(message)])
    }
}

/// A response whose body keeps flowing: the SSE stream.
public final class StreamWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    public private(set) var closed = false
    var onClose: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func write(_ text: String) {
        queue.async { [self] in
            guard !closed else { return }
            connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() }
            })
        }
    }

    public func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            connection.cancel()
            let callback = onClose
            onClose = nil
            if let callback { Task { @MainActor in callback() } }
        }
    }
}

public enum RouteResult {
    case response(HTTPResponse)
    /// Headers are written, then `start` owns the connection until close.
    case stream(headers: [(String, String)], start: @MainActor (StreamWriter) -> Void)
}

public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @MainActor (HTTPRequest) async -> RouteResult

    private let queue = DispatchQueue(label: "swarme.http")
    private var listener: NWListener?
    private let handler: Handler
    /// JSON bodies; raw uploads declare their own larger limit per route.
    public var maxBody = 12 * 1024 * 1024

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start(host: String = "127.0.0.1", port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case let .failed(error):
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: HTTPError(500, "listener cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Read more bytes, then try to parse.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if error != nil { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }
            self.process(connection, buffer: next, peerClosed: complete)
        }
    }

    /// Parse what is buffered before reading again: a keep-alive client may
    /// already have sent the next request.
    private func process(_ connection: NWConnection, buffer: Data, peerClosed: Bool = false) {
        var buffer = buffer
        switch parse(&buffer) {
        case .needMore:
            if peerClosed { connection.cancel(); return }
            receive(connection, buffer: buffer)
        case let .failed(status, message):
            send(connection, .error(status, message), keepAlive: false)
        case let .request(request, keepAlive):
            let rest = buffer
            let handler = self.handler
            Task { @MainActor in
                let result: RouteResult
                if let refused = Self.gate(request) { result = refused } else { result = await handler(request) }
                switch result {
                case let .response(response):
                    self.queue.async {
                        self.send(connection, response, keepAlive: keepAlive)
                        if keepAlive { self.process(connection, buffer: rest) }
                    }
                case let .stream(headers, start):
                    let writer = StreamWriter(connection: connection, queue: self.queue)
                    var head = "HTTP/1.1 200 OK\r\n"
                    for (name, value) in headers { head += "\(name): \(value)\r\n" }
                    head += "\r\n"
                    writer.write(head)
                    // a client hang-up shows as a completed receive
                    self.queue.async { self.watchClose(connection, writer) }
                    start(writer)
                }
            }
        }
    }

    private func watchClose(_ connection: NWConnection, _ writer: StreamWriter) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            if complete || error != nil { writer.close() } else { self?.watchClose(connection, writer) }
        }
    }

    private enum Parsed {
        case needMore
        case failed(Int, String)
        case request(HTTPRequest, keepAlive: Bool)
    }

    private func parse(_ buffer: inout Data) -> Parsed {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .failed(431, "headers too large") : .needMore
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .failed(400, "bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .failed(411, "chunked bodies are not supported; send Content-Length")
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBody else { return .failed(413, "body too large") }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return .needMore }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = buffer[bodyStart..<bodyEnd]
        buffer = Data(buffer[bodyEnd...])

        let target = String(requestLine[1])
        let components = URLComponents(string: "http://localhost\(target)")
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        let keepAlive = headers["connection"]?.lowercased() != "close"
        let request = HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.percentEncodedPath ?? target,
            query: query, headers: headers, body: Data(body)
        )
        return .request(request, keepAlive: keepAlive)
    }

    private func send(_ connection: NWConnection, _ response: HTTPResponse, keepAlive: Bool) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\n"
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            if !keepAlive { connection.cancel() }
        })
    }

    /// The loopback gates, before any route.
    @MainActor
    static func gate(_ request: HTTPRequest) -> RouteResult? {
        let host = request.header("host") ?? ""
        if !isLoopbackHost(host) {
            return .response(.error(403, "forbidden: loopback host required"))
        }
        if let origin = request.header("origin"), !origin.isEmpty, origin != "null" {
            guard let url = URL(string: origin), ["http", "https"].contains(url.scheme ?? ""),
                  isLoopbackHost(url.host ?? "") else {
                return .response(.error(403, "forbidden: cross-origin request"))
            }
        }
        return nil
    }

    static func isLoopbackHost(_ raw: String) -> Bool {
        var host = raw.lowercased()
        if host.hasPrefix("[") {
            return host.hasPrefix("[::1]")
        }
        if let colon = host.lastIndex(of: ":") {
            guard host[host.index(after: colon)...].allSatisfy(\.isNumber) else { return false }
            host = String(host[..<colon])
        }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }
}
