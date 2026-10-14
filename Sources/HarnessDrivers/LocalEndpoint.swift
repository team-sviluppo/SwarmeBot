// Local Endpoint — `server/drivers/local-endpoint.ts`, ported.
//
// OpenAI-compatible chat completions against whatever endpoint the user
// configured (LiteLLM, vLLM, llama.cpp, a hosted proxy). The catalog is the
// endpoint's /v1/models; URL and key are settings, not a CLI login.
//
// The subtle part is Hermes Agent's session continuity, and it is kept rule
// for rule because every rule cost a bug to learn:
//
// - we always name the session ourselves (`swarme-<uuid>`), never let Hermes
//   derive one from the first message;
// - while the endpoint is unproven ("unknown") the header goes out AND the
//   body carries the whole branch — right against Hermes and against a plain
//   endpoint alike;
// - only OUR id echoed back proves continuity; LiteLLM echoes upstream
//   headers as `llm_provider-<name>` and only on non-streamed answers, so a
//   silent stream proves nothing either way;
// - only an explicit 403 refusal or a capabilities verdict turns it off, and
//   a 403 mid-turn is recovered by replaying the full branch without header.
import Foundation
import HarnessCore

public struct LocalEndpointDriver: ProviderDriver {
    public let driverKind = "localEndpoint"
    public let displayName = "Local Endpoint"
    public let access = "custom"

    public init() {}

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        let instance = LocalEndpointInstance(input: input)
        await instance.refreshModels()
        return instance
    }
}

/// What we know about the endpoint's ability to hold the conversation.
enum Continuity: Equatable {
    case unknown
    case session(header: String)
    case none
}

struct EndpointError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class LocalEndpointInstance: ProviderInstance, ProviderAdapter {
    static let hostId = "local_endpoint"
    static let hermesHeader = "X-Hermes-Session-Id"
    static let proxyPrefix = "llm_provider-"
    static let noEndpoint = "Set the Local Endpoint URL in Settings → Connections"
    static let noKey = "Add a Local Endpoint API key in Settings → Connections"

    let instanceId: InstanceID
    let driverKind = "localEndpoint"
    let displayName: String?
    let enabled: Bool
    private(set) var models = ModelCatalog.empty
    var adapter: ProviderAdapter { self }
    let provider = "localEndpoint"
    /// Images go out as `image_url` parts whatever the model: an endpoint
    /// that cannot see them answers with its own error.
    let capabilities: AdapterCapabilities = {
        var capabilities = AdapterCapabilities()
        capabilities.images = true
        return capabilities
    }()

    private let env: [String: String]
    private let host: LocalHost?
    private let apiKey: String
    private let hasKey: Bool
    var hermes: Continuity = .unknown
    private var active: [ThreadID: (task: Task<Void, Never>, turnId: String)] = [:]
    private let events = EventEmitter()
    let session: URLSession

    init(input: DriverCreateInput, session: URLSession = .shared) {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        env = input.environment
        host = LocalHosts.resolve(Self.hostId, env: input.environment)
        apiKey = host.map { LocalHosts.apiKey($0, env: input.environment) } ?? ""
        hasKey = !(input.environment[LocalHosts.apiKeyEnv] ?? "").isEmpty
        self.session = session
    }

    // MARK: Catalog

    func refreshModels() async {
        guard let host else { return }
        async let resolved = LocalHosts.probe(hostIds: [Self.hostId], env: env, session: session)
        async let probed = probeHermes(host)
        let (options, verdict) = await (resolved, probed)
        if !options.isEmpty { models = ModelCatalog(default: "", options: options) }
        // an inconclusive probe never undoes what a real turn established
        if let verdict, verdict != .unknown || hermes == .unknown { hermes = verdict }
    }

