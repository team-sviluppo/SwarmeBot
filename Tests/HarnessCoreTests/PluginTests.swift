@testable import HarnessCore
import XCTest

/// The engine's plugin system (Plugins.swift): routes, the switch, flags, turn hooks.
@MainActor
final class PluginTests: XCTestCase {
    /// A plugin that records what the engine tells it.
    @MainActor
    final class Probe: EnginePlugin {
        nonisolated let id: String
        nonisolated let name: String
        nonisolated let version = "1.2.0"
        nonisolated let requires: [String]
        nonisolated let botFlags = ["probeFlag"]
        nonisolated let groupFlags = ["probeGroupFlag"]
        var started = 0
        var results: [TurnResult] = []

        nonisolated init(id: String, requires: [String] = []) {
            self.id = id
            self.name = id.capitalized
            self.requires = requires
        }

        func routes(_ router: PluginRouter) {
            router.get("/api/threads/:tid/\(id)") { request in
                .response(.json(200, ["thread": .string(request.params["tid"] ?? ""), "plugin": .string(self.id)]))
            }
            router.post("/api/\(id)/echo") { request in
                .response(.json(200, .object(try request.http.json())))
            }
        }

        func beforeTurn(_ turn: inout TurnSetup) {
            turn.system = "Hello from \(id)."
            turn.environment["PROBE"] = id
        }

        func afterTurn(_ result: TurnResult) async { results.append(result) }
        func start(_ harness: Harness) async { started += 1 }
    }

