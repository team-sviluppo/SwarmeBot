@testable import CompanionCore
import XCTest

// `@Name` in a bot's chat: who it tags, and what the tagged bot is handed.
final class BotTaggingTests: XCTestCase {
    private struct Candidate: TagCandidate, Equatable {
        var tagId: String
        var tagName: String
    }

    private let all = [Candidate(tagId: "a", tagName: "Luca"), Candidate(tagId: "b", tagName: "Luca Rossi"), Candidate(tagId: "c", tagName: "Ada")]

    private func message(_ role: String, _ kind: String, _ text: String) throws -> Message {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "role": role, "kind": kind, "at": 0, "text": text])
        return try JSONDecoder().decode(Message.self, from: data)
    }

    func testTagsTheLongestNameAndEveryoneNamed() {
        XCTAssertEqual(BotTagging.mentioned(in: "@Luca Rossi guarda qui", among: all).map(\.tagId), ["b"])
        XCTAssertEqual(BotTagging.mentioned(in: "ciao @luca, e @Ada?", among: all).map(\.tagId), ["a", "c"])
    }

    func testEmailAddressesAndPartialNamesAreNoTags() {
        XCTAssertTrue(BotTagging.mentioned(in: "scrivi a ada@example.com", among: all).isEmpty)
        XCTAssertTrue(BotTagging.mentioned(in: "@Adam sei qui?", among: all).isEmpty)
        XCTAssertTrue(BotTagging.mentioned(in: "nessun tag", among: all).isEmpty)
    }

    func testTheBotPickedFromTheListWinsAmongHomonyms() {
        let twin = Candidate(tagId: "z", tagName: "Luca")
        XCTAssertEqual(BotTagging.mentioned(in: "@Luca ok", among: all + [twin], preferred: ["z"]).map(\.tagId), ["z"])
        XCTAssertEqual(BotTagging.mentioned(in: "@Luca ok", among: all + [twin]).first?.tagId, "a")
    }

    func testThePartialNameAndItsCompletion() {
        XCTAssertEqual(BotTagging.partial(in: "ciao @Lu"), "Lu")
        XCTAssertEqual(BotTagging.partial(in: "@"), "")
        XCTAssertNil(BotTagging.partial(in: "ada@exa"))
        XCTAssertNil(BotTagging.partial(in: "@Luca ciao"))
        XCTAssertNil(BotTagging.partial(in: "niente"))
        XCTAssertEqual(BotTagging.completing("ciao @Lu", with: "Luca Rossi"), "ciao @Luca Rossi ")
    }

    func testLinesKeepOnlyTheSpokenText() throws {
        let lines = BotTagging.lines(from: [try message("user", "text", "Ciao"), try message("bot", "activity", "tool"), try message("bot", "text", "Eccomi")])
        XCTAssertEqual(lines, [.init(isUser: true, text: "Ciao"), .init(isUser: false, text: "Eccomi")])
    }

    func testHandoffCarriesTheTextOfTheConversation() {
        let history: [BotTagging.Line] = [.init(isUser: true, text: "Come va?"), .init(isUser: false, text: "Bene, grazie."),
                                          .init(isUser: true, text: "guarda <attached-image path=\"/tmp/x.png\" />")]
        let prompt = BotTagging.handoffPrompt(sourceName: "Sara", history: history, message: "@Ada puoi aiutare?")
        XCTAssertTrue(prompt.contains("User: Come va?\n\nSara: Bene, grazie.\n\nUser: guarda [attachment]"))
        XCTAssertFalse(prompt.contains("/tmp/x.png"))
        XCTAssertTrue(prompt.hasSuffix("@Ada puoi aiutare?"))
    }

    func testWithoutHistoryTheMessageGoesAsItIs() {
        XCTAssertEqual(BotTagging.handoffPrompt(sourceName: "Sara", history: [], message: "@Ada ciao"), "@Ada ciao")
    }

    func testHistoryIsCappedAndAPhoneBotGetsLess() {
        let history = (0..<200).map { BotTagging.Line(isUser: true, text: "message \($0)") }
        let full = BotTagging.handoffPrompt(sourceName: "Sara", history: history, message: "x")
        XCTAssertTrue(full.contains("message 140")); XCTAssertFalse(full.contains("message 139\n"))
        let short = BotTagging.handoffPrompt(sourceName: "Sara", history: history, message: "x", maxMessages: 12)
        XCTAssertTrue(short.contains("message 188")); XCTAssertFalse(short.contains("message 187\n"))
    }

    func testSplitGivesBackTheMessageAndWhoItCameFrom() {
        let prompt = BotTagging.handoffPrompt(sourceName: "Sara \"S\" & co", history: [.init(isUser: true, text: "ciao")], message: "@Ada ok?\n\nanche questo")
        let parts = BotTagging.split(prompt)
        XCTAssertEqual(parts.from, "Sara \"S\" & co")
        XCTAssertEqual(parts.rest, "@Ada ok?\n\nanche questo")
        XCTAssertNil(BotTagging.split("un messaggio normale").from)
    }
}
