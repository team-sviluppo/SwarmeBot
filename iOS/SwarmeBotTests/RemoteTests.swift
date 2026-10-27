@testable import SwarmeBot
import CompanionCore
import SwiftUI
import XCTest

final class RemoteTests: XCTestCase {
    func testAttachmentTagsShowAsAPicture() {
        XCTAssertEqual(MessageRow.visibleText("<attached-image path=\"/a/b.jpg\"/>\nguarda"), "🖼\nguarda")
    }

    func testBotsWearThePaletteColours() {
        XCTAssertTrue(SwarmePalette.hex("red").hasPrefix("#"))
        var bot = LocalBot(id: "b", name: "B", kind: .apple, createdAt: Date())
        XCTAssertEqual(bot.paletteColor, "blue")
        bot.color = "#1084FE"  // saved before the palette
        XCTAssertEqual(bot.paletteColor, "blue")
        bot.color = "red"
        XCTAssertEqual(bot.paletteColor, "red")
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
    func testTheEnginesDataSitsBesideAps() {
        let userInfo: [AnyHashable: Any] = ["aps": ["category": "approval"], "kind": "approval", "threadId": "t1", "requestId": "r1",
                                            "server": "https://x/"]
        let data = PushManager.data(userInfo)
        XCTAssertEqual(data["threadId"] as? String, "t1")
        XCTAssertEqual(data["requestId"] as? String, "r1")
        XCTAssertNil(data["aps"])
        XCTAssertTrue(PushManager.data([:]).isEmpty)
    }

    func testTheApnsEnvironmentComesFromTheProvisioningProfile() {
        func profile(_ aps: String) -> Data {
            // a profile is a signed blob with the plist inside it
            Data("\u{1}\u{2}garbage<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict><key>aps-environment</key><string>\(aps)</string></dict></dict></plist>\u{3}tail".utf8)
        }
        XCTAssertEqual(PushManager.environment(provisioningProfile: profile("development")), "sandbox")
        XCTAssertEqual(PushManager.environment(provisioningProfile: profile("production")), "production")
        XCTAssertEqual(PushManager.environment(provisioningProfile: nil), "production", "no profile: the App Store or TestFlight")
        XCTAssertEqual(PushManager.environment(provisioningProfile: Data("nothing here".utf8)), "production")
    }
}
