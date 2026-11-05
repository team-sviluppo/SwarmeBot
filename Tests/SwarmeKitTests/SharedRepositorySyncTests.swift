import CompanionCore
@testable import SwarmeKit
import XCTest

@MainActor
final class SharedRepositorySyncTests: XCTestCase {
    private func connect(_ model: AppModel, to host: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedRepositorySyncStub.self]
        model.client = CompanionClient(connection: Connection(name: "Catalog test", host: host, port: 80),
                                       token: nil, session: URLSession(configuration: configuration))
    }

    func testDuplicateWarningsStayDismissedAcrossAutomaticSyncs() async throws {
        let model = AppModel()
        connect(model, to: "missing.invalid")
        await model.syncSharedRepositories(automatically: true)
        let warning = try XCTUnwrap(model.lastError)
        XCTAssertEqual(warning, tr("Cartella condivisa non disponibile. Le copie locali sono conservate. Controlla i percorsi in Impostazioni → Condivisione."))
        XCTAssertFalse(warning.contains("\n"), "both missing folders produce a single warning")
        model.lastError = nil
        await model.syncSharedRepositories(automatically: true)
        XCTAssertNil(model.lastError, "a reconnect must respect dismissal")
        await model.syncSharedRepositories()
        XCTAssertEqual(model.lastError, warning, "an explicit refresh always reports the current problem")
    }

    func testRecoveryRearmsWarningsAndKeepsUnrelatedErrors() async throws {
        let model = AppModel()
        connect(model, to: "missing.invalid")
        await model.syncSharedRepositories(automatically: true)
        let warning = try XCTUnwrap(model.lastError)
        model.lastError = "An unrelated action failed"
        await model.syncSharedRepositories(automatically: true)
        XCTAssertEqual(model.lastError, "An unrelated action failed")
        connect(model, to: "healthy.invalid")
        await model.syncSharedRepositories(automatically: true)
        XCTAssertEqual(model.lastError, "An unrelated action failed")
        model.lastError = nil
        connect(model, to: "missing.invalid")
        await model.syncSharedRepositories(automatically: true)
        XCTAssertEqual(model.lastError, warning, "a new outage after recovery must be reported")
        connect(model, to: "healthy.invalid")
        await model.syncSharedRepositories(automatically: true)
        XCTAssertNil(model.lastError, "recovery removes a warning that is still visible")
    }

    func testChangedProblemsAndNetworkFailuresAreReported() async {
        let model = AppModel()
        connect(model, to: "missing.invalid")
        await model.syncSharedRepositories(automatically: true)
        model.lastError = nil
        connect(model, to: "invalid.invalid")
        await model.syncSharedRepositories(automatically: true)
        XCTAssertEqual(model.lastError, "invalid catalog")
        model.lastError = nil
        connect(model, to: "offline.invalid")
        await model.syncSharedRepositories(automatically: true)
        XCTAssertNotNil(model.lastError, "transport errors must not be swallowed")
    }
}

private final class SharedRepositorySyncStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "offline.invalid" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body: String
        if request.url?.path == "/api/shared-repositories/sync" {
            switch request.url?.host {
            case "missing.invalid":
                body = #"{"problems":["shared folder is unavailable; local copies have been kept","shared folder is unavailable; local copies have been kept"]}"#
            case "invalid.invalid": body = #"{"problems":["invalid catalog"]}"#
            default: body = #"{"problems":[]}"#
            }
        } else {
            body = #"{"connectors":[]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
