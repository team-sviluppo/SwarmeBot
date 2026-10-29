@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

@MainActor
final class CodexUsageTests: XCTestCase {
    func testQuotaBucketsAndUnknownSparseUpdates() {
        let primary: JSON = ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1000]
        let snapshot: JSON = ["rateLimits": ["limitId": "codex", "primary": primary]]
        XCTAssertEqual(CodexQuota.session(snapshot)?.utilization, 0.42)
        XCTAssertEqual(CodexQuota.session(snapshot)?.window, "five_hour")
        XCTAssertEqual(CodexQuota.session(snapshot)?.resetsAt, 1000)
        XCTAssertNil(CodexQuota.session(["rateLimits": ["limitId": "other", "primary": primary]]))
        XCTAssertNil(CodexQuota.session(["rateLimits": ["primary": .null, "secondary": primary]]))
        XCTAssertNil(CodexQuota.session(["primary": ["usedPercent": -1]]))
        XCTAssertEqual(CodexQuota.session(["primary": ["usedPercent": 0, "windowDurationMins": 15]])?.window, "minutes_15")
        let multi: JSON = ["rateLimits": ["limitId": "other"], "rateLimitsByLimitId": ["codex": ["primary": primary]]]
        XCTAssertEqual(CodexQuota.session(multi)?.utilization, 0.42)
    }

    func testCostSubtractsCacheAndDeduplicatesLifetimeSnapshotsOnResume() throws {
        var estimate = CodexCostEstimate()
        let first: JSON = ["total": ["inputTokens": 100_000, "cachedInputTokens": 20_000, "outputTokens": 20_000],
                           "last": ["inputTokens": 1000, "cachedInputTokens": 250, "outputTokens": 100]]
        estimate.record(first, model: "gpt-6.1-sol-2026-10-01", provider: "openai")
        XCTAssertEqual(try XCTUnwrap(estimate.cost), 0.002525, accuracy: 0.000000001)
        estimate.record(first, model: "gpt-6.1-sol", provider: "openai")
        XCTAssertEqual(try XCTUnwrap(estimate.cost), 0.002525, accuracy: 0.000000001)
        let next: JSON = ["total": ["inputTokens": 100_300, "cachedInputTokens": 20_100, "outputTokens": 20_020],
                          "last": ["inputTokens": 300, "cachedInputTokens": 100, "outputTokens": 20]]
        estimate.record(next, model: "gpt-6.1-sol", provider: "openai")
        XCTAssertEqual(try XCTUnwrap(estimate.cost), 0.003135, accuracy: 0.000000001)
    }

    func testLongContextCacheWritesAndUnknownModels() throws {
        var estimate = CodexCostEstimate()
        let usage: JSON = ["last": ["inputTokens": 300_000, "cachedInputTokens": 100_000, "cacheWriteInputTokens": 10_000, "outputTokens": 1000]]
        estimate.record(usage, model: "gpt-6.1-sol", provider: "openai")
        XCTAssertEqual(try XCTUnwrap(estimate.cost), 0.845, accuracy: 0.000000001)
        for (model, provider) in [("future-model", "openai"), ("gpt-6.1-sol", "local"), ("local::gpt-6.1-sol", "openai")] {
            var unknown = CodexCostEstimate()
            unknown.record(usage, model: model, provider: provider)
            XCTAssertNil(unknown.cost)
        }
        var legacy = CodexCostEstimate()
        legacy.record(["total": ["inputTokens": 1_000_000, "outputTokens": 1_000_000]], model: "gpt-6.1-sol", provider: "openai")
        XCTAssertNil(legacy.cost, "a lifetime total alone must not be billed again on resume")
        legacy.record(usage, model: "gpt-6.1-sol", provider: nil)
        XCTAssertNil(legacy.cost, "a default provider not identified as OpenAI must not be priced as OpenAI")
    }

    func testDriverLoadsQuotaBeforeATurnAndEmitsTheEstimatedCost() async throws {
        let paths = temporaryPaths()
        var env = ProcessInfo.processInfo.environment
        env["FAKE_CODEX_USAGE"] = "1"
        env["FAKE_CODEX_STATE"] = paths.root.appendingPathComponent("state").path
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../parity/fake_codex.py").standardized.path
        let instance = CodexInstance(input: DriverCreateInput(instanceId: "codex", displayName: nil, environment: env,
            enabled: true, config: ["cli": .string(fake)]))
        var events: [RuntimeEvent] = []
        instance.onEvent { events.append($0) }
        await instance.refreshModels()
        XCTAssertTrue(events.contains { $0.body == .usageLimit(window: "five_hour", utilization: 0.25, resetsAt: 4102444800) })
        _ = try await instance.sendTurn(SendTurnInput(threadId: "t", text: "USAGE", model: "gpt-6.1-sol"))
        for _ in 0..<250 where instance.hasSession(threadId: "t") { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(events.contains { $0.body == .usageLimit(window: "five_hour", utilization: 0.42, resetsAt: 4102444800) })
        let completed = try XCTUnwrap(events.first { if case .turnCompleted = $0.body { return true }; return false })
        XCTAssertTrue(completed.costEstimated)
        if case let .turnCompleted(ok, _, cost, _, _) = completed.body {
            XCTAssertTrue(ok)
            XCTAssertEqual(try XCTUnwrap(cost), 0.0000905, accuracy: 0.000000001)
        }
        await instance.dispose()
    }

    func testCostProvenancePersistsAcrossModelChangesAndRestart() throws {
        let paths = temporaryPaths()
        let store = try Store(paths: paths)
        let bot = store.createBot(seedMessages: false)
        let id = try XCTUnwrap(bot["id"]?.string), thread = try XCTUnwrap(bot["threadId"]?.string)
        store.addTaskUsage(id, thread, input: 10, output: 10, costUsd: 0.01, costEstimated: true)
        store.addTaskUsage(id, thread, input: 10, output: 10, costUsd: 0.02)
        let restarted = try Store(paths: paths)
        let usage = try XCTUnwrap(restarted.taskByThread(id, thread)?["usage"])
        XCTAssertEqual(usage["costUsd"]?.double ?? 0, 0.03, accuracy: 0.000000001)
        XCTAssertEqual(usage["costEstimated"]?.bool, true)
    }
}
