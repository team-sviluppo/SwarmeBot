@testable import HarnessCore
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What SNS (or the relay) would have been sent, and what the fake answers.
final class CapturingProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []
    /// The answer to a request: status and body. Nil answers like SNS would to a good call.
    nonisolated(unsafe) static var handler: ((URLRequest, [String: String]) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static let endpointArn = "arn:aws:sns:eu-south-1:123456789012:endpoint/APNS/swarmebot-ios/11111111-2222-3333-4444-555555555555"

    /// The form fields of a body.
    static func form(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[String(parts[0]).removingPercentEncoding ?? ""] = String(parts[1]).removingPercentEncoding ?? ""
        }
        return fields
    }

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
        let fields = Self.form(body)
        var (status, text) = Self.handler?(request, fields) ?? (200, "")
        if text.isEmpty {
            switch fields["Action"] {
            case "CreatePlatformEndpoint":
                // an endpoint of the application asked for
                let arn = (fields["PlatformApplicationArn"] ?? "").replacingOccurrences(of: ":app/", with: ":endpoint/") + "/11111111-2222-3333-4444-555555555555"
                text = "<CreatePlatformEndpointResponse><CreatePlatformEndpointResult><EndpointArn>\(arn)</EndpointArn></CreatePlatformEndpointResult></CreatePlatformEndpointResponse>"
            case "Publish":
                text = "<PublishResponse><PublishResult><MessageId>m1</MessageId></PublishResult></PublishResponse>"
            default:
                text = "<Response/>"
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> (Int, String) {
        (status, "<ErrorResponse><Error><Type>Sender</Type><Code>\(code)</Code><Message>\(message)</Message></Error></ErrorResponse>")
    }
}

@MainActor
final class PushTests: XCTestCase {
    static let production = "arn:aws:sns:eu-south-1:123456789012:app/APNS/swarmebot-ios"
    static let sandbox = "arn:aws:sns:eu-south-1:123456789012:app/APNS_SANDBOX/swarmebot-ios-sandbox"
    static let deviceToken = String(repeating: "ab12", count: 16)

    private func relay(limit: Int = 120, registerLimit: Int = 300) -> Relay {
        var config = RelayConfig(appArn: Self.production, sandboxAppArn: Self.sandbox, accessKeyId: "AKIATEST", secretAccessKey: "aws-secret",
                                 secret: String(repeating: "s", count: 32))
        config.snsURL = URL(string: "https://sns.test/")!
        config.hourlyLimit = limit
        config.registerLimit = registerLimit
        return Relay(config: config, session: CapturingProtocol.session())
    }

    override func setUp() {
        CapturingProtocol.requests = []
        CapturingProtocol.handler = nil
    }

    func testSigV4MatchesAWSTestVector() {
        // "get-vanilla" of AWS's Signature Version 4 test suite
        let header = AWSSigV4.authorization(
            method: "GET", path: "/", query: "", headers: [("host", "example.amazonaws.com"), ("x-amz-date", "20150830T123600Z")], body: Data(),
            credentials: AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            region: "us-east-1", service: "service", date: Date(timeIntervalSince1970: 1_440_938_160))
        XCTAssertEqual(header, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, "
            + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        XCTAssertEqual(AWSSigV4.percentEncode("a b/é~-_."), "a%20b%2F%C3%A9~-_.")
    }

    func testTokensAreBoundToTheirEndpointEnvironmentAndLanguage() {
        let relay = relay()
        let token = relay.token(environment: .sandbox, language: "it", endpointId: "11111111-2222-3333-4444-555555555555")
        let parsed = relay.parse(token: token)
        XCTAssertEqual(parsed?.environment, .sandbox)
        XCTAssertEqual(parsed?.language, "it")
        XCTAssertEqual(parsed?.endpointId, "11111111-2222-3333-4444-555555555555")
        // the same signature under another endpoint, environment or language
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertNil(relay.parse(token: "v2.\(parts[1]).\(parts[2]).99999999-2222-3333-4444-555555555555.\(parts[4])"))
        XCTAssertNil(relay.parse(token: "v2.p.\(parts[2]).\(parts[3]).\(parts[4])"))
        XCTAssertNil(relay.parse(token: "v2.\(parts[1]).en.\(parts[3]).\(parts[4])"))
        XCTAssertNil(relay.parse(token: token + "x"))
        XCTAssertNil(relay.parse(token: "v1.c3ViLTAwMDAwMDAx.abc"), "an OneSignal-era token is not ours any more")
        var other = RelayConfig(appArn: Self.production, accessKeyId: "a", secretAccessKey: "k", secret: String(repeating: "t", count: 32))
        other.snsURL = URL(string: "https://sns.test")!
        XCTAssertNil(Relay(config: other).parse(token: token), "another relay's secret does not accept it")
        XCTAssertFalse(Relay.validDeviceToken("../x"))
        XCTAssertTrue(Relay.validDeviceToken(Self.deviceToken))
    }

    func testRelayKeysLiveInTheirOwnFileAndKeepTheSecret() throws {
        let paths = DataPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)"))
        XCTAssertThrowsError(try RelayConfig.configure(["appArn": .string(Self.production)], paths: paths), "the AWS keys are required")
        XCTAssertThrowsError(try RelayConfig.configure(["accessKeyId": "AKIA1", "secretAccessKey": "s1"], paths: paths), "an app is required")
        XCTAssertThrowsError(try RelayConfig.configure(["accessKeyId": "AKIA1", "secretAccessKey": "s1", "appArn": .string(Self.sandbox)], paths: paths),
                             "a sandbox ARN is not the production one")
        XCTAssertThrowsError(try RelayConfig.configure(["accessKeyId": "AKIA1", "secretAccessKey": "s1", "appArn": .string(Self.production),
                                                         "sandboxAppArn": "arn:aws:sns:eu-west-1:123456789012:app/APNS_SANDBOX/x"], paths: paths),
                             "one region only")
        try RelayConfig.configure(["accessKeyId": "AKIA1", "secretAccessKey": "s1", "appArn": .string(Self.production),
                                   "sandboxAppArn": .string(Self.sandbox)], paths: paths)
        let first = try RelayConfig.load([:], paths: paths)
        XCTAssertEqual(first.accessKeyId, "AKIA1")
        XCTAssertEqual(first.region, "eu-south-1")
        XCTAssertEqual(first.secret.utf8.count, 64)
        let mode = try FileManager.default.attributesOfItem(atPath: RelayConfig.file(paths).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // new keys keep the secret: the phones' tokens stay valid
        try RelayConfig.configure(["accessKeyId": "AKIA2", "secretAccessKey": "s2", "appArn": .string(Self.production)], paths: paths)
        let second = try RelayConfig.load([:], paths: paths)
        XCTAssertEqual(second.secretAccessKey, "s2")
        XCTAssertEqual(second.secret, first.secret)
        XCTAssertNil(second.appArn(for: .sandbox))
        // the environment wins over the file
        XCTAssertEqual(try RelayConfig.load(["AWS_SECRET_ACCESS_KEY": "from-env"], paths: paths).secretAccessKey, "from-env")
        // an old OneSignal file is not a configuration
        try FileIO.writeAtomic(JSON.object(["appId": "x", "apiKey": "y", "secret": .string(first.secret)]).data, to: RelayConfig.file(paths), mode: 0o600)
        XCTAssertThrowsError(try RelayConfig.load([:], paths: paths))
    }

    func testRegisterCreatesTheEndpointAndSignsTheCall() async throws {
        let relay = relay()
        let answer = try await relay.register(["deviceToken": .string(Self.deviceToken), "environment": "sandbox", "language": "it"])
        XCTAssertEqual(answer.status, 201)
        let (request, body) = try XCTUnwrap(CapturingProtocol.requests.first)
        let form = CapturingProtocol.form(body)
        XCTAssertEqual(form["Action"], "CreatePlatformEndpoint")
        XCTAssertEqual(form["PlatformApplicationArn"], Self.sandbox, "a development build uses the sandbox application")
        XCTAssertEqual(form["Token"], Self.deviceToken)
        XCTAssertTrue(try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization")).hasPrefix("AWS4-HMAC-SHA256 Credential=AKIATEST/"))
        XCTAssertTrue(try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization")).contains("/eu-south-1/sns/aws4_request"))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("aws-secret"), "the secret key is never sent")
        let token = try XCTUnwrap(try JSON.parse(answer.body)["pushToken"]?.string)
        // the endpoint of the sandbox application is not the production one's
        XCTAssertEqual(relay.parse(token: token)?.environment, .sandbox)
        XCTAssertEqual(relay.parse(token: token)?.language, "it")

        let refused = try await relay.register(["deviceToken": "not hex"])
        XCTAssertEqual(refused.status, 400)
        let unknown = try await relay.register(["deviceToken": .string(Self.deviceToken), "environment": "moon"])
        XCTAssertEqual(unknown.status, 400)
    }

    func testRegisterTurnsADisabledEndpointBackOn() async throws {
        CapturingProtocol.handler = { _, form in
            form["Action"] == "CreatePlatformEndpoint"
                ? CapturingProtocol.error(400, "InvalidParameter", "Invalid parameter: Token Reason: Endpoint \(CapturingProtocol.endpointArn) already exists with the same Token, but different attributes.")
                : (200, "")
        }
        let relay = relay()
        let answer = try await relay.register(["deviceToken": .string(Self.deviceToken)])
        XCTAssertEqual(answer.status, 201)
        let forms = CapturingProtocol.requests.map { CapturingProtocol.form($0.1) }
        XCTAssertEqual(forms.map { $0["Action"] }, ["CreatePlatformEndpoint", "SetEndpointAttributes"])
        XCTAssertEqual(forms[1]["EndpointArn"], CapturingProtocol.endpointArn)
        XCTAssertEqual(forms[1]["Attributes.entry.1.key"], "Enabled")
        XCTAssertEqual(forms[1]["Attributes.entry.1.value"], "true")
        XCTAssertEqual(relay.parse(token: try XCTUnwrap(try JSON.parse(answer.body)["pushToken"]?.string))?.endpointId,
                       "11111111-2222-3333-4444-555555555555")
    }

    func testRegisterIsRateLimitedForTheWholeRelay() async throws {
        let relay = relay(registerLimit: 1)
        let first = try await relay.register(["deviceToken": .string(Self.deviceToken)])
        let second = try await relay.register(["deviceToken": .string(Self.deviceToken)])
        XCTAssertEqual([first, second].map(\.status), [201, 429])
    }

    func testNotifyPublishesToTheEndpointInThePhonesLanguageAndWithNoChatText() async throws {
        let relay = relay()
        let token = relay.token(environment: .production, language: "it", endpointId: "11111111-2222-3333-4444-555555555555")
        let answer = try await relay.notify([
            "pushToken": .string(token), "title": ["en": "Sage needs your approval", "it": "Sage chiede un'approvazione"],
            "category": "approval", "data": ["kind": "approval", "threadId": "t1", "requestId": "r1", "aps": "ignored"],
        ])
        XCTAssertEqual(answer.status, 200)
        let form = CapturingProtocol.form(try XCTUnwrap(CapturingProtocol.requests.first).1)
        XCTAssertEqual(form["Action"], "Publish")
        XCTAssertEqual(form["TargetArn"], CapturingProtocol.endpointArn)
        XCTAssertEqual(form["MessageStructure"], "json")
        let message = try JSON.parse(Data(try XCTUnwrap(form["Message"]).utf8))
        let apns = try JSON.parse(Data(try XCTUnwrap(message["APNS"]?.string).utf8))
        XCTAssertNil(message["APNS_SANDBOX"])
        XCTAssertEqual(apns["aps"]?["alert"]?["body"]?.string, "Sage chiede un'approvazione")
        XCTAssertEqual(apns["aps"]?["category"]?.string, "approval")
        XCTAssertEqual(apns["aps"]?["sound"]?.string, "default")
        XCTAssertEqual(apns["requestId"]?.string, "r1", "the ids sit beside aps, for the app to open the chat")
        XCTAssertNil(apns["aps"]?["aps"], "the engine's data cannot overwrite aps")

        // another language, a sandbox endpoint
        let english = relay.token(environment: .sandbox, language: "en", endpointId: "11111111-2222-3333-4444-555555555555")
        _ = try await relay.notify(["pushToken": .string(english), "title": ["en": "Sage finished", "it": "Sage ha finito"]])
        let sandboxForm = CapturingProtocol.form(try XCTUnwrap(CapturingProtocol.requests.last).1)
        XCTAssertEqual(sandboxForm["TargetArn"], "arn:aws:sns:eu-south-1:123456789012:endpoint/APNS_SANDBOX/swarmebot-ios-sandbox/11111111-2222-3333-4444-555555555555")
        let sandboxMessage = try JSON.parse(Data(try XCTUnwrap(sandboxForm["Message"]).utf8))
        XCTAssertNotNil(sandboxMessage["APNS_SANDBOX"])
        XCTAssertTrue(try XCTUnwrap(sandboxMessage["APNS_SANDBOX"]?.string).contains("Sage finished"))

        let refused = try await relay.notify(["pushToken": "v2.bad.token", "title": ["en": "x"]])
        XCTAssertEqual(refused.status, 401)
        let untitled = try await relay.notify(["pushToken": .string(token), "title": ["it": "x"]])
        XCTAssertEqual(untitled.status, 400)
    }

    func testNotifyTellsAGoneEndpointFromAnAWSFailure() async throws {
        let relay = relay()
        let token = relay.token(environment: .production, language: "en", endpointId: "11111111-2222-3333-4444-555555555555")
        let body: JSONObject = ["pushToken": .string(token), "title": ["en": "x"]]
        CapturingProtocol.handler = { _, _ in CapturingProtocol.error(400, "EndpointDisabled", "Endpoint is disabled") }
        let disabled = try await relay.notify(body)
        XCTAssertEqual(disabled.status, 410, "the engine drops the subscription, the phone registers again")
        CapturingProtocol.handler = { _, _ in CapturingProtocol.error(403, "InvalidClientTokenId", "The security token included in the request is invalid.") }
        let rejected = try await relay.notify(body)
        XCTAssertEqual(rejected.status, 502)
    }

    func testNotifyIsRateLimitedPerToken() async throws {
        let relay = relay(limit: 2)
        let token = relay.token(environment: .production, language: "en", endpointId: "11111111-2222-3333-4444-555555555555")
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

    func testEngineDropsASubscriptionTheRelayDoesNotKnow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = PushRegistry(paths: DataPaths(root: root))
        _ = try registry.add(deviceId: "d1", body: ["pushToken": "v1.old.token", "relayUrl": "https://relay.example"])
        _ = try registry.add(deviceId: "d1", body: ["pushToken": "v2.good.token", "relayUrl": "https://relay.example"])
        CapturingProtocol.handler = { request, _ in (request.url?.host == "relay.example" ? 401 : 200, "{}") }
        // one notification goes to both; both answer 401
        registry.send(["kind": "done", "botId": "b1", "botName": "Sage", "threadId": "t1"], requestId: nil, server: nil, session: CapturingProtocol.session())
        for _ in 0..<50 where !registry.list().isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(registry.list().isEmpty, "a 401 from the relay drops the subscription")

        _ = try registry.add(deviceId: "d1", body: ["pushToken": "v2.again.token", "relayUrl": "https://relay.example"])
        CapturingProtocol.handler = { _, _ in (500, "{}") }
        registry.send(["kind": "done", "botId": "b1", "botName": "Sage", "threadId": "t1"], requestId: nil, server: nil, session: CapturingProtocol.session())
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(registry.list().count, 1, "a relay that is merely down costs a push, not the subscription")
    }
}
