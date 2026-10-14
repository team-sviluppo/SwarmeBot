import CoreGraphics
import CoreText
@testable import HarnessCore
import XCTest

final class LibraryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A PDF with one page per string; `asPicture` draws the text as a bitmap,
    /// like a scan, so PDFKit finds nothing on it.
    private func makePDF(_ pages: [String], asPicture: Bool = false, at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            if asPicture {
                let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1190, height: 1684, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: 1190, height: 1684))
                bitmap.scaleBy(x: 2, y: 2)
                draw(text, in: bitmap)
                context.draw(try XCTUnwrap(bitmap.makeImage()), in: box)
            } else {
                draw(text, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func draw(_ text: String, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 50, y: 50, width: 495, height: 742), transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    func testPDFTextBecomesMarkdownWithPages() throws {
        let url = try temporaryDirectory().appendingPathComponent("contratto.pdf")
        try makePDF(["Il canone mensile del servizio è di trenta euro.", "Il contratto si disdice con sessanta giorni di preavviso."], at: url)
        let converted = try LibraryConversion.convert(url, name: "contratto.pdf")
        XCTAssertEqual(converted.pages, 2)
        XCTAssertEqual(converted.ocrPages, 0)
        XCTAssertTrue(converted.markdown.hasPrefix("# contratto.pdf\n\n## Page 1\n\nIl canone mensile"))
        XCTAssertTrue(converted.markdown.contains("## Page 2\n\nIl contratto si disdice"))
        XCTAssertEqual(converted.passages.map(\.page), [1, 2])
    }

    func testScannedPageIsReadWithOCR() throws {
        let url = try temporaryDirectory().appendingPathComponent("scansione.pdf")
        try makePDF(["Fattura numero 4512 del fornitore Rossi"], asPicture: true, at: url)
        let converted = try LibraryConversion.convert(url, name: "scansione.pdf")
        XCTAssertEqual(converted.ocrPages, 1)
        XCTAssertTrue(converted.body.contains("4512"), converted.body)
        XCTAssertTrue(converted.body.localizedCaseInsensitiveContains("Rossi"), converted.body)
    }

    func testPassagesStayUnderTheEmbeddingWindow() {
        let paragraph = String(repeating: "parola ", count: 400)
        let parts = LibraryConversion.split("breve\n\n\(paragraph)\n\nfine")
        XCTAssertTrue(parts.allSatisfy { $0.count <= LibraryConversion.passageChars }, parts.map(\.count).description)
        XCTAssertTrue(parts.first?.hasPrefix("breve\n\nparola") == true)
        XCTAssertTrue(parts.last?.hasSuffix("parola\n\nfine") == true, "a paragraph's tail packs with what follows")
        XCTAssertEqual(parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).count, 402)
    }

    func testRetrievalPrefersTheMatchingPassageAndKeepsPageOrder() {
        let passages = [
            LibraryPassage(page: 1, text: "Il gatto dorme sul divano tutto il pomeriggio.", vector: nil),
            LibraryPassage(page: 2, text: "Il canone mensile dell'abbonamento è di trenta euro, IVA esclusa.", vector: nil),
            LibraryPassage(page: 3, text: "La sede legale si trova a Milano in via Roma.", vector: nil),
        ]
        let one = LibraryConversion.tokens(passages[1].text)
        let picked = LibraryRetrieval.select("Quanto costa il canone mensile?", [("contratto.pdf", passages)], budget: one)
        XCTAssertEqual(picked.map(\.passage.page), [2])
        let all = LibraryRetrieval.select("canone", [("contratto.pdf", passages)], budget: 10_000)
        XCTAssertEqual(all.map(\.passage.page), [1, 2, 3])
    }

    @MainActor
    func testImportThenPromptByEngine() async throws {
        let root = try temporaryDirectory()
        let library = Library(paths: DataPaths(root: root))
        let source = root.appendingPathComponent("listino.md")
        try Data("# Listino\n\nIl piano Pro costa 49 euro al mese.".utf8).write(to: source)
        let doc = try library.add("bot1", from: source)
        XCTAssertEqual(library.docs("bot1").first?.status, "processing")
        for _ in 0..<100 where library.docs("bot1").first?.status == "processing" { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(library.docs("bot1").first?.status, "ready")
        XCTAssertEqual(Library.mode("localEndpoint"), .inline)
        XCTAssertEqual(Library.mode("claudeAgent"), .paths)

        let inline = library.prompt("bot1", off: [], mode: .inline, message: "quanto costa?")
        XCTAssertTrue(inline.contains("<document name=\"listino.md\""))
        XCTAssertTrue(inline.contains("Il piano Pro costa 49 euro al mese."))

        let paths = library.prompt("bot1", off: [], mode: .paths, message: "")
        XCTAssertTrue(paths.contains(library.textFile("bot1", doc).path))
        XCTAssertFalse(paths.contains("49 euro"))

        XCTAssertEqual(library.prompt("bot1", off: [doc.id], mode: .inline, message: ""), "")
        XCTAssertTrue(library.remove("bot1", doc.id))
        XCTAssertTrue(library.docs("bot1").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.originalFile("bot1", doc).path))
    }

    @MainActor
    func testOnlyPDFAndTextAreAccepted() throws {
        let root = try temporaryDirectory()
        let library = Library(paths: DataPaths(root: root))
        let source = root.appendingPathComponent("foglio.xlsx")
        try Data([0x50, 0x4B]).write(to: source)
        XCTAssertThrowsError(try library.add("bot1", from: source))
    }
}
