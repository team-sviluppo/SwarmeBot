// Engine plugins (docs/plans/2026-10-28-code-mode-t3.md §12).
//
// A plugin is a Swift module linked into the executable at build time: no
// discovery, no dlopen. The core offers the hooks below and never imports a
// plugin; the executable hands the list in (`HarnessMain.run(plugins:)`). An
// engine built with an empty list is the core alone.
//
// What a plugin can do: register routes, add text and environment to a turn
// before it starts, hear when a turn ends, start background work, accept extra
// boolean flags on bots and channels, and answer `swarme-harness <subcommand>`.
// Switching one off (`PUT /api/plugins/:id`) silences all of that without
// removing the data it wrote: `JSON` keeps the fields it does not know.
import Foundation

/// A command line a plugin answers, like the MCP helpers (`swarme-harness mcp-*`).
public struct PluginSubcommand: Sendable {
    public var name: String
    public var run: @Sendable (_ arguments: [String], _ paths: DataPaths, _ environment: [String: String]) -> Never

    public init(name: String, run: @escaping @Sendable (_ arguments: [String], _ paths: DataPaths, _ environment: [String: String]) -> Never) {
        self.name = name
        self.run = run
    }
}

/// What a plugin may change about a turn that is about to start.
public struct TurnSetup {
    public let botId: String
    public let threadId: String
    /// Set for a turn spoken in a channel.
    public let groupId: String?
    public let driverKind: String
    public let bot: JSONObject
    public let group: JSONObject?
    /// The folder the turn runs in; nil for engines with no local filesystem.
    public let cwd: String?
    /// Appended to the system prompt, after the persona and the library.
    public var system = ""
    /// Added to the CLI's environment for this turn.
    public var environment: [String: String] = [:]

    public init(botId: String, threadId: String, groupId: String?, driverKind: String, bot: JSONObject, group: JSONObject?, cwd: String?) {
        self.botId = botId
        self.threadId = threadId
        self.groupId = groupId
        self.driverKind = driverKind
        self.bot = bot
        self.group = group
        self.cwd = cwd
    }

    /// What the plugins decided, onto the input the driver will get.
    public func apply(to input: inout SendTurnInput) {
        if !system.isEmpty { input.system = [input.system, system].compactMap { $0 }.joined(separator: "\n\n") }
        input.pluginEnvironment = environment
    }
}

public struct TurnResult: Sendable {
    public let threadId: String
    /// The bot that ran the turn; in a channel, the member that spoke.
    public let botId: String?
    public let groupId: String?
    public let ok: Bool
    public let cost: Double?
}

@MainActor
public protocol EnginePlugin: AnyObject {
    /// Stable and lowercase: it is the key of the plugin's data and of `/api/plugins`.
    nonisolated var id: String { get }
    nonisolated var name: String { get }
    nonisolated var version: String { get }
    /// Ids of the plugins this one needs; an engine without them leaves it off.
    nonisolated var requires: [String] { get }
    /// Boolean flags `PATCH /api/bots/:id` and `PATCH /api/groups/:id` accept on top of the core's.
    nonisolated var botFlags: [String] { get }
    nonisolated var groupFlags: [String] { get }
    nonisolated var subcommands: [PluginSubcommand] { get }

    func routes(_ router: PluginRouter)
    func beforeTurn(_ turn: inout TurnSetup)
    func afterTurn(_ result: TurnResult) async
    /// Once, after the fleet is loaded: background work starts here.
    func start(_ harness: Harness) async
}

public extension EnginePlugin {
    nonisolated var requires: [String] { [] }
    nonisolated var botFlags: [String] { [] }
    nonisolated var groupFlags: [String] { [] }
    nonisolated var subcommands: [PluginSubcommand] { [] }
    func routes(_ router: PluginRouter) {}
    func beforeTurn(_ turn: inout TurnSetup) {}
    func afterTurn(_ result: TurnResult) async {}
    func start(_ harness: Harness) async {}
}

/// Routes of the plugins. Paths use `:name` segments (`/api/threads/:tid/git/diff`);
/// a plugin cannot take `/api/internal/` (the proxies' door) or a path the core serves.
@MainActor
public final class PluginRouter {
    public struct Request {
        public let http: HTTPRequest
        public let params: [String: String]
        public unowned let harness: Harness
    }

    public typealias Handler = @MainActor (Request) async throws -> RouteResult

    struct Entry {
        var pluginId: String
        var method: String
        var segments: [String]
        var handler: Handler
    }

    private(set) var entries: [Entry] = []
    private var currentPlugin = ""

    func register(for pluginId: String, _ body: () -> Void) {
        currentPlugin = pluginId
        body()
        currentPlugin = ""
    }

