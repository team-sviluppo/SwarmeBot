// The push relay (docs/plans/2026-10-22-app-ios.md §6.5): the only holder of
// the OneSignal key. Phones register their OneSignal subscription and get a
// `pushToken`; engines post notifications with that token. The relay keeps no
// database: a token is the subscription id with an HMAC of the relay's
// secret, so it can only ever push to the phone that registered it.
//
//   POST /v1/register {subscriptionId}                       → {pushToken}
//   POST /v1/notify   {pushToken, title{en,it}, category?, data?} → {ok}
//   GET  /health
//
// Open source on purpose: anyone may run their own relay with their own
// OneSignal app — which then also needs their own build of the iOS app,
// because Apple's pushes are bound to the app that receives them.
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

public struct RelayConfig: Sendable {
    public var appId: String
    public var apiKey: String
    public var secret: String
    /// OneSignal's API; a test points it at a fake.
    public var oneSignalURL = URL(string: "https://api.onesignal.com/notifications?c=push")!
    /// Pushes one token may send per hour.
    public var hourlyLimit = 120

    public init(appId: String, apiKey: String, secret: String) {
        self.appId = appId
        self.apiKey = apiKey
        self.secret = secret
    }

    /// Where `swarme-harness push-relay` keeps its keys: `<data>/push-relay.json`, 0600.
    public static func file(_ paths: DataPaths) -> URL { paths.root.appendingPathComponent("push-relay.json") }

    /// The environment, else the file's values (`appId`, `apiKey`, `secret`) under the same names.
    public static func load(_ env: [String: String], paths: DataPaths) throws -> RelayConfig {
        var merged = env
        if let saved = FileIO.readJSON(file(paths)) {
            for (name, key) in [("ONESIGNAL_APP_ID", "appId"), ("ONESIGNAL_API_KEY", "apiKey"), ("RELAY_SECRET", "secret")]
            where (merged[name] ?? "").isEmpty {
                if let value = saved[key]?.string { merged[name] = value }
            }
        }
        return try fromEnvironment(merged)
    }

    /// `push-relay configure`: the OneSignal app and key, with the relay's
    /// secret kept when there is one (a new secret would void every phone's token).
    public static func configure(_ body: JSONObject, paths: DataPaths) throws {
        guard let appId = body["appId"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !appId.isEmpty,
              let apiKey = body["apiKey"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw RelayError(message: "appId and apiKey are required")
        }
        let existing = FileIO.readJSON(file(paths))?["secret"]?.string ?? ""
        let secret = existing.utf8.count >= 32 ? existing : (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        paths.ensure()
        try FileIO.writeAtomic(JSON.object(["appId": .string(appId), "apiKey": .string(apiKey), "secret": .string(secret)]).data,
                               to: file(paths), mode: 0o600)
    }

    public static func fromEnvironment(_ env: [String: String]) throws -> RelayConfig {
        func required(_ name: String) throws -> String {
            guard let value = env[name], !value.isEmpty else { throw RelayError(message: "\(name) is required") }
            return value
        }
        var config = RelayConfig(appId: try required("ONESIGNAL_APP_ID"), apiKey: try required("ONESIGNAL_API_KEY"),
                                 secret: try required("RELAY_SECRET"))
        guard config.secret.utf8.count >= 32 else { throw RelayError(message: "RELAY_SECRET must be at least 32 bytes") }
        if let url = env["ONESIGNAL_API"].flatMap(URL.init(string:)) { config.oneSignalURL = url }
        if let limit = env["RELAY_HOURLY_LIMIT"].flatMap(Int.init), limit > 0 { config.hourlyLimit = limit }
        return config
    }
}

public struct RelayError: LocalizedError {
    let message: String
    public var errorDescription: String? { message }
}

@MainActor
public final class Relay {
    let config: RelayConfig
    private let session: URLSession
    private var sent: [String: [Date]] = [:]

    public init(config: RelayConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: Tokens

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unbase64url(_ text: Substring) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }

    private func mac(_ subscription: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("v1:\(subscription)".utf8), using: SymmetricKey(data: Data(config.secret.utf8))))
    }

    func token(for subscription: String) -> String {
        "v1.\(Self.base64url(Data(subscription.utf8))).\(Self.base64url(mac(subscription)))"
    }

    /// The subscription a token is for, when the token is ours.
    func subscription(of token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts[0] == "v1", let id = Self.unbase64url(parts[1]), let given = Self.unbase64url(parts[2]),
              let subscription = String(data: id, encoding: .utf8) else { return nil }
        let expected = mac(subscription)
        guard given.count == expected.count, zip(given, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
        return subscription
    }

    static func validSubscription(_ id: String) -> Bool {
        (8...100).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    // MARK: Routes

    public func handle(_ request: HTTPRequest) async -> RouteResult {
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                return .response(.json(200, ["app": "swarme-push-relay", "ok": true]))
            case ("POST", "/v1/register"):
                let body = try request.json()
                guard let id = body["subscriptionId"]?.string, Self.validSubscription(id) else {
                    return .response(.error(400, "subscriptionId required"))
                }
                return .response(.json(201, ["pushToken": .string(token(for: id))]))
            case ("POST", "/v1/notify"):
                return .response(try await notify(try request.json()))
            default:
                return .response(.error(404, "not found"))
            }
        } catch let error as HTTPError {
            return .response(.error(error.status, error.message))
        } catch {
            return .response(.error(502, error.localizedDescription))
        }
    }

    func notify(_ body: JSONObject) async throws -> HTTPResponse {
        guard let token = body["pushToken"]?.string, let subscription = subscription(of: token) else {
            return .error(401, "unknown pushToken")
        }
        let now = Date()
        let recent = (sent[token] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < config.hourlyLimit else { return .error(429, "too many pushes for this token") }
        sent[token] = recent + [now]

        var contents = JSONObject()
        for language in ["en", "it"] {
            if let text = body["title"]?[language]?.string, !text.isEmpty { contents[language] = .string(String(text.prefix(200))) }
        }
        guard contents["en"] != nil else { return .error(400, "title.en required") }
        var payload: JSONObject = [
            "app_id": .string(config.appId), "target_channel": "push",
            "include_subscription_ids": [.string(subscription)], "contents": .object(contents),
        ]
        if let category = body["category"]?.string, ["approval", "chat"].contains(category) { payload["ios_category"] = .string(category) }
        if let data = body["data"], data.object != nil, data.serialized().utf8.count <= 2048 { payload["data"] = data }

        var request = URLRequest(url: config.oneSignalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Key \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = JSON.object(payload).data
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            return .error(502, "OneSignal HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return .json(200, ["ok": true])
    }
}
