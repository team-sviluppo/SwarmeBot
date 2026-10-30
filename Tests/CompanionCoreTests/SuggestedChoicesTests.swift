@testable import CompanionCore
import XCTest

final class SuggestedChoicesTests: XCTestCase {
    func testLetterAndNumberQuestions() {
        XCTAssertEqual(SuggestedChoices.parse("Quale preferisci?\nA) Una correzione\nB) Una funzione"), ["A) Una correzione", "B) Una funzione"])
        XCTAssertEqual(SuggestedChoices.parse("Scegli una soluzione:\n1) Prima\n2) Seconda").count, 2)
        XCTAssertEqual(SuggestedChoices.parse("Quale preferisci? a) Prima b) Seconda c) Terza").count, 3)
        XCTAssertEqual(SuggestedChoices.parse("Which option?\n1. First\n2. Second\n3. Third").count, 3)
        XCTAssertEqual(SuggestedChoices.parse("**1.** Prima\n**2.** Seconda\nQuale scegli?").count, 2)
        XCTAssertEqual(SuggestedChoices.parse("Would you prefer a fix or a feature?\nA) Fix\nB) Feature").count, 2)
    }

    func testInstructionsCodeAndBrokenSequencesAreNotQuestions() {
        XCTAssertTrue(SuggestedChoices.parse("Procedura:\n1. Compila\n2. Avvia").isEmpty)
        XCTAssertTrue(SuggestedChoices.parse("Quale preferisci?\n```\nA) esempio\nB) esempio\n```").isEmpty)
        XCTAssertTrue(SuggestedChoices.parse("Which option?\n1. First\n3. Third").isEmpty)
        XCTAssertTrue(SuggestedChoices.parse("Quale preferisci?\nA) Unica").isEmpty)
        XCTAssertTrue(SuggestedChoices.parse("Quale preferisci?\n```\nesempio\n```\nA) Prima\nB) Seconda").isEmpty)
    }

    func testSummariesAndInstructionsDoNotBorrowAQuestionFromElsewhere() {
        let replies = [
            "Riepilogo delle opzioni configurate:\n1. Accesso in lettura\n2. Repository selezionato\nTutto chiaro?",
            "Ecco la procedura:\n1. Apri GitHub\n2. Compila i campi\n3. Genera il token\nVuoi che verifichi la configurazione?",
            "Summary of the options:\n1. Fixed notifications\n2. Updated tests\nDo you want me to commit?",
            "What do you think?\n1. Fixed notifications\n2. Updated tests",
            "Quale preferisci?\n\nOra riepilogo il lavoro completato:\n1. Corretto il parser\n2. Aggiunti i test",
            "Quale preferisci? Ecco intanto il riepilogo:\n1. Corretto il parser\n2. Aggiunti i test",
            "Passaggi:\n1. Scegli Only select repositories\n2. Genera il token\nHai domande?",
            "Opzioni disponibili:\n1. [Documentazione](https://example.com/?page=1)\n2. [Guida](https://example.com/?page=2)",
        ]
        for reply in replies {
            XCTAssertTrue(SuggestedChoices.parse(reply).isEmpty, reply)
        }
    }

    func testTokenSetupInstructionsAreNotChoices() {
        let reply = """
        Vuoi configurare le opzioni del token? Ecco i passaggi:
        1. Apri [GitHub](https://github.com/settings/personal-access-tokens/new).
        2. Compila i campi:

        | Campo | Valore |
        | --- | --- |
        | Repository access | Only select repositories |

        3. In **Permissions**, aggiungi **Contents → Read-only**.
        4. Premi **Generate token** e copia il valore.
        5. Salvalo in `.env.mac-release.local`:
        ```dotenv
        SWARMEBOT_UPDATE_TOKEN=example
        ```
        Segna la scadenza: dovremo distribuire il token sostitutivo.
        """
        XCTAssertTrue(SuggestedChoices.parse(reply).isEmpty)
    }

    func testOnlyTheChoiceListBesideThePromptBecomesAnswers() {
        let reply = """
        Riepilogo:
        1. Corretto il parser
        2. Aggiunti i test

        Quale preferisci?
        1. Commit ora
        2. Rivedi prima
        """
        XCTAssertEqual(SuggestedChoices.parse(reply), ["1) Commit ora", "2) Rivedi prima"])
        XCTAssertEqual(SuggestedChoices.parse("**Scegli una soluzione:**\n\nA) Prima\n\nB) Seconda"),
                       ["A) Prima", "B) Seconda"])
    }
}
