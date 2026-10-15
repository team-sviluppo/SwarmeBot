// The harness contracts, from `server/contracts.ts`.
//
// Same names and the same wire shapes, so the two engines stay readable side
// by side and a runtime event serialized here is byte-for-byte the frame the
// Node engine would broadcast. Promises became `async`, listener callbacks
// stayed callbacks.
//
// Concurrency model: the harness core runs on the main actor, the way the
// Node engine runs on its one event loop. Drivers do their I/O wherever they
// like and hand events back through `emit`, which hops to the main actor.
import Foundation

public typealias ThreadID = String
public typealias InstanceID = String

public let effortLevels = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

public func isEffortLevel(_ value: String?) -> Bool {
    value.map { effortLevels.contains($0) } ?? false
}

// MARK: - Model selection and catalog

public struct ModelSelection: Equatable, Sendable {
    public var instanceId: InstanceID
    public var model: String
    public var effort: String?

    public init(instanceId: InstanceID, model: String, effort: String? = nil) {
        self.instanceId = instanceId
        self.model = model
        self.effort = effort
    }

    public init(json: JSON?) {
        instanceId = json?["instanceId"]?.string ?? ""
        model = json?["model"]?.string ?? ""
        effort = json?["effort"]?.string
    }

    public var json: JSON {
        var object = JSONObject([("instanceId", .string(instanceId)), ("model", .string(model))])
        if let effort { object["effort"] = .string(effort) }
        return .object(object)
    }
}

public struct ModelOption: Equatable, Sendable {
    public var id: String
    public var label: String
    public var custom: Bool?
    public var loaded: Bool?
    public var contextWindow: Int?
    public var effortLevels: [String]?

    public init(id: String, label: String, custom: Bool? = nil, loaded: Bool? = nil, contextWindow: Int? = nil, effortLevels: [String]? = nil) {
        self.id = id
        self.label = label
        self.custom = custom
        self.loaded = loaded
        self.contextWindow = contextWindow
        self.effortLevels = effortLevels
    }

    public var json: JSON {
        var object = JSONObject([("id", .string(id)), ("label", .string(label))])
        if let custom { object["custom"] = .bool(custom) }
        if let loaded { object["loaded"] = .bool(loaded) }
        if let contextWindow { object["contextWindow"] = .number(Double(contextWindow)) }
        if let effortLevels { object["effortLevels"] = .strings(effortLevels) }
        return .object(object)
    }
}

public struct ModelCatalog: Equatable, Sendable {
    public var `default`: String
    public var options: [ModelOption]

    public static let empty = ModelCatalog(default: "", options: [])

    public init(default: String, options: [ModelOption]) {
        self.default = `default`
        self.options = options
    }

    public var json: JSON {
        ["default": .string(self.default), "options": .array(options.map(\.json))]
    }
}

/// `effortLevelsForModel` from src/lib/model-effort.ts: the model's own
/// list wins, else the driver's; nil means no effort control at all.
public func effortLevelsForModel(_ options: [ModelOption], model: String, driverLevels: [String]?) -> [String]? {
    options.first { $0.id == model }?.effortLevels ?? driverLevels
}

// MARK: - Runtime events

public struct RuntimeEvent: Sendable {
    public enum Body: Sendable, Equatable {
        case sessionStarted(sessionId: String?, model: String?, resumeCursor: String?)
        case sessionExited(reason: String?)
        case turnStarted
        case turnCompleted(ok: Bool, stopReason: String?, cost: Double?, denials: [String]?, usage: TokenUsage?)
        case itemStarted(itemType: String, title: String?)
        /// tokens: nil = key absent, .null = an explicit null (codex sends one)
        case itemUpdated(itemType: String, tokens: JSON?)
        case toolCompleted(ok: Bool)
        case textCompleted(text: String)
        case contentDelta(streamKind: String, delta: String)
        case requestOpened(requestType: String, tool: String, summary: String, choices: [String]?, multiSelect: Bool?, approvalScope: String?)
        case requestResolved(behavior: String, source: String, approvalScope: String?)
        case tokenUsage(input: Double, output: Double)
        case runtimeError(message: String, setup: Bool?)
    }

    public struct TokenUsage: Sendable, Equatable {
        public var input: Double
        public var output: Double
        public init(input: Double, output: Double) {
            self.input = input
            self.output = output
        }
    }

    public var eventId: String
    public var provider: String
    public var providerInstanceId: InstanceID?
    public var threadId: ThreadID
    public var createdAt: String
    public var turnId: String?
    public var itemId: String?
    public var requestId: String?
    public var raw: JSON?
    public var body: Body
    /// turn.completed without a `cost` key at all (pi); everyone else sends null.
    public var costAbsent = false

