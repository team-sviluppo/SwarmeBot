import Foundation
import XCTest
@testable import CompanionCore

final class WorkingClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 1_120)

    private func bot(_ id: String = "b1", busy: Bool = true, activity: String? = nil, thread: String? = nil) throws -> Bot {
        var value = try JSONDecoder().decode(Bot.self, from: Data(#"{"id":"b1","threadId":"t1","name":"Test","title":"","description":"","notifications":true,"color":"blue","unread":false,"modelSelection":{"instanceId":"i","model":"m"},"createdAt":1}"#.utf8))
        value.id = id
        value.threadId = thread ?? "thread-" + id
        value.busy = busy
        value.activity = activity
        return value
    }

    private func room(_ id: String = "r1", speaker: String? = "b1") throws -> Room {
        var value = try JSONDecoder().decode(Room.self, from: Data(#"{"id":"r1","threadId":"rt1","name":"Room","memberIds":["b1","b2"],"defaultResponder":{"kind":"all"},"bulletin":"","unread":false,"createdAt":1}"#.utf8))
        value.id = id
        value.threadId = "thread-" + id
        value.busyBotId = speaker
        return value
    }

    func testTheClockSurvivesOtherChatsAndRepeatedBotUpdates() throws {
        var state = CompanionState()
        state.apply(.bot(try bot()), now: start)
        state.apply(.bot(try bot("b2")), now: later)
        var updated = try bot()
        updated.name = "Renamed while working"
        state.apply(.bot(updated), now: later)
        XCTAssertEqual(state.botWorkingSince["b1"], start)
        XCTAssertEqual(state.botWorkingSince["b2"], later)
    }

    func testSwitchingTheSameBotsTaskDoesNotRestartItsRunningTurn() throws {
        var state = CompanionState()
        state.apply(.bot(try bot(thread: "original")), now: start)
        state.apply(.bot(try bot(thread: "other-task")), now: later)
        state.apply(.bot(try bot(thread: "original")), now: later)
        XCTAssertEqual(state.botWorkingSince["b1"], start)
    }

    func testWaitingAndNoSignalPreserveTheTurnClock() throws {
        var state = CompanionState()
        state.apply(.bot(try bot(busy: false, activity: "working")), now: start)
        for activity in ["waiting-on-you", "no-signal", "working"] {
            state.apply(.bot(try bot(busy: false, activity: activity)), now: later)
            XCTAssertEqual(state.botWorkingSince["b1"], start)
        }
    }

    func testANewTurnStartsANewClockAfterIdleOrFailure() throws {
        for activity in ["idle", "dead"] {
            var state = CompanionState()
            state.apply(.bot(try bot()), now: start)
            state.apply(.bot(try bot(busy: false, activity: activity)), now: later)
            XCTAssertNil(state.botWorkingSince["b1"])
            state.apply(.bot(try bot()), now: later)
            XCTAssertEqual(state.botWorkingSince["b1"], later)
        }
    }

    func testRehydrationPreservesActiveClocksAndRemovesFinishedOrDeletedOnes() throws {
        var state = CompanionState()
        state.hydrate(Fleet(bots: [try bot(), try bot("b2")], groups: [try room()]), now: start)
        state.hydrate(Fleet(bots: [try bot(), try bot("b2", busy: false), try bot("b3")], groups: [try room()]), now: later)
        XCTAssertEqual(state.botWorkingSince["b1"], start)
        XCTAssertNil(state.botWorkingSince["b2"])
        XCTAssertEqual(state.botWorkingSince["b3"], later)
        XCTAssertEqual(state.roomWorkingSince["r1"], start)
        state.hydrate(Fleet(bots: [], groups: []), now: later)
        XCTAssertTrue(state.botWorkingSince.isEmpty)
        XCTAssertTrue(state.roomWorkingSince.isEmpty)
    }

    func testRoomUpdatesPreserveTheClockButANewSpeakerRestartsIt() throws {
        var state = CompanionState()
        state.apply(.room(try room()), now: start)
        state.apply(.room(try room()), now: later)
        XCTAssertEqual(state.roomWorkingSince["r1"], start)
        state.apply(.room(try room(speaker: "b2")), now: later)
        XCTAssertEqual(state.roomWorkingSince["r1"], later)
        state.apply(.room(try room(speaker: nil)), now: later)
        XCTAssertNil(state.roomWorkingSince["r1"])
    }

    func testRehydrationWithANewRoomSpeakerStartsANewClock() throws {
        var state = CompanionState()
        state.hydrate(Fleet(bots: [], groups: [try room()]), now: start)
        state.hydrate(Fleet(bots: [], groups: [try room(speaker: "b2")]), now: later)
        XCTAssertEqual(state.roomWorkingSince["r1"], later)
    }

    func testBotAndRoomClocksAreIndependentEvenWhenIdsMatch() throws {
        var state = CompanionState()
        state.apply(.bot(try bot("same")), now: start)
        state.apply(.room(try room("same")), now: later)
        XCTAssertEqual(state.botWorkingSince["same"], start)
        XCTAssertEqual(state.roomWorkingSince["same"], later)
        state.apply(.botDeleted(botId: "same"), now: later)
        XCTAssertNil(state.botWorkingSince["same"])
        XCTAssertEqual(state.roomWorkingSince["same"], later)
        state.apply(.roomDeleted(groupId: "same"), now: later)
        XCTAssertTrue(state.roomWorkingSince.isEmpty)
    }

    func testSettledTextAndStreamCleanupDoNotRestartTheTurnClock() throws {
        var state = CompanionState()
        state.apply(.bot(try bot()), now: start)
        let reply = Message(id: "reply", role: .bot, kind: .text, at: 1_100_000)
        state.apply(.message(threadId: "thread-b1", message: reply), now: later)
        state.clearStream("thread-b1")
        XCTAssertEqual(state.botWorkingSince["b1"], start)
    }

    func testTakingAnEngineSnapshotKeepsItsClocks() throws {
        var original = CompanionState()
        original.apply(.bot(try bot()), now: start)
        var restored = original
        restored.hydrate(Fleet(bots: [try bot()], groups: []), now: later)
        XCTAssertEqual(restored.botWorkingSince["b1"], start)
    }
}
