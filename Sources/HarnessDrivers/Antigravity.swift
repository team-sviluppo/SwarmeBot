// Antigravity — `server/drivers/antigravity.ts`, ported.
//
// Google's `agy` CLI in headless print mode (`--print <prompt> --output-format
// stream-json`), one process per turn, continued with `--conversation <id>`.
// Print mode reads the prompt from argv only (piped stdin yields nothing), so
// an oversized prompt is refused up front instead of failing the spawn.
//
// No interactive permission channel exists in print mode: fullAuto (the
// default — agy otherwise auto-denies the tools it calls on trivial prompts)
// skips permissions, accept-edits allows edits and denies shell.
import Foundation
import HarnessCore

public struct AntigravityDriver: ProviderDriver {
    public let driverKind = "antigravityAgent"
    public let displayName = "Antigravity"
    public let access = "subscription"
    public let install: EngineInstall? = EngineInstall(darwinCommand: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
                                                       docsUrl: "https://github.com/google-antigravity/antigravity-cli#installation")

    public init() {}

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        let instance = try AntigravityInstance(input: input)
        await instance.refreshModels()
        return instance
    }
}

@MainActor
final class AntigravityInstance: ProviderInstance, ProviderAdapter {
    static let staticModels = ModelCatalog(default: "gemini-3.1-pro-high", options: [
        ModelOption(id: "gemini-3.1-pro-high", label: "Gemini 3.1 Pro (High)"), ModelOption(id: "gemini-3.1-pro-low", label: "Gemini 3.1 Pro (Low)"),
        ModelOption(id: "gemini-3.7-flash-high", label: "Gemini 3.7 Flash (High)"), ModelOption(id: "gemini-3.7-flash-medium", label: "Gemini 3.7 Flash (Medium)"),
        ModelOption(id: "gemini-3.7-flash-low", label: "Gemini 3.7 Flash (Low)"), ModelOption(id: "gemini-3.6-flash-high", label: "Gemini 3.6 Flash (High)"),
        ModelOption(id: "gemini-3.6-flash-medium", label: "Gemini 3.6 Flash (Medium)"), ModelOption(id: "gemini-3.6-flash-low", label: "Gemini 3.6 Flash (Low)"),
        ModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6 (Thinking)"),
        ModelOption(id: "claude-opus-4-6-thinking", label: "Claude Opus 4.6 (Thinking)"),
        ModelOption(id: "gpt-oss-120b-medium", label: "GPT-OSS 120B (Medium)"),
    ])

    let instanceId: InstanceID
    let driverKind = "antigravityAgent"
    let provider = "antigravityAgent"
    let displayName: String?
    let enabled: Bool
    private(set) var models = AntigravityInstance.staticModels
    var adapter: ProviderAdapter { self }
    let capabilities = AdapterCapabilities()

    let cli: String
    let fullAuto: Bool
    private let environment: [String: String]
    private let dataDir: URL
    private let events = EventEmitter()
    private var active: [ThreadID: (turnId: String, process: CLIProcess)] = [:]
    /// every live child, also those still running after their `result`
    private var children: [ObjectIdentifier: CLIProcess] = [:]

    struct ConfigError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(input: DriverCreateInput) throws {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        if let raw = input.config["cli"], raw.string == nil { throw ConfigError(message: "antigravity: invalid cli \(raw.serialized())") }
        if let raw = input.config["fullAuto"], raw.bool == nil { throw ConfigError(message: "antigravity: invalid fullAuto \(raw.serialized())") }
        cli = input.config["cli"]?.string ?? "agy"
        fullAuto = input.config["fullAuto"]?.bool ?? true
        environment = input.environment
        dataDir = DataPaths.fromEnvironment(input.environment).root
    }

    /// agy uses its own login: no workspace credential belongs in its children.
    func childEnvironment() -> [String: String] {
        var env = environment
        env["PATH"] = EnvPath.augmented(environment)
        WorkspaceCredentials.strip(&env)
        return env
    }

    static func isModelId(_ id: String) -> Bool { ClaudeCatalog.isModelId(id) }

