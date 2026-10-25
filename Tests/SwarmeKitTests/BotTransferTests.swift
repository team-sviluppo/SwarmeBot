@testable import CompanionCore
@testable import SwarmeKit
import XCTest

/// "Sposta su…": what goes over, and a real move between two throwaway engines.
final class BotTransferTests: XCTestCase {
    func testAOneOffThatHasPassedGoesOverSwitchedOff() {
        let now = Date()
        func routine(_ schedule: RoutineSchedule) -> Routine {
            Routine(id: "r", name: "R", prompt: "p", botId: "old", runOn: "cloud", enabled: true, schedule: schedule)
        }
        let past = BotTransfer.routineInput(routine(.once(now.addingTimeInterval(-60))), botId: "new", now: now)
        XCTAssertFalse(past.enabled)
        XCTAssertEqual(past.botId, "new")
        XCTAssertEqual(past.json["runOn"] as? String, "cloud")
        XCTAssertTrue(BotTransfer.routineInput(routine(.once(now.addingTimeInterval(600))), botId: "new", now: now).enabled)
        XCTAssertTrue(BotTransfer.routineInput(routine(.daily("09:00", weekdays: [1])), botId: "new", now: now).enabled)
    }

    func testTheIdentityLeavesTheEnvironmentBehind() {
        let body = BotTransfer.identity(of: bot()).bodyForTesting
        XCTAssertEqual(Set(body.keys), ["name", "title", "description", "notifications", "color", "mascotExpression"])
    }

