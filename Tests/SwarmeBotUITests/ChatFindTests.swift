import CompanionCore
@testable import SwarmeBotUI
import SwiftUI
import XCTest

@MainActor
final class ChatFindTests: XCTestCase {
    private func message(_ id: String, _ role: String, _ text: String, kind: String = "text") throws -> Message {
        let body: [String: Any] = ["id": id, "role": role, "kind": kind, "text": text, "at": 1]
        return try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: body))
    }

    func testMatchesIgnoreCaseAndAccents() {
        XCTAssertEqual(FindText.count("perche", in: "Perché? PERCHE no, perchè sì"), 3)
        XCTAssertEqual(FindText.count("aa", in: "aaaa"), 2, "occurrences do not overlap")
        XCTAssertEqual(FindText.count("", in: "text"), 0)
    }

    func testBotRepliesAreSearchedAsDrawnNotAsMarkdown() {
        let source = """
        # Titolo **forte**

        - un [link](https://example.com) qui
        1. secondo

        ```swift
        let forte = 1
        ```

        | a | forte |
        |---|---|
        | **forte** | b |
        """
        let pieces = FindText.pieces(markdown: source)
        XCTAssertEqual(pieces.count, 2 + 4, "a prose run, a code block, then each table cell")
        XCTAssertEqual(pieces.reduce(0) { $0 + FindText.count("forte", in: $1) }, 4)
        XCTAssertEqual(pieces.reduce(0) { $0 + FindText.count("**", in: $1) }, 0, "markdown markers are not text")
        XCTAssertEqual(pieces.reduce(0) { $0 + FindText.count("https", in: $1) }, 0, "a link reads as its title")
    }

    func testProseIsCountedInTheCharactersTheTextViewLaysOut() {
        let blocks = Markdown.blocks("Uno *due*\n\n> citata\n\n- punto\n  - sotto\n3. tre\n\n## Fine")
        XCTAssertEqual(FindText.prose(blocks), MarkdownText.proseCharacters(blocks))
    }

    func testTheSearchStartsAtTheNewestMatchAndWrapsBothWays() throws {
        let find = ChatFind()
        find.isOpen = true
        find.query = "gatto"
        let messages = try [
            message("u1", "user", "Il gatto e il Gatto"),
            message("t1", "bot", "gatto", kind: "activity"),
            message("b1", "bot", "Nessun animale"),
            message("b2", "bot", "Un **gatto**"),
        ]
        find.update(messages)
        XCTAssertEqual(find.matches, [FindMatch(messageId: "u1", occurrence: 0), FindMatch(messageId: "u1", occurrence: 1),
                                      FindMatch(messageId: "b2", occurrence: 0)], "activity rows are not searched")
        XCTAssertEqual(find.currentMatch?.messageId, "b2")
        XCTAssertEqual(find.position?.index, 1)
        XCTAssertEqual(find.position?.total, 3)
        find.older()
        XCTAssertEqual(find.currentMatch, FindMatch(messageId: "u1", occurrence: 1))
        XCTAssertEqual(find.highlight(for: "u1"), FindHighlight(query: "gatto", current: 1))
        XCTAssertEqual(find.highlight(for: "b2"), FindHighlight(query: "gatto", current: nil))
        find.older(); find.older()
        XCTAssertEqual(find.currentMatch?.messageId, "b2", "past the oldest it wraps to the newest")
        find.newer()
        XCTAssertEqual(find.currentMatch, FindMatch(messageId: "u1", occurrence: 0), "past the newest it wraps to the oldest")
    }

    func testANewMessageKeepsTheCurrentMatch() throws {
        let find = ChatFind()
        find.isOpen = true
        find.query = "uno"
        var messages = try [message("a", "user", "uno"), message("b", "bot", "uno")]
        find.update(messages)
        find.older()
        messages.append(try message("c", "bot", "ancora uno"))
        find.update(messages)
        XCTAssertEqual(find.currentMatch?.messageId, "a")
        XCTAssertEqual(find.matches.count, 3)
    }

    func testAttachmentsAreNotSearched() throws {
        let find = ChatFind()
        find.isOpen = true
        find.query = "report"
        find.update([try message("u", "user", "<attached-file path=\"/tmp/report.pdf\"/>\nleggi questo")])
        XCTAssertTrue(find.matches.isEmpty)
        XCTAssertNil(find.highlight(for: "u"))
    }

    func testMarkingColoursEachOccurrenceAndTheCurrentOne() {
        let marked = FindText.marked(AttributedString("Caffè e caffe"), FindHighlight(query: "caffe", current: 1))
        let runs = marked.runs.filter { $0.backgroundColor != nil }.map { String(marked[$0.range].characters) }
        XCTAssertEqual(runs, ["Caffè", "caffe"])
        let current = Color(nsColor: FindText.currentColor)
        XCTAssertEqual(marked.runs.filter { $0.backgroundColor == current }.map { String(marked[$0.range].characters) }, ["caffe"])
    }
}
