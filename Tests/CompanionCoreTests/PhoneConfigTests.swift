@testable import CompanionCore
import CryptoKit
import XCTest

final class PhoneConfigTests: XCTestCase {
    private let config = PhoneConfig(
        endpoints: [.init(name: "Local Endpoint", baseUrl: "http://192.168.1.5:4000/v1", apiKey: "sk-secret")],
        connectors: [.init(name: "GitHub", url: "https://mcp.example/mcp", auth: "headers", headers: ["Authorization": "Bearer x"]),
                     .init(name: "Notion", url: "https://notion.example/mcp", auth: "oauth", oauthClientId: "c1")])

    func testSealedWithAKeyOpensOnlyWithIt() throws {
        let key = SymmetricKey(size: .bits256)
        let blob = try config.sealed(with: key)
        XCTAssertFalse(String(decoding: blob, as: UTF8.self).contains("sk-secret"))
        XCTAssertEqual(try PhoneConfig.open(blob, with: key), config)
        XCTAssertThrowsError(try PhoneConfig.open(blob, with: SymmetricKey(size: .bits256)))
    }

    func testFileOpensOnlyWithThePassphrase() throws {
        let file = try config.file(passphrase: "una frase lunga")
        XCTAssertEqual(try PhoneConfig.open(file: file, passphrase: "una frase lunga"), config)
        XCTAssertThrowsError(try PhoneConfig.open(file: file, passphrase: "un'altra frase"))
        XCTAssertThrowsError(try PhoneConfig.open(file: Data("{}".utf8), passphrase: "x"))
    }

    func testLinkRoundTrip() throws {
        let link = PhoneConfigLink(host: "192.168.1.5", port: 50123, code: "abcdefghijklmnopqrstuvwx", key: Data(repeating: 7, count: 32))
        XCTAssertEqual(PhoneConfigLink(url: try XCTUnwrap(link.url)), link)
        XCTAssertNil(PhoneConfigLink(url: URL(string: "swarmebot://import?host=x&port=1&code=short&key=AA")!))
    }
}
