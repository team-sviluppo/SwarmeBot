import CompanionCore
import Foundation
@testable import SwarmeKit
import XCTest

final class HarnessLocatorTests: XCTestCase {
    func testPortsMatchElectron() {
        XCTAssertEqual(HarnessLocator.ports, [8799, 18799, 28799])
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

final class CredentialStoreTests: XCTestCase {
    func testOSCryptRoundTrip() throws {
        let password = Data("pa55w0rd".utf8)
        let secret = Data(#"{"xaiApiKey":"xai-123"}"#.utf8)
        let blob = try CredentialStore.encryptOSCrypt(secret, password: password)
        XCTAssertTrue(blob.starts(with: Data("v10".utf8)))
        XCTAssertEqual(try CredentialStore.decryptOSCrypt(blob, password: password), secret)
    }

    /// A vector computed independently with Python `cryptography` using
    /// Chromium's parameters (PBKDF2-SHA1, "saltysalt", 1003, AES-128-CBC,
    /// IV of spaces), so the round trip above is not testing itself.
    func testOSCryptKnownVector() throws {
        let blob = Data(base64Encoded: OSCryptVector.blob)!
        let plain = try CredentialStore.decryptOSCrypt(blob, password: Data("peanuts".utf8))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), "hello swarmebot")
    }

    func testWrongPrefixIsRejected() {
        XCTAssertThrowsError(try CredentialStore.decryptOSCrypt(Data("v11xxxx".utf8), password: Data()))
    }
}

/// Generated with: hashlib.pbkdf2_hmac('sha1', b'peanuts', b'saltysalt',
/// 1003, 16) → `openssl enc -aes-128-cbc -K <key> -iv 20…20` over
/// "hello swarmebot" with PKCS#7 padding, prefixed "v10".
enum OSCryptVector {
    static let blob = "djEwS8P3sKza2bmFMKPheJ7kOQ=="
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
