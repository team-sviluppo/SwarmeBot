// Computer (boxAgent) — `server/drivers/boxagent.ts`, ported.
//
// The turn runs ON the bot's own cloud box, through the Box substrate's
// native agent: POST /boxes/{id}/prompt, then poll /events and
// /prompts/{promptId} until the run settles; /interrupt stops it. Payload
// shapes are tolerated liberally and teed verbatim to the native log.
//
// One difference from the Node engine: `OMB_BOX_API` overrides the API base
// here too (the Node driver hard-codes it), so the driver can be tested
// against a stub like the rest of the Box code.
import Foundation
import HarnessCore

public struct BoxAgentDriver: ProviderDriver {
    public let driverKind = "boxAgent"
    public let displayName = "Computer"
    public let access = "subscription"

    public init() {}

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        BoxAgentInstance(input: input)
    }
}

@MainActor
final class BoxAgentInstance: ProviderInstance, ProviderAdapter {
    static let catalog = ModelCatalog(default: "claude-fable-5", options: [
        ModelOption(id: "claude-fable-5", label: "Claude Fable 5 · on the box"),
        ModelOption(id: "sonnet", label: "Claude Sonnet · on the box"),
        ModelOption(id: "gpt-5.4", label: "GPT-5.4 (Codex) · on the box"),
    ])

    let instanceId: InstanceID
    let driverKind = "boxAgent"
    let provider = "boxAgent"
    let displayName: String?
    let enabled: Bool
    let models = BoxAgentInstance.catalog
    var adapter: ProviderAdapter { self }
    let capabilities = AdapterCapabilities()

    private let token: String
    private let api: String
    private let pollSeconds: Double
    private let session: URLSession
    private let events = EventEmitter()
    private var active: [ThreadID: (task: Task<Void, Never>, boxId: String)] = [:]

