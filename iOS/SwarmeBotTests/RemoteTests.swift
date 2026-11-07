@testable import SwarmeBot
import CompanionCore
import SwiftUI
import XCTest

final class RemoteTests: XCTestCase {
    @MainActor
    func testToolVisibilityUpdatesFromTheServerAndSurvivesAFailedSave() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolVisibilityStub.self]
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        let server = PairedServer(id: UUID().uuidString, name: "Test", chatURL: "https://test.example/prefix/", pairedAt: Date())
        let session = RemoteSession(server: server, session: http)
        defer { session.stop() }

        await session.setShowToolCalls("bot", false)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(session.state.bot("bot")?.showsToolCalls, false)
        let messages = try JSONDecoder().decode([Message].self, from: Data("""
        [{"id":"tool","role":"bot","kind":"activity","at":1,"tool":{"name":"Read"}},
         {"id":"permission","role":"bot","kind":"options","at":2},
         {"id":"reply","role":"bot","kind":"text","at":3,"text":"Done"}]
        """.utf8))
        XCTAssertEqual(session.state.chatMessages(messages, forThread: "thread").map(\.id), ["permission", "reply"])

        // The stub rejects this save. Keep the last confirmed value and show the error.
        await session.setShowToolCalls("reject", true)
        XCTAssertNotNil(session.lastError)
        XCTAssertEqual(session.state.bot("bot")?.showsToolCalls, false)

        session.lastError = nil
        await session.setShowToolCalls("bot", true)
        XCTAssertNil(session.lastError)
        XCTAssertEqual(session.state.bot("bot")?.showsToolCalls, true)
        XCTAssertEqual(session.state.chatMessages(messages, forThread: "thread"), messages)
    }

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

/// Respond from the actual PATCH body so this also checks the request's route and flag.
private final class ToolVisibilityStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let show = fields?["showToolCalls"] as? Bool
        let valid = request.httpMethod == "PATCH" && request.url?.path == "/prefix/api/bots/bot" && fields?.count == 1 && show != nil
        let json = valid ? """
        {"bot":{"id":"bot","threadId":"thread","name":"Bot","title":"","description":"",
        "notifications":true,"color":"blue","unread":false,"modelSelection":{"instanceId":"","model":""},
        "createdAt":1,"showToolCalls":\(show == true ? "true" : "false")}}
        """ : "{\"error\":\"save rejected\"}"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 500, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
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
