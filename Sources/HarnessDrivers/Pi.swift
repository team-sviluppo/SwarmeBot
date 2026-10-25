// pi — `server/drivers/pi.ts`, ported.
//
// The pi coding agent over its own JSON RPC mode (`pi --mode rpc
// --no-session`): commands go in as `{type:…}` lines, responses come back as
// `{type:"response", command, success, data}` and the turn streams as events.
// BYOK: credentials live in ~/.pi/agent/auth.json and pi reads them itself,
// so the child inherits no provider key at all.
//
// Continuity: `new_session` on the first turn, `switch_session` with the
// returned sessionFile afterwards — that path is the resume cursor. Picker ids
// are `provider/modelId`, split for `set_model`.
import Foundation
import HarnessCore

public struct PiDriver: ProviderDriver {
    public let driverKind = "piAgent"
    public let displayName = "pi"
    public let access = "custom"
    public let install: EngineInstall? = EngineInstall(darwinCommand: "npm install -g @earendil-works/pi-coding-agent",
                                                       docsUrl: "https://pi.dev", needsNode: true)

    public init() {}

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        let instance = try PiInstance(input: input)
        await instance.refreshModels()
        return instance
    }
}

enum PiCatalog {
    static let args = ["--mode", "rpc", "--no-session"]

    /// `parsePiCatalog`: every row custom, id `provider/modelId`.
    static func parse(_ line: String, fallbackDefault: String) -> ModelCatalog? {
        guard let message = try? JSON.parse(line), message["type"]?.string == "response",
              message["command"]?.string == "get_available_models", message["success"]?.bool == true else { return nil }
        let options = (message["data"]?["models"]?.array ?? []).compactMap { row -> ModelOption? in
            guard let provider = row["provider"]?.string, !provider.isEmpty, let id = row["id"]?.string, !id.isEmpty else { return nil }
            return ModelOption(id: "\(provider)/\(id)", label: row["name"]?.string ?? id, custom: true)
        }
        return ModelCatalog(default: fallbackDefault.isEmpty ? options.first?.id ?? "" : fallbackDefault, options: options)
    }

    /// What `pi` itself would run, from ~/.pi/agent/settings.json.
    static func defaultModel(_ env: [String: String]) -> String {
        let settings = FileIO.readJSON(URL(fileURLWithPath: "\(env["HOME"] ?? NSHomeDirectory())/.pi/agent/settings.json"))
        guard let provider = settings?["defaultProvider"]?.string, !provider.isEmpty,
              let model = settings?["defaultModel"]?.string, !model.isEmpty else { return "" }
        return "\(provider)/\(model)"
    }

    @MainActor
    static func fetch(cli: String, env: [String: String]) async -> ModelCatalog {
        let empty = ModelCatalog.empty
        guard let process = try? CLIProcess(cli: cli, args: args, cwd: nil, environment: env) else { return empty }
        let fallback = defaultModel(env)
        return await withCheckedContinuation { continuation in
            var done = false
            let finish: (ModelCatalog) -> Void = { catalog in
                guard !done else { return }
                done = true
                process.killTree()
                continuation.resume(returning: catalog)
            }
            process.onLine = { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let parsed = parse(line, fallbackDefault: fallback)
                if let parsed, !parsed.options.isEmpty { return finish(parsed) }
                if line.contains("\"get_available_models\"") { finish(parsed ?? ModelCatalog(default: fallback, options: [])) }
            }
            process.onClose = { _ in finish(empty) }
            process.start()
            process.write(#"{"id":"catalog","type":"get_available_models"}"# + "\n")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                finish(empty)
            }
        }
    }
}

@MainActor
final class PiInstance: ProviderInstance, ProviderAdapter {
    let instanceId: InstanceID
    let driverKind = "piAgent"
    let provider = "piAgent"
    let displayName: String?
    let enabled: Bool
    private(set) var models = ModelCatalog.empty
    var adapter: ProviderAdapter { self }
    let capabilities = AdapterCapabilities()

    let cli: String
    private let environment: [String: String]
    private let events = EventEmitter()
    private var active: [ThreadID: PiTurn] = [:]

    struct ConfigError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(input: DriverCreateInput) throws {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        switch input.config {
        case .null: cli = "pi"
        case let .object(object):
            if let raw = object["cli"], raw.string == nil { throw ConfigError(message: "pi config `cli` must be a string") }
            let trimmed = object["cli"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            cli = trimmed.isEmpty ? "pi" : trimmed
        default: throw ConfigError(message: "pi config must be an object")
        }
        environment = input.environment
    }

    /// BYOK: an inherited provider key would bill one pi was never given, and
    /// workspace credentials are the harness's. pi's keys live in its own file.
    func childEnvironment() -> [String: String] {
        var env = environment
        env["PATH"] = EnvPath.augmented(environment)
        WorkspaceCredentials.strip(&env)
        for key in providerCredentialEnv { env[key] = nil }
        return env
    }

