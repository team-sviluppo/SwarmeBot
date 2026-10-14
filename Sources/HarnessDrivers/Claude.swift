// Claude — `server/drivers/claude.ts`, ported.
//
// One `claude -p` process per turn, stream-json both ways: the prompt goes in
// over stdin (never argv: ARG_MAX, and `ps` shows argv to everyone), the turn
// completes on a real `result` frame, and the conversation continues across
// turns with `--resume <sessionId>` (the resume cursor).
//
// Anything the permission mode would silently deny becomes an Allow/Deny card
// through the PermissionBroker and the `mcp-permission` proxy; the agent also
// gets `ask_user`. In bypassPermissions nothing ever asks, so neither exists.
//
// Not ported yet (they need harness pieces the Swift engine does not have,
// docs/plans/fase-2-architettura.md §2e): the computer MCP server, images,
// and generateText. The adapter claims none of those
// capabilities, so nothing upstream offers them. Connected apps (Composio),
// the Android phone tools and dweb are out of scope and will not be ported.
import Foundation
import HarnessCore

public struct ClaudeDriver: ProviderDriver {
    public static let kind = "claudeAgent"
    public let driverKind = ClaudeDriver.kind
    public let displayName = "Claude"
    public let access = "subscription"
    public let cliDefault: String? = "claude"
    public let install: EngineInstall? = EngineInstall(
        darwinCommand: "npm install -g @anthropic-ai/claude-code",
        docsUrl: "https://claude.com/claude-code", signInCommand: "claude", needsNode: true
    )

    public init() {}

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        let instance = try ClaudeInstance(input: input)
        await instance.refreshModels()
        return instance
    }
}

public struct ClaudeConfig: Equatable, Sendable {
    public enum PermissionMode: String, Sendable { case acceptEdits, auto, bypassPermissions }
    public var cli: String
    public var permissionMode: PermissionMode

    public struct Invalid: LocalizedError {
        let mode: String
        public var errorDescription: String? { "claude: invalid permissionMode \(mode)" }
    }

    public init(_ raw: JSON) throws {
        cli = raw["cli"]?.string ?? "claude"
        switch raw["permissionMode"] {
        case nil, .null?:
            permissionMode = .acceptEdits
        case let .string(mode)? where PermissionMode(rawValue: mode) != nil:
            permissionMode = PermissionMode(rawValue: mode)!
        case let other?:
            throw Invalid(mode: other.serialized())
        }
    }
}

// MARK: - Catalog

public enum ClaudeCatalog {
    public static let staticModels = ModelCatalog(default: "claude-sonnet-5", options: [
        ModelOption(id: "claude-fable-5", label: "Claude Fable 5"),
        ModelOption(id: "claude-opus-5", label: "Claude Opus 5"),
        ModelOption(id: "claude-sonnet-5", label: "Claude Sonnet 5"),
        ModelOption(id: "claude-haiku-4-5", label: "Claude Haiku 4.5"),
    ])

