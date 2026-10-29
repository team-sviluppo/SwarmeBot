import XCTest
@testable import CompanionCore

final class ToolVisibilityTests: XCTestCase {
    private func state() throws -> CompanionState {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bots-paged", withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "bots-paged", withExtension: "json"))
        var state = CompanionState()
        state.hydrate(try JSONDecoder().decode(Fleet.self, from: Data(contentsOf: url)))
        return state
    }

    private func message(_ id: String, kind: String, tool: String? = nil, setup: Bool = false) throws -> Message {
        var value: [String: Any] = ["id": id, "role": "bot", "kind": kind, "at": 1]
        if let tool { value["tool"] = ["name": tool, "setup": setup] }
        return try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testVisibilityDefaultsOnAndCanBeRestoredWithoutLosingMessages() throws {
        var state = try state()
        let thread = state.bots[0].threadId
        let messages = try [message("tool", kind: "activity", tool: "Bash"), message("reply", kind: "text"),
                            message("ask", kind: "options"), message("error", kind: "activity", tool: "error: failed"),
                            message("setup", kind: "activity", tool: "Missing CLI", setup: true), message("note", kind: "activity")]
        XCTAssertTrue(state.bots[0].showsToolCalls)
        state.messages[thread] = messages
        XCTAssertEqual(state.chatMessages(messages, forThread: thread), messages)
        state.bots[0].showToolCalls = false
        XCTAssertEqual(state.chatMessages(messages, forThread: thread).map(\.id), ["reply", "ask", "error", "setup", "note"])
        XCTAssertEqual(state.transcript(forThread: thread), messages, "only the presentation is filtered")
        state.bots[0].showToolCalls = true
        XCTAssertEqual(state.chatMessages(messages, forThread: thread), messages)
        XCTAssertEqual(BotPatch(showToolCalls: false).bodyForTesting["showToolCalls"] as? Bool, false)
        XCTAssertNil(BotPatch(name: "Renamed").bodyForTesting["showToolCalls"])
    }

    func testRoomRespectsEachSendingBotsPreference() throws {
        var state = try state()
        state.bots[0].showToolCalls = false
        var other = state.bots[0]
        other.id = "other"
        other.threadId = "other-thread"
        other.showToolCalls = true
        state.bots.append(other)
        var hidden = try message("hidden", kind: "activity", tool: "Read")
        hidden.from = Sender(botId: state.bots[0].id, name: "Hidden", color: "blue")
        var visible = try message("visible", kind: "activity", tool: "Read")
        visible.from = Sender(botId: other.id, name: "Visible", color: "blue")
        let unknown = try message("unknown", kind: "activity", tool: "Read")
        XCTAssertEqual(state.chatMessages([hidden, visible, unknown], forThread: "room").map(\.id), ["visible", "unknown"])
    }
}
