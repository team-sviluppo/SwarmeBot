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

final class PushDataTests: XCTestCase {
    func testOneSignalDataIsReadFromCustomA() {
        let userInfo: [AnyHashable: Any] = ["aps": ["category": "approval"],
                                            "custom": ["i": "n1", "a": ["threadId": "t1", "requestId": "r1", "server": "https://x/"]]]
        let data = PushManager.data(userInfo)
        XCTAssertEqual(data["threadId"] as? String, "t1")
        XCTAssertEqual(data["requestId"] as? String, "r1")
        XCTAssertTrue(PushManager.data([:]).isEmpty)
    }
}