    static func isModelId(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9][a-z0-9._:/-]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func configDir(_ env: [String: String]) -> URL {
        if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".claude")
    }

    static func extras(_ value: JSON?) -> [ModelOption] {
        (value?.array ?? []).compactMap { item in
            if let id = item.string { return isModelId(id) ? ModelOption(id: id, label: id) : nil }
            guard item.object != nil else { return nil }
            guard let id = [item["id"], item["model"], item["slug"]].lazy.compactMap({ $0?.string }).first, isModelId(id) else { return nil }
            let label = [item["name"], item["displayName"], item["label"]].lazy.compactMap({ $0?.string }).first
            var option = ModelOption(id: id, label: (label?.isEmpty == false ? label! : id))
            if let levels = item["effortLevels"]?.array {
                let strings = levels.compactMap(\.string)
                if strings.count == levels.count, strings.allSatisfy(isEffortLevel) { option.effortLevels = strings }
            }
            return option
        }
    }

    /// `readClaudeModelCatalog`: extra ids from ~/.claude/settings.json.
    public static func fromSettings(_ env: [String: String]) -> ModelCatalog {
        guard let data = try? Data(contentsOf: configDir(env).appendingPathComponent("settings.json")),
              let settings = try? JSON.parse(data), settings.object != nil else { return staticModels }
        var found = extras(settings["availableModels"]) + extras(settings["customModels"]) + extras(settings["extraModels"])
        if let model = (settings["env"]?["ANTHROPIC_MODEL"] ?? env["ANTHROPIC_MODEL"].map(JSON.string))?.string {
            found += extras([.string(model)])
        }
        if let model = settings["model"]?.string { found += extras([.string(model)]) }
        var options = staticModels.options
        for extra in found where !options.contains(where: { $0.id == extra.id }) {
            var row = extra
            row.custom = true
            options.append(row)
        }
        return ModelCatalog(default: staticModels.default, options: options)
    }

    static let families = ["fable", "opus", "sonnet", "haiku"]

    static func family(ofKey key: String) -> String? {
        guard !key.contains("MYTHOS"), key.hasSuffix("_ID") else { return nil }
        for family in families where key.contains(family.uppercased()) { return family }
        return nil
    }

    static func version(_ id: String) -> [Int] {
        let tail = id.replacingOccurrences(of: #"^claude-(?:fable|opus|sonnet|haiku)-"#, with: "", options: .regularExpression)
        let parts = tail.split(separator: "-", omittingEmptySubsequences: false).map { part in
            part.allSatisfy(\.isNumber) && !part.isEmpty ? Int(part) ?? -1 : -1
        }
        return parts.isEmpty ? [-1] : parts
    }

    static func newer(_ a: [Int], than b: [Int]) -> Bool {
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// `readLatestClaudeModelsFromBinary`: the newest first-party row per
    /// family, from the catalog baked into the installed `claude` binary.
    public static func fromBinary(_ data: Data) -> [ModelOption]? {
        guard let at = data.range(of: Data(#"FABLE_ID:"claude-"#.utf8)) else { return nil }
        let slice = String(decoding: data[at.lowerBound..<min(at.lowerBound + 1500, data.endIndex)], as: UTF8.self)
        var fields: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"([A-Z_]+):"([^"]*)""#)
        for match in pattern.matches(in: slice, range: NSRange(slice.startIndex..., in: slice)) {
            guard let key = Range(match.range(at: 1), in: slice), let value = Range(match.range(at: 2), in: slice) else { continue }
            fields[String(slice[key])] = String(slice[value])
        }
        var best: [String: (id: String, label: String, version: [Int])] = [:]
        for (key, id) in fields.sorted(by: { $0.key < $1.key }) {
            guard let family = family(ofKey: key), isModelId(id) else { continue }
            let name = fields[String(key.dropLast(3)) + "_NAME"]
            let label = name?.isEmpty == false ? name! : id
            let candidate = version(id)
            if let current = best[family], !newer(candidate, than: current.version) { continue }
            best[family] = (id, label, candidate)
        }
        let options = families.compactMap { best[$0].map { ModelOption(id: $0.id, label: $0.label) } }
        return options.isEmpty ? nil : options
    }

    nonisolated(unsafe) private static var binaryCache: [String: (modified: Date, options: [ModelOption]?)] = [:]
    private static let cacheLock = NSLock()

    /// The installed CLI's catalog, cached on the binary's mtime.
    public static func fromInstalledCli(_ cli: String) -> [ModelOption]? {
        guard let head = EnvPath.split(cli).first, let found = EnvPath.which(head) else { return nil }
        let binary = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: binary))?[.modificationDate] as? Date else { return nil }
        cacheLock.lock()
        if let cached = binaryCache[binary], cached.modified == modified { cacheLock.unlock(); return cached.options }
        cacheLock.unlock()
        let options = (try? Data(contentsOf: URL(fileURLWithPath: binary), options: .alwaysMapped)).flatMap(fromBinary)
        cacheLock.lock()
        binaryCache[binary] = (modified, options)
        cacheLock.unlock()
        return options
    }

    /// `withCliModels`: the CLI's own rows lead; custom extras follow.
    public static func withCliModels(_ catalog: ModelCatalog, _ cliModels: [ModelOption]?) -> ModelCatalog {
        guard let cliModels, !cliModels.isEmpty else { return catalog }
        let seen = Set(cliModels.map(\.id))
        let options = cliModels + catalog.options.filter { $0.custom == true && !seen.contains($0.id) }
        return ModelCatalog(default: options.contains { $0.id == catalog.default } ? catalog.default : options[0].id, options: options)
    }
}

// MARK: - Instance

@MainActor
final class ClaudeInstance: ProviderInstance, ProviderAdapter {
    let instanceId: InstanceID
    let driverKind = ClaudeDriver.kind
    let displayName: String?
    let enabled: Bool
    private(set) var models = ClaudeCatalog.staticModels
    var adapter: ProviderAdapter { self }
    let provider = ClaudeDriver.kind
    var capabilities: AdapterCapabilities {
        var capabilities = AdapterCapabilities()
        capabilities.effortLevels = ["low", "medium", "high", "xhigh", "max"]
        capabilities.agentsMcp = true
        capabilities.computerMcp = true
        capabilities.localComputerMcp = config.permissionMode != .bypassPermissions
        capabilities.images = true
        return capabilities
    }

    let config: ClaudeConfig
    private let environment: [String: String]
    private let events = EventEmitter()
    private let dataDir: URL

    private struct Turn {
        var turnId: String
        var process: CLIProcess
        var broker: PermissionBroker?
    }
    private var active: [ThreadID: Turn] = [:]

    init(input: DriverCreateInput) throws {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        config = try ClaudeConfig(input.config)
        environment = input.environment
        // broker sockets live in the data dir, like the Node engine's
        dataDir = DataPaths.fromEnvironment(input.environment).root
    }

    /// `claudeEnvironment`: the env shared by auth probes and real turns, so
    /// setup never claims a login the turn would then strip. Subscription
    /// users must not be billed through a leaked API key, and a nested CLI
    /// must not inherit this session's identity.
    nonisolated static func environment(model: String?, source: [String: String]) -> [String: String] {
        var env = source
        env["PATH"] = EnvPath.augmented(source)
        env["NPM_CONFIG_LOGLEVEL"] = "error"
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        WorkspaceCredentials.strip(&env)
        if !LocalHosts.applyClaudeInject(&env, modelId: model).injected { env["ANTHROPIC_API_KEY"] = nil }
        return env
    }

    // MARK: Catalog and health

    func refreshModels() async {
        let base = ClaudeCatalog.withCliModels(ClaudeCatalog.fromSettings(environment), ClaudeCatalog.fromInstalledCli(config.cli))
        let resolved = await LocalHosts.merge(base, env: environment)
        if !resolved.options.isEmpty { models = resolved }
    }

    func snapshot() async -> ProviderSnapshot {
        let env = Self.environment(model: nil, source: environment)
        guard let version = await CLIProcess.run(config.cli, ["--version"], environment: env, timeout: 8),
              version.ok else { return .unavailable("`\(config.cli)` CLI not found") }
        let authenticated = await Self.signedIn(cli: config.cli, environment: env)
        // turns run on the CLI's own login (the API key is stripped), so the
        // cost it reports is what the call would bill, not a charge
        return ProviderSnapshot(state: "available", reason: nil, authenticated: authenticated,
                                version: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines), billing: "subscription",
                                versionFirst: true)
    }

    /// `claudeSignedIn`: the CLI's own machine-readable status is the only
    /// source of truth — Keychain, files and future backends alike.
    static func signedIn(cli: String, environment: [String: String]) async -> Bool {
        guard let output = await CLIProcess.run(cli, ["auth", "status", "--json"], environment: environment, timeout: 8),
              let status = try? JSON.parse(output.stdout) else { return false }
        return status["loggedIn"]?.bool == true
    }

    func dispose() async {
        await stopAll()
        events.removeAll()
    }

    // MARK: Turns

    private func emit(_ threadId: String, _ turnId: String, itemId: String? = nil, requestId: String? = nil, _ body: RuntimeEvent.Body) {
        events.emit(RuntimeEvent(provider: provider, threadId: threadId, turnId: turnId, itemId: itemId, requestId: requestId, body))
    }

    struct TurnError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        let threadId = turn.threadId
        guard active[threadId] == nil else { throw TurnError(message: "a turn is already running on this thread") }
        let turnId = newId()
        let sessionId = turn.resumeCursor?.string
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose", // required by stream-json output
            // token-level streaming: deltas between the whole-message frames
            "--include-partial-messages",
            "--permission-mode", config.permissionMode == .auto ? "acceptEdits" : config.permissionMode.rawValue,
        ]
        if let sessionId { args += ["--resume", sessionId] } else { args += ["--session-id", newId()] }
        var probe = environment
        if let model = LocalHosts.applyClaudeInject(&probe, modelId: turn.model).model { args += ["--model", model] }
        if let effort = turn.effort { args += ["--effort", effort] }
        if let system = turn.system { args += ["--append-system-prompt", system] }

        // integrations become MCP servers, their tools pre-allowed (a headless
        // acceptEdits run silently denies anything unlisted). For agents it
        // matters doubly: the CLI's own ListAgents look-alike would shadow it.
        if turn.computerScope == "local-computer", config.permissionMode == .bypassPermissions {
            throw TurnError(message: "local computer control requires the interactive approval broker")
        }
        var mcpServers = JSONObject()
        var allowed: [String] = []
        if let computer = turn.computer {
            mcpServers["computer"] = computer.json
            if turn.computerScope != "local-computer" { allowed.append("mcp__computer") }
        }
        if let agents = turn.agents {
            mcpServers["agents"] = agents.json
            allowed.append("mcp__agents")
        }
        var broker: PermissionBroker?
        if config.permissionMode != .bypassPermissions {
            let socketPath = PermissionBroker.socketPath(dataDir: dataDir, threadId: threadId)
            broker = PermissionBroker(
                socketPath: socketPath,
                onAsk: { [weak self] ask in
                    let choices = ask.input["choices"]?.array.map { Array($0.compactMap(\.string).prefix(5)) }
                    self?.emit(threadId, turnId, requestId: ask.id, .requestOpened(
                        requestType: ask.kind.rawValue, tool: ask.tool, summary: PermissionBroker.summary(ask),
                        choices: choices, multiSelect: nil, approvalScope: nil
                    ))
                },
                onResolve: { [weak self] ask, behavior, source in
                    self?.emit(threadId, turnId, requestId: ask.id, .requestResolved(behavior: behavior, source: source, approvalScope: nil))
                }
            )
            args += ["--permission-prompt-tool", "mcp__ogb__approve"]
            mcpServers["ogb"] = ["command": .string(HelperCommand.executable), "args": ["mcp-permission", .string(socketPath)], "env": [:]]
            allowed.append("mcp__ogb")
        }
        // the MCP config can carry credentials: a 0600 file, never argv, gone with the turn
        var mcpDir: URL?
        if !mcpServers.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omb-mcp-\(newId().prefix(8))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent("mcp.json")
            FileManager.default.createFile(atPath: file.path, contents: JSON.object(["mcpServers": .object(mcpServers)]).data,
                                           attributes: [.posixPermissions: 0o600])
            mcpDir = dir
            args += ["--mcp-config", file.path, "--allowedTools", allowed.joined(separator: ",")]
        }

        let env = Self.environment(model: turn.model, source: environment)
        let process: CLIProcess
        do {
            process = try CLIProcess(cli: config.cli, args: args, cwd: turn.cwd ?? NSHomeDirectory(), environment: env)
        } catch let failure as SpawnFailure {
            // Node reports a failed spawn as events, after turn.started
            broker?.shutdown()
            if let mcpDir { try? FileManager.default.removeItem(at: mcpDir) }
            emit(threadId, turnId, .turnStarted)
            emit(threadId, turnId, .runtimeError(message: failure.message, setup: failure.setup))
            emit(threadId, turnId, .turnCompleted(ok: false, stopReason: "spawn_error", cost: nil, denials: nil, usage: nil))
            return turnId
        }

        var settled = false
        let settle: (Bool, String?, Double?, RuntimeEvent.TokenUsage?) -> Void = { [weak self] ok, stopReason, cost, usage in
            guard let self, !settled else { return }
            settled = true
            // closing first answers every open ask before anyone sees the turn gone
            broker?.close()
            // a backgrounded MCP grandchild can keep a one-shot `-p` alive (#211)
            process.killTree()
            if let mcpDir { try? FileManager.default.removeItem(at: mcpDir) }
            self.active[threadId] = nil
            self.emit(threadId, turnId, .turnCompleted(ok: ok, stopReason: stopReason, cost: cost, denials: nil, usage: usage))
        }

        // true while partial messages are streaming the current block, so the
        // whole-message frame does not repeat it as one big delta
        var sawStreamDelta = false
        process.onLine = { [weak self] line in
            guard let self, !line.trimmingCharacters(in: .whitespaces).isEmpty, let o = try? JSON.parse(line) else { return }
            NativeLog.append(threadId: threadId, dir: "in", source: "claude.sdk.message", msg: o)
            switch o["type"]?.string {
            case "system":
                if o["subtype"]?.string == "init" {
                    self.emit(threadId, turnId, .sessionStarted(sessionId: o["session_id"]?.string, model: o["model"]?.string, resumeCursor: nil))
                } else if o["subtype"]?.string == "thinking_tokens" {
                    self.emit(threadId, turnId, .itemUpdated(itemType: "reasoning", tokens: o["estimated_tokens"]))
                }
            case "stream_event":
                // subagent narration is dropped: parallel Tasks would interleave
                if let parent = o["parent_tool_use_id"], parent.truthy { break }
                guard o["event"]?["type"]?.string == "content_block_delta", let delta = o["event"]?["delta"] else { break }
                if delta["type"]?.string == "text_delta", let text = delta["text"]?.string, !text.isEmpty {
                    sawStreamDelta = true
                    self.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: text))
                } else if delta["type"]?.string == "thinking_delta", let text = delta["thinking"]?.string, !text.isEmpty {
                    self.emit(threadId, turnId, .contentDelta(streamKind: "reasoning_text", delta: text))
                }
            case "assistant":
                let message = o["message"] ?? .null
                let text = Self.firstText(message["content"])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // fallback delta for paths that never streamed the block
                    if !sawStreamDelta { self.emit(threadId, turnId, .contentDelta(streamKind: "assistant_text", delta: text)) }
                    sawStreamDelta = false
                    self.emit(threadId, turnId, .textCompleted(text: text))
                }
                for block in message["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
                    self.emit(threadId, turnId, itemId: block["id"]?.string, .itemStarted(itemType: "tool", title: block["name"]?.string))
                }
                if let usage = message["usage"], usage.object != nil {
                    self.emit(threadId, turnId, .tokenUsage(
                        input: (usage["input_tokens"]?.double ?? 0) + (usage["cache_read_input_tokens"]?.double ?? 0),
                        output: usage["output_tokens"]?.double ?? 0
                    ))
                }
            case "user":
                for block in o["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
                    self.emit(threadId, turnId, itemId: block["tool_use_id"]?.string, .toolCompleted(ok: block["is_error"]?.truthy != true))
                }
            case "result":
                // one process per turn: result.usage is the turn's total; cache
                // reads and writes count as input (billed, and they fill the window)
                let usage = o["usage"].flatMap { u -> RuntimeEvent.TokenUsage? in
                    guard u.object != nil else { return nil }
                    return .init(input: (u["input_tokens"]?.double ?? 0) + (u["cache_read_input_tokens"]?.double ?? 0)
                                     + (u["cache_creation_input_tokens"]?.double ?? 0),
                                 output: u["output_tokens"]?.double ?? 0)
                }
                let stopReason = o["stop_reason"]?.string ?? o["terminal_reason"]?.string
                settle(o["is_error"]?.bool != true, stopReason, o["total_cost_usd"]?.double, usage)
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
            broker?.shutdown()
            guard let self, !settled else { return }
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = tail.isEmpty ? "" : ": \(String(tail.suffix(300)))"
            self.emit(threadId, turnId, .runtimeError(message: "claude exited \(code.map(String.init) ?? "null") before result\(detail)", setup: nil))
            settle(false, "exit_before_result", nil, nil)
        }

        active[threadId] = Turn(turnId: turnId, process: process, broker: broker)
        emit(threadId, turnId, .turnStarted)
        process.start()
        let prompt: JSON = ["type": "user", "message": ["role": "user", "content": .string(turn.text)]]
        process.write(prompt.serialized() + "\n")
        process.closeStdin()
        NativeLog.append(threadId: threadId, dir: "out", source: "claude.sdk.message", msg: prompt)
        return turnId
    }

    static func firstText(_ content: JSON?) -> String {
        if let text = content?.string { return text }
        return (content?.array ?? [])
            .filter { $0["type"]?.string == "text" && ($0["text"]?.string.map { !$0.isEmpty } ?? false) }
            .compactMap { $0["text"]?.string }
            .joined()
    }

    func interruptTurn(threadId: ThreadID) async {
        active[threadId]?.process.killTree()
    }

    /// Fail-closed: no broker, or an ask that already timed out or settled,
    /// is `unavailable` and the caller denies.
    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome {
        guard let broker = active[threadId]?.broker else { return .unavailable }
        guard broker.answer(requestId, behavior: decision.behavior, message: decision.message) else { return .unavailable }
        switch decision.behavior {
        case "allow": return .allowedOnce
        case "answer": return .answered
        default: return .rejected
        }
    }

    func hasSession(threadId: ThreadID) -> Bool { active[threadId] != nil }

    func stopAll() async {
        for turn in active.values { turn.process.killTree() }
    }

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { events.add(listener) }
}