    /// Extra ids from ~/.gemini/antigravity-cli/settings.json.
    static func catalog(_ env: [String: String]) -> ModelCatalog {
        guard let settings = FileIO.readJSON(URL(fileURLWithPath: "\(env["HOME"] ?? NSHomeDirectory())/.gemini/antigravity-cli/settings.json")),
              settings.object != nil else { return staticModels }
        let extras: (JSON?) -> [ModelOption] = { value in
            (value?.array ?? []).compactMap { item in
                if let id = item.string { return isModelId(id) ? ModelOption(id: id, label: id) : nil }
                guard item.object != nil else { return nil }
                let id = item["id"]?.string ?? item["model"]?.string ?? ""
                guard isModelId(id) else { return nil }
                return ModelOption(id: id, label: item["name"]?.string ?? item["displayName"]?.string ?? id)
            }
        }
        var found = extras(settings["availableModels"]) + extras(settings["customModels"]) + extras(settings["extraModels"])
        if let model = settings["model"]?.string { found += extras([.string(model)]) }
        var options = staticModels.options
        for extra in found where !options.contains(where: { $0.id == extra.id }) {
            options.append(ModelOption(id: extra.id, label: extra.label, custom: true))
        }
        return ModelCatalog(default: staticModels.default, options: options)
    }

    func refreshModels() async {
        let resolved = await LocalHosts.merge(Self.catalog(environment), env: environment)
        if !resolved.options.isEmpty { models = resolved }
    }