    public init(
        provider: String, providerInstanceId: InstanceID? = nil, threadId: ThreadID, turnId: String? = nil,
        itemId: String? = nil, requestId: String? = nil, raw: JSON? = nil, _ body: Body
    ) {
        eventId = newEventId()
        self.provider = provider
        self.providerInstanceId = providerInstanceId
        self.threadId = threadId
        createdAt = isoNow()
        self.turnId = turnId
        self.itemId = itemId
        self.requestId = requestId
        self.raw = raw
        self.body = body
    }

    public var type: String {
        switch body {
        case .sessionStarted: return "session.started"
        case .sessionExited: return "session.exited"
        case .turnStarted: return "turn.started"
        case .turnCompleted: return "turn.completed"
        case .itemStarted: return "item.started"
        case .itemUpdated: return "item.updated"
        case .toolCompleted, .textCompleted: return "item.completed"
        case .contentDelta: return "content.delta"
        case .requestOpened: return "request.opened"
        case .requestResolved: return "request.resolved"
        case .tokenUsage: return "thread.token-usage.updated"
        case .runtimeError: return "runtime.error"
        }
    }

    /// The wire shape, field for field what the Node engine emits.
    public var json: JSON {
        var o = JSONObject()
        o["eventId"] = .string(eventId)
        o["provider"] = .string(provider)
        if let providerInstanceId { o["providerInstanceId"] = .string(providerInstanceId) }
        o["threadId"] = .string(threadId)
        o["createdAt"] = .string(createdAt)
        if let turnId { o["turnId"] = .string(turnId) }
        if let itemId { o["itemId"] = .string(itemId) }
        if let requestId { o["requestId"] = .string(requestId) }
        if let raw { o["raw"] = raw }
        o["type"] = .string(type)
        switch body {
        case let .sessionStarted(sessionId, model, resumeCursor):
            o["sessionId"] = .from(sessionId)
            if let model { o["model"] = .string(model) }
            if let resumeCursor { o["resumeCursor"] = .string(resumeCursor) }
        case let .sessionExited(reason):
            if let reason { o["reason"] = .string(reason) }
        case .turnStarted:
            break
        case let .turnCompleted(ok, stopReason, cost, denials, usage):
            o["ok"] = .bool(ok)
            o["stopReason"] = .from(stopReason)
            if !costAbsent { o["cost"] = .from(cost) }
            if let denials { o["denials"] = .strings(denials) }
            if let usage { o["usage"] = ["input": .number(usage.input), "output": .number(usage.output)] }
        case let .itemStarted(itemType, title):
            o["itemType"] = .string(itemType)
            if let title { o["title"] = .string(title) }
        case let .itemUpdated(itemType, tokens):
            o["itemType"] = .string(itemType)
            if let tokens { o["tokens"] = tokens }
        case let .toolCompleted(ok):
            o["itemType"] = "tool"
            o["ok"] = .bool(ok)
        case let .textCompleted(text):
            o["itemType"] = "assistant_text"
            o["text"] = .string(text)
        case let .contentDelta(streamKind, delta):
            o["streamKind"] = .string(streamKind)
            o["delta"] = .string(delta)
        case let .requestOpened(requestType, tool, summary, choices, multiSelect, approvalScope):
            o["requestType"] = .string(requestType)
            o["tool"] = .string(tool)
            o["summary"] = .string(summary)
            if let choices { o["choices"] = .strings(choices) }
            if let multiSelect { o["multiSelect"] = .bool(multiSelect) }
            if let approvalScope { o["approvalScope"] = .string(approvalScope) }
        case let .requestResolved(behavior, source, approvalScope):
            o["behavior"] = .string(behavior)
            o["source"] = .string(source)
            if let approvalScope { o["approvalScope"] = .string(approvalScope) }
        case let .tokenUsage(input, output):
            o["input"] = .number(input)
            o["output"] = .number(output)
        case let .runtimeError(message, setup):
            o["message"] = .string(message)
            if let setup { o["setup"] = .bool(setup) }
        }
        return .object(o)
    }
}

public typealias RuntimeEventListener = @MainActor (RuntimeEvent) -> Void

// MARK: - Turns and requests

/// A stdio MCP server the harness hands a CLI to mount (the `agents`
/// comms tools; the computer tools later). Secrets ride in `env`, never argv.
public struct MCPServer: Sendable, Equatable {
    public var command: String
    public var args: [String]
    /// Ordered: ACP passes it on as a `{name,value}` list, in this order.
    public var env: JSONObject

    public init(command: String, args: [String], env: JSONObject) {
        self.command = command
        self.args = args
        self.env = env
    }

    /// The `{command,args,env}` object Claude's --mcp-config takes.
    public var json: JSON { ["command": .string(command), "args": .strings(args), "env": .object(env)] }

