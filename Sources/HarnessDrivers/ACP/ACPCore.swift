// The ACP driver core — `server/drivers/acp/core.ts`, ported.
//
// One JSON-RPC 2.0 session over stdio that every ACP CLI rides (Grok, Gemini,
// Kimi, Droid, Cursor, OpenCode, Qwen, Hermes). The protocol lives here; each
// harness is an `ACPSupport` value with its quirks: argv, auth method, model
// catalog, sign-in check, session settings.
//
// Invariants kept from the Node engine:
// - ACP has no turn-completed notification: the `session/prompt` RPC result
//   is the settle (stopReason + usage);
// - permissions are fail-closed: nothing is approved unless the agent offered
//   an `allow`-kind option — option ORDER is never a security contract;
// - `session/load` replays history as ordinary updates, so updates are
//   double-gated: nothing emits before the prompt is sent, and
//   `_meta.isReplay` updates are dropped;
// - an unknown server→client request is answered "method not found" at once,
//   or the agent blocks on it forever.
//
// Not ported yet (2e): the computer MCP server the Node engine mounts per
// session. The adapter does not claim it.
import Foundation
import HarnessCore

public struct ACPConfig: Equatable, Sendable {
    public var cli: String
    public var fullAuto: Bool
    public var workspace: String?

    init(_ raw: JSON, defaultCli: String) {
        cli = raw["cli"]?.string ?? defaultCli
        fullAuto = raw["fullAuto"]?.bool == true
        workspace = raw["workspace"]?.string
    }
}

/// A JSON-RPC error answer, or a local failure with the same shape.
public struct RPCError: LocalizedError {
    public var message: String
    public var code: JSON?
    public var errorDescription: String? { message }
}

/// What `configureSession` may do: requests on the live session.
@MainActor
public struct ACPSession {
    public let sessionId: String
    let send: (String, JSON, TimeInterval?) async throws -> JSON

    public func request(_ method: String, _ params: JSON, timeout: TimeInterval? = 20) async throws -> JSON {
        try await send(method, params, timeout)
    }
}

/// Everything that differs between ACP harnesses.
public struct ACPSupport: Sendable {
    public enum AuthFailure: Sendable { case fail, `continue` }

    public var driverKind: String
    public var displayName: String
    public var access = "subscription"
    public var models: ModelCatalog
    public var effortLevels: [String]?
    public var defaultCli: String
    public var nativeSource: String
    public var images = true
    public var loginNote: String
    public var install: EngineInstall?
    /// argv after the binary to enter ACP stdio mode (model already resolved).
    public var spawnArgs: @Sendable (_ config: ACPConfig, _ model: String?, _ effort: String?) -> [String]
    /// Provider credentials this CLI may inherit; every other one is stripped.
    public var credentialEnv: [String] = []
    /// Select the model through this session config option (opencode).
    public var selectModelConfigId: String?
    public var transformEnv: (@Sendable (inout [String: String], ACPConfig) -> Void)?
    public var pickAuthMethod: @Sendable ([String]) -> String?
    public var authFailure: AuthFailure
    public var isAuthenticated: @MainActor @Sendable ([String: String], ACPConfig) async -> Bool
    /// invalid_credentials · inactive_subscription · …
    public var classifyError: (@Sendable (Error) -> String?)?
    public var resolveModels: (@MainActor @Sendable ([String: String], ACPConfig) async -> ModelCatalog?)?
    /// Picker id → CLI-native id; may write the CLI's config (local injects).
    public var resolveTurnModel: (@Sendable (String?, [String: String]) throws -> String?)?
    /// Between session/new|load and the first prompt; a throw fails the turn.
    public var configureSession: (@MainActor @Sendable (ACPSession, ACPConfig, _ model: String?) async throws -> Void)?
}

public struct ACPDriver: ProviderDriver {
    public let support: ACPSupport
    public var driverKind: String { support.driverKind }
    public var displayName: String { support.displayName }
    public var access: String { support.access }
    public var install: EngineInstall? { support.install }
    public var cliDefault: String? { support.defaultCli }

    public init(_ support: ACPSupport) {
        self.support = support
    }

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        let instance = ACPInstance(support: support, input: input)
        await instance.refreshModels()
        return instance
    }
}

/// `PROVIDER_CREDENTIAL_ENV`: keys a CLI could read as its billing identity.
let providerCredentialEnv = [
    "ANTHROPIC_API_KEY", "FACTORY_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "KIMI_API_KEY", "MOONSHOT_API_KEY",
    "OPENAI_API_KEY", "OPENCODE_API_KEY", "XAI_API_KEY", "CURSOR_API_KEY", "CURSOR_AUTH_TOKEN",
]

