@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

@MainActor
final class SubagentTests: XCTestCase {
    private static let parity = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../parity").standardized

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for provider lifecycle")
    }

    private func completed(_ events: [RuntimeEvent]) -> Bool {
        events.contains { if case .turnCompleted = $0.body { return true }; return false }
    }

    /// Opt-in smoke test against a real subscription, always in an empty
    /// working directory. Run one provider at a time and report its usage.
    func testLiveSubagentLifecycle() async throws {
        guard let provider = ProcessInfo.processInfo.environment["SWARMEBOT_SUBAGENT_LIVE"], ["claude", "codex"].contains(provider) else {
            throw XCTSkip("Set SWARMEBOT_SUBAGENT_LIVE=claude|codex for a real subscription smoke test")
        }
        let paths = temporaryPaths()
        var env = ProcessInfo.processInfo.environment
        env["OMB_DATA_DIR"] = paths.root.path
        let input = DriverCreateInput(instanceId: provider, displayName: nil, environment: env, enabled: true,
            config: ["cli": .string(provider), "permissionMode": "bypassPermissions", "fullAuto": true])
        let adapter: ProviderAdapter = try provider == "claude" ? ClaudeInstance(input: input) : CodexInstance(input: input)
        let model: String?
        if let codex = adapter as? CodexInstance {
            await codex.refreshModels()
            model = codex.models.options.first { $0.id.hasSuffix("luna") }?.id ?? codex.models.default
        } else { model = "claude-haiku-4-5" }
        var events: [RuntimeEvent] = []
        adapter.onEvent { events.append($0) }
        _ = try await adapter.sendTurn(SendTurnInput(threadId: "live-subagents", text:
            "Integration test: launch exactly one native subagent in the background whose entire task is to reply CHILD_OK. Let it finish, then reply PARENT_OK. Do not use shell commands or read/write files. Use your native subagent tools, not MCP peer bots.",
            model: model, cwd: paths.root.path))
        for _ in 0..<1200 where !completed(events) { try await Task.sleep(nanoseconds: 100_000_000) }
        await adapter.stopAll()
        let tasks = events.compactMap(\.subagent)
        XCTAssertFalse(tasks.isEmpty, "Provider did not expose any native subagent lifecycle")
        XCTAssertTrue(tasks.contains { $0.status == "completed" && $0.result?.contains("CHILD_OK") == true }, "\(tasks)")
        XCTAssertTrue(events.contains { if case let .textCompleted(text) = $0.body { return text.contains("PARENT_OK") }; return false })
        for event in events {
            if case .turnCompleted = event.body { print("Live \(provider) usage: \(event.json.serialized())") }
            if case .runtimeError = event.body { print("Live \(provider) error: \(event.json.serialized())") }
        }
    }

    func testClaudePatchOnlyCompletionAndDuplicateNotification() {
        let ledger = SubagentLedger()
        var changes: [SubagentState] = []
        ledger.onChange = { task, _ in changes.append(task) }
        ledger.claude(["type": "system", "subtype": "task_started", "task_id": "a", "description": "Review", "task_type": "local_agent"], parentId: "parent")
        XCTAssertEqual(ledger.pending.count, 1)
        ledger.claude(["type": "system", "subtype": "task_updated", "task_id": "a", "patch": ["status": "completed"]], parentId: "parent")
        XCTAssertTrue(ledger.pending.isEmpty)
        let notification: JSON = ["type": "system", "subtype": "task_notification", "task_id": "a", "status": "completed", "summary": "Result"]
        ledger.claude(notification, parentId: "parent")
        ledger.claude(notification, parentId: "parent")
        XCTAssertEqual(changes.count, 3, "a duplicate must not create another row/update")
        XCTAssertEqual(ledger.tasks["a"]?.result, "Result")
        XCTAssertEqual(ledger.tasks["a"]?.parentId, "parent")
    }

    func testClaudeShellAndMonitorDoNotHoldTheRunOpen() {
        let ledger = SubagentLedger()
        for kind in ["local_bash", "local_monitor", "teammate"] {
            ledger.claude(["type": "system", "subtype": "task_started", "task_id": .string(kind), "task_type": .string(kind)], parentId: "parent")
        }
        XCTAssertTrue(ledger.pending.isEmpty)
        ledger.finishRunning("interrupted", reason: "Run ended")
        XCTAssertTrue(ledger.tasks.values.allSatisfy { $0.status == "interrupted" })
        for status in ["stopped", "killed", "shutdown", "interrupted"] {
            XCTAssertEqual(SubagentLedger.status(status), "interrupted")
        }
    }

    func testClaudeKeepsInputOpenAndWaitsForTheParentsContinuation() async throws {
        for text in ["SUBAGENTS", "SUBAGENTS EARLY", "SUBAGENTS LATE"] {
            let paths = temporaryPaths()
            var env = ProcessInfo.processInfo.environment
            env["OMB_DATA_DIR"] = paths.root.path
            let instance = try ClaudeInstance(input: DriverCreateInput(instanceId: "claude", displayName: nil, environment: env,
                enabled: true, config: ["cli": .string(Self.parity.appendingPathComponent("fake_claude.py").path), "permissionMode": "bypassPermissions"]))
            var events: [RuntimeEvent] = []
            instance.onEvent { events.append($0) }
            _ = try await instance.sendTurn(SendTurnInput(threadId: "t", text: text, model: nil))
            try await waitUntil { self.completed(events) }
            let texts = events.compactMap { if case let .textCompleted(text) = $0.body { return text }; return nil }
            XCTAssertEqual(texts, ["Parent is waiting", "Parent used Child result"])
            XCTAssertFalse(events.contains { if case .itemStarted(_, "Bash") = $0.body { return true }; return false }, "child tools stay out of the parent transcript")
            XCTAssertEqual(events.compactMap(\.subagent).last?.result, "Child result")
            XCTAssertEqual(events.compactMap(\.subagent).last?.status, "completed")
            XCTAssertFalse(instance.hasSession(threadId: "t"))
            await instance.dispose()
        }
    }

    func testCodexRetrievesLateResultsAndResumesOnlyTheRoot() async throws {
        let paths = temporaryPaths()
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CODEX_STATE"] = paths.root.appendingPathComponent("codex").path
        let instance = CodexInstance(input: DriverCreateInput(instanceId: "codex", displayName: nil, environment: env,
            enabled: true, config: ["cli": .string(Self.parity.appendingPathComponent("fake_codex.py").path)]))
        var events: [RuntimeEvent] = []
        instance.onEvent { events.append($0) }
        _ = try await instance.sendTurn(SendTurnInput(threadId: "t", text: "SUBAGENTS", model: nil))
        try await waitUntil { self.completed(events) }
        let texts = events.compactMap { if case let .textCompleted(text) = $0.body { return text }; return nil }
        XCTAssertEqual(texts, ["Parent is waiting", "Parent used Child result"])
        let tasks = events.compactMap(\.subagent)
        XCTAssertEqual(tasks.last(where: { $0.id == "child-1" })?.result, "First child result")
        XCTAssertEqual(tasks.last(where: { $0.id == "child-2" })?.result, "Child result")
        XCTAssertTrue(tasks.suffix(2).allSatisfy { $0.status == "completed" })
        XCTAssertEqual(events.filter { if case .turnCompleted = $0.body { return true }; return false }.count, 1)
        XCTAssertFalse(instance.hasSession(threadId: "t"))
        await instance.dispose()
    }

    func testInterruptStopsTheEntireRunAndSettlesChildren() async throws {
        for provider in ["claude", "codex"] {
            let paths = temporaryPaths()
            var env = ProcessInfo.processInfo.environment
            env["OMB_DATA_DIR"] = paths.root.path
            env["FAKE_CODEX_STATE"] = paths.root.appendingPathComponent("codex").path
            let input = DriverCreateInput(instanceId: provider, displayName: nil, environment: env, enabled: true,
                config: ["cli": .string(Self.parity.appendingPathComponent("fake_\(provider).py").path), "permissionMode": "bypassPermissions"])
            let adapter: ProviderAdapter = try provider == "claude" ? ClaudeInstance(input: input) : CodexInstance(input: input)
            var events: [RuntimeEvent] = []
            adapter.onEvent { events.append($0) }
            _ = try await adapter.sendTurn(SendTurnInput(threadId: "t", text: "SUBAGENTS STOP", model: nil))
            try await waitUntil { !events.compactMap(\.subagent).isEmpty }
            await adapter.interruptTurn(threadId: "t")
            try await waitUntil { self.completed(events) }
            XCTAssertEqual(events.compactMap(\.subagent).last?.status, "interrupted")
            XCTAssertFalse(adapter.hasSession(threadId: "t"))
            await adapter.stopAll()
        }
    }

    func testCodexMissingChildResultIsVisibleAndTheParentStillResumes() async throws {
        let paths = temporaryPaths()
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CODEX_STATE"] = paths.root.appendingPathComponent("codex").path
        let instance = CodexInstance(input: DriverCreateInput(instanceId: "codex", displayName: nil, environment: env,
            enabled: true, config: ["cli": .string(Self.parity.appendingPathComponent("fake_codex.py").path)]))
        var events: [RuntimeEvent] = []
        instance.onEvent { events.append($0) }
        _ = try await instance.sendTurn(SendTurnInput(threadId: "t", text: "SUBAGENTS BROKEN", model: nil))
        try await waitUntil { self.completed(events) }
        XCTAssertEqual(events.compactMap(\.subagent).last?.status, "failed")
        XCTAssertTrue(events.compactMap(\.subagent).last?.result?.contains("Could not retrieve") == true)
        XCTAssertTrue(events.contains { if case .textCompleted("Parent reported missing child result") = $0.body { return true }; return false })
        await instance.dispose()
    }

    func testTranscriptKeepsOneRowAndRecoversInterruptedTasksAfterRestart() throws {
        let paths = temporaryPaths()
        let harness = try Harness(paths: paths, environment: [:], drivers: [])
        let bot = harness.store.createBot(seedMessages: false)
        let thread = try XCTUnwrap(bot["threadId"]?.string)
        var task = SubagentState(id: "child", parentId: "parent", title: "Review")
        func fold() {
            var event = RuntimeEvent(provider: "claude", threadId: thread, turnId: "parent", itemId: "subagent:child", .itemUpdated(itemType: "tool", tokens: nil))
            event.subagent = task
            harness.fold(event)
        }
        fold()
        task.result = "Progress"
        fold()
        XCTAssertEqual(harness.store.messages(thread).count, 1)
        XCTAssertEqual(harness.store.messages(thread).first?["tool"]?["subagent"]?["result"]?.string, "Progress")
        let restarted = try Store(paths: paths)
        XCTAssertEqual(restarted.messages(thread).first?["tool"]?["subagent"]?["status"]?.string, "interrupted")
        task.status = "completed"
        task.result = "sk-ant-abcdefghijklmnopqrstu"
        fold()
        XCTAssertFalse(harness.store.messages(thread).first?["tool"]?["output"]?.string?.contains("abcdefghijklmnopqrstu") ?? true)
        let settled = try Store(paths: paths)
        XCTAssertEqual(settled.messages(thread).first?["tool"]?["subagent"]?["status"]?.string, "completed")
    }
}
