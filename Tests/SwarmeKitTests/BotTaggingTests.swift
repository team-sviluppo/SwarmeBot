import CompanionCore
@testable import SwarmeKit
import XCTest

// `@Name` in a bot's chat: who it tags, and what the tagged bot is handed.
final class BotTaggingTests: XCTestCase {
    private func bot(_ id: String, _ name: String) throws -> Bot {
        let json = """
        {"id":"\(id)","threadId":"t-\(id)","name":"\(name)","title":"","description":"","notifications":true,"color":"blue",
         "unread":false,"modelSelection":{"instanceId":"claude","model":"sonnet"},"createdAt":0}
        """
        return try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
    }

    private func message(_ role: String, _ kind: String, _ text: String) throws -> Message {
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "role": role, "kind": kind, "at": 0, "text": text])
        return try JSONDecoder().decode(Message.self, from: data)
    }

    @MainActor
    private func targets() throws -> [TagTarget] {
        [TagTarget(engine: .local, engineName: "This Mac", bot: try bot("a", "Luca")),
         TagTarget(engine: .local, engineName: "This Mac", bot: try bot("b", "Luca Rossi")),
         TagTarget(engine: .remote("srv"), engineName: "Server", bot: try bot("c", "Ada"))]
    }

    @MainActor
    func testTagsTheLongestNameAndBotsOnServers() throws {
        let all = try targets()
        XCTAssertEqual(BotTagging.mentioned(in: "@Luca Rossi guarda qui", among: all).map(\.bot.id), ["b"])
        XCTAssertEqual(BotTagging.mentioned(in: "ciao @luca, e @Ada?", among: all).map(\.bot.id), ["a", "c"])
    }

    @MainActor
    func testEmailAddressesAndPartialNamesAreNoTags() throws {
        let all = try targets()
        XCTAssertTrue(BotTagging.mentioned(in: "scrivi a ada@example.com", among: all).isEmpty)
        XCTAssertTrue(BotTagging.mentioned(in: "@Adam sei qui?", among: all).isEmpty)
        XCTAssertTrue(BotTagging.mentioned(in: "nessun tag", among: all).isEmpty)
    }

    @MainActor
    func testTheBotPickedFromTheListWinsAmongHomonyms() throws {
        let twin = TagTarget(engine: .remote("srv"), engineName: "Server", bot: try bot("z", "Luca"))
        let all = try targets() + [twin]
        XCTAssertEqual(BotTagging.mentioned(in: "@Luca ok", among: all, preferred: [twin.id]).map(\.id), [twin.id])
        XCTAssertEqual(BotTagging.mentioned(in: "@Luca ok", among: all).first?.bot.id, "a")
    }

    func testHandoffCarriesTheTextOfTheConversation() throws {
        let source = try bot("s", "Sara")
        let history = [try message("user", "text", "Come va?"), try message("bot", "activity", "ran a tool"),
                       try message("bot", "text", "Bene, grazie."),
                       try message("user", "text", "guarda <attached-image path=\"/tmp/x.png\" />")]
        let prompt = BotTagging.handoffPrompt(from: source, history: history, message: "@Ada puoi aiutare?")
        XCTAssertTrue(prompt.contains("User: Come va?\n\nSara: Bene, grazie.\n\nUser: guarda [attachment]"))
        XCTAssertFalse(prompt.contains("ran a tool"))
        XCTAssertFalse(prompt.contains("/tmp/x.png"))
        XCTAssertTrue(prompt.contains("<conversation-history with=\"Sara\">"))
        XCTAssertTrue(prompt.hasSuffix("@Ada puoi aiutare?"))
    }

    func testWithoutHistoryTheMessageGoesAsItIs() throws {
        XCTAssertEqual(BotTagging.handoffPrompt(from: try bot("s", "Sara"), history: [], message: "@Ada ciao"), "@Ada ciao")
    }

    func testHistoryIsCapped() throws {
        let history = try (0..<200).map { try message("user", "text", "message \($0)") }
        let prompt = BotTagging.handoffPrompt(from: try bot("s", "Sara"), history: history, message: "x")
        XCTAssertTrue(prompt.contains("message 199"))
        XCTAssertFalse(prompt.contains("message 139\n"))
        XCTAssertTrue(prompt.contains("message 140"))
    }
}