let acpDenyTimeoutNote = "SwarmeBot: nobody answered this permission request in time. Skip this action and finish what you can without it."

@MainActor
final class ACPInstance: ProviderInstance, ProviderAdapter {
    static let initTimeout: TimeInterval = 20
    static let newSessionTimeout: TimeInterval = 30
    static let loadSessionTimeout: TimeInterval = 120 // history replay on a long thread is slow

    let support: ACPSupport
    let instanceId: InstanceID
    let displayName: String?
    let enabled: Bool
    let config: ACPConfig
    private let environment: [String: String]
    private(set) var models: ModelCatalog
    var driverKind: String { support.driverKind }
    var provider: String { support.driverKind }
    var adapter: ProviderAdapter { self }
    let capabilities: AdapterCapabilities
    private let events = EventEmitter()
    private var active: [ThreadID: ACPTurn] = [:]

    init(support: ACPSupport, input: DriverCreateInput) {
        self.support = support
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        config = ACPConfig(input.config, defaultCli: support.defaultCli)
        environment = input.environment
        models = support.models
        var capabilities = AdapterCapabilities()
        capabilities.sessionModelSwitch = "unsupported"
        capabilities.effortLevels = support.effortLevels
        capabilities.agentsMcp = true
        capabilities.computerMcp = true
        capabilities.localComputerMcp = !config.fullAuto
        capabilities.images = support.images
        self.capabilities = capabilities
    }

    /// Two lists, one rule: foreign provider keys must not move a CLI off its
    /// own login, and workspace credentials are the harness's — riding along
    /// in the environment is not a grant. Only `credentialEnv` survives.
    func childEnvironment() -> [String: String] {
        var env = environment
        env["PATH"] = EnvPath.augmented(environment)
        let allowed = Set(support.credentialEnv)
        for key in providerCredentialEnv + WorkspaceCredentials.env where !allowed.contains(key) { env[key] = nil }
        support.transformEnv?(&env, config)
        return env
    }

    func refreshModels() async {
        guard let resolve = support.resolveModels else { return }
        // a failed lookup keeps the last usable catalog
        if let resolved = await resolve(childEnvironment(), config), !resolved.options.isEmpty { models = resolved }
    }

    func snapshot() async -> ProviderSnapshot {
        let env = childEnvironment()
        guard let version = await CLIProcess.run(config.cli, ["--version"], environment: env, timeout: 8), version.ok else {
            return .unavailable("`\(config.cli)` CLI not found")
        }
        return ProviderSnapshot(state: "available", reason: nil, authenticated: await support.isAuthenticated(env, config),
                                version: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines), billing: nil, versionFirst: true)
    }

    func dispose() async {
        await stopAll()
        events.removeAll()
    }

    func emit(_ event: RuntimeEvent) { events.emit(event) }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        guard active[turn.threadId] == nil else { throw RPCError(message: "a turn is already running on this thread") }
        if turn.computerScope == "local-computer", config.fullAuto {
            throw RPCError(message: "local computer control requires interactive provider approvals")
        }
        // before anything starts, as in the Node engine: a config writer that
        // refuses (droid's unreadable settings.json) fails the send itself
        let env = childEnvironment()
        let model = try support.resolveTurnModel.map { try $0(turn.model, env) } ?? turn.model
        let acpTurn = ACPTurn(instance: self, turn: turn, environment: env, model: model)
        active[turn.threadId] = acpTurn
        acpTurn.start()
        return acpTurn.turnId
    }

    func turnEnded(_ threadId: ThreadID) { active[threadId] = nil }

    func interruptTurn(threadId: ThreadID) async { active[threadId]?.interrupt() }

    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome {
        // settled, timed out, or turn gone
        guard let turn = active[threadId], turn.answer(requestId, behavior: decision.behavior == "allow" ? "allow" : "deny") else {
            return .unavailable
        }
        return decision.behavior == "allow" ? .allowedOnce : .rejected
    }

    func hasSession(threadId: ThreadID) -> Bool { active[threadId] != nil }

    func stopAll() async {
        for turn in active.values { turn.stop() }
    }

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { events.add(listener) }
}