    private func temporaryPaths() -> DataPaths {
        DataPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("swarme-plugins-\(UUID().uuidString)", isDirectory: true))
    }

    private func engine(_ plugins: [any EnginePlugin], paths: DataPaths? = nil) throws -> (Harness, Routes) {
        let harness = try Harness(paths: paths ?? temporaryPaths(), environment: ProcessInfo.processInfo.environment, drivers: [], plugins: plugins)
        return (harness, Routes(harness: harness))
    }

    private func call(_ routes: Routes, _ method: String, _ path: String, body: JSON? = nil, json: Bool = true) async -> (status: Int, body: JSON?) {
        let request = HTTPRequest(method: method, path: path, query: [:], headers: json ? ["content-type": "application/json"] : [:], body: body?.data ?? Data())
        guard case let .response(response) = await routes.handle(request) else { return (-1, nil) }
        return (response.status, try? JSON.parse(response.body))
    }

    func testAnEngineWithoutPluginsListsNone() async throws {
        let (_, routes) = try engine([])
        let answer = await call(routes, "GET", "/api/plugins")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.body?["plugins"]?.array?.count, 0)
    }

    func testPluginsAreListedWithTheirVersionAndState() async throws {
        let (_, routes) = try engine([Probe(id: "code"), Probe(id: "cylon", requires: ["code"])])
        let list = await call(routes, "GET", "/api/plugins").body?["plugins"]?.array ?? []
        XCTAssertEqual(list.compactMap { $0["id"]?.string }, ["code", "cylon"])
        XCTAssertEqual(list.first?["version"], "1.2.0")
        XCTAssertEqual(list.first?["enabled"], true)
        XCTAssertNil(list.first?["requires"])
        XCTAssertEqual(list.last?["requires"]?.array?.compactMap(\.string), ["code"])
    }

    func testTwoPluginsCannotShareAnId() throws {
        let (harness, _) = try engine([Probe(id: "code"), Probe(id: "code")])
        XCTAssertEqual(harness.plugins.plugins.count, 1)
    }

    func testAPluginRouteTakesItsParametersFromThePath() async throws {
        let (harness, routes) = try engine([Probe(id: "code")])
        let found = await call(routes, "GET", "/api/threads/t-123/code")
        XCTAssertEqual(found.status, 200)
        XCTAssertEqual(found.body?["thread"], "t-123")
        // what no plugin serves goes on to the core (which needs a booted engine to answer)
        func request(_ method: String, _ path: String) -> HTTPRequest { HTTPRequest(method: method, path: path, query: [:], headers: [:], body: Data()) }
        let unknown = try await harness.plugins.route(request("GET", "/api/threads/t-123/nothing"))
        XCTAssertNil(unknown)
        let wrongMethod = try await harness.plugins.route(request("DELETE", "/api/threads/t-123/code"))
        XCTAssertNil(wrongMethod)
        let shorter = try await harness.plugins.route(request("GET", "/api/threads/code"))
        XCTAssertNil(shorter)
    }

    func testAPluginMutationNeedsJSON() async throws {
        let (_, routes) = try engine([Probe(id: "code")])
        let form = await call(routes, "POST", "/api/code/echo", body: ["a": 1], json: false)
        XCTAssertEqual(form.status, 415)
        let accepted = await call(routes, "POST", "/api/code/echo", body: ["a": 1])
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(accepted.body?["a"], 1)
    }

    func testSwitchingAPluginOffSilencesItAndSurvivesARestart() async throws {
        let paths = temporaryPaths()
        let (harness, routes) = try engine([Probe(id: "code")], paths: paths)
        let off = await call(routes, "PUT", "/api/plugins/code", body: ["enabled": false])
        XCTAssertEqual(off.status, 200)
        XCTAssertEqual(off.body?["plugins"]?.array?.first?["enabled"], false)
        let get = HTTPRequest(method: "GET", path: "/api/threads/t-1/code", query: [:], headers: [:], body: Data())
        let silent = try await harness.plugins.route(get)
        XCTAssertNil(silent)
        XCTAssertTrue(harness.plugins.botFlags.isEmpty)

        let (restartedHarness, restarted) = try engine([Probe(id: "code")], paths: paths)
        let still = try await restartedHarness.plugins.route(get)
        XCTAssertNil(still, "the choice is on disk")
        _ = await call(restarted, "PUT", "/api/plugins/code", body: ["enabled": true])
        let back = await call(restarted, "GET", "/api/threads/t-1/code")
        XCTAssertEqual(back.status, 200)
    }

    func testAPluginNeedsTheOnesItRequires() async throws {
        let (harness, routes) = try engine([Probe(id: "code"), Probe(id: "cylon", requires: ["code"]), Probe(id: "lonely", requires: ["missing"])])
        XCTAssertTrue(harness.plugins.isEnabled("cylon"))
        XCTAssertFalse(harness.plugins.isEnabled("lonely"), "a plugin it needs is not linked in")
        _ = await call(routes, "PUT", "/api/plugins/code", body: ["enabled": false])
        XCTAssertFalse(harness.plugins.isEnabled("cylon"), "code is off, so cylon is too")
        let state = await call(routes, "GET", "/api/plugins").body?["plugins"]?.array?.map { $0["enabled"]?.bool }
        XCTAssertEqual(state, [false, false, false])
    }

    func testSwitchingAnUnknownPluginIsRefused() async throws {
        let (_, routes) = try engine([Probe(id: "code")])
        let missing = await call(routes, "PUT", "/api/plugins/nope", body: ["enabled": false])
        XCTAssertEqual(missing.status, 404)
        let bad = await call(routes, "PUT", "/api/plugins/code", body: ["enabled": "no"])
        XCTAssertEqual(bad.status, 400)
        let form = await call(routes, "PUT", "/api/plugins/code", body: ["enabled": false], json: false)
        XCTAssertEqual(form.status, 415)
    }

    func testAPluginAddsFlagsToBotsAndChannels() async throws {
        let (harness, routes) = try engine([Probe(id: "code")])
        let bot = harness.store.createBot(seedMessages: false)
        let botId = bot["id"]!.string!
        let set = await call(routes, "PATCH", "/api/bots/\(botId)", body: ["probeFlag": true])
        XCTAssertEqual(set.status, 200)
        XCTAssertEqual(harness.store.bot(botId)?["probeFlag"], true)
        let bad = await call(routes, "PATCH", "/api/bots/\(botId)", body: ["probeFlag": "yes"])
        XCTAssertEqual(bad.status, 400)

        let groupId = harness.store.createGroup(name: "Room", memberIds: [botId])["id"]?.string ?? ""
        let room = await call(routes, "PATCH", "/api/groups/\(groupId)", body: ["probeGroupFlag": true])
        XCTAssertEqual(room.status, 200)
        XCTAssertEqual(harness.store.group(groupId)?["probeGroupFlag"], true)
    }

    func testTheTurnHooksReachTheDriverInput() throws {
        let probe = Probe(id: "code")
        let (harness, _) = try engine([probe])
        var setup = TurnSetup(botId: "b", threadId: "t", groupId: nil, driverKind: "claude", bot: JSONObject(), group: nil, cwd: "/tmp")
        harness.plugins.beforeTurn(&setup)
        var input = SendTurnInput(threadId: "t", text: "hi", system: "You are Bot.")
        input.secretEnvironment = ["PROBE": "vault"]
        setup.apply(to: &input)
        XCTAssertEqual(input.system, "You are Bot.\n\nHello from code.")
        XCTAssertEqual(input.pluginEnvironment, ["PROBE": "code"])
        XCTAssertEqual(input.turnEnvironment["PROBE"], "vault", "a vault secret beats a plugin's value")

        var bare = SendTurnInput(threadId: "t", text: "hi")
        TurnSetup(botId: "b", threadId: "t", groupId: nil, driverKind: "claude", bot: JSONObject(), group: nil, cwd: nil).apply(to: &bare)
        XCTAssertNil(bare.system, "no plugin text leaves the system prompt as it was")
    }

    func testAnOffPluginHearsNothing() async throws {
        let probe = Probe(id: "code")
        let (harness, _) = try engine([probe])
        try harness.plugins.setEnabled("code", false)
        var setup = TurnSetup(botId: "b", threadId: "t", groupId: nil, driverKind: "claude", bot: JSONObject(), group: nil, cwd: nil)
        harness.plugins.beforeTurn(&setup)
        XCTAssertEqual(setup.system, "")
        harness.plugins.afterTurn(TurnResult(threadId: "t", botId: "b", groupId: nil, ok: true, cost: nil))
        await harness.plugins.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(probe.results.isEmpty)
        XCTAssertEqual(probe.started, 0)
    }

    func testAnActivePluginHearsTurnsEndAndStarts() async throws {
        let probe = Probe(id: "code")
        let (harness, _) = try engine([probe])
        await harness.plugins.start()
        XCTAssertEqual(probe.started, 1)
        harness.plugins.afterTurn(TurnResult(threadId: "t", botId: "b", groupId: nil, ok: true, cost: 0.5))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(probe.results.map(\.threadId), ["t"])
    }

    func testSubcommandsComeFromThePlugins() {
        final class WithCommand: EnginePlugin {
            nonisolated var id: String { "x" }
            nonisolated var name: String { "X" }
            nonisolated var version: String { "1" }
            nonisolated var subcommands: [PluginSubcommand] { [PluginSubcommand(name: "mcp-x") { _, _, _ in exit(0) }] }
        }
        let plugins: [any EnginePlugin] = [WithCommand()]
        XCTAssertNotNil(PluginRegistry.subcommand("mcp-x", in: plugins))
        XCTAssertNil(PluginRegistry.subcommand("mcp-y", in: plugins))
    }
}