    /// ACP's session `mcpServers` entry.
    public func acp(name: String) -> JSON {
        ["name": .string(name), "command": .string(command), "args": .strings(args),
         "env": .array(env.map { ["name": .string($0.key), "value": .string($0.value.string ?? $0.value.serialized())] })]
    }
}

/// A connector as one turn mounts it: the proxy that stands in for the
/// server (`swarme-harness mcp-connector <id>`) and the name the CLI shows
/// its tools under (`mcp__<name>__tool`).
public struct MountedConnector: Sendable, Equatable {
    public var name: String
    public var server: MCPServer

    public init(name: String, server: MCPServer) {
        self.name = name
        self.server = server
    }
}

/// How an engine takes connectors: not at all, as MCP servers it spawns
/// itself, or through the engine's own tool loop (Local Endpoint, phase 3).
public enum ConnectorMount: String, Sendable {
    case none, mcp, inline
}

public struct SendTurnInput: Sendable {
    public var threadId: ThreadID
    public var sessionKey: String?
    public var text: String
    public var model: String?
    public var effort: String?
    public var resumeCursor: JSON?
    public var transcript: [(role: String, text: String)]
    public var system: String?
    public var cwd: String?
    /// Peer comms (list_bots / ask_bot / delegate_bot), only for drivers whose
    /// capabilities say `agentsMcp`.
    public var agents: MCPServer?
    /// The bot's cloud box, for the engine that runs ON it (boxAgent).
    public var cloudBoxId: String?
    /// MCP server named `computer`: the box REST proxy, or Cua Driver in a VM.
    public var computer: MCPServer?
    /// `local-computer` routes every tool through the approval broker.
    public var computerScope: String?
    /// The bot's connectors for this turn, only for engines whose
    /// capabilities say `connectors == .mcp`. Empty changes nothing.
    public var connectors: [MountedConnector] = []

    public init(threadId: ThreadID, text: String, model: String? = nil, effort: String? = nil, resumeCursor: JSON? = nil,
                transcript: [(role: String, text: String)] = [], system: String? = nil, cwd: String? = nil,
                sessionKey: String? = nil, agents: MCPServer? = nil) {
        self.sessionKey = sessionKey
        self.agents = agents
        self.threadId = threadId
        self.text = text
        self.model = model
        self.effort = effort
        self.resumeCursor = resumeCursor
        self.transcript = transcript
        self.system = system
        self.cwd = cwd
    }
}

public struct RequestDecision: Sendable {
    /// allow · deny · answer
    public var behavior: String
    public var message: String?
    public var selected: [String]?
    public var custom: String?

    public init(behavior: String, message: String? = nil, selected: [String]? = nil, custom: String? = nil) {
        self.behavior = behavior
        self.message = message
        self.selected = selected
        self.custom = custom
    }
}

public enum RequestOutcome: String, Sendable {
    case allowedOnce = "allowed-once"
    case rejected
    case answered
    case alreadyResolved = "already-resolved"
    case retryable
    case unavailable
}

public struct AdapterCapabilities: Sendable {
    public var sessionModelSwitch = "in-session"
    public var agentsMcp = false
    public var computerMcp = false
    public var composioMcp = false
    public var phoneMcp = false
    public var images = false
    public var effortLevels: [String]?
    public var queueing = false
    public var localComputerMcp = false
    public var connectors = ConnectorMount.none

    public init() {}

    /// The subset `GET /api/instances` publishes.
    public var json: JSON {
        var o = JSONObject()
        o["computerMcp"] = .bool(computerMcp)
        o["agentsMcp"] = .bool(agentsMcp)
        o["composioMcp"] = .bool(composioMcp)
        o["phoneMcp"] = .bool(phoneMcp)
        o["images"] = .bool(images)
        if let effortLevels { o["effortLevels"] = .strings(effortLevels) }
        o["localComputerMcp"] = .bool(localComputerMcp)
        o["connectors"] = .string(connectors.rawValue)
        return .object(o)
    }
}

/// The conversation runtime every provider is flattened into.
@MainActor
public protocol ProviderAdapter: AnyObject {
    var provider: String { get }
    var capabilities: AdapterCapabilities { get }
    /// Starts the turn and returns its id; events follow on `onEvent`.
    func sendTurn(_ input: SendTurnInput) async throws -> String
    func interruptTurn(threadId: ThreadID) async
    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome
    func hasSession(threadId: ThreadID) -> Bool
    func stopAll() async
    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void
}

/// Listener bookkeeping every adapter needs, so drivers don't each re-grow it.
@MainActor
public final class EventEmitter {
    private var listeners: [UUID: RuntimeEventListener] = [:]

