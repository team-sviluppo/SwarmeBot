@testable import HarnessCore
import XCTest

@MainActor
final class ToolVisibilityTests: XCTestCase {
    func testPreferenceIsValidatedPersistedAndScopedToTheBot() async throws {
        let paths = temporaryPaths()
        let harness = try Harness(paths: paths, environment: [:], drivers: [])
        let routes = Routes(harness: harness)
        let bot = harness.store.createBot(seedMessages: false)
        let other = harness.store.createBot(seedMessages: false)
        let id = try XCTUnwrap(bot["id"]?.string)
        let otherId = try XCTUnwrap(other["id"]?.string)
        for (value, expected) in [(JSON.bool(false), 200), (.string("no"), 400), (.null, 400), (.bool(true), 200)] {
            let request = HTTPRequest(method: "PATCH", path: "/api/bots/\(id)", query: [:],
                                      headers: ["content-type": "application/json"], body: JSON.object(["showToolCalls": value]).data)
            guard case let .response(response) = await routes.handle(request) else { return XCTFail("missing response") }
            XCTAssertEqual(response.status, expected)
            if expected == 200 { XCTAssertEqual(harness.store.bot(id)?["showToolCalls"], value) }
            XCTAssertNil(harness.store.bot(otherId)?["showToolCalls"])
        }
        let restarted = try Store(paths: paths)
        XCTAssertEqual(restarted.bot(id)?["showToolCalls"], true)
    }
}
