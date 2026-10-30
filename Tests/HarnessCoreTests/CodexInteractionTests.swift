@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

@MainActor
final class CodexInteractionTests: XCTestCase {
    private func instance() -> CodexInstance {
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CODEX_STATE"] = temporaryPaths().root.appendingPathComponent("codex").path
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../parity/fake_codex.py").standardized.path
        return CodexInstance(input: DriverCreateInput(instanceId: "codex", displayName: nil, environment: env,
            enabled: true, config: ["cli": .string(fake)]))
    }

    func testMultipleQuestionsKeepTheirOwnOptionsAndAnswers() async throws {
        let instance = instance()
        var asks: [(String, [String]?)] = []
        var reply = ""
        instance.onEvent { event in
            if case let .requestOpened(_, _, _, choices, _, _) = event.body, let id = event.requestId { asks.append((id, choices)) }
            if case let .textCompleted(text) = event.body { reply = text }
        }
        _ = try await instance.sendTurn(SendTurnInput(threadId: "t", text: "DOMANDE_MULTIPLE"))
        for _ in 0..<100 where asks.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(asks.count, 2)
        guard asks.count == 2 else { await instance.dispose(); return }
        XCTAssertEqual(asks[0].1, ["Rosso", "Blu"])
        XCTAssertEqual(asks[1].1, ["Piccolo", "Grande"])
        _ = await instance.respond(threadId: "t", requestId: asks[1].0, decision: RequestDecision(behavior: "answer", message: "Personalizzato"))
        _ = await instance.respond(threadId: "t", requestId: asks[0].0, decision: RequestDecision(behavior: "answer", message: "Blu"))
        for _ in 0..<100 where instance.hasSession(threadId: "t") { try await Task.sleep(nanoseconds: 20_000_000) }
        let answers = try JSON.parse(reply)
        XCTAssertEqual(answers["color"]?["answers"], ["Blu"])
        XCTAssertEqual(answers["size"]?["answers"], ["Personalizzato"])
        await instance.dispose()
    }

    func testMCPStartupFailureIsVisibleAndContextIncludesTheWindow() async throws {
        let instance = instance()
        var events: [RuntimeEvent] = []
        instance.onEvent { events.append($0) }
        _ = try await instance.sendTurn(SendTurnInput(threadId: "t", text: "MCP_FAILURE"))
        for _ in 0..<100 where instance.hasSession(threadId: "t") { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(events.contains { if case let .runtimeError(message, _) = $0.body { return message.contains("MCP fake: tools/list timed out") }; return false })
        XCTAssertTrue(events.contains { $0.context?.used == 26 && $0.context?.window == 1000 })
        await instance.dispose()
    }

    func testMountForwardsCredentialsWithoutPuttingThemOnArgvAndAllowsColdStartup() {
        var env: [String: String] = [:]
        let args = CodexTurn.mount(&env, name: "fake", MCPServer(command: "/engine", args: ["mcp-connector", "fake"],
            env: ["OMB_COMMS_TOKEN": "secret-token", "OMB_CONNECTOR_GRANT": "grant"]))
        XCTAssertEqual(env["OMB_COMMS_TOKEN"], "secret-token")
        XCTAssertFalse(args.joined().contains("secret-token"))
        XCTAssertTrue(args.contains("mcp_servers.fake.startup_timeout_sec=120"))
        XCTAssertTrue(args.contains("mcp_servers.fake.enabled=true"))
    }

    func testClaudeContextWindowUsesTheActualModelAndRejectsUnknownLimits() {
        let result: JSON = ["modelUsage": ["main": ["contextWindow": 200_000], "helper": ["contextWindow": 100_000]]]
        XCTAssertEqual(ClaudeInstance.contextWindow(result, model: "main"), 200_000)
        XCTAssertNil(ClaudeInstance.contextWindow(result, model: "unknown"))
        XCTAssertNil(ClaudeInstance.contextWindow(["modelUsage": ["main": ["contextWindow": 0]]], model: "main"))
    }

    func testQuestionsKeepTheBotWaitingUntilAllAreAnsweredAndSilentTurnsNotify() throws {
        let harness = try Harness(paths: temporaryPaths(), environment: [:], drivers: [])
        let bot = harness.store.createBot(seedMessages: false)
        let id = try XCTUnwrap(bot["id"]?.string), thread = try XCTUnwrap(bot["threadId"]?.string)
        harness.store.setActivity(id, "working")
        var notices: [JSONObject] = []
        harness.onNotify = { notice, _ in notices.append(notice) }
        for request in ["one", "two"] {
            harness.fold(RuntimeEvent(provider: "codex", threadId: thread, requestId: request,
                .requestOpened(requestType: "question", tool: "ask_user", summary: "Choose?", choices: ["A", "B"], multiSelect: nil, approvalScope: nil)))
        }
        harness.fold(RuntimeEvent(provider: "codex", threadId: thread, requestId: "one", .requestResolved(behavior: "answer", source: "user", approvalScope: nil)))
        XCTAssertEqual(harness.store.bot(id)?["activity"], "waiting-on-you")
        harness.fold(RuntimeEvent(provider: "codex", threadId: thread, requestId: "two", .requestResolved(behavior: "answer", source: "user", approvalScope: nil)))
        XCTAssertEqual(harness.store.bot(id)?["activity"], "working")
        harness.fold(RuntimeEvent(provider: "codex", threadId: thread, .turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil)))
        XCTAssertEqual(notices.map { $0["kind"]?.string }, ["question", "question", "done"])
        XCTAssertEqual(notices.last?["body"], "The turn has finished.")
    }

    func testClaudeKeepsLastRequestTokensInsteadOfCumulativeBilling() async throws {
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../parity/fake_claude.py").standardized.path
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CLAUDE_CONTEXT"] = "1"
        let instance = try ClaudeInstance(input: DriverCreateInput(instanceId: "claude", displayName: nil, environment: env,
            enabled: true, config: ["cli": .string(fake), "permissionMode": "bypassPermissions"]))
        var events: [RuntimeEvent] = []
        instance.onEvent { events.append($0) }
        _ = try await instance.sendTurn(SendTurnInput(threadId: "t", text: "Ciao"))
        for _ in 0..<100 where instance.hasSession(threadId: "t") { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(events.contains { $0.context?.used == 17 && $0.context?.window == 200_000 })
        await instance.dispose()
    }
}
