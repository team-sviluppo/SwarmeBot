@testable import CompanionCore
import XCTest

final class SuggestedChoicesTests: XCTestCase {
    func testLetterAndNumberQuestions() {
        XCTAssertEqual(SuggestedChoices.parse("Quale preferisci?\nA) Una correzione\nB) Una funzione"), ["A) Una correzione", "B) Una funzione"])
        XCTAssertEqual(SuggestedChoices.parse("Scegli una soluzione:\n1) Prima\n2) Seconda").count, 2)
        XCTAssertEqual(SuggestedChoices.parse("Quale preferisci? a) Prima b) Seconda c) Terza").count, 3)
        XCTAssertEqual(SuggestedChoices.parse("Which option?\n1. First\n2. Second\n3. Third").count, 3)
        XCTAssertEqual(SuggestedChoices.parse("**1.** Prima\n**2.** Seconda\nQuale scegli?").count, 2)
    }

    func testInstructionsCodeAndBrokenSequencesAreNotQuestions() {
        XCTAssertTrue(SuggestedChoices.parse("Procedura:\n1. Compila\n2. Avvia").isEmpty)
        XCTAssertTrue(SuggestedChoices.parse("Quale preferisci?\n```\nA) esempio\nB) esempio\n```").isEmpty)
        XCTAssertTrue(SuggestedChoices.parse("Which option?\n1. First\n3. Third").isEmpty)
        XCTAssertTrue(SuggestedChoices.parse("Quale preferisci?\nA) Unica").isEmpty)
    }
}
