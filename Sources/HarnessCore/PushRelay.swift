// The push relay (docs/plans/2026-10-22-app-ios.md §6.5): the only holder of
// the AWS credentials. Phones register their APNs device token and get a
// `pushToken`; engines post notifications with that token, and the relay
// publishes them to Amazon SNS, which talks to APNs. The relay keeps no
// database: a token names the phone's SNS endpoint, signed with an HMAC of
// the relay's secret, so it can only ever push to the phone that registered.
//
//   POST /v1/register {deviceToken, environment?, language?}   → {pushToken}
//   POST /v1/notify   {pushToken, title{en,it}, category?, data?} → {ok}
//   GET  /health
//
// The APNs key (.p8) lives in AWS, in the SNS platform applications; the
// relay only has an IAM user that may create endpoints and publish to them.
//
// Open source on purpose: anyone may run their own relay with their own AWS
// account — which then also needs their own build of the iOS app, because
// Apple's pushes are bound to the app that receives them.
//
// It runs as `swarme-push-relay`, or as `swarme-harness push-relay` next to a
// remote engine (the same binary, so it is installed and updated with it).
// Its keys come from the environment or from `push-relay.json` (0600) in the
// engine's data folder, never from the engine's secrets: those reach the
// coding agents' processes.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Which APNs the phone's build talks to: a build signed for development
/// gets sandbox tokens, TestFlight and the App Store production ones. SNS
/// keeps one platform application for each.
public enum RelayEnvironment: String, Sendable {
    case production = "p"
    case sandbox = "s"

    init?(name: String) {
        switch name {
        case "production": self = .production
        case "sandbox": self = .sandbox
        default: return nil
        }
    }

    var name: String { self == .production ? "production" : "sandbox" }
    var platform: String { self == .production ? "APNS" : "APNS_SANDBOX" }
}

public struct RelayConfig: Sendable {
    /// ARN of the production SNS platform application (`…:app/APNS/<name>`); empty when unused.
    public var appArn: String
    /// ARN of the sandbox one (`…:app/APNS_SANDBOX/<name>`); empty when unused.
    public var sandboxAppArn: String
    public var accessKeyId: String
    public var secretAccessKey: String
    public var secret: String
    /// SNS's endpoint; a test points it at a fake.
    public var snsURL: URL?
    /// Pushes one token may send per hour.
    public var hourlyLimit = 120
    /// Registrations the whole relay accepts per hour: each one may create an SNS endpoint.
    public var registerLimit = 300

    public init(appArn: String, sandboxAppArn: String = "", accessKeyId: String, secretAccessKey: String, secret: String) {
        self.appArn = appArn
        self.sandboxAppArn = sandboxAppArn
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.secret = secret
    }

    var credentials: AWSCredentials { AWSCredentials(accessKeyId: accessKeyId, secretAccessKey: secretAccessKey) }

    /// The AWS region the platform applications live in (it is in their ARN).
    var region: String {
        let arn = appArn.isEmpty ? sandboxAppArn : appArn
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count > 3 ? String(parts[3]) : ""
    }

    var snsEndpoint: URL { snsURL ?? URL(string: "https://sns.\(region).amazonaws.com/")! }

    func appArn(for environment: RelayEnvironment) -> String? {
        let arn = environment == .production ? appArn : sandboxAppArn
        return arn.isEmpty ? nil : arn
    }

    /// Where `swarme-harness push-relay` keeps its keys: `<data>/push-relay.json`, 0600.
    public static func file(_ paths: DataPaths) -> URL { paths.root.appendingPathComponent("push-relay.json") }

    private static let fileKeys = [("AWS_ACCESS_KEY_ID", "accessKeyId"), ("AWS_SECRET_ACCESS_KEY", "secretAccessKey"),
                                   ("SNS_APNS_APP_ARN", "appArn"), ("SNS_APNS_SANDBOX_APP_ARN", "sandboxAppArn"), ("RELAY_SECRET", "secret")]

