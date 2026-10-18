// The DeepSeek Harness Host API client — `server/drivers/deepseek-harness/
// {client,protocol,models}.ts`, ported.
//
// DSH is a separate server, not a CLI: unary calls are HTTP POSTs of a
// `client-request` envelope to `/api/<method>` (or `/remote/api/<method>`
// for a paired device, with its cookie), answers to server→client asks go to
// `/api/respond`, and two WebSocket downlinks — `events.mux` (sessions) and
// `events.host` (the host) — carry `server-request` frames.
//
// It lives in HarnessCore, not with the driver, because the settings routes
// (DeepSeekSettings.swift) speak the same API.
//
// Kept from the Node client:
// - strict readiness: a turn may start only while BOTH downlinks are open;
// - a paired credential rejected on any HTTP call is latched as revoked and
//   the streams stop reconnecting with it (re-pairing builds a new client);
// - loopback-only methods are refused through paired transport;
// - bodies and frames are bounded (1 MB), rpc ids must round-trip.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DSHRpcError: LocalizedError {
    public let code: String
    public var errorDescription: String? { "DSH request was rejected (\(code))" }
}

public struct DSHTransportError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum DSHProtocol {
    public static let maxJSONBytes = 1_000_000

    static let muxTypes: Set<String> = [
        "session/event", "session/subscribed", "approval/requested", "approval/resolved", "question/requested",
        "question/resolved", "session/queue", "session/jobs", "session/projection", "stream/error",
    ]
    static let hostTypes: Set<String> = [
        "host/session-added", "host/session-removed", "host/session-status", "host/agent-error", "host/workspace-changed",
        "host/workspace-removed", "host/workspace-order-changed", "host/archived-sessions-changed", "host/remote-event", "stream/error",
    ]

    /// Outbound methods are dot-qualified domain calls, never URL paths.
    public static func isApiMethod(_ value: String) -> Bool {
        value.count >= 3 && value.count <= 160
            && value.range(of: #"^[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+$"#, options: .regularExpression) != nil
    }

    static let pairedLoopbackOnly: Set<String> = [
        "host.pickDirectory", "host.openPath", "agentPreset.read", "agentPreset.copy", "agentPreset.openDocument", "agentPreset.remove",
        // older builds called this domain agentPresets
        "agentPresets.read", "agentPresets.copy", "agentPresets.openDocument", "agentPresets.remove",
    ]

    static func pairedMethodIsLoopbackOnly(_ method: String) -> Bool {
        method.hasPrefix("settings.") || method.hasPrefix("credentials.") || method == "llm.discoverModels" || pairedLoopbackOnly.contains(method)
    }

    /// A stream frame the client may hand on: a server-request whose method
    /// names its payload type, from the union of its downlink.
    static func streamFrame(_ text: String, kind: DSHClient.StreamKind) -> JSON? {
        guard let frame = try? JSON.parse(text), frame["type"]?.string == "server-request", frame["rpcId"]?.string != nil,
              let method = frame["method"]?.string, frame["payload"]?.object != nil, frame["payload"]?["type"]?.string == method,
              (kind == .mux ? muxTypes : hostTypes).contains(method) else { return nil }
        if method == "stream/error" { return frame["payload"]?["error"]?["code"]?.string != nil ? frame : nil }
        if method != "host/workspace-changed", method != "host/workspace-removed", method != "host/workspace-order-changed",
           method != "host/archived-sessions-changed", method != "host/remote-event",
           (frame["payload"]?["sessionId"]?.string ?? "").isEmpty { return nil }
        return frame
    }

    static func nonEmpty(_ value: JSON?) -> Bool { !(value?.string ?? "").isEmpty }

    /// The unary value shapes the client checks before handing a value on
    /// (`dshUnaryValueSchema`). Unknown methods pass through as JSON data.
    static func validUnaryValue(_ method: String, _ value: JSON?) -> Bool {
        guard let value else { return !["session.create", "session.selectModel", "session.prompt", "session.cancel", "host.describe",
                                         "llm.providers", "llm.models", "llm.discoverModels", "settings.describe", "settings.mutate",
                                         "agentPreset.list"].contains(method) }
        switch method {
        case "session.create": return nonEmpty(value["sessionId"])
        case "session.selectModel":
            return nonEmpty(value["selected"]?["provider"]) && nonEmpty(value["selected"]?["model"])
        case "session.prompt", "session.cancel": return value["accepted"]?.bool == true
        case "host.describe":
            return value["version"]?.string != nil && value["cwd"]?.string != nil && value["home"]?.string != nil
                && value["attachedSessions"]?.double != nil && value["canOpenPath"]?.bool != nil
        case "llm.providers": return value["providers"]?.array != nil
        case "llm.models": return value["groups"]?.array != nil && value["failures"]?.array != nil
        case "llm.discoverModels": return value["models"]?.array != nil
        case "settings.describe": return value["writable"]?.bool != nil && value["namespaces"]?.array != nil
        case "settings.mutate": return nonEmpty(value["ns"]) && value["revision"]?.double != nil
        case "agentPreset.list": return value["presets"]?.array != nil
        default: return true
        }
    }

    // MARK: models

    static func base64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ text: String) -> String? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `dsh:<b64url provider>:<b64url model>` — opaque to everything but this driver.
    public static func encodeModelId(provider: String, model: String) -> String {
        "dsh:\(base64url(provider)):\(base64url(model))"
    }