/// One turn: one CLI process, one ACP session.
@MainActor
final class ACPTurn {
    let turnId = newId()
    private unowned let instance: ACPInstance
    private let turn: SendTurnInput
    private var support: ACPSupport { instance.support }
    private var config: ACPConfig { instance.config }
    private var threadId: String { turn.threadId }
    private var process: CLIProcess?
    private var settled = false
    private var promptSent = false
    private var text = ""
    private var sessionId: String?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var asks: [String: (String, String) -> Void] = [:]
    private var interruptTimer: Task<Void, Never>?
    private var stderr = ""

    private let environment: [String: String]
    /// The CLI-native model id (local picks already resolved).
    private let model: String?

    init(instance: ACPInstance, turn: SendTurnInput, environment: [String: String], model: String?) {
        self.instance = instance
        self.turn = turn
        self.environment = environment
        self.model = model
    }

    private func emit(itemId: String? = nil, requestId: String? = nil, _ body: RuntimeEvent.Body) {
        instance.emit(RuntimeEvent(provider: support.driverKind, threadId: threadId, turnId: turnId,
                                   itemId: itemId, requestId: requestId, body))
    }

    // MARK: Wire

    private func send(_ message: JSON) {
        process?.write(message.serialized() + "\n")
        NativeLog.append(threadId: threadId, dir: "out", source: support.nativeSource, msg: message)
    }

