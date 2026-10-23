// Local Endpoint — `server/drivers/local-endpoint.ts`, ported.
//
// OpenAI-compatible chat completions against whatever endpoint the user
// configured (LiteLLM, vLLM, llama.cpp, a hosted proxy). The catalog is the
// endpoint's /v1/models; URL and key are settings, not a CLI login.
//
// The subtle part — Hermes Agent's session continuity — and the request,
// stream and tool-loop mechanics are `OpenAIChatEndpoint` (AgentCore),
// shared with the iOS app; this is the engine's half: catalog, events,
// connectors, transcript log.
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

@MainActor
final class LocalEndpointInstance: ProviderInstance, ProviderAdapter {
    static let hostId = "local_endpoint"
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
    /// Nil without an endpoint URL.
    let endpoint: OpenAIChatEndpoint?
    private var active: [ThreadID: (task: Task<Void, Never>, turnId: String)] = [:]
    private let events = EventEmitter()
    let session: URLSession

    init(input: DriverCreateInput, session: URLSession = .shared) {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        env = input.environment
        let host = LocalHosts.resolve(Self.hostId, env: input.environment)
        let apiKey = host.map { LocalHosts.apiKey($0, env: input.environment) } ?? ""
        self.host = host
        self.apiKey = apiKey
        hasKey = !(input.environment[LocalHosts.apiKeyEnv] ?? "").isEmpty
        self.session = session
        endpoint = host.map { OpenAIChatEndpoint(baseUrl: $0.baseUrl, apiKey: apiKey, session: session) }
    }

    // MARK: Catalog

    func refreshModels() async {
        guard let endpoint else { return }
        endpoint.toolsUnsupported = []
        async let resolved = LocalHosts.probe(hostIds: [Self.hostId], env: env, session: session)
        async let probed = endpoint.probeHermes()
        let (options, verdict) = await (resolved, probed)
        if !options.isEmpty { models = ModelCatalog(default: "", options: options) }
        endpoint.applyProbe(verdict)
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

    // MARK: Tools

    static let parallelToolCalls = 4

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
    private func runTool(_ call: ToolCall, routes: [String: ChatTool], gateway: ConnectorGateway,
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
    private func runTools(_ calls: [ToolCall], routes: [String: ChatTool], gateway: ConnectorGateway,
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
        guard let endpoint else { throw EndpointError(status: 0, message: Self.noEndpoint) }
        guard hasKey else { throw EndpointError(status: 0, message: Self.noKey) }
        guard active[threadId] == nil else { throw EndpointError(status: 0, message: "a turn is already running on this thread") }
        let turnId = newId()
        let model = Self.apiModel(turn.model).isEmpty ? Self.apiModel(models.default) : Self.apiModel(turn.model)
        let cursor = turn.resumeCursor?.string.flatMap { $0.isEmpty ? nil : $0 }
        let session = endpoint.session(cursor: cursor)
        let replay: [JSON] = turn.transcript.map {
            ["role": .string($0.role == "assistant" ? "assistant" : "user"), "content": .string(AttachmentInliner.label($0.text))]
        }
        let system: [JSON] = turn.system.map { [["role": "system", "content": .string($0)]] } ?? []
        // no filesystem on the other side: attachments travel as content
        let latest: JSON = ["role": "user", "content": AttachmentInliner.content(turn.text)]
        let full = system + replay + [latest]
        let isSession = endpoint.isSession
        let messages = isSession ? system + [latest] : full
        NativeLog.append(threadId: threadId, dir: "out", source: "localEndpoint.chat.completions",
                         msg: ["model": .string(model), "session": JSON.from(session),
                               "messages": .array(messages.dropLast() + [["role": "user", "content": .string(AttachmentInliner.label(turn.text))]])])

        emit(threadId, turnId, .turnStarted)
        emit(threadId, turnId, .sessionStarted(sessionId: session, model: turn.model ?? models.default, resumeCursor: nil))

        let task = Task { @MainActor [weak self] in
            guard let self, let endpoint = self.endpoint else { return }
            do {
                // connectors, when this turn has them and the endpoint takes client tools (§5.3):
                // a proven Hermes session never does, nor a model that refused them once
                var offered: [JSON]?
                var routes: [String: ChatTool] = [:]
                let gateway = turn.connectorGateway
                if let gateway, !isSession, !endpoint.toolsUnsupported.contains(model) {
                    let listed = await gateway.tools()
                    for failure in listed.failures { self.note(threadId, turnId, "Connettore non raggiungibile — \(failure)") }
                    let converted = OpenAIChatEndpoint.openAITools(listed.tools)
                    if !converted.tools.isEmpty { (offered, routes) = converted }
                }
                // the stream is read on the main actor, so deltas go out in order
                let result = try await endpoint.runTurn(
                    model: model, session: session, messages: messages, full: full, tools: offered,
                    onDelta: { [weak self] delta in self?.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: delta)) },
                    note: { self.note(threadId, turnId, $0) },
                    runTools: { calls in
                        guard let gateway else { return [] }
                        return await self.runTools(calls, routes: routes, gateway: gateway, threadId: threadId, turnId: turnId)
                    })
                let text = result.text
                let usage = result.usage
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
