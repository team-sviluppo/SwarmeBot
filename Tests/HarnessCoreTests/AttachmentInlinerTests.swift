@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

final class AttachmentInlinerTests: XCTestCase {
    private func temporaryFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testPlainTextStaysAString() {
        XCTAssertEqual(AttachmentInliner.content("ciao"), .string("ciao"))
    }

    func testTextFileIsInlinedAndImageBecomesAPart() throws {
        let notes = try temporaryFile("note \"uno\".md", Data("# Titolo\nriga".utf8))
        let image = try temporaryFile("foto.png", Data([0x89, 0x50, 0x4E, 0x47]))
        let escaped = notes.path.replacingOccurrences(of: "\"", with: "&quot;")
        let text = "leggi\n\n<attached-file path=\"\(escaped)\" />\n\n<attached-image path=\"\(image.path)\" />"
        let parts = try XCTUnwrap(AttachmentInliner.content(text).array)
        XCTAssertEqual(parts.count, 2)
        let body = try XCTUnwrap(parts[0]["text"]?.string)
        XCTAssertTrue(body.contains("<attached-file name=\"note \"uno\".md\">\n# Titolo\nriga\n</attached-file>"))
        XCTAssertTrue(body.contains("[immagine allegata: foto.png]"))
        XCTAssertEqual(parts[1]["type"]?.string, "image_url")
        XCTAssertTrue(parts[1]["image_url"]?["url"]?.string?.hasPrefix("data:image/png;base64,") == true)
    }

    func testBinaryFileIsNamedNotSent() throws {
        let zip = try temporaryFile("archivio.zip", Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]))
        let parts = try XCTUnwrap(AttachmentInliner.content("<attached-file path=\"\(zip.path)\" />").array)
        XCTAssertEqual(parts[0]["text"]?.string, "[file allegato in un formato che questo modello non può leggere: archivio.zip]")
        XCTAssertFalse(AttachmentInliner.isInlinable(zip.path))
    }

    func testHistoryKeepsOnlyLabels() {
        let text = "guarda <attached-image path=\"/x/a.png\" /> e <attached-file path=\"/x/b.txt\" />"
        XCTAssertEqual(AttachmentInliner.label(text), "guarda [immagine allegata: a.png] e [file allegato: b.txt]")
    }
}
