@testable import SwarmeBot
import CompanionCore
import SwiftUI
import XCTest

final class RemoteTests: XCTestCase {
    func testAttachmentTagsShowAsAPicture() {
        XCTAssertEqual(MessageRow.visibleText("<attached-image path=\"/a/b.jpg\"/>\nguarda"), "🖼\nguarda")
    }

    func testHexColors() {
        XCTAssertNotNil(Color(hex: "#1084FE"))
        XCTAssertNil(Color(hex: "blue"))
    }

    func testPairingLinkRoundTrip() throws {
        let link = RemotePairingLink(chatURL: "https://bot.example.it/srv1/deploy/", code: "ABCDE12345", name: "VPS")
        XCTAssertEqual(RemotePairingLink(url: try XCTUnwrap(link.url)), link)
    }

    func testServerConnectionKeepsThePrefix() throws {
        let server = PairedServer(id: "d1", name: "VPS", chatURL: "https://bot.example.it/srv1/deploy/", pairedAt: Date())
        let connection = try XCTUnwrap(server.connection)
        XCTAssertEqual(connection.host, "bot.example.it")
        XCTAssertEqual(connection.basePath, "/srv1/deploy")
    }
}