    private func request(_ method: String, _ params: JSON, timeout: TimeInterval? = nil) async throws -> JSON {
        if settled { throw RPCError(message: "turn settled") }
        let id = nextId
        nextId += 1
        if let timeout {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.pending.removeValue(forKey: id)?.resume(throwing: RPCError(message: "\(method) timed out"))
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    private func handle(line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let message = try? JSON.parse(line) else { return }
        NativeLog.append(threadId: threadId, dir: "in", source: support.nativeSource, msg: message)
        let id = message["id"]
        if let id, message["result"] != nil || message["error"] != nil {
            guard let key = id.int, let continuation = pending.removeValue(forKey: key) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: RPCError(message: error["message"]?.string ?? error.serialized(), code: error["code"]))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        } else if id != nil, message["method"] != nil {
            handleServerRequest(message)
        } else if message["method"] != nil {
            handleNotification(message)
        }
    }

    // MARK: Permissions

    private func handleServerRequest(_ message: JSON) {
        let id = message["id"] ?? .null
        guard message["method"]?.string == "session/request_permission" else {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]])
            return
        }
        let params = message["params"] ?? .null
        let options = params["options"]?.array ?? []
        let optionFor: (String) -> String? = { want in
            options.first { ($0["kind"]?.string ?? "").hasPrefix(want) && $0["optionId"]?.string != nil }?["optionId"]?.string
        }
        let cancelled: JSON = ["outcome": ["outcome": "cancelled"]]
        let missing: (String) -> Void = { [weak self] want in
            guard let self else { return }
            self.emit(.runtimeError(message: "\(self.support.driverKind) offered no \"\(want)\" permission option — cancelling the request instead of guessing", setup: nil))
        }
        let selected: (String) -> JSON = { ["outcome": ["outcome": "selected", "optionId": .string($0)]] }

        if config.fullAuto {
            let allow = optionFor("allow")
            if allow == nil { missing("allow") }
            send(["jsonrpc": "2.0", "id": id, "result": allow.map(selected) ?? cancelled])
            return
        }
        let toolCall = params["toolCall"] ?? .null
        let kind = toolCall["kind"]?.string ?? ""
        let tool = kind == "execute" ? "shell" : kind == "edit" ? "edit" : kind.isEmpty ? "tool" : kind
        let summary = String((toolCall["rawInput"]?["command"].flatMap(Self.text) ?? toolCall["title"].flatMap(Self.text) ?? tool).prefix(200))
        let requestId = newId()
        var timer: Task<Void, Never>?
        let finish: (String, String) -> Void = { [weak self] behavior, source in
            guard let self, self.asks.removeValue(forKey: requestId) != nil else { return }
            timer?.cancel()
            let want = behavior == "allow" ? "allow" : "reject"
            let optionId = behavior == "cancel" ? nil : optionFor(want)
            if behavior != "cancel", optionId == nil { missing(want) }
            self.send(["jsonrpc": "2.0", "id": id, "result": optionId.map(selected) ?? cancelled])
            self.emit(requestId: requestId, .requestResolved(
                behavior: optionId != nil && behavior == "allow" ? "allow" : "deny",
                source: optionId != nil ? source : "system", approvalScope: nil
            ))
        }
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self, self.asks[requestId] != nil else { return }
            self.emit(.runtimeError(message: acpDenyTimeoutNote, setup: nil))
            finish("deny", "timeout")
        }
        asks[requestId] = finish
        emit(requestId: requestId, .requestOpened(requestType: "permission", tool: tool, summary: summary,
                                                  choices: nil, multiSelect: nil, approvalScope: nil))
    }

    /// `String(x)` on a JSON scalar, as the Node engine stringifies it.
    static func text(_ value: JSON) -> String? {
        switch value {
        case let .string(s): return s
        case let .number(n): return JSON.number(n).serialized()
        case let .bool(b): return b ? "true" : "false"
        case .null: return nil
        default: return value.serialized()
        }
    }

    func answer(_ requestId: String, behavior: String) -> Bool {
        guard let finish = asks[requestId] else { return false }
        finish(behavior, "user")
        return true
    }

    // MARK: Updates

    private func handleNotification(_ message: JSON) {
        // vendor side channels (grok's `_x.ai/*`) are in the native log only
        guard message["method"]?.string == "session/update" else { return }
        let params = message["params"] ?? .null
        guard promptSent, params["_meta"]?["isReplay"]?.bool != true else { return }
        let update = params["update"] ?? .null
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            if let delta = update["content"]?["text"]?.string, !delta.isEmpty {
                text += delta
                emit(.contentDelta(streamKind: "assistant_text", delta: delta))
            }
        case "agent_thought_chunk":
            if let delta = update["content"]?["text"]?.string, !delta.isEmpty {
                emit(.contentDelta(streamKind: "reasoning_text", delta: delta))
            }
        case "tool_call":
            let title = update["rawInput"]?["command"].flatMap(Self.text) ?? update["title"].flatMap(Self.text) ?? "tool"
            emit(itemId: update["toolCallId"].flatMap(Self.text), .itemStarted(itemType: "tool", title: String(title.prefix(80))))
        case "tool_call_update":
            let status = update["status"]?.string
            if status == "completed" || status == "failed" {
                emit(itemId: update["toolCallId"].flatMap(Self.text), .toolCompleted(ok: status != "failed"))
            }
        default:
            break
        }
    }

    // MARK: Lifecycle

    func stop() { process?.killTree() }

    private func settle(ok: Bool, stopReason: String?) {
        guard !settled else { return }
        settled = true
        interruptTimer?.cancel()
        for finish in Array(asks.values) { finish("cancel", "system") }
        for continuation in pending.values { continuation.resume(throwing: RPCError(message: "turn settled")) }
        pending.removeAll()
        instance.turnEnded(threadId)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emit(.textCompleted(text: text)) }
        emit(.turnCompleted(ok: ok, stopReason: stopReason, cost: nil, denials: nil, usage: nil))
        stop() // the agent process does not exit on its own
    }

    func interrupt() {
        if let sessionId {
            send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": .string(sessionId)]])
        } else {
            stop()
        }
        interruptTimer?.cancel()
        interruptTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.settle(ok: true, stopReason: "cancelled")
        }
    }

    func start() {
        let cwd = turn.cwd ?? config.workspace ?? NSHomeDirectory()
        let env = environment
        let model = self.model
        let support = self.support

        do {
            process = try CLIProcess(cli: config.cli, args: support.spawnArgs(config, model, turn.effort), cwd: cwd, environment: env)
        } catch {
            let failure = error as? SpawnFailure ?? SpawnFailure(message: "spawn failed: \(error.localizedDescription)", setup: false)
            emit(.turnStarted)
            emit(.runtimeError(message: failure.message, setup: failure.setup))
            settle(ok: false, stopReason: "spawn_error")
            return
        }
        process?.onLine = { [weak self] line in self?.handle(line: line) }
        process?.onStderr = { [weak self] chunk in
            guard let self else { return }
            self.stderr += chunk
            if self.stderr.count > 8192 { self.stderr = String(self.stderr.suffix(8192)) }
        }
        process?.onClose = { [weak self] code in
            guard let self, !self.settled else { return }
            let tail = self.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            self.emit(.runtimeError(message: "\(support.driverKind) exited \(code.map(String.init) ?? "null") before the prompt result"
                                    + (tail.isEmpty ? "" : ": \(String(tail.suffix(300)))"), setup: nil))
            self.settle(ok: false, stopReason: "exit_before_result")
        }
        emit(.turnStarted)
        process?.start()

        Task { @MainActor in
            do {
                try await self.run(cwd: cwd, model: model)
            } catch {
                guard !self.settled else { return }
                let message = (error as? RPCError)?.message ?? error.localizedDescription
                let code = support.classifyError?(error)
                // signing in is a user action, not a retry
                let needsAuth = code == "invalid_credentials" || code == "inactive_subscription" || message == support.loginNote
                self.emit(.runtimeError(message: message, setup: needsAuth ? true : nil))
                self.settle(ok: false, stopReason: needsAuth ? "auth_required" : "rpc_error")
            }
        }
    }

    private func run(cwd: String, model: String?) async throws {
        let initResult = try await request("initialize", [
            "protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
        ], timeout: ACPInstance.initTimeout)
        let methods = (initResult["authMethods"]?.array ?? []).compactMap { $0["id"]?.string }
        if let methodId = support.pickAuthMethod(methods) {
            do {
                _ = try await request("authenticate", ["methodId": .string(methodId)], timeout: ACPInstance.initTimeout)
            } catch {
                if support.authFailure == .fail { throw RPCError(message: support.loginNote) }
                // else: ride an ambient login
            }
        } else if support.authFailure == .fail {
            throw RPCError(message: support.loginNote)
        }

        // stdio is the baseline every ACP agent supports
        var servers: [JSON] = []
        if let agents = turn.agents { servers.append(agents.acp(name: "agents")) }
        if let computer = turn.computer { servers.append(computer.acp(name: "computer")) }
        let mcpServers: JSON = .array(servers)
        var sessionResult: JSON = .null
        if let cursor = turn.resumeCursor?.string, !cursor.isEmpty {
            do {
                sessionResult = try await request("session/load", ["sessionId": .string(cursor), "cwd": .string(cwd), "mcpServers": mcpServers],
                                                  timeout: ACPInstance.loadSessionTimeout)
                sessionId = cursor
            } catch {
                // session gone, load unsupported, or too slow — start fresh
            }
        }
        if sessionId == nil {
            sessionResult = try await request("session/new", ["cwd": .string(cwd), "mcpServers": mcpServers], timeout: ACPInstance.newSessionTimeout)
            sessionId = sessionResult["sessionId"]?.string
            guard sessionId != nil else { throw RPCError(message: "session/new returned no sessionId") }
        }
        let sessionId = self.sessionId!

        var selectedModel: String?
        var sessionStarted = false
        let emitSessionStarted = {
            guard !sessionStarted else { return }
            sessionStarted = true
            self.emit(.sessionStarted(sessionId: sessionId,
                                      model: selectedModel ?? initResult["_meta"]?["modelState"]?["currentModelId"]?.string ?? model,
                                      resumeCursor: nil))
        }
        do {
            if let configId = support.selectModelConfigId {
                let currentOf: (JSON) -> String? = { result in
                    result["configOptions"]?.array?.first { $0["id"]?.string == configId }?["currentValue"]?.string
                }
                selectedModel = currentOf(sessionResult)
                if let model, model != selectedModel {
                    selectedModel = currentOf(try await request("session/set_config_option", [
                        "sessionId": .string(sessionId), "configId": .string(configId), "value": .string(model),
                    ], timeout: ACPInstance.initTimeout))
                    // answering OK but keeping the old model burns a paid turn on the wrong thing
                    if selectedModel != model {
                        throw RPCError(message: "\(support.driverKind) did not switch to \(model) (still \(selectedModel ?? "unknown"))")
                    }
                }
            }
            if let configure = support.configureSession {
                let session = ACPSession(sessionId: sessionId) { [weak self] method, params, timeout in
                    guard let self else { throw RPCError(message: "turn settled") }
                    return try await self.request(method, params, timeout: timeout)
                }
                try await configure(session, config, model)
                // initialize's currentModelId is the CLI default, not this turn's pick
                if selectedModel == nil, let model { selectedModel = model }
            }
        } catch {
            // session.started is the only place the cursor is recorded: never orphan a session
            emitSessionStarted()
            throw error
        }
        emitSessionStarted()
        promptSent = true
        let prompt = turn.system.map { "\($0)\n\n\(turn.text)" } ?? turn.text
        let result = try await request("session/prompt", ["sessionId": .string(sessionId), "prompt": [["type": "text", "text": .string(prompt)]]])
        // opencode reports usage at the root; grok and gemini under _meta
        let usage = result["usage"] ?? result["_meta"] ?? .null
        let input = usage["inputTokens"]?.double, output = usage["outputTokens"]?.double
        if input != nil || output != nil { emit(.tokenUsage(input: input ?? 0, output: output ?? 0)) }
        switch result["stopReason"]?.string {
        case "end_turn": settle(ok: true, stopReason: nil)
        case "cancelled": settle(ok: true, stopReason: "cancelled")
        case let reason: settle(ok: false, stopReason: reason ?? "failed")
        }
    }
}