    /// No auth field: agy's login is in the keyring, with no reliable marker.
    func snapshot() async -> ProviderSnapshot {
        guard let output = await CLIProcess.run(cli, ["--version"], environment: childEnvironment(), timeout: 8), output.ok else {
            return .unavailable("`\(cli)` CLI not found")
        }
        return ProviderSnapshot(state: "available", reason: nil, authenticated: nil,
                                version: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), billing: nil, versionFirst: true)
    }

    func dispose() async {
        await stopAll()
        events.removeAll()
    }

    private func emit(_ threadId: String, _ turnId: String, itemId: String? = nil, _ body: RuntimeEvent.Body) {
        events.emit(RuntimeEvent(provider: provider, threadId: threadId, turnId: turnId, itemId: itemId, body))
    }

    struct TurnError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        let threadId = turn.threadId
        guard active[threadId] == nil else { throw TurnError(message: "a turn is already running on this thread") }
        let turnId = newId()
        // a per-thread workspace under the data dir, never the whole home
        let workspace = dataDir.appendingPathComponent("workspaces/\(threadId.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })").path
        try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        let cwd = turn.cwd ?? workspace
        let prompt = turn.system.map { "\($0)\n\n\(turn.text)" } ?? turn.text

        var settled = false
        var watchdog: Task<Void, Never>?
        let settle: (Bool, String?, RuntimeEvent.TokenUsage?) -> Void = { [weak self] ok, stopReason, usage in
            guard let self, !settled else { return }
            settled = true
            watchdog?.cancel()
            self.active[threadId] = nil
            self.emit(threadId, turnId, .turnCompleted(ok: ok, stopReason: stopReason, cost: nil, denials: nil, usage: usage))
        }

        let size = prompt.utf8.count
        if size > 256 * 1024 {
            emit(threadId, turnId, .runtimeError(message: "prompt too large for Antigravity's argv-only print mode (\(size) bytes)", setup: nil))
            settle(false, "prompt_too_large", nil)
            return turnId
        }

        var args = ["--print", prompt, "--output-format", "stream-json", "--print-timeout", "10m", "--add-dir", cwd,
                    fullAuto ? "--dangerously-skip-permissions" : "--mode"]
        if !fullAuto { args.append("accept-edits") }
        if let model = turn.model { args += ["--model", LocalHosts.decode(model)?.model ?? model] }
        if let cursor = turn.resumeCursor?.string { args += ["--conversation", cursor] }

        let process: CLIProcess
        do {
            process = try CLIProcess(cli: cli, args: args, cwd: cwd,
                                     environment: childEnvironment().merging(turn.secretEnvironment) { _, secret in secret })
        } catch {
            let failure = error as? SpawnFailure ?? SpawnFailure(message: "spawn failed: \(error.localizedDescription)", setup: false)
            // as in Node, where the spawn error arrives after turn.started
            emit(threadId, turnId, .turnStarted)
            emit(threadId, turnId, .runtimeError(message: failure.message, setup: failure.setup))
            settle(false, "spawn_error", nil)
            return turnId
        }
        process.closeStdin() // the prompt is on argv
        children[ObjectIdentifier(process)] = process

        var conversationId: String?
        let usageOf: (JSON?) -> RuntimeEvent.TokenUsage? = { usage in
            guard let usage, usage.truthy else { return nil }
            return .init(input: (usage["input_tokens"]?.double ?? 0) + (usage["cache_read_tokens"]?.double ?? 0), output: usage["output_tokens"]?.double ?? 0)
        }
        process.onLine = { [weak self] line in
            guard let self, !line.trimmingCharacters(in: .whitespaces).isEmpty, let o = try? JSON.parse(line) else { return }
            NativeLog.append(threadId: threadId, dir: "in", source: "agy.stream", msg: o)
            let event = o["event"]?.string ?? ""
            let payload = o[event] ?? .null
            switch event {
            case "init":
                conversationId = o["conversation_id"]?.string
                self.emit(threadId, turnId, .sessionStarted(sessionId: conversationId, model: turn.model, resumeCursor: nil))
            case "step_update":
                if payload["step_type"]?.string == "tool" {
                    let index = payload["step_index"].flatMap(ACPTurn.text) ?? "undefined"
                    let itemId = "\(conversationId ?? o["conversation_id"]?.string ?? "conv"):\(index)"
                    switch payload["state"]?.string {
                    case "ACTIVE": self.emit(threadId, turnId, itemId: itemId, .itemStarted(itemType: "tool", title: payload["tool_name"]?.string))
                    case "DONE": self.emit(threadId, turnId, itemId: itemId, .toolCompleted(ok: true))
                    case "ERROR": self.emit(threadId, turnId, itemId: itemId, .toolCompleted(ok: false))
                    default: break
                    }
                } else if payload["step_type"]?.string == "agent_response", let usage = usageOf(payload["usage"]) {
                    self.emit(threadId, turnId, .tokenUsage(input: usage.input, output: usage.output))
                }
            case "result":
                // the text arrives whole in result.response, not streamed
                if let response = payload["response"]?.string, !response.isEmpty {
                    self.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: response))
                    self.emit(threadId, turnId, .textCompleted(text: response))
                }
                let usage = usageOf(payload["usage"])
                if let usage { self.emit(threadId, turnId, .tokenUsage(input: usage.input, output: usage.output)) }
                settle(payload["status"]?.string == "SUCCESS", payload["status"]?.string, usage)
            default:
                break
            }
        }
        var stderr = ""
        process.onStderr = { chunk in
            stderr += chunk
            if stderr.count > 8192 { stderr = String(stderr.suffix(8192)) }
        }
        process.onClose = { [weak self] code in
            guard let self else { return }
            self.children[ObjectIdentifier(process)] = nil
            guard !settled else { return }
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            self.emit(threadId, turnId, .runtimeError(message: "agy exited \(code.map(String.init) ?? "null") before result" + (tail.isEmpty ? "" : ": \(String(tail.suffix(300)))"), setup: nil))
            settle(false, "exit_before_result", nil)
        }
        active[threadId] = (turnId, process)
        // just above agy's own 10m --print-timeout: the backstop for a wedged child
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 11 * 60 * 1_000_000_000)
            guard !Task.isCancelled, !settled else { return }
            self?.emit(threadId, turnId, .runtimeError(message: "agy watchdog timeout", setup: nil))
            process.killTree()
            settle(false, "timeout", nil)
        }
        emit(threadId, turnId, .turnStarted)
        process.start()
        return turnId
    }

    func interruptTurn(threadId: ThreadID) async { active[threadId]?.process.killTree() }

    // print mode has no asks to answer
    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome { .unavailable }

    func hasSession(threadId: ThreadID) -> Bool { active[threadId] != nil }

    func stopAll() async {
        for entry in active.values { entry.process.killTree() }
        for child in children.values { child.killTree() } // also the ones hung after `result`
    }

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { events.add(listener) }
}
