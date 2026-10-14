@testable import CompanionCore
import XCTest

/// The frames and fields only the desktop client folds.
final class DesktopFrameTests: XCTestCase {
    private func frame(_ json: String) throws -> StreamFrame {
        try JSONDecoder().decode(StreamFrame.self, from: Data(json.utf8))
    }

    func testRoutineFramesFold() throws {
        var state = CompanionState()
        let routine = """
        {"kind":"routine","seq":3,"routine":{"id":"r1","name":"Daily","prompt":"p","botId":"b","enabled":true,
         "schedule":{"type":"daily","time":"09:00","weekdays":[1,2,3]},"nextRunAt":1700000000000}}
        """
        state.apply(try frame(routine))
        XCTAssertEqual(state.routines.map(\.id), ["r1"])
        XCTAssertEqual(state.routines.first?.schedule.weekdays, [1, 2, 3])

        state.apply(try frame(#"{"kind":"routine.run","seq":4,"run":{"id":"x","routineId":"r1","botId":"b","status":"running"}}"#))
        XCTAssertEqual(state.routineRuns.first?.isActive, true)
        state.apply(try frame(#"{"kind":"routine.run","seq":5,"run":{"id":"x","routineId":"r1","botId":"b","status":"completed"}}"#))
        XCTAssertEqual(state.routineRuns.count, 1, "a run is updated in place, not appended")
        XCTAssertEqual(state.routineRuns.first?.isActive, false)

        state.apply(try frame(#"{"kind":"routine.deleted","seq":6,"routineId":"r1"}"#))
        XCTAssertTrue(state.routines.isEmpty)
    }

    func testWebhookAndComputerControlFrames() throws {
        var state = CompanionState()
        state.apply(try frame(#"{"kind":"webhook","seq":1,"webhook":{"id":"w","endpointId":"wh_1","name":"CI","prompt":"p","botId":"b","enabled":true}}"#))
        state.apply(try frame(#"{"kind":"webhook.attempt","seq":2,"attempt":{"id":"a","webhookId":"w","receivedAt":1,"outcome":"accepted"}}"#))
        state.apply(try frame(#"{"kind":"computer-control","seq":3,"botId":"b","held":true,"helpReason":"captcha"}"#))
        XCTAssertEqual(state.webhooks.first?.endpointId, "wh_1")
        XCTAssertEqual(state.webhookAttempts.first?.outcome, "accepted")
        XCTAssertEqual(state.computerControl["b"], ComputerControl(held: true, helpReason: "captcha"))
        state.apply(try frame(#"{"kind":"webhook.deleted","seq":4,"webhookId":"w"}"#))
        XCTAssertTrue(state.webhooks.isEmpty)
    }

    func testDesktopMessageFieldsDecode() throws {
        let json = """
        {"id":"m","role":"user","kind":"text","at":1,"text":"hi","queued":true,
         "card":{"title":"t","subtitle":"s","options":["a","b"],"multiSelect":true,"approvalScope":"local-computer"}}
        """
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        XCTAssertEqual(message.queued, true)
        XCTAssertEqual(message.card?.multiSelect, true)
        XCTAssertEqual(message.card?.approvalScope, "local-computer")
    }

    func testBotPatchCarriesEffortAndSection() {
        let patch = BotPatch(modelSelection: ModelSelection(instanceId: "i", model: "m", effort: "high"), section: "")
        let body = patch.bodyForTesting
        XCTAssertEqual((body["modelSelection"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual(body["section"] as? String, "", "an empty section is how the label is cleared")
    }
}
