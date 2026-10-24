@testable import HarnessCore
import XCTest

// `POST /api/bots/:id/notes`: a line in a bot's chat that nobody said — what a
// chat shows after its message was handed to another bot.
@MainActor
final class BotNotesTests: XCTestCase {
    private func prepare() throws -> (Harness, Routes, String) {
        let harness = try Harness(paths: temporaryPaths(), environment: ProcessInfo.processInfo.environment, drivers: [])
        return (harness, Routes(harness: harness), harness.store.createBot(seedMessages: false)["id"]!.string!)
    }

    private func call(_ routes: Routes, _ path: String, _ body: JSON) async -> (Int, JSON?) {
        let request = HTTPRequest(method: "POST", path: path, query: [:], headers: ["content-type": "application/json"], body: body.data)
        guard case let .response(response) = await routes.handle(request) else { XCTFail("not a response"); return (0, nil) }
        return (response.status, try? JSON.parse(response.body))
    }

    func testTheNoteLandsInTheBotsChatAsAnActivityLine() async throws {
        let (harness, routes, id) = try prepare()
        let (status, body) = await call(routes, "/api/bots/\(id)/notes", ["text": "Message sent to Ada. Check their chat"])
        XCTAssertEqual(status, 201)
        XCTAssertEqual(body?["message"]?["kind"]?.string, "activity")
        let threadId = harness.store.bot(id)!["threadId"]!.string!
        let last = harness.store.messages(threadId).last
        XCTAssertEqual(last?["text"]?.string, "Message sent to Ada. Check their chat")
        XCTAssertEqual(last?["role"]?.string, "bot")
        XCTAssertNil(last?["tool"])
        XCTAssertFalse(Store.isBusy(harness.store.bot(id)!), "a note starts no turn")
    }

    func testRefusesAnEmptyOrUnknown() async throws {
        let (_, routes, id) = try prepare()
        var (status, _) = await call(routes, "/api/bots/\(id)/notes", ["text": "  "])
        XCTAssertEqual(status, 400)
        (status, _) = await call(routes, "/api/bots/nobody/notes", ["text": "hi"])
        XCTAssertEqual(status, 404)
    }
}
