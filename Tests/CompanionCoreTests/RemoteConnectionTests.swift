@testable import CompanionCore
import XCTest

// A remote engine behind a proxy: https, a path prefix, a device token
// (docs/plans/2026-10-16-bot-remoto.md §6–§7).
final class RemoteConnectionTests: XCTestCase {
    func testChatURLBecomesSchemeHostAndPrefix() throws {
        let connection = try XCTUnwrap(Connection.remote(chatURL: " https://bot.example.it/srv1/deploy/ "))
        XCTAssertEqual(connection.scheme, "https")
        XCTAssertEqual(connection.host, "bot.example.it")
        XCTAssertEqual(connection.port, 443)
        XCTAssertEqual(connection.basePath, "/srv1/deploy")
        XCTAssertEqual(connection.baseURL?.absoluteString, "https://bot.example.it/srv1/deploy")
    }

    func testExplicitPortAndRoot() throws {
        let connection = try XCTUnwrap(Connection.remote(chatURL: "https://10.0.4.12:8443"))
        XCTAssertEqual(connection.port, 8443)
        XCTAssertEqual(connection.basePath, "")
        XCTAssertEqual(connection.baseURL?.absoluteString, "https://10.0.4.12:8443")
    }

    func testRejectsWhatIsNotAChatURL() {
        XCTAssertNil(Connection.remote(chatURL: "ftp://bot.example.it"))
        XCTAssertNil(Connection.remote(chatURL: "https://bot.example.it/x?token=1"))
        XCTAssertNil(Connection.remote(chatURL: "https://user@bot.example.it/x"))
        XCTAssertNil(Connection.remote(chatURL: "bot.example.it"))
    }

    func testEveryRouteKeepsThePrefixAndTheToken() throws {
        let connection = try XCTUnwrap(Connection.remote(chatURL: "https://bot.example.it/srv1/deploy"))
        let client = CompanionClient(connection: connection, token: "tok")
        let request = try client.makeRequest("GET", "/api/events", query: [URLQueryItem(name: "screens", value: "off")])
        XCTAssertEqual(request.url?.absoluteString, "https://bot.example.it/srv1/deploy/api/events?screens=off")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let upload = try client.makeRequest("GET", "/api/attachments/a.png")
        XCTAssertEqual(upload.url?.path, "/srv1/deploy/api/attachments/a.png")
    }

    func testTheLocalConnectionIsUnchanged() throws {
        let local = Connection(name: "Questo Mac", host: "127.0.0.1", port: 8799)
        XCTAssertEqual(local.baseURL?.absoluteString, "http://127.0.0.1:8799")
        let request = try CompanionClient(connection: local, token: nil).makeRequest("GET", "/api/bots")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8799/api/bots")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testOlderSavesWithoutTheNewFieldsStillDecode() throws {
        let saved = #"{"id":"a","name":"Mac","host":"192.168.1.3","port":8810}"#
        let connection = try JSONDecoder().decode(Connection.self, from: Data(saved.utf8))
        XCTAssertNil(connection.scheme)
        XCTAssertEqual(connection.baseURL?.absoluteString, "http://192.168.1.3:8810")
    }
}

final class RemotePairingLinkTests: XCTestCase {
    func testRoundTripAndNoToken() throws {
        let link = RemotePairingLink(chatURL: "https://bot.example.it/srv1/deploy", code: "ABCD234567", name: "srv1 · deploy")
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(url.scheme, "swarmebot")
        XCTAssertFalse(url.absoluteString.contains("token"))
        XCTAssertEqual(RemotePairingLink(url: url), link)
    }

    func testRejectsForeignOrIncompleteLinks() {
        XCTAssertNil(RemotePairingLink(url: URL(string: "https://pair?url=https://a.b&code=X")!))
        XCTAssertNil(RemotePairingLink(url: URL(string: "swarmebot://pair?url=https://a.b")!))
        XCTAssertNil(RemotePairingLink(url: URL(string: "swarmebot://pair?url=ftp://a.b&code=X")!))
    }
}