    public static func decodeModelId(_ value: String?) -> (provider: String, model: String)? {
        guard let value, value.range(of: #"^dsh:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 3, let provider = fromBase64url(parts[1]), let model = fromBase64url(parts[2]),
              !provider.isEmpty, !model.isEmpty, encodeModelId(provider: provider, model: model) == value else { return nil }
        return (provider, model)
    }

    static let effortMap: [(String, String)] = [
        ("off", "none"), ("minimal", "minimal"), ("low", "low"), ("medium", "medium"), ("high", "high"), ("xhigh", "xhigh"), ("max", "max"),
    ]

    public static func mapEffortLevels(_ efforts: [String]) -> [String] {
        var mapped: [String] = []
        for effort in efforts {
            guard let level = effortMap.first(where: { $0.0 == effort })?.1, !mapped.contains(level) else { continue }
            mapped.append(level)
        }
        return mapped
    }

    static func boundedText(_ value: JSON?, _ max: Int) -> String? {
        guard let text = value?.string, !text.isEmpty, text.count <= max else { return nil }
        return text
    }

    /// `flattenDshModelCatalog`: one picker row per provider model.
    public static func flattenCatalog(_ value: JSON?) -> (catalog: ModelCatalog?, diagnostics: [String]) {
        guard let groups = value?["groups"]?.array, let failures = value?["failures"]?.array,
              groups.count <= 256, failures.count <= 256 else { return (nil, ["DSH model catalog was invalid"]) }
        var diagnostics: [String] = []
        var options: [ModelOption] = []
        for failure in failures {
            if let name = boundedText(failure["name"], 512), boundedText(failure["id"], 512) != nil,
               let message = boundedText(failure["message"], 500) { diagnostics.append("\(name): \(message)") }
        }
        for group in groups {
            guard let id = boundedText(group["id"], 512), let name = boundedText(group["name"], 512), let models = group["models"]?.array,
                  models.count <= 1_000, models.allSatisfy(validModel) else {
                diagnostics.append("DSH provider catalog entry was invalid")
                continue
            }
            for model in models {
                var option = ModelOption(id: encodeModelId(provider: id, model: model["id"]!.string!), label: "\(name): \(model["name"]!.string!)")
                if let window = model["contextWindow"]?.int { option.contextWindow = window }
                let levels = mapEffortLevels((model["reasoning"]?["efforts"]?.array ?? []).compactMap { $0["id"]?.string })
                if !levels.isEmpty { option.effortLevels = levels }
                options.append(option)
            }
        }
        return options.isEmpty ? (nil, diagnostics) : (ModelCatalog(default: options[0].id, options: options), [])
    }

    static func validModel(_ model: JSON) -> Bool {
        guard boundedText(model["id"], 512) != nil, boundedText(model["name"], 512) != nil else { return false }
        if let window = model["contextWindow"] {
            guard let value = window.double, value == value.rounded(), value > 0, value <= 10_000_000 else { return false }
        }
        if let reasoning = model["reasoning"] {
            guard let efforts = reasoning["efforts"]?.array, efforts.count <= 16,
                  efforts.allSatisfy({ boundedText($0["id"], 512) != nil && boundedText($0["name"], 512) != nil }) else { return false }
        }
        return true
    }
}

/// One DSH host connection. Main-actor bound like every driver.
@MainActor
public final class DSHClient {
    public enum StreamKind: String { case mux, host }
    public struct Health { public let kind: StreamKind; public let connected: Bool; public let generation: Int }

    static let reconnectBase: TimeInterval = 0.025
    static let reconnectMax: TimeInterval = 0.5

