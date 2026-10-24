@testable import SwarmeBot
import CompanionCore
import XCTest

// `@Name` in a phone bot's chat: the other bot gets a new chat with the history, this one a note.
@MainActor
final class TaggingTests: XCTestCase {
    private func model() throws -> AppModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = LocalBots(store: try LocalStore(folder: folder))
        for (id, name, at) in [("a", "Sara", 1.0), ("b", "Ada", 2.0)] {
            var bot = LocalBot(id: id, name: name, kind: .apple, createdAt: Date(timeIntervalSince1970: at))
            bot.chats = [LocalChatSummary(id: id, title: "", createdAt: bot.createdAt)]
            local.save(bot)
        }
        return AppModel(local: local)
    }

    func testTargetsAreTheOtherBots() throws {
        let model = try model()
        XCTAssertEqual(model.tagTargets(excluding: .phone("a")).filter { $0.place == .phone }.map(\.name), ["Ada"])
        XCTAssertEqual(model.tagTargets(excluding: .phone("b")).filter { $0.place == .phone }.map(\.name), ["Sara"])
    }

    func testHandingOverStartsANewChatAndLeavesANote() async throws {
        let model = try model()
        let first = model.local.chat("a")
        let source = LocalMessage(id: "m1", botId: "a", role: .user, text: "Che tempo fa?", at: Date(timeIntervalSince1970: 1))
        model.local.store?.save(source)
        first.reload()
        let target = try XCTUnwrap(model.tagTargets(excluding: .phone("a")).first { $0.place == .phone })

        let ok = await model.handOff(text: "@Ada puoi aiutarmi?", documents: [], attachments: .pictures([]), from: .phone("a"), to: [target])
        XCTAssertTrue(ok)

        let received = model.local.chat("b").messages.first { $0.role == .user }
        XCTAssertTrue(received?.text.contains("User: Che tempo fa?") == true)
        XCTAssertTrue(received?.text.hasSuffix("@Ada puoi aiutarmi?") == true)
        XCTAssertEqual(BotTagging.split(received?.text ?? "").from, "Sara")
        XCTAssertEqual(model.local.bot("b")?.chats?.first?.title, "Da Sara: @Ada puoi aiutarmi?")

        // the first chat only says where the message went
        XCTAssertEqual(first.messages.filter { $0.role == .note }.count, 1)
        XCTAssertEqual(first.messages.filter { $0.role == .user }.map(\.text), ["Che tempo fa?"])
    }

    func testPicturesOfAnotherEngineAreRefused() async throws {
        let model = try model()
        let target = try XCTUnwrap(model.tagTargets(excluding: .phone("a")).first)
        let ok = await model.handOff(text: "@Ada guarda", documents: [], attachments: .uploaded(["<attached-image path=\"/x.png\"/>"]), from: .phone("a"), to: [target])
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.local.chat("b").messages.isEmpty)
    }
}