    public init() {}

    public func add(_ listener: @escaping RuntimeEventListener) -> () -> Void {
        let id = UUID()
        listeners[id] = listener
        return { [weak self] in
            MainActor.assumeIsolated { _ = self?.listeners.removeValue(forKey: id) }
        }
    }

    public func emit(_ event: RuntimeEvent) {
        for listener in listeners.values { listener(event) }
    }

    public func removeAll() { listeners.removeAll() }
}

// MARK: - Instances and drivers

public struct ProviderSnapshot: Sendable {
    /// available · unavailable
    public var state: String
    public var reason: String?
    public var authenticated: Bool?
    public var version: String?
    public var billing: String?

    public init(state: String, reason: String?, authenticated: Bool?, version: String?, billing: String?, versionFirst: Bool = false) {
        self.state = state
        self.reason = reason
        self.authenticated = authenticated
        self.version = version
        self.billing = billing
        self.versionFirst = versionFirst
    }

    public static func available(version: String? = nil, authenticated: Bool? = true) -> ProviderSnapshot {
        ProviderSnapshot(state: "available", reason: nil, authenticated: authenticated, version: version, billing: nil)
    }

    public static func unavailable(_ reason: String) -> ProviderSnapshot {
        ProviderSnapshot(state: "unavailable", reason: reason, authenticated: nil, version: nil, billing: nil)
    }

    /// CLI drivers report `version` before `authenticated`, API drivers the
    /// other way round: the key order the Node engine writes, per driver.
    public var versionFirst = false

    public var json: JSON {
        var o = JSONObject([("state", .string(state))])
        if let reason { o["reason"] = .string(reason) }
        if versionFirst, state == "available" { o["version"] = .from(version) }
        if let authenticated { o["authenticated"] = .bool(authenticated) }
        if !versionFirst, state == "available" { o["version"] = .from(version) }
        if let billing { o["billing"] = .string(billing) }
        return .object(o)
    }
}

public struct EngineInstall: Sendable {
    public var darwinCommand: String?
    public var docsUrl: String?
    public var signInCommand: String?
    public var needsNode: Bool?

    public init(darwinCommand: String? = nil, docsUrl: String? = nil, signInCommand: String? = nil, needsNode: Bool? = nil) {
        self.darwinCommand = darwinCommand
        self.docsUrl = docsUrl
        self.signInCommand = signInCommand
        self.needsNode = needsNode
    }

    public var json: JSON {
        var o = JSONObject()
        if let darwinCommand { o["command"] = ["darwin": .string(darwinCommand)] }
        if let docsUrl { o["docsUrl"] = .string(docsUrl) }
        if let signInCommand { o["signInCommand"] = .string(signInCommand) }
        if let needsNode { o["needsNode"] = .bool(needsNode) }
        return .object(o)
    }
}

@MainActor
public protocol ProviderInstance: AnyObject {
    var instanceId: InstanceID { get }
    var driverKind: String { get }
    var displayName: String? { get }
    var enabled: Bool { get }
    var models: ModelCatalog { get }
    var adapter: ProviderAdapter { get }
    func refreshModels() async
    func snapshot() async -> ProviderSnapshot
    func dispose() async
}

public struct DriverCreateInput: Sendable {
    public var instanceId: InstanceID
    public var displayName: String?
    /// Process env merged with the instance's injected environment.
    public var environment: [String: String]
    public var enabled: Bool
    public var config: JSON

    public init(instanceId: InstanceID, displayName: String?, environment: [String: String], enabled: Bool, config: JSON) {
        self.instanceId = instanceId
        self.displayName = displayName
        self.environment = environment
        self.enabled = enabled
        self.config = config
    }
}

@MainActor
public protocol ProviderDriver {
    var driverKind: String { get }
    var displayName: String { get }
    /// subscription · custom
    var access: String { get }
    var install: EngineInstall? { get }
    /// The default binary name, for CLI drivers.
    var cliDefault: String? { get }
    func create(_ input: DriverCreateInput) async throws -> ProviderInstance
}

extension ProviderDriver {
    public var install: EngineInstall? { nil }
    public var cliDefault: String? { nil }
}

// MARK: - Ids and time

private let counterLock = NSLock()
nonisolated(unsafe) private var eventCounter = 0

public func newEventId() -> String {
    counterLock.lock()
    defer { counterLock.unlock() }
    eventCounter += 1
    let millis = Int(Date().timeIntervalSince1970 * 1000)
    return "ev-\(String(millis, radix: 36))-\(String(eventCounter, radix: 36))"
}

public func newId() -> String { UUID().uuidString.lowercased() }

public func nowMillis() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

public func isoNow() -> String { isoFormatter.string(from: Date()) }
