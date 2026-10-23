import CompanionCore
import Foundation
@testable import SwarmeKit
import XCTest

final class HarnessLocatorTests: XCTestCase {
    func testPortsMatchElectron() {
        XCTAssertEqual(HarnessLocator.ports, [8799, 18799, 28799])
    }

    func testMissingDataDirectoryIsCreatedBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swarme-ensure-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent(".swarmebot", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try HarnessEngine.ensureDirectories([data])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testBotPatchSendsOnlySetFields() {
        let body = BotPatch(pinned: true, section: "").bodyForTesting
        XCTAssertEqual(body.keys.sorted(), ["pinned", "section"])
    }

    func testInstanceEffortFallsBackToDriverLevels() throws {
        let json = """
        {"instanceId":"claude","driverKind":"claudeAgent","snapshot":{"state":"available"},
         "models":{"default":"a","options":[{"id":"a","label":"A"},{"id":"b","label":"B","effortLevels":["low"]}]},
         "capabilities":{"effortLevels":["low","medium","high"]}}
        """
        let instance = try JSONDecoder().decode(Instance.self, from: Data(json.utf8))
        XCTAssertEqual(instance.effortLevels(for: "a"), ["low", "medium", "high"])
        XCTAssertEqual(instance.effortLevels(for: "b"), ["low"])
    }
}

@MainActor
final class LiveTextTests: XCTestCase {
    private func event(_ json: String) throws -> RuntimeEvent {
        try JSONDecoder().decode(RuntimeEvent.self, from: Data(json.utf8))
    }

    func testDeltasAccumulateAndTurnEndClears() throws {
        let live = LiveText()
        live.apply(try event(#"{"type":"content.delta","threadId":"t","delta":"Ciao ","streamKind":"assistant_text"}"#))
        live.apply(try event(#"{"type":"content.delta","threadId":"t","delta":"mondo","streamKind":"assistant_text"}"#))
        live.apply(try event(#"{"type":"content.delta","threadId":"t","delta":"hmm","streamKind":"reasoning_text"}"#))
        XCTAssertEqual(live.text["t"], "Ciao mondo")
        XCTAssertEqual(live.reasoning["t"], "hmm")
        live.apply(try event(#"{"type":"turn.completed","threadId":"t"}"#))
        XCTAssertNil(live.text["t"])
        XCTAssertNil(live.reasoning["t"])
    }

    func testAttributeEscapingKeepsPathsInsideTheTag() {
        XCTAssertEqual(AppModel.escapeAttribute("a\"b<c>&\nd"), "a&quot;b&lt;c&gt;&amp;&#10;d")
    }

    func testBenchmarkFixtureDecodesThroughTheRealModel() {
        let model = AppModel()
        model.installBenchmark(messages: 120)
        XCTAssertEqual(model.visibleTranscript("bench-thread").count, 120)
        XCTAssertEqual(model.selection, .bot(AppModel.benchmarkBotId))
        model.appendBenchmarkMessage(0)
        XCTAssertEqual(model.visibleTranscript("bench-thread").count, 121, "the cache must see the append")
    }
}
