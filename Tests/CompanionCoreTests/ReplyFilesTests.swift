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
