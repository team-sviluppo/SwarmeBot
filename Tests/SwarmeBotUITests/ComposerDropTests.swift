import AppKit
@testable import SwarmeBotUI
import UniformTypeIdentifiers
import XCTest

final class ComposerDropTests: XCTestCase {
    private func bitmap(_ type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: type, properties: [:])!
    }

    func testAnImageEnginesTakeGoesUpAsIs() throws {
        let png = bitmap(.png)
        let result = try XCTUnwrap(ComposerImage.normalize(png))
        XCTAssertEqual(result.mime, "image/png")
        XCTAssertEqual(result.data, png)
        let jpeg = bitmap(.jpeg)
        XCTAssertEqual(ComposerImage.normalize(jpeg, type: .jpeg)?.mime, "image/jpeg")
    }

    func testOtherImagesAreConvertedToPNG() throws {
        let result = try XCTUnwrap(ComposerImage.normalize(bitmap(.tiff)))
        XCTAssertEqual(result.mime, "image/png")
        XCTAssertEqual(Array(result.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testBytesThatAreNotAnImageAreRefused() {
        XCTAssertNil(ComposerImage.normalize(Data("not an image".utf8)))
        XCTAssertNil(ComposerImage.normalize(Data(count: ComposerImage.maxBytes + 1), type: .png))
    }

    func testAPasteboardYieldsFilesBeforeImagesAndNothingForText() throws {
        let board = NSPasteboard(name: .init("swarme-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        board.clearContents()
        board.setString("just text", forType: .string)
        XCTAssertNil(ComposerImage.attachments(on: board))

        board.clearContents()
        board.setData(bitmap(.tiff), forType: .tiff)
        let image = try XCTUnwrap(ComposerImage.attachments(on: board))
        XCTAssertTrue(image.files.isEmpty)
        XCTAssertNotNil(image.image)

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drop.png")
        board.clearContents()
        board.writeObjects([url as NSURL])
        let files = try XCTUnwrap(ComposerImage.attachments(on: board))
        XCTAssertEqual(files.files.map(\.path), [url.path])
        XCTAssertNil(files.image)
    }
}