    func refreshModels() async {
        let resolved = await PiCatalog.fetch(cli: cli, env: childEnvironment())
        if !resolved.options.isEmpty { models = resolved }
    }

    /// pi manages its own credentials: there is no sign-in to probe.
    func snapshot() async -> ProviderSnapshot {
        guard let output = await CLIProcess.run(cli, ["--version"], environment: childEnvironment(), timeout: 8) else {
            return .unavailable("`\(cli)` CLI not found")
        }
        let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.isEmpty { return .unavailable("`\(cli)` CLI not found") }
        return ProviderSnapshot(state: "available", reason: nil, authenticated: true, version: version, billing: nil, versionFirst: true)
    }

    func dispose() async {
        await stopAll()
        events.removeAll()
    }

    func emit(_ event: RuntimeEvent) { events.emit(event) }
    func turnEnded(_ threadId: ThreadID) { active[threadId] = nil }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        guard active[turn.threadId] == nil else { throw RPCError(message: "a turn is already running on this thread") }
        let piTurn = PiTurn(instance: self, turn: turn)
        active[turn.threadId] = piTurn
        piTurn.start()
        return piTurn.turnId
    }

    func interruptTurn(threadId: ThreadID) async { active[threadId]?.stop() }

    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome {
        guard let turn = active[threadId], turn.answer(requestId, decision) else { return .unavailable }
        switch decision.behavior {
        case "allow": return .allowedOnce
        case "answer": return .answered
        default: return .rejected
        }
    }

    func hasSession(threadId: ThreadID) -> Bool { active[threadId] != nil }

    func stopAll() async {
        for turn in active.values { turn.stop() }
    }

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { events.add(listener) }
}

@MainActor
final class PiTurn {
    let turnId = newId()
    private unowned let instance: PiInstance
    private let turn: SendTurnInput
    private var threadId: String { turn.threadId }
    private var process: CLIProcess?
    private var settled = false
    private var assistantText = ""
    /// one-shot responses, keyed by command (new_session, switch_session, set_model)
    private var waiters: [String: CheckedContinuation<JSON, Error>] = [:]
    private var pending: [String: (RequestDecision) -> Void] = [:]

    init(instance: PiInstance, turn: SendTurnInput) {
        self.instance = instance
        self.turn = turn
    }

    private func emit(itemId: String? = nil, requestId: String? = nil, _ body: RuntimeEvent.Body) {
        var event = RuntimeEvent(provider: "piAgent", threadId: threadId, turnId: turnId, itemId: itemId, requestId: requestId, body)
        event.costAbsent = true
        instance.emit(event)
    }

    private func send(_ message: JSON) {
        NativeLog.append(threadId: threadId, dir: "out", source: "pi.rpc", msg: message)
        process?.write(message.serialized() + "\n")
    }

