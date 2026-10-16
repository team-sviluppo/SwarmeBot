// Codex — `server/drivers/codex.ts` and `codex-catalog.ts`, ported.
//
// The official `codex` CLI headless over its app-server JSON-RPC (newline-
// delimited JSON on stdio), one process per turn. Completion is a real
// `turn/completed` notification; approvals and questions arrive as server→
// client requests and are answered in-process — no MCP proxy, no socket.
// Two generations of approval methods coexist (execCommandApproval /
// applyPatchApproval answer approved|denied, the item/* ones accept|decline).
//
// The resume cursor is the codex thread id: thread/resume, else thread/start.
// Picker ids are `provider::model` for anything but the official rows, since
// thread/start takes model and modelProvider separately.
import Foundation
import HarnessCore

public struct CodexDriver: ProviderDriver {
    public let driverKind = "codex"
    public let displayName = "Codex"
    public let access = "subscription"
    public let cliDefault: String? = "codex"
    public let install: EngineInstall? = EngineInstall(darwinCommand: "npm install -g @openai/codex",
                                                       docsUrl: "https://github.com/openai/codex", signInCommand: "codex login", needsNode: true)

    public init() {}

    public func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        let instance = CodexInstance(input: input)
        await instance.refreshModels()
        return instance
    }
}

// MARK: - Catalog

public enum CodexCatalog {
    public static let staticModels = ModelCatalog(default: "gpt-5.6-sol", options: [
        ModelOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol"), ModelOption(id: "gpt-5.6-terra", label: "GPT-5.6 Terra"),
        ModelOption(id: "gpt-5.6-luna", label: "GPT-5.6 Luna"), ModelOption(id: "gpt-5.5", label: "GPT-5.5"),
        ModelOption(id: "gpt-5.4", label: "GPT-5.4"), ModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini"),
        ModelOption(id: "gpt-5.3-codex-spark", label: "GPT-5.3 Codex Spark"),
    ])
    /// Official rows force this provider, so a local default does not swallow them.
    static let official = "openai"

