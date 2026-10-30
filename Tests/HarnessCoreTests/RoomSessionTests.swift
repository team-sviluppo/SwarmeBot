@testable import HarnessCore
import XCTest

@MainActor
final class RoomSessionTests: XCTestCase {
    private func fixture() throws -> (Harness, String, String, String) {
        let harness = try Harness(paths: temporaryPaths(), environment: ProcessInfo.processInfo.environment, drivers: [])
        let bot = harness.store.createBot(seedMessages: false)["id"]!.string!
        let group = harness.store.createGroup(name: "Session", memberIds: [bot])
        return (harness, group["id"]!.string!, group["threadId"]!.string!, bot)
    }

    func testResetClearsEveryCursorAndKeepsTheVisibleHistory() async throws {
        let (harness, id, thread, bot) = try fixture()
        harness.store.appendMessage(thread, ["role": "user", "kind": "text", "text": "old work"])
        harness.store.setGroupResumeCursor(id, botId: bot, instanceId: "claude", cursor: "old-session")
        _ = try await harness.newRoomSession(id, summarize: false)
        XCTAssertNil(harness.store.groupResumeCursor(id, botId: bot, instanceId: "claude"))
        XCTAssertEqual(harness.store.messages(thread).count, 2)
        XCTAssertTrue(harness.roomContext(thread).isEmpty)
        harness.store.appendMessage(thread, ["role": "user", "kind": "text", "text": "new work"])
        XCTAssertTrue(harness.roomContext(thread).contains("new work"))
        XCTAssertFalse(harness.roomContext(thread).contains("old work"))
        let reloaded = try Store(paths: harness.paths)
        XCTAssertNotNil(reloaded.group(id)?["sessionEpoch"]?.string)
        XCTAssertEqual(reloaded.messages(thread).filter { $0["sessionDivider"] == true }.count, 1)
    }

    func testBusyAndQueuedRoomsCannotReset() async throws {
        let (harness, id, thread, bot) = try fixture()
        harness.store.patchGroup(id, ["busyBotId": .string(bot)])
        do { _ = try await harness.newRoomSession(id, summarize: false); XCTFail("busy") } catch {}
        harness.store.patchGroup(id, ["busyBotId": .null])
        harness.groupQueues[id] = Task {}
        do { _ = try await harness.newRoomSession(id, summarize: false); XCTFail("queued") } catch {}
        XCTAssertTrue(harness.store.messages(thread).isEmpty)
        harness.groupQueues[id] = nil
    }

    func testQueuedMessagesStayOutOfTheRunningContext() throws {
        let (harness, _, thread, _) = try fixture()
        harness.store.appendMessage(thread, ["role": "user", "kind": "text", "text": "now"])
        harness.store.appendMessage(thread, ["role": "user", "kind": "text", "text": "later", "queued": true])
        XCTAssertTrue(harness.roomContext(thread).contains("now"))
        XCTAssertFalse(harness.roomContext(thread).contains("later"))
    }

    func testSummaryFailureDoesNotEraseTheSession() async throws {
        let (harness, id, thread, bot) = try fixture()
        harness.store.setGroupResumeCursor(id, botId: bot, instanceId: "claude", cursor: "old")
        do { _ = try await harness.newRoomSession(id, summarize: true); XCTFail("no model") } catch {}
        XCTAssertEqual(harness.store.groupResumeCursor(id, botId: bot, instanceId: "claude"), "old")
        XCTAssertTrue(harness.store.messages(thread).isEmpty)
        XCTAssertFalse(harness.roomSessionResets.contains(id))
    }

    func testMixedRoomResetIsScopedToTheAuthenticatedHostAndIsIdempotent() throws {
        let (harness, id, thread, _) = try fixture()
        harness.store.patchGroup(id, ["guest": ["deviceId": "host-a", "conversationId": "remote-room"]])
        let body: JSONObject = ["conversationId": "remote-room", "sessionEpoch": "epoch-1", "startedAt": 100, "summary": "keep this"]
        _ = harness.resetGuestSession(body, deviceId: "host-b")
        XCTAssertTrue(harness.store.messages(thread).isEmpty)
        _ = harness.resetGuestSession(body, deviceId: "host-a")
        _ = harness.resetGuestSession(body, deviceId: "host-a")
        XCTAssertEqual(harness.store.messages(thread).count, 2)
        XCTAssertEqual(harness.sessionMessages(thread).first?["text"], "keep this")
        _ = harness.resetGuestSession(["conversationId": "remote-room", "sessionEpoch": "old", "startedAt": 99], deviceId: "host-a")
        XCTAssertEqual(harness.store.group(id)?["sessionEpoch"], "epoch-1", "a delayed request cannot restore an older session")
        let outbound = harness.guestTurnBody(harness.store.group(id)!, botId: "guest")
        XCTAssertEqual(outbound["sessionEpoch"], "epoch-1")
        XCTAssertEqual(outbound["messages"]?.array?.count, 1)
    }
}
