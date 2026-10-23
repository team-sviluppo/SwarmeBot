@testable import SwarmeBot
import UIKit
import XCTest

final class DocumentTests: XCTestCase {
    private func pdf(_ text: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 300)).pdfData { context in
            context.beginPage()
            if let text { (text as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)]) }
        }
        try data.write(to: url)
        return url
    }

    func testAPDFBecomesItsTextInThePrompt() throws {
        let document = try AttachedDocument.pdf(at: pdf("Fattura 42 del cliente"))
        XCTAssertTrue(document.text.contains("Fattura 42"))
        XCTAssertFalse(document.truncated)
        XCTAssertTrue(document.promptBlock.hasPrefix("<attached-file name=\"\(document.name)\">\n"))
        XCTAssertTrue(document.promptBlock.hasSuffix("\n</attached-file>"))

        let message = LocalMessage(id: "m", botId: "b", role: .user, text: "Riassumi", at: Date(), documents: [document])
        XCTAssertEqual(promptText(message), document.promptBlock + "\n\nRiassumi")
        XCTAssertEqual(AttachedDocument.displayed(promptText(message)), "📄 \(document.name)\nRiassumi")
    }

    func testAPDFWithoutTextIsRefused() throws {
        XCTAssertThrowsError(try AttachedDocument.pdf(at: pdf(nil)))
    }
}
