// Grok (API) — `server/drivers/grok.ts`, ported.
//
// xAI chat completions with SSE streaming, billed to the user's xAI key. Not
// the grok.com CLI (that is `grokAgent`, an ACP harness). Transcript-replay:
// the harness hands over the folded history every turn.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HarnessCore

public struct GrokDriver: ProviderDriver {
    public let driverKind = "grok"
    // "(API)" tells it apart from grokAgent, the CLI
    public let displayName = "Grok (API)"
    public let access = "subscription"

    public init() {}

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        GrokInstance(input: input)
    }
}

@MainActor
final class GrokInstance: ProviderInstance, ProviderAdapter {
    static let catalog = ModelCatalog(default: "grok-4", options: [
        ModelOption(id: "grok-4", label: "Grok 4"), ModelOption(id: "grok-4-fast", label: "Grok 4 Fast"),
        ModelOption(id: "grok-3-mini", label: "Grok 3 Mini"),
    ])

    let instanceId: InstanceID
    let driverKind = "grok"
    let provider = "grok"
    let displayName: String?
    let enabled: Bool
    let models = GrokInstance.catalog
    var adapter: ProviderAdapter { self }
    let capabilities = AdapterCapabilities()

    private let url: String
    private let apiKeyEnv: String
    private let apiKey: String
    private let session: URLSession
    private var active: [ThreadID: Task<Void, Never>] = [:]
    private let events = EventEmitter()

    init(input: DriverCreateInput, session: URLSession = .shared) {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        url = input.config["url"]?.string ?? "https://api.x.ai/v1"
        apiKeyEnv = input.config["apiKeyEnv"]?.string ?? "XAI_API_KEY"
        apiKey = input.environment[apiKeyEnv] ?? ""
        self.session = session
    }

    func refreshModels() async {}

    func snapshot() async -> ProviderSnapshot {
        if apiKey.isEmpty {
            return .unavailable("no xAI API key — add {\"xai\":{\"key\":\"xai-…\"}} to ~/.swarmebot/config.json or set \(apiKeyEnv)")
        }
        return .available(version: nil)
    }

    func dispose() async {
        await stopAll()
        events.removeAll()
    }

    struct HTTPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One streamed completion; deltas go out as they arrive.
    func complete(_ messages: [JSON], model: String, onDelta: @escaping (String) -> Void) async throws -> (text: String, usage: RuntimeEvent.TokenUsage?) {
        guard let endpoint = URL(string: url + "/chat/completions") else { throw HTTPError(message: "invalid xAI URL \(url)") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = JSON.object(["model": .string(model), "messages": .array(messages), "stream": true]).data
        let (bytes, response) = try await session.streamingBytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 200 { break }
            }
            let text = String(decoding: body, as: UTF8.self)
            throw HTTPError(message: "xAI HTTP \(status)\(text.isEmpty ? "" : ": \(text)")")
        }
        var text = ""
        var usage: RuntimeEvent.TokenUsage?
        for try await raw in bytes.lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard data != "[DONE]", let chunk = try? JSON.parse(data) else { continue }
            if let delta = chunk["choices"]?.array?.first?["delta"]?["content"]?.string, !delta.isEmpty {
                text += delta
                onDelta(delta)
            }
            if let reported = chunk["usage"], reported.truthy {
                usage = .init(input: reported["prompt_tokens"]?.double ?? 0, output: reported["completion_tokens"]?.double ?? 0)
            }
        }
        return (text, usage)
    }

    private func emit(_ threadId: String, _ turnId: String, _ body: RuntimeEvent.Body) {
        events.emit(RuntimeEvent(provider: provider, threadId: threadId, turnId: turnId, body))
    }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        let threadId = turn.threadId
        guard !apiKey.isEmpty else { throw HTTPError(message: "no xAI key — set \(apiKeyEnv) or config.json xai.key") }
        guard active[threadId] == nil else { throw HTTPError(message: "a turn is already running on this thread") }
        let turnId = newId()
        let messages: [JSON] = (turn.system.map { [["role": "system", "content": .string($0)]] } ?? [])
            + turn.transcript.map { ["role": .string($0.role == "assistant" ? "assistant" : "user"), "content": .string($0.text)] }
            + [["role": "user", "content": .string(turn.text)]]
        NativeLog.append(threadId: threadId, dir: "out", source: "xai.chat.completions",
                         msg: ["model": JSON.from(turn.model), "messages": .array(messages)])
        emit(threadId, turnId, .turnStarted)
        emit(threadId, turnId, .sessionStarted(sessionId: nil, model: turn.model ?? models.default, resumeCursor: nil))
        let model = turn.model.flatMap { $0.isEmpty ? nil : $0 } ?? models.default

        // the stream is read on the main actor, so deltas stay in order
        active[threadId] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.complete(messages, model: model) { [weak self] delta in
                    self?.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: delta))
                }
                try Task.checkCancellation()
                var native: JSONObject = ["text": .string(result.text)]
                native["usage"] = result.usage.map { ["input": .number($0.input), "output": .number($0.output)] } ?? .null
                NativeLog.append(threadId: threadId, dir: "in", source: "xai.chat.completions", msg: .object(native))
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.emit(threadId, turnId, .textCompleted(text: result.text)) }
                if let usage = result.usage { self.emit(threadId, turnId, .tokenUsage(input: usage.input, output: usage.output)) }
                self.active[threadId] = nil
                self.emit(threadId, turnId, .turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil))
            } catch {
                self.active[threadId] = nil
                let aborted = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !aborted { self.emit(threadId, turnId, .runtimeError(message: error.localizedDescription, setup: nil)) }
                self.emit(threadId, turnId, .turnCompleted(ok: false, stopReason: aborted ? "interrupted" : "error", cost: nil, denials: nil, usage: nil))
            }
        }
        return turnId
    }

    func interruptTurn(threadId: ThreadID) async { active[threadId]?.cancel() }

    // this engine never asks anything
    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome { .unavailable }

    func hasSession(threadId: ThreadID) -> Bool { active[threadId] != nil }

    func stopAll() async {
        for task in active.values { task.cancel() }
    }

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { events.add(listener) }
}