    public func get(_ path: String, _ handler: @escaping Handler) { add("GET", path, handler) }
    public func post(_ path: String, _ handler: @escaping Handler) { add("POST", path, handler) }
    public func put(_ path: String, _ handler: @escaping Handler) { add("PUT", path, handler) }
    public func patch(_ path: String, _ handler: @escaping Handler) { add("PATCH", path, handler) }
    public func delete(_ path: String, _ handler: @escaping Handler) { add("DELETE", path, handler) }

    private func add(_ method: String, _ path: String, _ handler: @escaping Handler) {
        precondition(path.hasPrefix("/api/") && !path.hasPrefix("/api/internal/"), "plugin route \(path) must be under /api/ and not /api/internal/")
        entries.append(Entry(pluginId: currentPlugin, method: method, segments: path.split(separator: "/", omittingEmptySubsequences: true).map(String.init), handler: handler))
    }

    /// The first entry of an enabled plugin that matches, with its `:name` captures.
    func match(_ request: HTTPRequest, enabled: (String) -> Bool) -> (Entry, [String: String])? {
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for entry in entries where entry.method == request.method && entry.segments.count == parts.count && enabled(entry.pluginId) {
            var params: [String: String] = [:]
            var matched = true
            for (pattern, part) in zip(entry.segments, parts) {
                if pattern.hasPrefix(":") {
                    guard !part.isEmpty else { matched = false; break }
                    params[String(pattern.dropFirst())] = part.removingPercentEncoding ?? part
                } else if pattern != part {
                    matched = false
                    break
                }
            }
            if matched { return (entry, params) }
        }
        return nil
    }
}

/// The plugins linked into this engine, which are on, and what they hook.
@MainActor
public final class PluginRegistry {
    public let plugins: [any EnginePlugin]
    let router = PluginRouter()
    private unowned let harness: Harness
    private let file: URL
    private var disabled: Set<String>

    init(harness: Harness, plugins: [any EnginePlugin]) {
        self.harness = harness
        var seen: Set<String> = []
        // the first one with an id wins: two plugins cannot share their data
        self.plugins = plugins.filter { seen.insert($0.id).inserted }
        file = harness.paths.plugins
        if let data = try? Data(contentsOf: file), let json = try? JSON.parse(data) {
            disabled = Set(json["disabled"]?.array?.compactMap(\.string) ?? [])
        } else {
            disabled = []
        }
        for plugin in self.plugins { router.register(for: plugin.id) { plugin.routes(router) } }
    }

    public func plugin(_ id: String) -> (any EnginePlugin)? { plugins.first { $0.id == id } }

    /// Off by the user, or because a plugin it needs is off or not linked in.
    public func isEnabled(_ id: String) -> Bool {
        guard let plugin = plugin(id), !disabled.contains(id) else { return false }
        return plugin.requires.allSatisfy { isEnabled($0) }
    }

    public var active: [any EnginePlugin] { plugins.filter { isEnabled($0.id) } }

    public func setEnabled(_ id: String, _ on: Bool) throws {
        guard plugin(id) != nil else { throw HTTPError(404, "no such plugin") }
        if on { disabled.remove(id) } else { disabled.insert(id) }
        let json: JSON = ["disabled": .strings(disabled.sorted())]
        try FileIO.writeAtomic(json.data, to: file)
    }

    /// `GET /api/plugins`.
    var wire: JSON {
        .array(plugins.map { plugin in
            var entry: JSONObject = ["id": .string(plugin.id), "name": .string(plugin.name), "version": .string(plugin.version),
                                     "enabled": .bool(isEnabled(plugin.id))]
            if !plugin.requires.isEmpty { entry["requires"] = .strings(plugin.requires) }
            return .object(entry)
        })
    }

    var botFlags: [String] { active.flatMap(\.botFlags) }
    var groupFlags: [String] { active.flatMap(\.groupFlags) }

    func route(_ request: HTTPRequest) async throws -> RouteResult? {
        guard let (entry, params) = router.match(request, enabled: { isEnabled($0) }) else { return nil }
        // the same gate as the core's mutations: a form cannot post to a plugin
        if ["POST", "PUT", "PATCH"].contains(request.method), !request.isJSON {
            return .response(.error(415, "content-type must be application/json"))
        }
        return try await entry.handler(PluginRouter.Request(http: request, params: params, harness: harness))
    }

    func beforeTurn(_ setup: inout TurnSetup) {
        for plugin in active { plugin.beforeTurn(&setup) }
    }

    func afterTurn(_ result: TurnResult) {
        let listening = active
        guard !listening.isEmpty else { return }
        Task { @MainActor in
            for plugin in listening { await plugin.afterTurn(result) }
        }
    }

    func start() async {
        for plugin in active { await plugin.start(harness) }
    }

    /// `swarme-harness <name> …`, before the engine touches anything.
    nonisolated public static func subcommand(_ name: String, in plugins: [any EnginePlugin]) -> PluginSubcommand? {
        for plugin in plugins { if let found = plugin.subcommands.first(where: { $0.name == name }) { return found } }
        return nil
    }
}
