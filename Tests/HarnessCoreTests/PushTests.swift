@testable import HarnessCore
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What OneSignal would have been sent.
final class CapturingProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"n1"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class PushTests: XCTestCase {
    private func relay(limit: Int = 120) -> Relay {
        var config = RelayConfig(appId: "app-1", apiKey: "rest-key", secret: String(repeating: "s", count: 32))
        config.oneSignalURL = URL(string: "https://onesignal.test/notifications")!
        config.hourlyLimit = limit
        return Relay(config: config, session: CapturingProtocol.session())
    }

    override func setUp() {
        CapturingProtocol.requests = []
        CapturingProtocol.status = 200
    }

    func testTokensAreBoundToTheirSubscription() {
        let relay = relay()
        let token = relay.token(for: "3f2a6c1e-1111-2222-3333-444455556666")
        XCTAssertEqual(relay.subscription(of: token), "3f2a6c1e-1111-2222-3333-444455556666")
        // another subscription id under the same signature
        let parts = token.split(separator: ".")
        let forged = "v1.\(Data("other-subscription-id".utf8).base64EncodedString()).\(parts[2])"
        XCTAssertNil(relay.subscription(of: forged))
        XCTAssertNil(relay.subscription(of: token + "x"))
        var other = RelayConfig(appId: "a", apiKey: "k", secret: String(repeating: "t", count: 32))
        other.oneSignalURL = URL(string: "https://onesignal.test")!
        XCTAssertNil(Relay(config: other).subscription(of: token), "another relay's secret does not accept it")
        XCTAssertFalse(Relay.validSubscription("../x"))
    }

    func testRelayKeysLiveInTheirOwnFileAndKeepTheSecret() throws {
        let paths = DataPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)"))
        XCTAssertThrowsError(try RelayConfig.configure(["appId": "app-1"], paths: paths))
        try RelayConfig.configure(["appId": "app-1", "apiKey": "rest-1"], paths: paths)
        let first = try RelayConfig.load([:], paths: paths)
        XCTAssertEqual(first.appId, "app-1")
        XCTAssertEqual(first.secret.utf8.count, 64)
        let mode = try FileManager.default.attributesOfItem(atPath: RelayConfig.file(paths).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // a new key keeps the secret: the phones' tokens stay valid
        try RelayConfig.configure(["appId": "app-1", "apiKey": "rest-2"], paths: paths)
        let second = try RelayConfig.load([:], paths: paths)
        XCTAssertEqual(second.apiKey, "rest-2")
        XCTAssertEqual(second.secret, first.secret)
        // the environment wins over the file
        XCTAssertEqual(try RelayConfig.load(["ONESIGNAL_API_KEY": "from-env"], paths: paths).apiKey, "from-env")
    }

    func testNotifySendsOneSignalTheSubscriptionAndNoChatText() async throws {
        let relay = relay()
        let token = relay.token(for: "sub-00000001")
        let answer = try await relay.notify([
            "pushToken": .string(token), "title": ["en": "Sage needs your approval", "it": "Sage chiede un'approvazione"],
            "category": "approval", "data": ["kind": "approval", "threadId": "t1", "requestId": "r1"],
        ])
        XCTAssertEqual(answer.status, 200)
        let (request, body) = try XCTUnwrap(CapturingProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Key rest-key")
        let sent = try JSON.parse(body)
        XCTAssertEqual(sent["app_id"]?.string, "app-1")
        XCTAssertEqual(sent["include_subscription_ids"]?.array?.first?.string, "sub-00000001")
        XCTAssertEqual(sent["contents"]?["it"]?.string, "Sage chiede un'approvazione")
        XCTAssertEqual(sent["ios_category"]?.string, "approval")
        XCTAssertEqual(sent["data"]?["requestId"]?.string, "r1")

        let refused = try await relay.notify(["pushToken": "v1.bad.token", "title": ["en": "x"]])
        XCTAssertEqual(refused.status, 401)
    }

    func testNotifyIsRateLimitedPerToken() async throws {
        let relay = relay(limit: 2)
        let token = relay.token(for: "sub-00000002")
        let body: JSONObject = ["pushToken": .string(token), "title": ["en": "x"]]
        let first = try await relay.notify(body)
        let second = try await relay.notify(body)
        let third = try await relay.notify(body)
        XCTAssertEqual([first, second, third].map(\.status), [200, 200, 429])
    }

    func testEngineKeepsSubscriptionsPerDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = PushRegistry(paths: DataPaths(root: root))
        XCTAssertThrowsError(try registry.add(deviceId: "d1", body: ["pushToken": "t"]), "the relay is required")
        let added = try registry.add(deviceId: "d1", body: ["pushToken": "t1", "relayUrl": "https://relay.example", "kinds": ["approval", "nope"]])
        XCTAssertEqual(added["kinds"]?.array?.compactMap(\.string), ["approval"])
        _ = try registry.add(deviceId: "d2", body: ["pushToken": "t2", "relayUrl": "https://relay.example"])
        XCTAssertNil(PushRegistry.wire(added)["pushToken"], "the token never goes back out")
        XCTAssertFalse(try registry.remove(added["id"]!.string!, deviceId: "d2"), "a device removes only its own")
        registry.remove(deviceId: "d1")
        XCTAssertEqual(registry.list().compactMap { $0["deviceId"]?.string }, ["d2"])
    }

    func testPushSaysWhoAndWhatButNotTheChat() throws {
        let subscription: JSONObject = ["pushToken": "t", "relayUrl": "https://relay.example/", "kinds": ["approval", "done"]]
        let notification: JSONObject = ["kind": "approval", "botId": "b1", "botName": "Sage", "threadId": "t1",
                                        "title": "Sage needs approval", "body": "rm -rf /secret/project"]
        let (url, body) = try XCTUnwrap(PushRegistry.payload(subscription, notification: notification, requestId: "r1", server: "https://bot.example/"))
        XCTAssertEqual(url.absoluteString, "https://relay.example/v1/notify")
        XCTAssertFalse(body.serialized().contains("secret/project"))
        XCTAssertEqual(body["title"]?["it"]?.string, "Sage chiede un'approvazione")
        XCTAssertEqual(body["category"]?.string, "approval")
        XCTAssertEqual(body["data"]?["server"]?.string, "https://bot.example/")
        var question = notification
        question["kind"] = "question"
        XCTAssertNil(PushRegistry.payload(subscription, notification: question, requestId: nil, server: nil), "a kind turned off")
    }
}
