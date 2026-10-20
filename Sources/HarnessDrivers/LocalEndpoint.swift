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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
        // the tool loop is ours: connectors are called in-process (plan §5)
        capabilities.connectors = .inline
        return capabilities
    }()

    private let env: [String: String]
    private let host: LocalHost?
    private let apiKey: String
    private let hasKey: Bool
    var hermes: Continuity = .unknown
    /// Models that answered 400 to a request carrying `tools`: no connectors
    /// for them until the catalog is read again.
    var toolsUnsupported = Set<String>()
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
        toolsUnsupported = []
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

    struct ToolCall: Equatable {
        var id: String
        var name: String
        var arguments: String
    }

    struct Completion {
        var text: String
        var usage: RuntimeEvent.TokenUsage?
        var sessionId: String?
        /// What the model asked to run, in the order it listed them.
        var toolCalls: [ToolCall] = []
    }

    /// The session Hermes says served the turn — directly or renamed by a proxy.
    static func sessionEcho(_ response: HTTPURLResponse, _ name: String) -> String? {
        let value = response.value(forHTTPHeaderField: name) ?? response.value(forHTTPHeaderField: proxyPrefix + name)
        return value?.isEmpty == false ? value : nil
    }

    /// `tool_calls` of a whole (non-streamed) message.
    static func toolCalls(_ value: JSON?) -> [ToolCall] {
        (value?.array ?? []).enumerated().map { index, call in
            ToolCall(id: call["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)_\(newId().prefix(6))",
                     name: call["function"]?["name"]?.string ?? "",
                     arguments: call["function"]?["arguments"]?.string ?? "")
        }
    }

    func complete(_ messages: [JSON], model: String, stream: Bool, sessionId: String?, tools: [JSON]? = nil,
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
        var body: JSONObject = ["model": .string(model), "messages": .array(messages), "stream": .bool(stream)]
        if let tools { body["tools"] = .array(tools) }
        request.httpBody = JSON.object(body).data

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
            let message = json?["choices"]?.array?.first?["message"]
            return Completion(text: message?["content"]?.string ?? "", usage: usage, sessionId: echo, toolCalls: Self.toolCalls(message?["tool_calls"]))
        }

        let (bytes, response) = try await session.streamingBytes(for: request)
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
        // tool calls arrive in pieces, keyed by index: id and name first, the arguments in fragments
        var calls: [Int: ToolCall] = [:]
        for try await raw in bytes.lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { continue }
            guard let chunk = try? JSON.parse(data) else { continue }
            let delta = chunk["choices"]?.array?.first?["delta"]
            if let piece = delta?["content"]?.string, !piece.isEmpty {
                text += piece
                onDelta?(piece)
            }
            for (position, call) in (delta?["tool_calls"]?.array ?? []).enumerated() {
                let index = call["index"]?.int ?? position
                var entry = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                if let id = call["id"]?.string, !id.isEmpty { entry.id = id }
                // some servers repeat the whole name on every fragment
                if let name = call["function"]?["name"]?.string, !name.isEmpty, name != entry.name { entry.name += name }
                if let arguments = call["function"]?["arguments"]?.string { entry.arguments += arguments }
                calls[index] = entry
            }
            if let reported = chunk["usage"], !reported.isNull {
                usage = .init(input: reported["prompt_tokens"]?.double ?? 0, output: reported["completion_tokens"]?.double ?? 0)
            }
        }
        let toolCalls = calls.sorted { $0.key < $1.key }.map { index, call in
            var call = call
            if call.id.isEmpty { call.id = "call_\(index)_\(newId().prefix(6))" }
            return call
        }
        return Completion(text: text, usage: usage, sessionId: echo, toolCalls: toolCalls)
    }

    // MARK: Tools

    /// How many times one turn may go back to the model with tool results (§5.2).
    static let maxToolRounds = 20
    static let parallelToolCalls = 4

    /// Connector tools as OpenAI `tools`, and the way back from the name the
    /// model calls to the connector and tool. Names become `<id>__<tool>`,
    /// within `^[a-zA-Z0-9_-]{1,64}$`; a long or clashing one gets a hash.
    static func openAITools(_ tools: [ConnectorGateway.Tool]) -> (tools: [JSON], routes: [String: ConnectorGateway.Tool]) {
        var out: [JSON] = []
        var routes: [String: ConnectorGateway.Tool] = [:]
        for tool in tools {
            let raw = "\(tool.connectorId)__\(tool.name)"
            var name = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" ? Character($0) : "_" })
            if name.count > 64 || routes[name] != nil {
                let hash = String(format: "%06x", raw.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } & 0xFFFFFF)
                name = String(name.prefix(57)) + "_" + hash
            }
            routes[name] = tool
            out.append(["type": "function", "function": [
                "name": .string(name),
                "description": .string(String("[\(tool.connectorName)] \(tool.description)".prefix(1024))),
                "parameters": tool.inputSchema.object != nil ? tool.inputSchema : ["type": "object", "properties": .object(JSONObject())],
            ]])
        }
        return (out, routes)
    }

    /// A line in the transcript, failed: what happened to the connectors.
    private func note(_ threadId: String, _ turnId: String, _ text: String) {
        let itemId = newId()
        events.emit(RuntimeEvent(provider: provider, providerInstanceId: instanceId, threadId: threadId, turnId: turnId, itemId: itemId,
                                 .itemStarted(itemType: "tool", title: text)))
        events.emit(RuntimeEvent(provider: provider, providerInstanceId: instanceId, threadId: threadId, turnId: turnId, itemId: itemId,
                                 .toolCompleted(ok: false)))
    }

    /// One call the model asked for, as a chip in the transcript; the
    /// answer is the `tool` message that goes back to the model.
    private func runTool(_ call: ToolCall, routes: [String: ConnectorGateway.Tool], gateway: ConnectorGateway,
                         threadId: String, turnId: String) async -> JSON {
        let itemId = newId()
        let route = routes[call.name]
        let title = route.map { "\($0.connectorName) · \($0.name)" } ?? call.name
        var started = RuntimeEvent(provider: provider, providerInstanceId: instanceId, threadId: threadId, turnId: turnId, itemId: itemId,
                                   .itemStarted(itemType: "tool", title: title))
        started.toolInput = call.arguments
        events.emit(started)
        let result: ConnectorGateway.Result
        let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if let route {
            if let arguments = trimmed.isEmpty ? .object(JSONObject()) : try? JSON.parse(trimmed), arguments.object != nil {
                result = await gateway.call(connectorId: route.connectorId, tool: route.name, arguments: arguments)
            } else {
                result = .init(text: "The arguments are not a valid JSON object: \(trimmed.prefix(200))", ok: false)
            }
        } else {
            result = .init(text: "Unknown tool \(call.name).", ok: false)
        }
        var completed = RuntimeEvent(provider: provider, providerInstanceId: instanceId, threadId: threadId, turnId: turnId, itemId: itemId,
                                     .toolCompleted(ok: result.ok))
        completed.toolOutput = result.text
        events.emit(completed)
        NativeLog.append(threadId: threadId, dir: "in", source: "localEndpoint.tool",
                         msg: ["name": .string(call.name), "ok": .bool(result.ok), "result": .string(String(result.text.prefix(2000)))])
        return ["role": "tool", "tool_call_id": .string(call.id), "content": .string(result.text)]
    }

    /// The calls of one answer, at most four at a time, answers in the model's order.
    private func runTools(_ calls: [ToolCall], routes: [String: ConnectorGateway.Tool], gateway: ConnectorGateway,
                          threadId: String, turnId: String) async -> [JSON] {
        var answers: [JSON] = []
        for start in stride(from: 0, to: calls.count, by: Self.parallelToolCalls) {
            let batch = Array(calls[start..<min(start + Self.parallelToolCalls, calls.count)])
            let results = await withTaskGroup(of: (Int, JSON).self) { group -> [Int: JSON] in
                for (index, call) in batch.enumerated() {
                    group.addTask { @MainActor in
                        (index, await self.runTool(call, routes: routes, gateway: gateway, threadId: threadId, turnId: turnId))
                    }
                }
                var collected: [Int: JSON] = [:]
                for await (index, answer) in group { collected[index] = answer }
                return collected
            }
            answers += batch.indices.compactMap { results[$0] }
        }
        return answers
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
            // the stream is read on the main actor, so deltas go out in order;
            // a later round's text starts on a new paragraph
            var replied = false
            var roundStarted = false
            let onDelta: (String) -> Void = { [weak self] delta in
                if replied, !roundStarted { self?.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: "\n\n")) }
                roundStarted = true
                self?.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: delta))
            }
            do {
                // connectors, when this turn has them and the endpoint takes client tools (§5.3):
                // a proven Hermes session never does, nor a model that refused them once
                var offered: [JSON]?
                var routes: [String: ConnectorGateway.Tool] = [:]
                let gateway = turn.connectorGateway
                if let gateway, !isSession, !self.toolsUnsupported.contains(model) {
                    let listed = await gateway.tools()
                    for failure in listed.failures { self.note(threadId, turnId, "Connettore non raggiungibile — \(failure)") }
                    let converted = Self.openAITools(listed.tools)
                    if !converted.tools.isEmpty { (offered, routes) = converted }
                }

                var conversation = messages
                var requestSession = session
                var texts: [String] = []
                var usage: RuntimeEvent.TokenUsage?
                var firstEcho: String?
                var round = 0
                while true {
                    let tools = round < Self.maxToolRounds ? offered : nil
                    roundStarted = false
                    var result: Completion
                    do {
                        result = try await self.complete(conversation, model: model, stream: true, sessionId: requestSession, tools: tools, onDelta: onDelta)
                    } catch let error as EndpointError where requestSession != nil && error.status == 403 && round == 0 {
                        // Hermes refused continuation: replay the whole branch, no header
                        self.hermes = .none
                        requestSession = nil
                        conversation = full
                        result = try await self.complete(conversation, model: model, stream: true, sessionId: nil, tools: tools, onDelta: onDelta)
                    } catch let error as EndpointError where tools != nil && error.status == 400 && round == 0 {
                        // a model without function calling: the turn goes on without connectors
                        self.toolsUnsupported.insert(model)
                        offered = nil
                        self.note(threadId, turnId, "Questo modello non accetta strumenti: connettori non usati")
                        result = try await self.complete(conversation, model: model, stream: true, sessionId: requestSession, onDelta: onDelta)
                    }
                    try Task.checkCancellation()
                    if round == 0 { firstEcho = result.sessionId }
                    if !result.text.isEmpty {
                        texts.append(result.text)
                        replied = true
                    }
                    if let reported = result.usage {
                        usage = .init(input: (usage?.input ?? 0) + reported.input, output: (usage?.output ?? 0) + reported.output)
                    }
                    guard tools != nil, let gateway, !result.toolCalls.isEmpty else { break }
                    var assistant: JSONObject = ["role": "assistant", "content": result.text.isEmpty ? .null : .string(result.text)]
                    assistant["tool_calls"] = .array(result.toolCalls.map {
                        ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments)]]
                    })
                    conversation.append(.object(assistant))
                    conversation += await self.runTools(result.toolCalls, routes: routes, gateway: gateway, threadId: threadId, turnId: turnId)
                    try Task.checkCancellation()
                    round += 1
                    if round == Self.maxToolRounds {
                        self.note(threadId, turnId, "Limite di \(Self.maxToolRounds) giri di strumenti raggiunto: il modello conclude senza")
                    }
                }
                let text = texts.joined(separator: "\n\n")
                // only OUR id coming back is proof; a silent stream proves nothing
                let honoured = firstEcho != nil && firstEcho == session
                if honoured {
                    if case .session = self.hermes {} else { self.hermes = .session(header: Self.hermesHeader) }
                } else if case .session = self.hermes {
                    self.hermes = .unknown
                }
                var nativeIn: JSONObject = ["text": .string(text)]
                nativeIn["usage"] = usage.map { ["input": .number($0.input), "output": .number($0.output)] } ?? .null
                NativeLog.append(threadId: threadId, dir: "in", source: "localEndpoint.chat.completions", msg: .object(nativeIn))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.emit(threadId, turnId, .textCompleted(text: text))
                }
                if let usage {
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