    public let baseUrl: URL
    public let transport: String
    private let prefix: String
    private let cookie: String?
    private let timeout: TimeInterval
    private let streamOpenTimeout: TimeInterval
    private let session: URLSession
    private let socketSession: URLSession
    private let delegate = SocketDelegate()
    private var closed = false
    private var pairedRevoked = false

    private final class Stream {
        var task: URLSessionWebSocketTask?
        var reconnect: Task<Void, Never>?
        var openTimer: Task<Void, Never>?
        var attempts = 0
        var generation = 0
        var connected = false
    }
    private var streams: [StreamKind: Stream] = [.mux: Stream(), .host: Stream()]
    private var listeners: [StreamKind: [UUID: (JSON) -> Void]] = [.mux: [:], .host: [:]]
    private var healthListeners: [UUID: (Health) -> Void] = [:]
    private var readiness: [UUID: (continuation: CheckedContinuation<Void, Error>, timer: Task<Void, Never>)] = [:]
    private var operations: [UUID: () -> Void] = [:]

    public init(baseUrl: String, transport: String, deviceCookie: String?, timeout: TimeInterval = 8, streamOpenTimeout: TimeInterval = 3) throws {
        guard let url = URL(string: baseUrl), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DSHTransportError(URL(string: baseUrl) == nil ? "DSH base URL is invalid" : "DSH base URL must use HTTP or HTTPS")
        }
        if transport == "paired" {
            guard let cookie = deviceCookie, !cookie.isEmpty, cookie.count <= 4_096, !cookie.contains("\r"), !cookie.contains("\n") else {
                throw DSHTransportError("DSH paired transport requires a device cookie")
            }
        }
        self.baseUrl = url
        self.transport = transport
        prefix = transport == "paired" ? "/remote/api" : "/api"
        cookie = transport == "paired" ? deviceCookie : nil
        self.timeout = timeout
        self.streamOpenTimeout = streamOpenTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        socketSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.owner = self
    }

    private func endpoint(_ name: String) -> URL {
        URL(string: "\(prefix)/\(name)", relativeTo: baseUrl)!.absoluteURL
    }

    private func pairedRejected(_ status: Int) -> Bool { transport == "paired" && (status == 401 || status == 403) }

    // MARK: Unary

    private func post(_ name: String, body: Data, unreachable: String) async throws -> (Int, Data) {
        if closed { throw DSHTransportError("DSH client is closed") }
        var request = URLRequest(url: endpoint(name))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpBody = body
        let id = UUID()
        let session = self.session
        let task = Task { () throws -> (Data, URLResponse) in try await session.data(for: request) }
        operations[id] = { task.cancel() }
        defer { operations[id] = nil }
        let result: (Data, URLResponse)
        do {
            result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            throw DSHTransportError(unreachable)
        }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        if result.0.count > DSHProtocol.maxJSONBytes { throw DSHTransportError("DSH response exceeds the size limit") }
        return (status, result.0)
    }

    public func unary(_ method: String, _ payload: JSON) async throws -> JSON {
        if pairedRevoked { throw DSHTransportError("DSH paired device is no longer authorized") }
        guard DSHProtocol.isApiMethod(method) else { throw DSHTransportError("DSH API method is invalid") }
        if transport == "paired", DSHProtocol.pairedMethodIsLoopbackOnly(method) {
            throw DSHTransportError("DSH method is not available through paired transport")
        }
        let rpcId = UUID().uuidString.lowercased()
        let body = JSON.object(["type": "client-request", "rpcId": .string(rpcId), "method": .string(method), "payload": payload]).data
        if body.count > DSHProtocol.maxJSONBytes { throw DSHTransportError("DSH request exceeds the size limit") }
        let (status, data) = try await post(method, body: body, unreachable: "DSH request could not reach the host")
        guard (200...299).contains(status) else {
            if pairedRejected(status) {
                invalidatePairedAuthorization()
                throw DSHTransportError("DSH paired device is no longer authorized")
            }
            throw DSHTransportError("DSH request failed with HTTP \(status)")
        }
        guard let envelope = try? JSON.parse(data), envelope["type"]?.string == "server-response", let result = envelope["result"] else {
            throw DSHTransportError("DSH response envelope was invalid")
        }
        guard envelope["rpcId"]?.string == rpcId else { throw DSHTransportError("DSH response rpc id did not match request") }
        if result["ok"]?.bool == false {
            guard let code = result["error"]?["code"]?.string else { throw DSHTransportError("DSH response envelope was invalid") }
            throw DSHRpcError(code: code)
        }
        guard result["ok"]?.bool == true else { throw DSHTransportError("DSH response envelope was invalid") }
        guard DSHProtocol.validUnaryValue(method, result["value"]) else { throw DSHTransportError("DSH response value was invalid") }
        return result["value"] ?? .null
    }