    func bot() -> Bot {
        try! JSONDecoder().decode(Bot.self, from: Data(#"""
        {"id":"b","threadId":"t","name":"Ada","title":"Analista","description":"Rispondi in breve.","notifications":false,
         "color":"#ff0000","unread":false,"modelSelection":{"instanceId":"claude","model":"opus"},"createdAt":1,
         "mascotExpression":"happy","cwd":"/Users/x","autoApprove":true,"alwaysAllow":["Bash"]}
        """#.utf8))
    }

    // MARK: Two engines

    func testABotMovesWithItsAutomations() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("swarme-harness")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("swarme-harness not built") }
        let root = URL(fileURLWithPath: "/tmp/sbt-\(UUID().uuidString.prefix(4))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await Engine.start(binary, data: root.appendingPathComponent("a"))
        defer { source.stop() }
        let target = try await Engine.start(binary, data: root.appendingPathComponent("b"))
        defer { target.stop() }

        // a bot with a picture, a routine and a webhook on the source
        var bot = try await source.client.createBot()
        bot = try await source.client.patchBot(bot.id, BotPatch(name: "Ada", title: "Analista", description: "Rispondi in breve.", color: "#ff0000"))
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="red"/></svg>"#
        bot = try await source.client.uploadAvatar(botId: bot.id, Data(svg.utf8), mime: "image/svg+xml")
        let routine = try await source.client.createRoutine(RoutineInput(name: "Ogni mattina", prompt: "Riassumi", botId: bot.id, enabled: true,
                                                                         schedule: .daily("08:30", weekdays: [1, 2, 3, 4, 5])))
        _ = try await source.client.createWebhook(WebhookInput(name: "GitHub", prompt: "Guarda la PR", botId: bot.id, enabled: true, eventTypes: ["push"]))
        let other = try await source.client.createBot()
        _ = try await source.client.createRoutine(RoutineInput(name: "Di un altro", prompt: "x", botId: other.id, enabled: true, schedule: .daily("10:00", weekdays: [1])))

        let result = try await BotTransfer.move(bot, from: source.client, to: target.client, deleteOriginal: true)

        // on the target: who the bot is, and its automations pointing at it
        let landed = try await target.client.fleet(messages: 0).bots
        let moved = try XCTUnwrap(landed.first { $0.id == result.bot.id })
        XCTAssertEqual(moved.name, "Ada")
        XCTAssertEqual(moved.title, "Analista")
        XCTAssertEqual(moved.description, "Rispondi in breve.")
        XCTAssertEqual(moved.color, "#ff0000")
        XCTAssertNotNil(moved.mascotAvatarSvg)
        let routines = try await target.client.routines().routines
        XCTAssertEqual(routines.map(\.name), ["Ogni mattina"])
        XCTAssertEqual(routines.first?.botId, moved.id)
        XCTAssertEqual(routines.first?.schedule, routine.schedule)
        let webhooks = try await target.client.webhooks().webhooks
        XCTAssertEqual(webhooks.map(\.name), ["GitHub"])
        XCTAssertEqual(webhooks.first?.botId, moved.id)
        XCTAssertEqual(webhooks.first?.eventTypes, ["push"])
        XCTAssertEqual(result.webhooks.first?.credential?.secret?.isEmpty, false, "the new secret is handed back")
        XCTAssertEqual(result.warnings, [])

        // on the source: the bot and its automations are gone, the other bot's stay
        let left = try await source.client.fleet(messages: 0).bots
        XCTAssertFalse(left.contains { $0.id == bot.id })
        let leftRoutines = try await source.client.routines().routines
        XCTAssertEqual(leftRoutines.map(\.name), ["Di un altro"])
        let leftWebhooks = try await source.client.webhooks().webhooks
        XCTAssertEqual(leftWebhooks, [])
    }

    func testAFailedMoveLeavesBothEnginesAsTheyWere() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("swarme-harness")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("swarme-harness not built") }
        let root = URL(fileURLWithPath: "/tmp/sbt-\(UUID().uuidString.prefix(4))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await Engine.start(binary, data: root.appendingPathComponent("a"))
        defer { source.stop() }
        let target = try await Engine.start(binary, data: root.appendingPathComponent("b"))
        defer { target.stop() }

        var bot = try await source.client.createBot()
        _ = try await source.client.createRoutine(RoutineInput(name: "R", prompt: "x", botId: bot.id, enabled: true, schedule: .daily("10:00", weekdays: [1])))
        // a picture the target cannot fetch: the source has no such attachment
        bot.mascotAvatarImage = "missing.png"
        let before = try await target.client.fleet(messages: 0).bots.count

        do {
            _ = try await BotTransfer.move(bot, from: source.client, to: target.client, deleteOriginal: true)
            XCTFail("the move should fail")
        } catch {}
        let after = try await target.client.fleet(messages: 0).bots.count
        XCTAssertEqual(after, before)
        let targetRoutines = try await target.client.routines().routines
        XCTAssertEqual(targetRoutines, [])
        let sourceBots = try await source.client.fleet(messages: 0).bots
        XCTAssertTrue(sourceBots.contains { $0.id == bot.id })
        let sourceRoutines = try await source.client.routines().routines
        XCTAssertEqual(sourceRoutines.map(\.name), ["R"])
    }
}

/// An OAuth connector copied to an engine: its settings and client secret go, its login does not.
final class OAuthConnectorCopyTests: XCTestCase {
    func testAnOAuthConnectorArrivesWithoutItsLogin() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("swarme-harness")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("swarme-harness not built") }
        let root = URL(fileURLWithPath: "/tmp/sbo-\(UUID().uuidString.prefix(4))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try await Engine.start(binary, data: root)
        defer { server.stop() }

        // as this Mac's engine shows it: logged in, its client secret only as "set"
        let local = try JSONDecoder().decode(MCPConnector.self, from: Data(#"""
        {"id":"notion","name":"Notion","transport":"http","url":"https://mcp.example.com/mcp","auth":"oauth",
         "oauth":{"clientId":"cid","scope":"read","clientSecret":{"secret":true,"set":true}},"oauthState":{"status":"connected"}}
        """#.utf8))
        let copied = try await ConnectorCopy.copy(local, secrets: ["notion": ["oauth": ["clientSecret": "cs-1"]]], to: server.client)
        XCTAssertTrue(copied.usesOAuth)
        XCTAssertEqual(copied.oauth?.clientId, "cid")
        guard case .secret(set: true)? = copied.oauth?.clientSecret else { return XCTFail("client secret not set") }
        XCTAssertNotEqual(copied.oauthState?.status, "connected", "the login is done again there")
        let secrets = try String(contentsOf: root.appendingPathComponent("mcp-connector-secrets.json"), encoding: .utf8)
        XCTAssertTrue(secrets.contains("cs-1"))
        XCTAssertFalse(secrets.contains("access"))
    }
}

/// A throwaway engine on loopback ports of its own.
private struct Engine {
    let process: Process
    let client: CompanionClient

    static func start(_ binary: URL, data: URL) async throws -> Engine {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let port = Int.random(in: 40000...49000)
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["OMB_PORT"] = String(port)
        env["OMB_WEBHOOK_PORT"] = String(port + 1)
        env["OMB_DATA_DIR"] = data.path
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let client = CompanionClient(connection: Connection(name: "test", host: "127.0.0.1", port: port), token: nil)
        for _ in 0..<600 {
            if (try? await client.health()) != nil { return Engine(process: process, client: client) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        process.terminate()
        throw XCTSkip("engine did not start on \(port)")
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}
