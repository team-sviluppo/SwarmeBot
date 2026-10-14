@testable import HarnessCore
import XCTest

final class PeerTextTests: XCTestCase {
    let alfa: JSONObject = ["id": "a", "name": "Alfa"]
    let alfaBeta: JSONObject = ["id": "ab", "name": "Alfa Beta"]
    let beta: JSONObject = ["id": "b", "name": "Beta"]
    let hidden: JSONObject = ["id": "h", "name": "Ombra", "hidden": true]

    func testMentionsPreferLongestNamesAndSkipEmails() {
        let found = PeerText.mentioned("@Alfa Beta e @beta, scrivi a mario@Alfa", [alfa, alfaBeta, beta])
        XCTAssertEqual(found.compactMap { $0["id"]?.string }, ["ab", "b"])
        XCTAssertTrue(PeerText.mentioned("@Alfabeto", [alfa]).isEmpty, "a tag must not run into a longer word")
        XCTAssertTrue(PeerText.mentioned("@Ombra", [hidden]).isEmpty)
    }

    func testRespondersFollowTagsThenPolicy() {
        let members = [alfa, beta, hidden]
        XCTAssertEqual(PeerText.responders("@everyone ciao", members: members, policy: ["kind": "mentions"]).count, 2)
        XCTAssertEqual(PeerText.responders("@Beta ciao", members: members, policy: ["kind": "member", "botId": "a"]).first?["id"], "b")
        XCTAssertEqual(PeerText.responders("ciao", members: members, policy: ["kind": "member", "botId": "a"]).first?["id"], "a")
        XCTAssertTrue(PeerText.responders("ciao", members: members, policy: ["kind": "mentions"]).isEmpty)
    }

    func testChiefRosterIsCappedAndHonestWithoutTools() {
        let team = (0..<45).map { JSONObject([("id", .string("b\($0)")), ("name", .string("Bot\($0)"))]) }
        let prompt = PeerText.chiefOfStaff(chiefId: "b0", bots: team, canDelegate: false)
        XCTAssertTrue(prompt.contains("…and 4 more"))
        XCTAssertTrue(prompt.contains("cannot contact teammates"))
        XCTAssertFalse(prompt.contains("- Bot0 "), "the chief is not on its own roster")
    }
}

final class TurnObserverTests: XCTestCase {
    func testRepeatDetectorChipsAtThresholdsAndForgetsOnSettle() {
        var repeats = RepeatDetector()
        XCTAssertNil(RepeatDetector.callKey("Bash", "Bash"))
        let key = RepeatDetector.callKey("tool", "ls   -la")!
        XCTAssertEqual(key, "tool:ls -la")
        let hits = (1...10).compactMap { _ in repeats.record("t", key) }
        XCTAssertEqual(hits, [5, 10])
        repeats.settle("t")
        XCTAssertNil(repeats.record("t", key))
    }

    @MainActor
    func testWatchdogSkipsTurnsWaitingOnAHuman() {
        var stalled: [String] = []
        let watchdog = TurnWatchdog(stallSeconds: 60) { stalled.append($0.threadId) }
        watchdog.watch("busy", botId: "a")
        watchdog.watch("asking", botId: "b")
        watchdog.setWaitingOnHuman("asking", true)
        watchdog.sweep(now: Date().addingTimeInterval(120))
        XCTAssertEqual(stalled, ["busy"])
        XCTAssertTrue(watchdog.watching("asking"))
    }
}