    /// Answer a server→client request; the receipt says whether it was taken.
    public func respond(_ rpcId: String, result: JSON) async throws -> JSON {
        if pairedRevoked { throw DSHTransportError("DSH paired device is no longer authorized") }
        let body = JSON.object(["type": "client-response", "rpcId": .string(rpcId), "result": result]).data
        if body.count > DSHProtocol.maxJSONBytes { throw DSHTransportError("DSH response exceeds the size limit") }
        let (status, data) = try await post("respond", body: body, unreachable: "DSH response could not reach the host")
        guard (200...299).contains(status) else {
            if pairedRejected(status) {
                invalidatePairedAuthorization()
                throw DSHTransportError("DSH paired device is no longer authorized")
            }
            throw DSHTransportError("DSH response failed with HTTP \(status)")
        }
        guard let receipt = try? JSON.parse(data), let accepted = receipt["accepted"]?.bool,
              accepted || ["not-pending", "bad-response"].contains(receipt["reason"]?.string ?? "") else {
            throw DSHTransportError("DSH response receipt was invalid")
        }
        return receipt
    }

    // MARK: Streams

    @discardableResult
    public func subscribe(_ kind: StreamKind, _ listener: @escaping (JSON) -> Void) -> () -> Void {
        let id = UUID()
        listeners[kind]?[id] = listener
        connect(kind)
        return { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.listeners[kind]?[id] = nil
                if self.listeners[kind]?.isEmpty == true { self.stopStream(kind) }
            }
        }
    }

    @discardableResult
    public func subscribeHealth(_ listener: @escaping (Health) -> Void) -> () -> Void {
        let id = UUID()
        healthListeners[id] = listener
        return { [weak self] in MainActor.assumeIsolated { _ = self?.healthListeners.removeValue(forKey: id) } }
    }

    private var bothConnected: Bool { streams[.mux]!.connected && streams[.host]!.connected }

    /// Strict readiness: unary startup proceeds only while both downlinks are open.
    public func waitForStreamsOpen() async throws {
        if closed { throw DSHTransportError("DSH client is closed") }
        if pairedRevoked { throw DSHTransportError("DSH paired device is no longer authorized") }
        if bothConnected { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.streamOpenTimeout ?? 3) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.handleStreamOpenTimeout()
            }
            readiness[id] = (continuation, timer)
        }
    }

    private func settleReadiness() {
        guard bothConnected else { return }
        let waiters = readiness.values
        readiness.removeAll()
        for waiter in waiters {
            waiter.timer.cancel()
            waiter.continuation.resume()
        }
    }

    private func rejectReadiness(_ message: String) {
        let waiters = readiness.values
        readiness.removeAll()
        for waiter in waiters {
            waiter.timer.cancel()
            waiter.continuation.resume(throwing: DSHTransportError(message))
        }
    }

    private func socketURL(_ kind: StreamKind) -> URL {
        var components = URLComponents(url: endpoint("events.\(kind.rawValue)"), resolvingAgainstBaseURL: true)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    private func connect(_ kind: StreamKind) {
        let state = streams[kind]!
        guard !closed, !pairedRevoked, listeners[kind]?.isEmpty == false, state.task == nil, state.reconnect == nil else { return }
        var request = URLRequest(url: socketURL(kind))
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let task = socketSession.webSocketTask(with: request)
        task.maximumMessageSize = DSHProtocol.maxJSONBytes
        state.task = task
        state.generation += 1
        delegate.register(task, kind: kind)
        state.openTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.streamOpenTimeout ?? 3) * 1_000_000_000))
            guard !Task.isCancelled, let self, state.task === task, !state.connected else { return }
            self.handleStreamOpenTimeout()
        }
        task.resume()
        receive(task, kind: kind)
    }

    private func receive(_ task: URLSessionWebSocketTask, kind: StreamKind) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.streams[kind]!.task === task else { return }
                switch result {
                case let .success(.string(text)):
                    if text.utf8.count <= DSHProtocol.maxJSONBytes, let frame = DSHProtocol.streamFrame(text, kind: kind) {
                        for listener in Array(self.listeners[kind]!.values) { listener(frame) }
                    }
                    self.receive(task, kind: kind)
                case .success:
                    self.receive(task, kind: kind) // binary frames are ignored
                case .failure:
                    self.socketClosed(task, kind: kind)
                }
            }
        }
    }

    fileprivate func socketOpened(_ task: URLSessionTask, kind: StreamKind) {
        let state = streams[kind]!
        guard state.task === task else { return }
        state.openTimer?.cancel()
        state.openTimer = nil
        state.attempts = 0
        state.connected = true
        emitHealth(kind, connected: true, generation: state.generation)
        settleReadiness()
    }

    fileprivate func socketClosed(_ task: URLSessionTask, kind: StreamKind) {
        let state = streams[kind]!
        guard state.task === task else { return }
        state.openTimer?.cancel()
        state.openTimer = nil
        state.task = nil
        state.connected = false
        emitHealth(kind, connected: false, generation: state.generation)
        scheduleReconnect(kind)
    }

    private func scheduleReconnect(_ kind: StreamKind) {
        let state = streams[kind]!
        guard !closed, !pairedRevoked, listeners[kind]?.isEmpty == false, state.reconnect == nil else { return }
        let delay = min(Self.reconnectBase * pow(2, Double(state.attempts)), Self.reconnectMax)
        state.attempts = min(state.attempts + 1, 10)
        state.reconnect = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            state.reconnect = nil
            guard !Task.isCancelled else { return }
            self?.connect(kind)
        }
    }

    private func stopStream(_ kind: StreamKind) {
        let state = streams[kind]!
        state.reconnect?.cancel()
        state.openTimer?.cancel()
        state.reconnect = nil
        state.openTimer = nil
        let task = state.task
        state.task = nil
        state.connected = false
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func dropAll(reconnect: Bool) {
        for kind in [StreamKind.mux, .host] {
            let state = streams[kind]!
            state.reconnect?.cancel()
            state.openTimer?.cancel()
            state.reconnect = nil
            state.openTimer = nil
            let lost = state.task != nil || state.connected
            let task = state.task
            state.task = nil
            state.connected = false
            task?.cancel(with: .goingAway, reason: nil)
            if lost { emitHealth(kind, connected: false, generation: state.generation) }
        }
        if reconnect { for kind in [StreamKind.mux, .host] where listeners[kind]?.isEmpty == false { scheduleReconnect(kind) } }
    }

    private func handleStreamOpenTimeout() {
        guard !closed else { return }
        rejectReadiness("DSH event streams did not open")
        dropAll(reconnect: true)
    }

    /// A rejected paired credential: never reconnect with it.
    private func invalidatePairedAuthorization() {
        guard !pairedRevoked else { return }
        pairedRevoked = true
        rejectReadiness("DSH paired device is no longer authorized")
        dropAll(reconnect: false)
    }

    private func emitHealth(_ kind: StreamKind, connected: Bool, generation: Int) {
        for listener in Array(healthListeners.values) { listener(Health(kind: kind, connected: connected, generation: generation)) }
    }

    /// Provider-wide teardown: in-flight calls abort, streams stay usable.
    public func abortOperations() {
        for cancel in operations.values { cancel() }
        operations.removeAll()
        rejectReadiness("DSH event stream wait was aborted")
    }

    public func close() {
        guard !closed else { return }
        closed = true
        abortOperations()
        stopStream(.mux)
        stopStream(.host)
        session.invalidateAndCancel()
        socketSession.invalidateAndCancel()
    }
}

/// URLSession's WebSocket open/close callbacks, hopped to the main actor.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: DSHClient?
    private let lock = NSLock()
    private var kinds: [Int: DSHClient.StreamKind] = [:]

    func register(_ task: URLSessionTask, kind: DSHClient.StreamKind) {
        lock.lock()
        kinds[task.taskIdentifier] = kind
        lock.unlock()
    }

    private func kind(_ task: URLSessionTask) -> DSHClient.StreamKind? {
        lock.lock()
        defer { lock.unlock() }
        return kinds[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard let kind = kind(webSocketTask) else { return }
        Task { @MainActor [weak owner] in owner?.socketOpened(webSocketTask, kind: kind) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let kind = kind(webSocketTask) else { return }
        Task { @MainActor [weak owner] in owner?.socketClosed(webSocketTask, kind: kind) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let kind = kind(task) else { return }
        Task { @MainActor [weak owner] in owner?.socketClosed(task, kind: kind) }
    }
}

/// `redirect: "manual"`: a redirect is answered, never followed.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