    /// Send one command and wait for its response. The waiter is in place
    /// before the line goes out, so a fast answer can never be missed.
    private func call(_ message: JSON, expecting command: String, timeout: TimeInterval = 20) async throws -> JSON {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.waiters.removeValue(forKey: command)?.resume(throwing: RPCError(message: "pi \(command) timed out"))
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[command] = continuation
            send(message)
        }
    }

    private func rejectWaiters(_ message: String) {
        for waiter in waiters.values { waiter.resume(throwing: RPCError(message: message)) }
        waiters.removeAll()
    }

    private func settle(ok: Bool, stopReason: String? = nil, usage: JSON? = nil) {
        guard !settled else { return }
        settled = true
        if !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emit(.textCompleted(text: assistantText)) }
        let tokens = usage.flatMap { $0.truthy ? RuntimeEvent.TokenUsage(input: $0["input"]?.double ?? 0, output: $0["output"]?.double ?? 0) : nil }
        emit(.turnCompleted(ok: ok, stopReason: stopReason ?? (ok ? "end_turn" : "failed"), cost: nil, denials: nil, usage: tokens))
        process?.closeStdin()
        process?.killTree()
        instance.turnEnded(threadId)
    }

    func stop() {
        send(["type": "abort"])
        process?.killTree()
        settle(ok: true, stopReason: "cancelled")
    }

    func answer(_ requestId: String, _ decision: RequestDecision) -> Bool {
        guard let reply = pending.removeValue(forKey: requestId) else { return false }
        reply(decision)
        emit(requestId: requestId, .requestResolved(behavior: decision.behavior, source: "user", approvalScope: nil))
        return true
    }

    private func handle(_ event: JSON) {
        NativeLog.append(threadId: threadId, dir: "in", source: "pi.rpc", msg: event)
        switch event["type"]?.string {
        case "response":
            guard let command = event["command"]?.string, let waiter = waiters.removeValue(forKey: command) else { return }
            if event["success"]?.truthy == true { waiter.resume(returning: event["data"] ?? .null) }
            else { waiter.resume(throwing: RPCError(message: "pi \(command) failed")) }
        case "message_update":
            let update = event["assistantMessageEvent"]
            guard let delta = update?["delta"]?.string else { return }
            if update?["type"]?.string == "text_delta" {
                assistantText += delta
                emit(.contentDelta(streamKind: "assistant_text", delta: delta))
            } else if update?["type"]?.string == "thinking_delta" {
                emit(.contentDelta(streamKind: "reasoning_text", delta: delta))
            }
        case "tool_execution_start":
            let name = event["toolName"].flatMap(ACPTurn.text) ?? "tool"
            emit(itemId: event["toolCallId"]?.string, .itemStarted(itemType: "tool", title: String(name.prefix(80))))
        case "tool_execution_end":
            emit(itemId: event["toolCallId"]?.string, .toolCompleted(ok: event["isError"]?.truthy != true))
        case "extension_ui_request":
            // setWidget/setStatus are TUI bookkeeping; only these three wait for an answer
            let method = event["method"]?.string
            guard method == "select" || method == "confirm" || method == "input" else { return }
            let requestId = event["id"]?.string ?? newId()
            let isQuestion = method == "input"
            let title = event["title"].flatMap(ACPTurn.text)
            emit(requestId: requestId, .requestOpened(requestType: isQuestion ? "question" : "permission", tool: title ?? "pi",
                                                      summary: title ?? "pi wants confirmation", choices: nil, multiSelect: nil, approvalScope: nil))
            pending[requestId] = { [weak self] decision in
                if decision.behavior == "deny" { self?.send(["type": "extension_ui_response", "id": .string(requestId), "cancelled": true]) }
                else if isQuestion { self?.send(["type": "extension_ui_response", "id": .string(requestId), "value": .string(decision.message ?? "")]) }
                else { self?.send(["type": "extension_ui_response", "id": .string(requestId), "confirmed": true]) }
            }
        case "turn_end", "agent_end":
            let reason = event["message"]?["stopReason"]?.string
            // pi ran a tool and continues on its own: settling now would drop the reply
            if reason == "toolUse" || reason == "tool_use" || reason == "tool_calls" { return }
            // the provider refused (403, quota, unknown model): no text, the reason only here
            if reason == "error" {
                let detail = event["message"]?["errorMessage"]?.string?.split(separator: "\n").first.map(String.init)
                emit(.runtimeError(message: String((detail ?? "pi reported an error").prefix(400)), setup: nil))
                settle(ok: false, usage: event["usage"] ?? event["message"]?["usage"])
                return
            }
            settle(ok: true, stopReason: reason == "cancelled" ? "cancelled" : "end_turn", usage: event["usage"] ?? event["message"]?["usage"])
        default:
            break
        }
    }

    func start() {
        do {
            process = try CLIProcess(cli: instance.cli, args: PiCatalog.args, cwd: turn.cwd,
                                     environment: instance.childEnvironment().merging(turn.secretEnvironment) { _, secret in secret })
        } catch {
            let failure = error as? SpawnFailure ?? SpawnFailure(message: "spawn failed: \(error.localizedDescription)", setup: false)
            emit(.turnStarted)
            emit(.runtimeError(message: failure.message, setup: failure.setup))
            settle(ok: false)
            return
        }
        process?.onLine = { [weak self] line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let event = try? JSON.parse(line) else { return }
            self?.handle(event)
        }
        process?.onClose = { [weak self] _ in
            // a clean close without a terminal event is a failed turn, never a hang
            self?.rejectWaiters("pi process exited before replying")
            self?.settle(ok: false)
        }
        emit(.turnStarted)
        process?.start()

        Task { @MainActor in
            let sessionPath = self.turn.resumeCursor?.string
            var sessionFile = sessionPath
            do {
                let command = sessionPath != nil ? "switch_session" : "new_session"
                let handshake = try await self.call(sessionPath.map { ["type": "switch_session", "sessionPath": .string($0)] } ?? ["type": "new_session"],
                                                    expecting: command)
                if let file = handshake["sessionFile"]?.string, !file.isEmpty { sessionFile = file }
                self.emit(.sessionStarted(sessionId: sessionFile ?? handshake["sessionId"]?.string, model: self.turn.model, resumeCursor: nil))
            } catch {
                // --no-session still takes a bare prompt
            }
            if let model = self.turn.model, let slash = model.firstIndex(of: "/") {
                // a refusal keeps going on the default model
                _ = try? await self.call(["type": "set_model", "provider": .string(String(model[..<slash])),
                                          "modelId": .string(String(model[model.index(after: slash)...]))], expecting: "set_model")
            }
            guard !self.settled else { return }
            self.send(["type": "prompt", "message": .string(self.turn.system.map { "\($0)\n\n\(self.turn.text)" } ?? self.turn.text)])
        }
    }
}
