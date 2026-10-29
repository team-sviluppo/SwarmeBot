@testable import CompanionCore
import XCTest

final class ReplyFilesTests: XCTestCase {
    func testFindsLinksCodeSpansAndAbsolutePaths() {
        let text = """
        Ho salvato il report in [report](out/report%20finale.pdf) e i dati in `hosting_sottoprezzo.csv`.
        Una copia è anche in /Users/me/Desktop/analisi.xlsx. Vedi [il sito](https://example.com/a.pdf)
        e [qui](file:///tmp/x.md), [sezione](#sotto), `~/Documents/Nota spese.docx`, `Report finale.md`.
        """
        XCTAssertEqual(ReplyFiles.candidates(in: text), [
            "out/report finale.pdf", "file:///tmp/x.md", "hosting_sottoprezzo.csv", "~/Documents/Nota spese.docx", "Report finale.md",
            "/Users/me/Desktop/analisi.xlsx",
        ])
    }

    func testIgnoresCommandsCodeBlocksAndWebAddresses() {
        let text = """
        Lancia `npm run build` oppure `swift test --filter A.b`, poi apri https://example.com/x.html.
        ```sh
        cat /etc/hosts.txt
        ```
        La versione è `1.2` e il comando `cat report.pdf | head` o `pandoc -o out.pdf`.
        """
        XCTAssertEqual(ReplyFiles.candidates(in: text), [])
    }

    func testKeepsAtMostTheLimitWithoutRepeats() {
        let text = (0..<30).map { "`f\($0).txt` `f0.txt`" }.joined(separator: " ")
        let found = ReplyFiles.candidates(in: text)
        XCTAssertEqual(found.count, ReplyFiles.limit)
        XCTAssertEqual(Set(found).count, found.count)
    }
}

// Code mode: the flag that turns it on, as every client reads and writes it.
final class CodeModeTests: XCTestCase {
    func testTheFlagTravelsInThePatch() {
        XCTAssertEqual(BotPatch(codeMode: true).bodyForTesting["codeMode"] as? Bool, true)
        XCTAssertNil(BotPatch(pinned: true).bodyForTesting["codeMode"])
    }

    func testABotDecodesWithAndWithoutTheFlag() throws {
        let base = #"{"id":"b","threadId":"t","name":"N","title":"","description":"","notifications":true,"color":"blue","unread":false,"modelSelection":{"instanceId":"i","model":"m"},"createdAt":1"#
        XCTAssertEqual(try JSONDecoder().decode(Bot.self, from: Data((base + #","codeMode":true}"#).utf8)).codeMode, true)
        XCTAssertNil(try JSONDecoder().decode(Bot.self, from: Data((base + "}").utf8)).codeMode)
    }
}

// What a plugin keeps on a bot or a channel: `plugins.<id>`, and the patch that sets it.
final class PluginDataTests: XCTestCase {
    private let bot = #"{"id":"b","threadId":"t","name":"N","title":"","description":"","notifications":true,"color":"blue","unread":false,"modelSelection":{"instanceId":"i","model":"m"},"createdAt":1"#

    func testABotCarriesItsPluginsData() throws {
        let decoded = try JSONDecoder().decode(Bot.self, from: Data((bot + #","plugins":{"code":{"projectId":"p1","role":"backend","future":{"x":1}},"other":{"a":true}}}"#).utf8))
        let code = (decoded.plugins ?? [:]).pluginData("code")
        XCTAssertEqual(code["projectId"]?.string, "p1")
        XCTAssertEqual(code["role"]?.string, "backend")
        XCTAssertNotNil(code["future"], "what this client does not know is carried, not dropped")
        XCTAssertTrue((decoded.plugins ?? [:]).pluginData("absent").isEmpty)
        XCTAssertNil(try JSONDecoder().decode(Bot.self, from: Data((bot + "}").utf8)).plugins)
    }

    func testThePatchesCarryAPluginsDataWithNullToRemove() throws {
        var botPatch = BotPatch()
        botPatch.pluginData = ["code": ["projectId": "p1", "role": NSNull()]]
        let body = botPatch.bodyForTesting
        let code = (body["plugins"] as? [String: Any])?["code"] as? [String: Any]
        XCTAssertEqual(code?["projectId"] as? String, "p1")
        XCTAssertTrue(code?["role"] is NSNull)
        XCTAssertNil(BotPatch(pinned: true).bodyForTesting["plugins"])
    }

    func testAChannelCarriesItsPluginsDataAndItsCodeFlag() throws {
        let json = #"{"id":"g","threadId":"t","name":"R","memberIds":[],"defaultResponder":{"kind":"everyone"},"bulletin":"","unread":false,"createdAt":1,"codeMode":true,"plugins":{"code":{"projectId":"p"}}}"#
        let room = try JSONDecoder().decode(Room.self, from: Data(json.utf8))
        XCTAssertEqual(room.codeMode, true)
        XCTAssertEqual((room.plugins ?? [:]).pluginData("code")["projectId"]?.string, "p")
        var patch = RoomPatch()
        patch.codeMode = true
        patch.pluginData = ["code": ["role": "app"]]
        XCTAssertEqual(patch.bodyForTesting["codeMode"] as? Bool, true)
        XCTAssertEqual(((patch.bodyForTesting["plugins"] as? [String: Any])?["code"] as? [String: Any])?["role"] as? String, "app")
    }
}
