@testable import HarnessCore
import XCTest

/// A room waits for a member that is working in another conversation, instead of skipping it.
@MainActor
final class RoomBusyQueueTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("room-queue-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertTrue(condition(), what)
    }

    @MainActor
    private struct Room {
        let harness: Harness
        let adapter: SkillFakeAdapter
        let groupId: String
        let threadId: String
        let alfa: String
        let beta: String

        func texts() -> [String] { harness.store.messages(threadId).filter { $0["role"]?.string == "bot" && $0["kind"]?.string == "text" }.compactMap { $0["from"]?["name"]?.string } }
        func chips() -> [String] { harness.store.messages(threadId).compactMap { $0["tool"]?["name"]?.string } }
        var idle: Bool { harness.store.group(groupId)?["busyBotId"]?.string == nil && harness.groupQueues[groupId] == nil }
        func busyElsewhere(_ id: String, _ on: Bool) { harness.store.patchBot(id, ["busy": .bool(on)]) }
    }

    private func room() async throws -> Room {
        let adapter = SkillFakeAdapter()
        let harness = try Harness(paths: DataPaths(root: scratch.appendingPathComponent("data", isDirectory: true)), environment: ProcessInfo.processInfo.environment,
                                  drivers: [SkillFakeDriver(adapter: adapter)])
        await harness.boot()
        let selection: JSON = ["instanceId": "claude", "model": "fake-1"]
        func bot(_ name: String) -> String {
            let id = harness.store.createBot(seedMessages: false)["id"]!.string!
            harness.store.patchBot(id, ["modelSelection": selection, "name": .string(name)])
            return id
        }
        let alfa = bot("Alfa"), beta = bot("Beta")
        let group = harness.store.createGroup(name: "Team", memberIds: [alfa, beta])
        return Room(harness: harness, adapter: adapter, groupId: group["id"]!.string!, threadId: group["threadId"]!.string!, alfa: alfa, beta: beta)
    }

    func testTheFreeMemberAnswersFirstAndTheBusyOneIsWaitedForThenAnswers() async throws {
        let r = try await room()
        r.busyElsewhere(r.beta, true)
        // Beta is named first, and is the one working elsewhere
        try r.harness.startGroupTurn(groupId: r.groupId, text: "@Beta @Alfa hello both")
        try await eventually("Alfa answers meanwhile") { r.texts() == ["Alfa"] }
        try await eventually("the room says it waits") { r.chips().contains("Beta is busy in another conversation — waiting for them") }
        XCTAssertEqual(r.harness.store.group(r.groupId)?["busyBotId"]?.string, r.beta, "the room shows it is waiting, so that Stop is there")
        XCTAssertFalse(r.chips().contains { $0.contains("skipped") }, "it is not skipped")
        XCTAssertEqual(r.adapter.received.count, 1)

        r.busyElsewhere(r.beta, false)
        try await eventually("Beta answers once it is free") { r.texts() == ["Alfa", "Beta"] }
        try await eventually("the room is idle again") { r.idle }
        XCTAssertEqual(r.adapter.received.count, 2)
        XCTAssertTrue(r.adapter.received[1].text.contains("hello both"), "with the conversation as it is now")
    }

    func testAMemberThatIsNotBusyIsNeverMadeToWait() async throws {
        let r = try await room()
        try r.harness.startGroupTurn(groupId: r.groupId, text: "@Alfa @Beta hello")
        try await eventually("both answer, in the order they were named") { r.texts() == ["Alfa", "Beta"] }
        try await eventually("idle") { r.idle }
        XCTAssertFalse(r.chips().contains { $0.contains("waiting") || $0.contains("skipped") })
    }

    func testStopEndsTheWaitAndTheMemberNeverSpeaks() async throws {
        let r = try await room()
        r.busyElsewhere(r.beta, true)
        try r.harness.startGroupTurn(groupId: r.groupId, text: "@Beta hello")
        try await eventually("it waits") { r.harness.store.group(r.groupId)?["busyBotId"]?.string == r.beta }
        let stopped = await r.harness.interruptGroup(r.groupId)
        XCTAssertTrue(stopped)
        try await eventually("the room is free again") { r.idle }
        XCTAssertTrue(r.adapter.received.isEmpty, "Beta was never asked")
        XCTAssertTrue(r.texts().isEmpty)
        r.busyElsewhere(r.beta, false)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(r.adapter.received.isEmpty, "and it does not speak later either")
    }

    func testAfterTheLimitTheMemberIsSkippedAsItAlwaysWas() async throws {
        let r = try await room()
        r.harness.roomBusyWaitOverride = 0.6
        r.busyElsewhere(r.beta, true)
        try r.harness.startGroupTurn(groupId: r.groupId, text: "@Beta @Alfa hello")
        try await eventually("Alfa answers") { r.texts() == ["Alfa"] }
        try await eventually("Beta is given up on") { r.chips().contains("Beta is busy in another conversation — skipped this round") }
        try await eventually("the room is idle") { r.idle }
        XCTAssertEqual(r.adapter.received.count, 1, "only Alfa was asked")
    }

    func testAMessageWrittenWhileWaitingGoesBehindIt() async throws {
        let r = try await room()
        r.busyElsewhere(r.beta, true)
        try r.harness.startGroupTurn(groupId: r.groupId, text: "@Beta first")
        try await eventually("it waits") { r.harness.store.group(r.groupId)?["busyBotId"]?.string == r.beta }
        try r.harness.startGroupTurn(groupId: r.groupId, text: "@Alfa second")
        let second = r.harness.store.messages(r.threadId).last { $0["role"]?.string == "user" }
        XCTAssertEqual(second?["queued"]?.bool, true, "the room is occupied by the wait, so it is queued like any other")
        XCTAssertTrue(r.texts().isEmpty)
        r.busyElsewhere(r.beta, false)
        try await eventually("Beta first, then Alfa") { r.texts() == ["Beta", "Alfa"] }
        try await eventually("idle") { r.idle }
        XCTAssertNotEqual(r.harness.store.messages(r.threadId).last { $0["role"]?.string == "user" }?["queued"]?.bool, true, "and it is dispatched in its turn")
    }

    func testAWaitingRoomCannotStartANewSession() async throws {
        let r = try await room()
        r.busyElsewhere(r.beta, true)
        try r.harness.startGroupTurn(groupId: r.groupId, text: "@Beta hello")
        try await eventually("it waits") { r.harness.store.group(r.groupId)?["busyBotId"]?.string == r.beta }
        do { _ = try await r.harness.newRoomSession(r.groupId, summarize: false); XCTFail("the room is occupied") } catch {}
        _ = await r.harness.interruptGroup(r.groupId)
        try await eventually("free") { r.idle }
    }
}
