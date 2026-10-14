@testable import HarnessCore
@testable import HarnessDrivers
import CryptoKit
import XCTest

final class RemoteComputerTests: XCTestCase {
    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// The hashes are the Node engine's own strings: a box set up by one
    /// engine must be exactly what the other expects.
    func testCommandsAreByteForByteTheNodeOnes() {
        XCTAssertEqual(Self.sha(RemoteComputer.ensureCuaCommand()), "820db0907db39325cbfcaafdfc060dd1f53ab4db179bdfa1469ab4375b04fff9")
        XCTAssertEqual(Self.sha(RemoteComputer.bootstrapCommand(botName: "Al\"fa's bot")), "02fec734c68d40f215bf4eef393fbc61507393c5b35fa3df19137c66b32ae3c8")
    }

    func testBoxNameIsDeterministic() {
        XCTAssertEqual(BoxComputer.name(for: "ABCD-ef12-3456"), "ogb-abcdef1-" + String(Self.sha("ABCD-ef12-3456").prefix(6)))
    }

    func testProviderWordsWinInErrors() {
        XCTAssertEqual(BoxComputer.errorMessage(402, "box create", ["message": "Start the plan.", "error": ["details": ["billingUrl": "https://b"]]]), "Start the plan. https://b")
        XCTAssertTrue(BoxComputer.errorMessage(401, "x", nil).contains("rejected"))
        XCTAssertEqual(BoxComputer.errorMessage(500, "box naming", nil), "box naming failed (500)")
    }
}

@MainActor
final class ComputerControlTests: XCTestCase {
    func testOnlyThePersonTakesAndReleaseSettlesThePlea() {
        let control = ComputerControl()
        var changes = 0
        control.onChange = { _, _ in changes += 1 }
        let (asked, requestId) = control.requestHelp("b", reason: "  login page  ")
        XCTAssertEqual(asked["helpReason"]?.string, "login page")
        XCTAssertEqual(control.requestHelp("b", reason: "another").snapshot["helpReason"]?.string, "login page", "the first plea stays")
        let held = control.take("b")
        XCTAssertEqual(held["held"]?.bool, true)
        XCTAssertEqual(control.take("b")["heldSinceMs"], held["heldSinceMs"], "idempotent")
        XCTAssertEqual(control.expireHelp("b", requestId: "stale")["helpReason"]?.string, "login page", "only its own lease expires it")
        XCTAssertEqual(control.expireHelp("b", requestId: .string(requestId))["helpReason"], .null)
        XCTAssertEqual(control.release("b")["held"]?.bool, false)
        XCTAssertGreaterThan(changes, 3)
    }
}

@MainActor
final class BoxAgentTests: XCTestCase {
    func testATurnStreamsTheGrowthAndSettlesOnTheRunStatus() async throws {
        let port = Int.random(in: 41000...49000)
        let fake = Process()
        fake.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../parity/fake_box.py").standardized.path
        fake.arguments = ["python3", "-I", script, String(port), NSTemporaryDirectory() + "box-\(port).ndjson"]
        try fake.run()
        defer { fake.terminate() }
        try await Task.sleep(nanoseconds: 700_000_000)

        let instance = BoxAgentInstance(input: DriverCreateInput(
            instanceId: "computer", displayName: nil,
            environment: ["BOX_TOKEN": "box_x", "OMB_BOX_API": "http://127.0.0.1:\(port)/api/box/v1"], enabled: true, config: ["pollMs": 50]
        ))
        var seen: [RuntimeEvent] = []
        let done = expectation(description: "settled")
        instance.onEvent { event in
            seen.append(event)
            if case .turnCompleted = event.body { done.fulfill() }
        }
        do {
            _ = try await instance.sendTurn(SendTurnInput(threadId: "t", text: "ciao"))
            XCTFail("no box, no turn")
        } catch {}
        var input = SendTurnInput(threadId: "t", text: "ciao")
        input.cloudBoxId = "box-1"
        _ = try await instance.sendTurn(input)
        await fulfillment(of: [done], timeout: 10)
        let deltas = seen.compactMap { if case let .contentDelta(_, delta) = $0.body { return delta } else { return nil } }
        XCTAssertEqual(deltas, ["Ciao", " dal box", "!"])
        XCTAssertTrue(seen.contains { if case let .textCompleted(text) = $0.body { return text == "Ciao dal box!" } else { return false } })
        XCTAssertTrue(seen.contains { if case let .itemStarted(_, title) = $0.body { return title == "ls -la" } else { return false } })
        XCTAssertTrue(seen.contains { if case let .turnCompleted(ok, _, _, _, _) = $0.body { return ok } else { return false } })
    }
}