    /// The environment, else the file's values (`accessKeyId`, `secretAccessKey`, `appArn`, `sandboxAppArn`, `secret`).
    public static func load(_ env: [String: String], paths: DataPaths) throws -> RelayConfig {
        var merged = env
        if let saved = FileIO.readJSON(file(paths)) {
            for (name, key) in fileKeys where (merged[name] ?? "").isEmpty {
                if let value = saved[key]?.string { merged[name] = value }
            }
        }
        return try fromEnvironment(merged)
    }

    /// `arn:aws:sns:<region>:<12-digit account>:app/<platform>/<name>`.
    private static func place(of arn: String, platform: String) -> String? {
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "arn", parts[1] == "aws", parts[2] == "sns", !parts[3].isEmpty,
              parts[4].count == 12, parts[4].allSatisfy(\.isNumber), parts[5].hasPrefix("app/\(platform)/"),
              parts[5].count > "app/\(platform)/".count,
              parts[5].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0)) }) else { return nil }
        return parts[3] + ":" + parts[4]
    }

    /// At least one platform application, each looking like an ARN of its platform, all in one region and account.
    static func check(appArn: String, sandboxAppArn: String) throws {
        guard !appArn.isEmpty || !sandboxAppArn.isEmpty else { throw RelayError(message: "an SNS platform application ARN is required") }
        var places = Set<String>()
        if !appArn.isEmpty {
            guard let place = place(of: appArn, platform: "APNS") else {
                throw RelayError(message: "appArn must look like arn:aws:sns:<region>:<account>:app/APNS/<name>")
            }
            places.insert(place)
        }
        if !sandboxAppArn.isEmpty {
            guard let place = place(of: sandboxAppArn, platform: "APNS_SANDBOX") else {
                throw RelayError(message: "sandboxAppArn must look like arn:aws:sns:<region>:<account>:app/APNS_SANDBOX/<name>")
            }
            places.insert(place)
        }
        guard places.count == 1 else { throw RelayError(message: "both platform applications must be in the same region and account") }
    }

    /// `push-relay configure`: the AWS keys and the SNS applications, with the
    /// relay's secret kept when there is one (a new secret would void every phone's token).
    public static func configure(_ body: JSONObject, paths: DataPaths) throws {
        func text(_ key: String) -> String { body[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard !text("accessKeyId").isEmpty, !text("secretAccessKey").isEmpty else {
            throw RelayError(message: "accessKeyId and secretAccessKey are required")
        }
        try check(appArn: text("appArn"), sandboxAppArn: text("sandboxAppArn"))
        let existing = FileIO.readJSON(file(paths))?["secret"]?.string ?? ""
        let secret = existing.utf8.count >= 32 ? existing : (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        paths.ensure()
        try FileIO.writeAtomic(JSON.object(["accessKeyId": .string(text("accessKeyId")), "secretAccessKey": .string(text("secretAccessKey")),
                                            "appArn": .string(text("appArn")), "sandboxAppArn": .string(text("sandboxAppArn")),
                                            "secret": .string(secret)]).data,
                               to: file(paths), mode: 0o600)
    }

    public static func fromEnvironment(_ env: [String: String]) throws -> RelayConfig {
        func required(_ name: String) throws -> String {
            guard let value = env[name], !value.isEmpty else { throw RelayError(message: "\(name) is required") }
            return value
        }
        var config = RelayConfig(appArn: env["SNS_APNS_APP_ARN"] ?? "", sandboxAppArn: env["SNS_APNS_SANDBOX_APP_ARN"] ?? "",
                                 accessKeyId: try required("AWS_ACCESS_KEY_ID"), secretAccessKey: try required("AWS_SECRET_ACCESS_KEY"),
                                 secret: try required("RELAY_SECRET"))
        guard config.secret.utf8.count >= 32 else { throw RelayError(message: "RELAY_SECRET must be at least 32 bytes") }
        try check(appArn: config.appArn, sandboxAppArn: config.sandboxAppArn)
        if let url = env["SNS_ENDPOINT"].flatMap(URL.init(string:)) { config.snsURL = url }
        if let limit = env["RELAY_HOURLY_LIMIT"].flatMap(Int.init), limit > 0 { config.hourlyLimit = limit }
        if let limit = env["RELAY_REGISTER_LIMIT"].flatMap(Int.init), limit > 0 { config.registerLimit = limit }
        return config
    }
}

public struct RelayError: LocalizedError {
    let message: String
    public var errorDescription: String? { message }
}

/// An error answer of SNS (`<ErrorResponse><Error><Code>…`).
struct SNSError: Error {
    let status: Int
    let code: String
    let message: String
}

@MainActor
public final class Relay {
    let config: RelayConfig
    private let session: URLSession
    private var sent: [String: [Date]] = [:]
    private var registrations: [Date] = []

    public init(config: RelayConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: Tokens

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func mac(_ text: String) -> String {
        Self.base64url(Data(HMAC<SHA256>.authenticationCode(for: Data("v2:\(text)".utf8), using: SymmetricKey(data: Data(config.secret.utf8)))))
    }

    /// `v2.<environment>.<language>.<endpoint id>.<mac>`: everything the relay needs to push, and no more.
    func token(environment: RelayEnvironment, language: String, endpointId: String) -> String {
        let body = "\(environment.rawValue).\(language).\(endpointId)"
        return "v2.\(body).\(mac(body))"
    }

    /// What a token says, when the token is ours.
    func parse(token: String) -> (environment: RelayEnvironment, language: String, endpointId: String)? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "v2", let environment = RelayEnvironment(rawValue: parts[1]),
              Self.languages.contains(parts[2]), Self.validEndpointId(parts[3]) else { return nil }
        let expected = Array(mac("\(parts[1]).\(parts[2]).\(parts[3])").utf8), given = Array(parts[4].utf8)
        guard given.count == expected.count, zip(given, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        return (environment, parts[2], parts[3])
    }

    static let languages = ["en", "it"]

    /// The last part of an SNS endpoint ARN: a UUID.
    static func validEndpointId(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isHexDigit || $0 == "-") }
    }

    /// An APNs device token: hexadecimal, 32 bytes today.
    static func validDeviceToken(_ token: String) -> Bool {
        (32...200).contains(token.count) && token.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private func endpointPrefix(_ appArn: String) -> String {
        appArn.replacingOccurrences(of: ":app/", with: ":endpoint/") + "/"
    }

    // MARK: SNS

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The text of the first `<tag>…</tag>` in an XML answer.
    static func xml(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return unescape(String(text[open.upperBound..<close.lowerBound]))
    }

    private func sns(_ action: String, _ fields: [(String, String)]) async throws -> String {
        let request = AWSSigV4.signedFormRequest(url: config.snsEndpoint, form: [("Action", action), ("Version", "2010-03-31")] + fields,
                                                 credentials: config.credentials, region: config.region, service: "sns")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200...299).contains(status) else {
            throw SNSError(status: status, code: Self.xml("Code", in: text) ?? "HTTP \(status)",
                           message: String((Self.xml("Message", in: text) ?? text).prefix(200)))
        }
        return text
    }

    /// The endpoint of a device token: created, or found when SNS already has
    /// one for it — and turned back on when APNs had disabled it.
    private func endpointArn(deviceToken: String, appArn: String) async throws -> String {
        do {
            let text = try await sns("CreatePlatformEndpoint", [("PlatformApplicationArn", appArn), ("Token", deviceToken)])
            guard let arn = Self.xml("EndpointArn", in: text) else { throw SNSError(status: 502, code: "BadResponse", message: "no EndpointArn") }
            return arn
        } catch let error as SNSError where error.code == "InvalidParameter" {
            // "… Endpoint arn:aws:sns:… already exists with the same Token, but different attributes."
            guard let start = error.message.range(of: "arn:aws:sns:") else { throw error }
            let existing = String(error.message[start.lowerBound...].prefix { !$0.isWhitespace })
            guard existing.hasPrefix(endpointPrefix(appArn)) else { throw error }
            _ = try await sns("SetEndpointAttributes", [("EndpointArn", existing), ("Attributes.entry.1.key", "Enabled"),
                                                         ("Attributes.entry.1.value", "true"), ("Attributes.entry.2.key", "Token"),
                                                         ("Attributes.entry.2.value", deviceToken)])
            return existing
        }
    }

    /// What the caller is told of an SNS error: a gone endpoint is a 410 (the phone registers again), the rest a 502.
    private func answer(_ error: SNSError) -> HTTPResponse {
        if ["EndpointDisabled", "NotFound"].contains(error.code) { return .error(410, "the phone's endpoint is gone: register again") }
        return .error(502, "SNS \(error.code): \(error.message)")
    }

    // MARK: Routes

    public func handle(_ request: HTTPRequest) async -> RouteResult {
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                return .response(.json(200, ["app": "swarme-push-relay", "ok": true]))
            case ("POST", "/v1/register"):
                return .response(try await register(try request.json()))
            case ("POST", "/v1/notify"):
                return .response(try await notify(try request.json()))
            default:
                return .response(.error(404, "not found"))
            }
        } catch let error as HTTPError {
            return .response(.error(error.status, error.message))
        } catch let error as SNSError {
            return .response(answer(error))
        } catch {
            return .response(.error(502, error.localizedDescription))
        }
    }

    func register(_ body: JSONObject) async throws -> HTTPResponse {
        guard let deviceToken = body["deviceToken"]?.string, Self.validDeviceToken(deviceToken) else { return .error(400, "deviceToken required") }
        guard let environment = RelayEnvironment(name: body["environment"]?.string ?? "production") else {
            return .error(400, "environment must be production or sandbox")
        }
        guard let appArn = config.appArn(for: environment) else {
            return .error(400, "this relay has no \(environment.name) platform application")
        }
        let language = body["language"]?.string.flatMap { Self.languages.contains($0) ? $0 : nil } ?? "en"
        let now = Date()
        registrations = registrations.filter { now.timeIntervalSince($0) < 3600 }
        guard registrations.count < config.registerLimit else { return .error(429, "too many registrations") }
        registrations.append(now)

        let arn: String
        do { arn = try await endpointArn(deviceToken: deviceToken, appArn: appArn) } catch let error as SNSError { return answer(error) }
        let prefix = endpointPrefix(appArn)
        guard arn.hasPrefix(prefix), Self.validEndpointId(String(arn.dropFirst(prefix.count))) else {
            return .error(502, "SNS answered an endpoint of another application")
        }
        return .json(201, ["pushToken": .string(token(environment: environment, language: language, endpointId: String(arn.dropFirst(prefix.count))))])
    }

    func notify(_ body: JSONObject) async throws -> HTTPResponse {
        guard let token = body["pushToken"]?.string, let target = parse(token: token) else { return .error(401, "unknown pushToken") }
        guard let appArn = config.appArn(for: target.environment) else { return .error(401, "unknown pushToken") }
        let now = Date()
        let recent = (sent[token] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < config.hourlyLimit else { return .error(429, "too many pushes for this token") }
        sent[token] = recent + [now]

        func title(_ language: String) -> String? {
            body["title"]?[language]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        }
        guard let english = title("en") else { return .error(400, "title.en required") }
        let text = title(target.language) ?? english

        // what APNs gets: the alert, and the engine's ids beside `aps` for the app to open the chat
        var aps: JSONObject = ["alert": ["body": .string(text)], "sound": "default"]
        if let category = body["category"]?.string, ["approval", "chat"].contains(category) { aps["category"] = .string(category) }
        var apns: JSONObject = ["aps": .object(aps)]
        if let data = body["data"], let object = data.object, data.serialized().utf8.count <= 2048 {
            for (key, value) in object where key != "aps" { apns[key] = value }
        }
        let message: JSONObject = ["default": .string(text), target.environment.platform: .string(JSON.object(apns).serialized())]
        do {
            _ = try await sns("Publish", [("TargetArn", endpointPrefix(appArn) + target.endpointId), ("MessageStructure", "json"),
                                          ("Message", JSON.object(message).serialized())])
        } catch let error as SNSError {
            return answer(error)
        }
        return .json(200, ["ok": true])
    }
}