    init(input: DriverCreateInput, session: URLSession = .shared) {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        token = input.environment["BOX_TOKEN"] ?? ""
        api = input.environment["OMB_BOX_API"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://ascii.dev/api/box/v1"
        pollSeconds = (input.config["pollMs"]?.double ?? 2500) / 1000
        self.session = session
    }

    struct BoxFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func call(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
        guard let url = URL(string: api + path) else { throw BoxFailure(message: "invalid box URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let body { request.httpBody = body.data }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSON.parse(data)
        if !(200...299).contains(status) || json?["ok"]?.bool == false {
            throw BoxFailure(message: json?["code"].flatMap(Harness.text) ?? json?["error"].flatMap(Harness.text) ?? "box HTTP \(status)")
        }
        return json ?? .null
    }

    func refreshModels() async {}

    func snapshot() async -> ProviderSnapshot {
        if token.isEmpty { return .unavailable(#"no Box token — add {"box":{"token":"…"}} to ~/.swarmebot/config.json"#) }
        do {
            _ = try await call("/me")
            return .available(version: nil)
        } catch {
            return .unavailable("box API unreachable: \(error.localizedDescription)")
        }
    }

    func dispose() async {
        await stopAll()
        events.removeAll()
    }

    private func emit(_ threadId: String, _ turnId: String, itemId: String? = nil, _ body: RuntimeEvent.Body) {
        events.emit(RuntimeEvent(provider: provider, threadId: threadId, turnId: turnId, itemId: itemId, body))
    }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        let threadId = turn.threadId
        if token.isEmpty { throw BoxFailure(message: #"box not configured — add {"box":{"token":"…"}} to ~/.swarmebot/config.json"#) }
        guard let boxId = turn.cloudBoxId else {
            throw BoxFailure(message: "this bot has no computer yet — open the Computer panel and provision one")
        }
        guard active[threadId] == nil else { throw BoxFailure(message: "a turn is already running on this thread") }
        let turnId = newId()
        let model = turn.model.flatMap { $0.isEmpty ? nil : $0 } ?? models.default
        let prompt = [turn.system, "You are working on your own cloud computer — its desktop, Chrome, and shell are yours.", "", turn.text]
            .compactMap { $0 }.joined(separator: "\n")
        let started = try await call("/boxes/\(boxId)/prompt", method: "POST", body: [
            "provider": .string(model.hasPrefix("gpt") ? "codex" : "claude-code"), "model": .string(model), "prompt": .string(prompt),
        ])
        NativeLog.append(threadId: threadId, dir: "out", source: "box.prompt",
                         msg: ["model": .string(model), "prompt": .string(prompt), "response": started])
        // {type:"prompt.queued", promptId, promptRun:{id}, id:<box id>}: never the bare id, that is the box's
        let promptId = (started["promptRun"]?["id"] ?? started["prompt"]?["id"] ?? started["promptId"]).flatMap(Harness.text)

        emit(threadId, turnId, .turnStarted)
        emit(threadId, turnId, .sessionStarted(sessionId: promptId, model: model, resumeCursor: nil))
        let poll = UInt64(pollSeconds * 1_000_000_000)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var seen = Set<String>()
            var lastText = ""
            let startedAt = Date()
            let settle = { (ok: Bool, reason: String?) in
                self.active[threadId] = nil
                self.emit(threadId, turnId, .turnCompleted(ok: ok, stopReason: reason, cost: nil, denials: nil, usage: nil))
            }
            do {
                while true {
                    try await Task.sleep(nanoseconds: poll)
                    let listed = try? await self.call("/boxes/\(boxId)/events")
                    for event in listed?["events"]?.array ?? listed?["items"]?.array ?? [] {
                        let id = (event["id"] ?? event["eventId"]).flatMap(Harness.text) ?? String(event.serialized().prefix(120))
                        guard seen.insert(id).inserted else { continue }
                        NativeLog.append(threadId: threadId, dir: "in", source: "box.events", msg: event)
                        let kind = (event["type"] ?? event["kind"]).flatMap(Harness.text) ?? ""
                        // `response` carries the FULL text so far: forward only the growth
                        let text = (event["text"] ?? event["message"] ?? event["data"]?["text"] ?? event["data"]?["content"])?.string
                        if kind.range(of: "assistant|message|output|response", options: [.regularExpression, .caseInsensitive]) != nil,
                           let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let delta = text.hasPrefix(lastText) ? String(text.dropFirst(lastText.count)) : text
                            lastText = text
                            if !delta.isEmpty { self.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: delta)) }
                        } else if kind.range(of: "tool|command|exec|browse", options: [.regularExpression, .caseInsensitive]) != nil {
                            let title = (event["title"] ?? event["command"]).flatMap(Harness.text) ?? kind
                            self.emit(threadId, turnId, itemId: id, .itemStarted(itemType: "tool", title: String(title.prefix(80))))
                        }
                        // without a promptId the status poll never ends: settle off the events
                        if promptId == nil, kind.range(of: "complete|finish|done|success|fail|error", options: [.regularExpression, .caseInsensitive]) != nil {
                            if !lastText.isEmpty { self.emit(threadId, turnId, .textCompleted(text: lastText)) }
                            let failed = kind.range(of: "fail|error", options: [.regularExpression, .caseInsensitive]) != nil
                            return settle(!failed, failed ? kind : nil)
                        }
                    }
                    if let promptId {
                        let status = try? await self.call("/boxes/\(boxId)/prompts/\(promptId)")
                        NativeLog.append(threadId: threadId, dir: "in", source: "box.prompt.status", msg: status ?? .null)
                        let run = status?["promptRun"] ?? status?["prompt"] ?? status ?? .null
                        let state = run["status"].flatMap(Harness.text) ?? ""
                        if state.range(of: "completed|succeeded|done|finished", options: [.regularExpression, .caseInsensitive]) != nil {
                            let result = (run["result"] ?? run["output"])?.string ?? lastText
                            let usable = !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            if usable, result != lastText, result.hasPrefix(lastText) {
                                self.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: String(result.dropFirst(lastText.count))))
                            }
                            self.emit(threadId, turnId, .textCompleted(text: usable ? result : (lastText.isEmpty ? "(finished)" : lastText)))
                            return settle(true, nil)
                        }
                        if state.range(of: "failed|error|cancelled|interrupted", options: [.regularExpression, .caseInsensitive]) != nil {
                            if !lastText.isEmpty { self.emit(threadId, turnId, .textCompleted(text: lastText)) }
                            return settle(false, state)
                        }
                    }
                    if Date().timeIntervalSince(startedAt) > 30 * 60 { throw BoxFailure(message: "box run exceeded 30 minutes — interrupted") }
                }
            } catch is CancellationError {
                settle(false, "interrupted")
            } catch {
                self.active[threadId] = nil
                self.emit(threadId, turnId, .runtimeError(message: error.localizedDescription, setup: nil))
                self.emit(threadId, turnId, .turnCompleted(ok: false, stopReason: "error", cost: nil, denials: nil, usage: nil))
            }
        }
        active[threadId] = (task, boxId)
        return turnId
    }

    func interruptTurn(threadId: ThreadID) async {
        guard let entry = active[threadId] else { return }
        entry.task.cancel()
        _ = try? await call("/boxes/\(entry.boxId)/interrupt", method: "POST")
    }

    // this engine never asks anything
    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome { .unavailable }

    func hasSession(threadId: ThreadID) -> Bool { active[threadId] != nil }

    func stopAll() async {
        for threadId in Array(active.keys) { await interruptTurn(threadId: threadId) }
    }

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { events.add(listener) }
}