    static func isModelId(_ id: String) -> Bool { id.range(of: #"^[\w][\w./:+-]*$"#, options: .regularExpression) != nil }
    static func isProviderId(_ id: String) -> Bool { id.range(of: #"^[a-zA-Z][a-zA-Z0-9_-]*$"#, options: .regularExpression) != nil }

    static func encode(_ provider: String, _ model: String) -> String { "\(provider)::\(model)" }

    /// Bare ids are official (a new cloud model must not fall to a local provider).
    public static func decode(_ id: String?) -> (model: String?, provider: String?) {
        guard let id, !id.isEmpty else { return (nil, nil) }
        if let range = id.range(of: "::"), range.lowerBound > id.startIndex {
            return (String(id[range.upperBound...]), String(id[..<range.lowerBound]))
        }
        return (id, isModelId(id) ? official : nil)
    }

    static func home(_ env: [String: String]) -> String {
        env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(env["HOME"] ?? NSHomeDirectory())/.codex"
    }

    struct Provider {
        var id: String
        var name: String?
        var baseUrl: String?
        var envKey: String?
    }

    struct Toml {
        var model: String?
        var modelProvider: String?
        var providers: [Provider] = []
    }

    static func unquote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #"), !(value.hasPrefix("\"") || value.hasPrefix("'")) {
            value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return value
    }

    static func parse(_ text: String) -> Toml {
        var result = Toml()
        var current: Int? // index into providers; nil = root, -1 = other section
        var inRoot = true
        for line in text.components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            if stripped.hasPrefix("["), stripped.hasSuffix("]") {
                inRoot = false
                current = nil
                let inner = String(stripped.dropFirst().dropLast())
                if inner.hasPrefix("model_providers.") {
                    var id = String(inner.dropFirst("model_providers.".count))
                    if id.count >= 2, id.hasPrefix("\""), id.hasSuffix("\"") { id = String(id.dropFirst().dropLast()) }
                    if isProviderId(id) {
                        if let index = result.providers.firstIndex(where: { $0.id == id }) { current = index } else {
                            result.providers.append(Provider(id: id))
                            current = result.providers.count - 1
                        }
                    }
                }
                continue
            }
            guard let eq = stripped.firstIndex(of: "=") else { continue }
            let key = stripped[..<eq].trimmingCharacters(in: .whitespaces)
            let value = unquote(String(stripped[stripped.index(after: eq)...]))
            if value.isEmpty { continue }
            if inRoot {
                if key == "model" { result.model = value }
                if key == "model_provider" { result.modelProvider = value }
                continue
            }
            guard let index = current else { continue }
            switch key {
            case "name": result.providers[index].name = value
            case "base_url": result.providers[index].baseUrl = value
            case "env_key": result.providers[index].envKey = value
            default: break
            }
        }
        return result
    }

    static func records(_ payload: JSON?) -> [JSON] {
        payload?.array ?? payload?["models"]?.array ?? payload?["data"]?.array ?? []
    }

    /// Labels from ~/.codex/model-catalogs/<provider>[-models].json.
    static func catalogNames(_ home: String) -> [(String, String)] {
        var named: [(String, String)] = []
        let dir = "\(home)/model-catalogs"
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where file.hasSuffix(".json") {
            let provider = String(file.dropLast(5)).replacingOccurrences(of: #"-models$"#, with: "", options: .regularExpression)
            guard isProviderId(provider), let parsed = FileIO.readJSON(URL(fileURLWithPath: "\(dir)/\(file)")) else { continue }
            for row in records(parsed) where row.object != nil {
                let slug = row["slug"]?.string ?? row["id"]?.string ?? ""
                guard isModelId(slug) else { continue }
                let label = row["display_name"]?.string ?? row["name"]?.string ?? ""
                if !label.isEmpty { named.append((encode(provider, slug), label)) }
            }
        }
        return named
    }

    static func probe(_ provider: Provider, env: [String: String], session: URLSession) async -> [String] {
        guard let base = provider.baseUrl, let url = URL(string: base.trimmingSuffix("/") + "/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        if let key = provider.envKey, let value = env[key], !value.isEmpty { request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
              let payload = try? JSON.parse(data) else { return [] }
        return records(payload).compactMap { $0.string ?? $0["id"]?.string ?? $0["slug"]?.string }.filter(isModelId)
    }

    /// The ChatGPT catalog the installed CLI can actually use (`model/list`, every page).
    @MainActor
    static func fromAppServer(cli: String, env: [String: String], timeout: TimeInterval = 8) async -> ModelCatalog? {
        guard let process = try? CLIProcess(cli: cli, args: ["app-server"], cwd: NSHomeDirectory(), environment: env) else { return nil }
        return await withCheckedContinuation { continuation in
            var finished = false
            var nextId = 1
            var pending: [Int: String] = [:]
            var rows: [JSON] = []
            var cursors = Set<String>()
            let finish: (ModelCatalog?) -> Void = { catalog in
                guard !finished else { return }
                finished = true
                process.killTree()
                continuation.resume(returning: catalog)
            }
            let request: (String, JSON, String) -> Void = { method, params, kind in
                pending[nextId] = kind
                process.write(JSON.object(["jsonrpc": "2.0", "id": .number(Double(nextId)), "method": .string(method), "params": params]).serialized() + "\n")
                nextId += 1
            }
            process.onLine = { line in
                guard let message = try? JSON.parse(line), let id = message["id"]?.int, let kind = pending.removeValue(forKey: id) else { return }
                if message["error"] != nil { return finish(nil) }
                if kind == "initialize" {
                    process.write(#"{"jsonrpc":"2.0","method":"initialized","params":{}}"# + "\n")
                    return request("model/list", ["cursor": .null, "limit": 100], "models")
                }
                let page = message["result"]
                rows += page?["data"]?.array ?? []
                if let cursor = page?["nextCursor"]?.string, !cursor.isEmpty, cursors.insert(cursor).inserted {
                    return request("model/list", ["cursor": .string(cursor), "limit": 100], "models")
                }
                var options: [ModelOption] = []
                var defaultModel: String?
                for row in rows {
                    guard row["hidden"]?.bool != true, let id = row["id"]?.string, isModelId(id), !options.contains(where: { $0.id == id }) else { continue }
                    let name = row["displayName"]?.string?.trimmingCharacters(in: .whitespaces)
                    options.append(ModelOption(id: id, label: name?.isEmpty == false ? row["displayName"]!.string! : id))
                    if row["isDefault"]?.bool == true { defaultModel = id }
                }
                guard !options.isEmpty else { return finish(nil) }
                finish(ModelCatalog(default: defaultModel ?? options[0].id, options: options))
            }
            process.onClose = { _ in finish(nil) }
            process.start()
            request("initialize", ["clientInfo": ["name": "swarmebot", "version": "1"]], "initialize")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(nil)
            }
        }
    }

    /// `readCodexModelCatalog`: official rows, then everything ~/.codex knows.
    @MainActor
    public static func read(env: [String: String], cli: String?, session: URLSession = .shared) async -> ModelCatalog {
        var officialCatalog = staticModels
        if let cli, let live = await fromAppServer(cli: cli, env: env) { officialCatalog = live }
        let home = home(env)
        guard let mainText = try? String(contentsOfFile: "\(home)/config.toml", encoding: .utf8) else {
            return await LocalHosts.merge(officialCatalog, env: env)
        }
        let main = parse(mainText)
        var known = main.providers
        let named = catalogNames(home)
        var extras: [(provider: String, model: String)] = []
        let remember: (String?, String?) -> Void = { provider, model in
            guard let provider, let model, isProviderId(provider), isModelId(model) else { return }
            // a local provider may serve an official slug: keep it qualified
            if provider == official, officialCatalog.options.contains(where: { $0.id == model }) { return }
            extras.append((provider, model))
        }
        remember(main.modelProvider, main.model)
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).sorted() where file.hasSuffix(".config.toml") {
            let profile = parse((try? String(contentsOfFile: "\(home)/\(file)", encoding: .utf8)) ?? "")
            for provider in profile.providers where !known.contains(where: { $0.id == provider.id }) { known.append(provider) }
            remember(profile.modelProvider ?? main.modelProvider, profile.model)
        }
        for (encoded, _) in named {
            let decoded = decode(encoded)
            if let model = decoded.model, let provider = decoded.provider { remember(provider, model) }
        }
        for provider in known {
            for model in await probe(provider, env: env, session: session) { remember(provider.id, model) }
        }
        var options = officialCatalog.options
        for extra in extras {
            let id = encode(extra.provider, extra.model)
            guard !options.contains(where: { $0.id == id }) else { continue }
            let label: String
            if let name = named.first(where: { $0.0 == id })?.1 { label = name } else {
                let host = known.first { $0.id == extra.provider }?.name.flatMap { $0.isEmpty ? nil : $0 } ?? extra.provider
                label = host == extra.provider ? extra.model : "\(extra.model) (\(host))"
            }
            options.append(ModelOption(id: id, label: label, custom: true))
        }
        let ids = Set(options.map(\.id))
        var configured: String?
        if let model = main.model, let provider = main.modelProvider {
            configured = provider == official && officialCatalog.options.contains(where: { $0.id == model }) ? model : encode(provider, model)
        } else if let model = main.model, ids.contains(model) {
            configured = model
        }
        return await LocalHosts.merge(ModelCatalog(default: configured.flatMap { ids.contains($0) ? $0 : nil } ?? officialCatalog.default,
                                                   options: options), env: env)
    }

    /// `codexLocalProviderArgs`: a local pick configured on the command line,
    /// secret in the child env, only its NAME on argv.
    static func localProviderArgs(_ env: inout [String: String], model: String?) -> [String] {
        guard let inject = LocalHosts.decode(model), !["openai", "ollama", "lmstudio"].contains(inject.host),
              let host = LocalHosts.resolve(inject.host, env: env) else { return [] }
        let envKey = "SWARMEBOT_LOCAL_\(host.id.uppercased().replacingOccurrences(of: #"[^A-Z0-9]+"#, with: "_", options: .regularExpression))_API_KEY"
        env[envKey] = LocalHosts.apiKey(host, env: env)
        return [
            "-c", "model_providers.\(host.id).name=\(JSON.string(host.label).serialized())",
            "-c", "model_providers.\(host.id).base_url=\(JSON.string(host.baseUrl).serialized())",
            "-c", "model_providers.\(host.id).env_key=\(JSON.string(envKey).serialized())",
        ]
    }
}

// MARK: - Instance

@MainActor
final class CodexInstance: ProviderInstance, ProviderAdapter {
    let instanceId: InstanceID
    let driverKind = "codex"
    let provider = "codex"
    let displayName: String?
    let enabled: Bool
    private(set) var models = CodexCatalog.staticModels
    var adapter: ProviderAdapter { self }
    var capabilities: AdapterCapabilities {
        var capabilities = AdapterCapabilities()
        capabilities.sessionModelSwitch = "unsupported"
        capabilities.effortLevels = ["low", "medium", "high", "xhigh", "max"]
        capabilities.agentsMcp = true
        capabilities.computerMcp = true
        capabilities.localComputerMcp = !fullAuto
        capabilities.connectors = .mcp
        capabilities.images = true
        return capabilities
    }

    let cli: String
    let fullAuto: Bool
    private let environment: [String: String]
    private let events = EventEmitter()
    private var active: [ThreadID: CodexTurn] = [:]

    init(input: DriverCreateInput) {
        instanceId = input.instanceId
        displayName = input.displayName
        enabled = input.enabled
        cli = input.config["cli"]?.string ?? "codex"
        fullAuto = input.config["fullAuto"]?.bool == true
        environment = input.environment
    }

    /// The CLI owns its ChatGPT login: a leaked API key flips billing.
    func childEnvironment() -> [String: String] {
        var env = environment
        env["PATH"] = EnvPath.augmented(environment)
        env["NPM_CONFIG_LOGLEVEL"] = "error"
        env["OPENAI_API_KEY"] = nil
        WorkspaceCredentials.strip(&env)
        return env
    }

    func refreshModels() async {
        let resolved = await CodexCatalog.read(env: childEnvironment(), cli: cli)
        if !resolved.options.isEmpty { models = resolved }
    }

    func snapshot() async -> ProviderSnapshot {
        let env = childEnvironment()
        guard let version = await CLIProcess.run(cli, ["--version"], environment: env, timeout: 8), version.ok else {
            return .unavailable("`\(cli)` CLI not found")
        }
        let status = await CLIProcess.run(cli, ["login", "status"], environment: env, timeout: 8)
        let authenticated = status.map { $0.ok && ($0.stdout + "\n" + $0.stderr).range(of: #"(?im)^logged in\b"#, options: .regularExpression) != nil } ?? false
        return ProviderSnapshot(state: "available", reason: nil, authenticated: authenticated,
                                version: version.stdout.trimmingCharacters(in: .whitespacesAndNewlines), billing: "subscription", versionFirst: true)
    }

    func dispose() async {
        await stopAll()
        events.removeAll()
    }

    func emit(_ event: RuntimeEvent) { events.emit(event) }
    func turnEnded(_ threadId: ThreadID) { active[threadId] = nil }

    func sendTurn(_ turn: SendTurnInput) async throws -> String {
        guard active[turn.threadId] == nil else { throw RPCError(message: "a turn is already running on this thread") }
        if turn.computerScope == "local-computer", fullAuto {
            throw RPCError(message: "local computer control requires interactive provider approvals")
        }
        let codexTurn = CodexTurn(instance: self, turn: turn)
        active[turn.threadId] = codexTurn
        codexTurn.start()
        return codexTurn.turnId
    }

    func interruptTurn(threadId: ThreadID) async { active[threadId]?.stop() }

    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome {
        guard let turn = active[threadId], turn.answer(requestId, behavior: decision.behavior, message: decision.message) else { return .unavailable }
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
final class CodexTurn {
    static let questionTimeoutNote = "No answer was given — use your best judgment."

    let turnId = newId()
    private unowned let instance: CodexInstance
    private let turn: SendTurnInput
    private var threadId: String { turn.threadId }
    private var process: CLIProcess?
    private var settled = false
    private var sawStreamDelta = false
    /// codex reports a running THREAD total; the last report is this turn's figure
    private var usage: RuntimeEvent.TokenUsage?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var asks: [String: (String, String?, String) -> Void] = [:]
    private var stderr = ""

    init(instance: CodexInstance, turn: SendTurnInput) {
        self.instance = instance
        self.turn = turn
    }

    private func emit(itemId: String? = nil, requestId: String? = nil, input: String? = nil, output: String? = nil, _ body: RuntimeEvent.Body) {
        var event = RuntimeEvent(provider: "codex", threadId: threadId, turnId: turnId, itemId: itemId, requestId: requestId, body)
        event.toolInput = input
        event.toolOutput = output
        instance.emit(event)
    }

    private func send(_ message: JSON) {
        process?.write(message.serialized() + "\n")
        NativeLog.append(threadId: threadId, dir: "out", source: "codex.app-server", msg: message)
    }

    /// A wedged app-server can accept stdin and never answer: every request times out.
    private func request(_ method: String, _ params: JSON, timeout: TimeInterval = 60) async throws -> JSON {
        if settled { throw RPCError(message: "turn settled") }
        let id = nextId
        nextId += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.pending.removeValue(forKey: id)?.resume(throwing: RPCError(message: "codex \(method) timed out after \(Int(timeout * 1000))ms"))
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    func stop() { process?.killTree() }

    private func settle(ok: Bool, stopReason: String?) {
        guard !settled else { return }
        settled = true
        for finish in Array(asks.values) { finish("deny", "SwarmeBot: the turn ended", "system") }
        for continuation in pending.values { continuation.resume(throwing: RPCError(message: "turn settled")) }
        pending.removeAll()
        instance.turnEnded(threadId)
        emit(.turnCompleted(ok: ok, stopReason: stopReason, cost: nil, denials: nil, usage: usage))
        stop() // the app-server never exits on its own
    }

    func answer(_ requestId: String, behavior: String, message: String?) -> Bool {
        guard let finish = asks[requestId] else { return false }
        finish(behavior, message, "user")
        return true
    }

    private func handle(line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let message = try? JSON.parse(line) else { return }
        NativeLog.append(threadId: threadId, dir: "in", source: "codex.app-server", msg: message)
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

    private func handleServerRequest(_ message: JSON) {
        let id = message["id"] ?? .null
        let method = message["method"]?.string ?? ""
        let params = message["params"] ?? .null
        let legacy = method == "execCommandApproval" || method == "applyPatchApproval"
        let isQuestion = method == "item/tool/requestUserInput"
        let tool = method == "item/fileChange/requestApproval" || method == "applyPatchApproval" ? "edit" : isQuestion ? "ask_user" : "shell"
        if instance.fullAuto, !isQuestion {
            send(["jsonrpc": "2.0", "id": id, "result": ["decision": legacy ? "approved" : "accept"]])
            return
        }
        let requestId = newId()
        let questions = params["questions"]?.array
        let summary: String
        if let command = params["command"]?.string { summary = String(command.prefix(200)) }
        else if let questions { summary = questions.compactMap { $0["question"]?.string ?? $0["header"]?.string }.filter { !$0.isEmpty }.joined(separator: " · ") }
        else if let reason = params["reason"]?.string { summary = reason }
        else { summary = tool }
        let choices: [String]? = isQuestion ? Array((questions?.first?["options"]?.array ?? []).compactMap { $0["label"]?.string }.prefix(5)) : nil
        var timer: Task<Void, Never>?
        let finish: (String, String?, String) -> Void = { [weak self] behavior, text, source in
            guard let self, self.asks.removeValue(forKey: requestId) != nil else { return }
            timer?.cancel()
            if isQuestion {
                var answers = JSONObject()
                for question in questions ?? [] {
                    let key = question["id"].flatMap(ACPTurn.text) ?? "undefined"
                    answers[key] = ["answers": [.string(text.flatMap { $0.isEmpty ? nil : $0 } ?? Self.questionTimeoutNote)]]
                }
                self.send(["jsonrpc": "2.0", "id": id, "result": ["answers": .object(answers)]])
            } else {
                let decision = behavior == "allow" ? (legacy ? "approved" : "accept") : (legacy ? "denied" : "decline")
                self.send(["jsonrpc": "2.0", "id": id, "result": ["decision": .string(decision)]])
            }
            self.emit(requestId: requestId, .requestResolved(behavior: behavior, source: source, approvalScope: nil))
        }
        timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if isQuestion { finish("answer", Self.questionTimeoutNote, "timeout") } else { finish("deny", acpDenyTimeoutNote, "timeout") }
        }
        asks[requestId] = finish
        emit(requestId: requestId, .requestOpened(requestType: isQuestion ? "question" : "permission", tool: tool, summary: summary,
                                                  choices: choices, multiSelect: nil, approvalScope: nil))
    }

    private func handleNotification(_ message: JSON) {
        let p = message["params"] ?? .null
        switch message["method"]?.string {
        case "item/agentMessage/delta":
            if let delta = p["delta"]?.string, !delta.isEmpty {
                sawStreamDelta = true
                emit(.contentDelta(streamKind: "assistant_text", delta: delta))
            }
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            if let delta = p["delta"]?.string, !delta.isEmpty { emit(.contentDelta(streamKind: "reasoning_text", delta: delta)) }
        case "item/started":
            let item = p["item"] ?? .null
            let title: String?
            switch item["type"]?.string {
            case "commandExecution": title = String((item["command"].flatMap(ACPTurn.text) ?? "shell").prefix(80))
            case "fileChange": title = "edit"
            case "mcpToolCall": title = item["tool"].flatMap(ACPTurn.text) ?? item["name"].flatMap(ACPTurn.text) ?? "mcp"
            case "webSearch": title = "web_search"
            default: title = nil
            }
            if let title {
                let input = item["type"]?.string == "mcpToolCall" ? ToolText.from(item["arguments"]) : nil
                emit(itemId: item["id"].flatMap(ACPTurn.text), input: input, .itemStarted(itemType: "tool", title: title))
            }
        case "item/completed":
            let item = p["item"] ?? .null
            switch item["type"]?.string {
            case "agentMessage":
                if let text = item["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !sawStreamDelta { emit(.contentDelta(streamKind: "assistant_text", delta: text)) }
                    sawStreamDelta = false
                    emit(.textCompleted(text: text))
                }
            case "commandExecution", "fileChange", "mcpToolCall":
                let status = item["status"]?.string
                let output = ToolText.from(item["aggregatedOutput"]) ?? ToolText.from(item["result"]) ?? ToolText.from(item["error"]?["message"])
                emit(itemId: item["id"].flatMap(ACPTurn.text), output: output, .toolCompleted(ok: status != "failed" && status != "declined"))
            case "reasoning":
                emit(.itemUpdated(itemType: "reasoning", tokens: .null))
            default:
                break
            }
        case "thread/tokenUsage/updated":
            let tokens = p["tokenUsage"]
            if let last = tokens?["last"] ?? tokens?["total"], last.truthy {
                usage = .init(input: last["inputTokens"]?.double ?? 0, output: last["outputTokens"]?.double ?? 0)
            }
            if let total = tokens?["total"], total.truthy {
                emit(.tokenUsage(input: total["inputTokens"]?.double ?? 0, output: total["outputTokens"]?.double ?? 0))
            }
        case "turn/completed":
            let t = p["turn"] ?? .null
            let completed = t["status"]?.string == "completed"
            settle(ok: completed, stopReason: completed ? nil : (t["error"]?["message"]?.string ?? t["status"]?.string ?? "failed"))
        case "error":
            // 0.144 sends {message}, 0.139 nests it under {error:{message}}
            if let text = (p["message"] ?? p["error"]?["message"]).flatMap(ACPTurn.text) {
                emit(.runtimeError(message: String(text.prefix(400)), setup: nil))
            }
        default:
            break
        }
    }

    func start() {
        var env = instance.childEnvironment()
        var args = ["app-server"] + CodexCatalog.localProviderArgs(&env, model: turn.model)
        if let agents = turn.agents { args += Self.mount(&env, name: "agents", agents) }
        if let computer = turn.computer { args += Self.mount(&env, name: "computer", computer) }
        for connector in turn.connectors { args += Self.mount(&env, name: connector.name, connector.server) }
        let cwd = turn.cwd ?? NSHomeDirectory()
        do {
            process = try CLIProcess(cli: instance.cli, args: args, cwd: cwd, environment: env)
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
            self.emit(.runtimeError(message: "codex exited \(code.map(String.init) ?? "null") before turn/completed" + (tail.isEmpty ? "" : ": \(String(tail.suffix(300)))"), setup: nil))
            self.settle(ok: false, stopReason: "exit_before_result")
        }
        emit(.turnStarted)
        process?.start()

        Task { @MainActor in
            do {
                try await self.run(cwd: cwd)
            } catch {
                guard !self.settled else { return }
                let message = (error as? RPCError)?.message ?? error.localizedDescription
                let needsAuth = message.range(of: #"(?i)(?:\b401\b|unauthorized|missing bearer|authentication required)"#, options: .regularExpression) != nil
                self.emit(.runtimeError(message: message, setup: needsAuth ? true : nil))
                self.settle(ok: false, stopReason: needsAuth ? "auth_required" : "rpc_error")
            }
        }
    }

    /// An MCP server through `-c`: values in the child env, only their
    /// NAMES on argv, so no credential ever shows in a process listing.
    static func mount(_ env: inout [String: String], name: String, _ server: MCPServer) -> [String] {
        for (key, value) in server.env { env[key] = value.string ?? value.serialized() }
        let prefix = "mcp_servers.\(name)"
        return [
            "-c", "\(prefix).command=\(JSON.string(server.command).serialized())",
            "-c", "\(prefix).args=\(JSON.strings(server.args).serialized())",
            "-c", "\(prefix).env_vars=\(JSON.strings(server.env.keys).serialized())",
            "-c", "\(prefix).default_tools_approval_mode=\"auto\"",
        ]
    }

    private func run(cwd: String) async throws {
        _ = try await request("initialize", ["clientInfo": ["name": "swarmebot", "version": "1"]])
        send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
        var codexThread: String?
        var startedModel: String?
        if let cursor = turn.resumeCursor?.string, !cursor.isEmpty {
            do {
                let resumed = try await request("thread/resume", ["threadId": .string(cursor)])
                codexThread = resumed["thread"]?["id"]?.string ?? cursor
            } catch {
                // resume unsupported or thread gone — start fresh
            }
        }
        if codexThread == nil {
            let selection = CodexCatalog.decode(turn.model)
            var params: JSONObject = ["cwd": .string(cwd), "model": JSON.from(selection.model)]
            if let provider = selection.provider { params["modelProvider"] = .string(provider) }
            params["sandbox"] = .string(instance.fullAuto ? "danger-full-access" : "workspace-write")
            params["approvalPolicy"] = .string(instance.fullAuto ? "never" : "on-request")
            params["ephemeral"] = false
            let started = try await request("thread/start", .object(params))
            codexThread = started["thread"]?["id"]?.string
            startedModel = started["model"]?.string
        }
        emit(.sessionStarted(sessionId: codexThread, model: startedModel ?? turn.model, resumeCursor: nil))
        var params: JSONObject = [
            "threadId": JSON.from(codexThread),
            "input": [["type": "text", "text": .string(turn.system.map { "\($0)\n\n\(turn.text)" } ?? turn.text)]],
        ]
        // absent, never null: null leaves the thread's effort alone just the same
        if let effort = turn.effort { params["effort"] = .string(effort) }
        _ = try await request("turn/start", .object(params))
    }
}