    /// `/v1/capabilities`: only a clear "hermes-agent with auth" is a yes; only
    /// an answer naming something else is a no; anything else stays unknown.
    func probeHermes(_ host: LocalHost) async -> Continuity? {
        guard let url = URL(string: host.baseUrl.trimmingSuffix("/") + "/capabilities") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return .unknown }
        guard let json = try? JSON.parse(data) else { return .unknown }
        guard json["platform"]?.string == "hermes-agent" else { return Continuity.none }
        guard json["auth"]?["required"]?.bool == true else { return Continuity.none }
        let header = json["features"]?["session_continuity_header"]?.string
        return .session(header: (header?.isEmpty == false ? header! : Self.hermesHeader))
    }

    func snapshot() async -> ProviderSnapshot {
        if host == nil { return .unavailable(Self.noEndpoint) }
        if !hasKey { return .unavailable(Self.noKey) }
        return .available(version: nil)
    }

    func dispose() async {
        await stopAll()
        events.removeAll()
    }

    // MARK: Requests

    static func apiModel(_ id: String?) -> String { LocalHosts.decode(id)?.model ?? id ?? "" }

    struct Completion {
        var text: String
        var usage: RuntimeEvent.TokenUsage?
        var sessionId: String?
    }

    /// The session Hermes says served the turn — directly or renamed by a proxy.
    static func sessionEcho(_ response: HTTPURLResponse, _ name: String) -> String? {
        let value = response.value(forHTTPHeaderField: name) ?? response.value(forHTTPHeaderField: proxyPrefix + name)
        return value?.isEmpty == false ? value : nil
    }

    func complete(_ messages: [JSON], model: String, stream: Bool, sessionId: String?,
                  onDelta: ((String) -> Void)? = nil) async throws -> Completion {
        guard let host, let url = URL(string: host.baseUrl + "/chat/completions") else { throw EndpointError(status: 0, message: Self.noEndpoint) }
        let headerName: String
        if case let .session(header) = hermes { headerName = header } else { headerName = Self.hermesHeader }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: headerName) }
        request.httpBody = JSON.object(["model": .string(model), "messages": .array(messages), "stream": .bool(stream)]).data

        if !stream {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let echo = http.flatMap { Self.sessionEcho($0, headerName) }
            guard let http, (200...299).contains(http.statusCode) else {
                let body = String(decoding: data.prefix(200), as: UTF8.self)
                throw EndpointError(status: http?.statusCode ?? 0, message: "Local Endpoint HTTP \(http?.statusCode ?? 0)\(body.isEmpty ? "" : ": \(body)")")
            }
            let json = try? JSON.parse(data)
            let usage = json?["usage"].map { RuntimeEvent.TokenUsage(input: $0["prompt_tokens"]?.double ?? 0, output: $0["completion_tokens"]?.double ?? 0) }
            return Completion(text: json?["choices"]?.array?.first?["message"]?["content"]?.string ?? "", usage: usage, sessionId: echo)
        }

        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let echo = http.flatMap { Self.sessionEcho($0, headerName) }
        guard let http, (200...299).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 200 { break }
            }
            let text = String(decoding: body, as: UTF8.self)
            throw EndpointError(status: http?.statusCode ?? 0, message: "Local Endpoint HTTP \(http?.statusCode ?? 0)\(text.isEmpty ? "" : ": \(text)")")
        }
        var text = ""
        var usage: RuntimeEvent.TokenUsage?
        for try await raw in bytes.lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { continue }
            guard let chunk = try? JSON.parse(data) else { continue }
            if let delta = chunk["choices"]?.array?.first?["delta"]?["content"]?.string, !delta.isEmpty {
                text += delta
                onDelta?(delta)
            }
            if let reported = chunk["usage"], !reported.isNull {
                usage = .init(input: reported["prompt_tokens"]?.double ?? 0, output: reported["completion_tokens"]?.double ?? 0)
            }
        }
        return Completion(text: text, usage: usage, sessionId: echo)
    }

    // MARK: Turns

    private func emit(_ threadId: String, _ turnId: String, _ body: RuntimeEvent.Body) {
        events.emit(RuntimeEvent(provider: provider, providerInstanceId: instanceId, threadId: threadId, turnId: turnId, body))
    }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        let threadId = turn.threadId
        guard host != nil else { throw EndpointError(status: 0, message: Self.noEndpoint) }
        guard hasKey else { throw EndpointError(status: 0, message: Self.noKey) }
        guard active[threadId] == nil else { throw EndpointError(status: 0, message: "a turn is already running on this thread") }
        let turnId = newId()
        let model = Self.apiModel(turn.model).isEmpty ? Self.apiModel(models.default) : Self.apiModel(turn.model)
        let cursor = turn.resumeCursor?.string.flatMap { $0.isEmpty ? nil : $0 }
        let session: String? = hermes == .none ? nil : (cursor ?? "swarme-\(newId())")
        let replay: [JSON] = turn.transcript.map {
            ["role": .string($0.role == "assistant" ? "assistant" : "user"), "content": .string(AttachmentInliner.label($0.text))]
        }
        let system: [JSON] = turn.system.map { [["role": "system", "content": .string($0)]] } ?? []
        // no filesystem on the other side: attachments travel as content
        let latest: JSON = ["role": "user", "content": AttachmentInliner.content(turn.text)]
        let full = system + replay + [latest]
        let isSession: Bool = { if case .session = hermes { return true } else { return false } }()
        let messages = isSession ? system + [latest] : full
        NativeLog.append(threadId: threadId, dir: "out", source: "localEndpoint.chat.completions",
                         msg: ["model": .string(model), "session": JSON.from(session),
                               "messages": .array(messages.dropLast() + [["role": "user", "content": .string(AttachmentInliner.label(turn.text))]])])

        emit(threadId, turnId, .turnStarted)
        emit(threadId, turnId, .sessionStarted(sessionId: session, model: turn.model ?? models.default, resumeCursor: nil))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // the stream is read on the main actor, so deltas go out in order
            let onDelta: (String) -> Void = { [weak self] delta in
                self?.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: delta))
            }
            do {
                var result: Completion
                do {
                    result = try await self.complete(messages, model: model, stream: true, sessionId: session, onDelta: onDelta)
                } catch let error as EndpointError where session != nil && error.status == 403 {
                    // Hermes refused continuation: replay the whole branch, no header
                    self.hermes = .none
                    result = try await self.complete(full, model: model, stream: true, sessionId: nil, onDelta: onDelta)
                }
                try Task.checkCancellation()
                // only OUR id coming back is proof; a silent stream proves nothing
                let honoured = result.sessionId != nil && result.sessionId == session
                if honoured {
                    if case .session = self.hermes {} else { self.hermes = .session(header: Self.hermesHeader) }
                } else if case .session = self.hermes {
                    self.hermes = .unknown
                }
                var nativeIn: JSONObject = ["text": .string(result.text)]
                nativeIn["usage"] = result.usage.map { ["input": .number($0.input), "output": .number($0.output)] } ?? .null
                NativeLog.append(threadId: threadId, dir: "in", source: "localEndpoint.chat.completions", msg: .object(nativeIn))
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.emit(threadId, turnId, .textCompleted(text: result.text))
                }
                if let usage = result.usage {
                    self.emit(threadId, turnId, .tokenUsage(input: usage.input, output: usage.output))
                }
                self.active[threadId] = nil
                self.emit(threadId, turnId, .turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil))
            } catch {
                self.active[threadId] = nil
                let aborted = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !aborted {
                    self.emit(threadId, turnId, .runtimeError(message: error.localizedDescription, setup: nil))
                }
                self.emit(threadId, turnId, .turnCompleted(ok: false, stopReason: aborted ? "interrupted" : "error", cost: nil, denials: nil, usage: nil))
            }
        }
        active[threadId] = (task, turnId)
        return turnId
    }

    func interruptTurn(threadId: ThreadID) async {
        active[threadId]?.task.cancel()
    }

    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome { .unavailable }

    func hasSession(threadId: ThreadID) -> Bool { active[threadId] != nil }

    func stopAll() async {
        for entry in active.values { entry.task.cancel() }
    }

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { events.add(listener) }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var out = self
        while out.hasSuffix(suffix) { out.removeLast(suffix.count) }
        return out
    }
}
