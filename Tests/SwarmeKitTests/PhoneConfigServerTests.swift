import CompanionCore
@testable import SwarmeKit
import XCTest

final class PhoneConfigServerTests: XCTestCase {
    func testServesOnceOnTheLocalNetwork() async throws {
        guard PhoneConfigServer.localAddress() != nil else { throw XCTSkip("no local network address") }
        let config = PhoneConfig(endpoints: [.init(name: "E", baseUrl: "http://10.0.0.2/v1", apiKey: "k")])
        let server = PhoneConfigServer()
        let delivered = expectation(description: "delivered")
        server.onFinish = { if $0 { delivered.fulfill() } }
        let link = try await server.start(config)
        let fetched = try await link.fetch()
        XCTAssertEqual(fetched, config)
        await fulfillment(of: [delivered], timeout: 5)
        do {
            _ = try await link.fetch()
            XCTFail("a second fetch must fail")
        } catch {}
        var wrong = link
        wrong.code = String(repeating: "x", count: 24)
        do {
            _ = try await wrong.fetch()
            XCTFail("a wrong code must fail")
        } catch {}
    }
}
