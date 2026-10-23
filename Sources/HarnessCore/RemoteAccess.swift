// The remote engine's front door — docs/plans/2026-10-16-bot-remoto.md §3–§4.
//
// The same engine runs on a server, behind Caddy, reachable from the
// internet. Everything the local engine trusts because it is on loopback is
// replaced here by a device token:
//
// - every request carries `Authorization: Bearer <device token>`; only
//   `GET /api/health` and `POST /api/devices/claim` go without;
// - `/api/internal/*` does not exist on this listener, token or not (the
//   proxies reach it on a separate loopback listener);
// - a request with an `Origin` is refused: browsers have no business here;
// - repeated failures from one client are slowed down (429).
//
// Devices live in `devices.json` (hash only, never the token). The first one
// is added over ssh with `swarme-harness device add`; the rest pair with a
// one-time code a paired device asks for (the QR on the Mac).
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum RemoteContract {
    /// Bumped when a remote client can no longer talk to an engine of the previous value.
    public static let version = 1
}

// MARK: - Devices

public final class DeviceRegistry {
    public let file: URL
    private var cache: [JSONObject] = []
    private var cacheStamp: Date?
    /// lastSeenAt is written at most this often per device, not on every request
    static let seenWriteInterval = 5.0 * 60_000

    public static let kinds: Set<String> = ["mac", "ios", "other"]

    public init(paths: DataPaths) {
        file = paths.root.appendingPathComponent("devices.json")
    }

    public struct InputError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Re-read when the file changes: `device add` over ssh writes it while the engine runs.
    private func load() -> [JSONObject] {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if stamp != nil, stamp == cacheStamp { return cache }
        cache = FileIO.readJSON(file)?["devices"]?.array?.compactMap(\.object) ?? []
        cacheStamp = stamp
        return cache
    }

    private func save(_ devices: [JSONObject]) throws {
        try FileIO.writeAtomic(JSON.object(["devices": .array(devices.map(JSON.object))]).data, to: file, mode: 0o600)
        cache = devices
        cacheStamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    public static func hash(_ token: String) -> String {
        "sha256:" + SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken(bytes count: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func cleanName(_ raw: String?) throws -> String {
        let name = String((raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty else { throw InputError(message: "Give the device a name") }
        return name
    }

    /// A new device and its token. The token is returned once and never stored.
    public func add(name rawName: String?, kind rawKind: String?) throws -> (device: JSONObject, token: String) {
        let name = try Self.cleanName(rawName)
        let kind = rawKind.flatMap { Self.kinds.contains($0) ? $0 : nil } ?? "other"
        let token = Self.randomToken()
        let now = nowMillis()
        let device = JSONObject([
            ("id", .string("dev_" + String(newId().replacingOccurrences(of: "-", with: "").prefix(16)))),
            ("name", .string(name)), ("kind", .string(kind)), ("tokenHash", .string(Self.hash(token))),
            ("createdAt", .number(now)), ("lastSeenAt", .null), ("revokedAt", .null),
        ])
        try save(load() + [device])
        return (device, token)
    }

    /// What the API shows: everything but the hash.
    public static func wire(_ device: JSONObject) -> JSONObject {
        var out = device
        out["tokenHash"] = nil
        return out
    }

    public func list(includeRevoked: Bool = false) -> [JSONObject] {
        load().filter { includeRevoked || $0["revokedAt"]?.isNull != false }
    }

    public func revoke(_ id: String) throws -> Bool {
        var devices = load()
        guard let index = devices.firstIndex(where: { $0["id"]?.string == id && $0["revokedAt"]?.isNull != false }) else { return false }
        devices[index]["revokedAt"] = .number(nowMillis())
        try save(devices)
        return true
    }

    /// The device id for a live token, or nil. Constant-time on the hash.
    public func authenticate(_ token: String) -> String? {
        guard !token.isEmpty else { return nil }
        let expected = Array(Self.hash(token).utf8)
        var devices = load()
        guard let index = devices.firstIndex(where: { device in
            guard device["revokedAt"]?.isNull != false, let stored = device["tokenHash"]?.string else { return false }
            let got = Array(stored.utf8)
            return got.count == expected.count && zip(got, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0
        }) else { return nil }
        let now = nowMillis()
        if now - (devices[index]["lastSeenAt"]?.double ?? 0) > Self.seenWriteInterval {
            devices[index]["lastSeenAt"] = .number(now)
            try? save(devices)
        }
        return devices[index]["id"]?.string
    }
}

// MARK: - Pairing codes and failure limits

/// One-time codes a paired device asks for and shows as a QR; a new device
/// trades one for its token. In memory only: a restart voids them.
public struct PairingCodes {
    static let lifetime = 10.0 * 60_000
    static let maxOpen = 5
    // no 0/O, 1/I/L: read off a screen if the camera fails
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private var open: [String: Double] = [:]

    public init() {}

    public mutating func issue(now: Double = nowMillis()) -> (code: String, expiresAt: Double) {
        open = open.filter { $0.value > now }
        while open.count >= Self.maxOpen, let oldest = open.min(by: { $0.value < $1.value }) { open[oldest.key] = nil }
        var generator = SystemRandomNumberGenerator()
        let code = String((0..<10).map { _ in Self.alphabet.randomElement(using: &generator)! })
        open[code] = now + Self.lifetime
        return (code, now + Self.lifetime)
    }

    /// True once per issued, unexpired code.
    public mutating func redeem(_ raw: String, now: Double = nowMillis()) -> Bool {
        let code = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard let expires = open.removeValue(forKey: code) else { return false }
        return expires > now
    }
}

/// Too many failures from one client in a minute → refused for five.
public struct FailureLimiter {
    static let window = 60_000.0
    static let maxFailures = 10
    static let penalty = 5.0 * 60_000
    private var failures: [String: [Double]] = [:]
    private var blockedUntil: [String: Double] = [:]

    public init() {}

    public func isBlocked(_ client: String, now: Double = nowMillis()) -> Bool {
        (blockedUntil[client] ?? 0) > now
    }

    public mutating func fail(_ client: String, now: Double = nowMillis()) {
        let recent = (failures[client] ?? []).filter { now - $0 < Self.window } + [now]
        failures[client] = recent
        if recent.count >= Self.maxFailures {
            blockedUntil[client] = now + Self.penalty
            failures[client] = []
        }
        // forget clients that went quiet, so the map cannot grow without bound
        if failures.count > 10_000 { failures = failures.filter { !($0.value.last.map { now - $0 > Self.window } ?? true) } }
        blockedUntil = blockedUntil.filter { $0.value > now }
    }
}

// MARK: - Gate and device routes

@MainActor
public final class RemoteAccess {
    public let devices: DeviceRegistry
    /// The phones' push subscriptions (Push.swift).
    public let push: PushRegistry
    /// The chat URL clients use (`--public-url`), handed out with pairing codes.
    public let publicURL: String?
    private var pairing = PairingCodes()
    private var limiter = FailureLimiter()
    /// Closes the SSE streams of a revoked device.
    public var onRevoke: ((String) -> Void)?

    static let unavailable = "non disponibile su un motore remoto"
    static let localOnly = [#"^/api/local-computer(/|$)"#, #"^/api/bots/[^/]+/computer(/|$)"#, #"^/api/peer-engines$"#]

    public init(paths: DataPaths, publicURL: String?) {
        devices = DeviceRegistry(paths: paths)
        push = PushRegistry(paths: paths)
        self.publicURL = publicURL
    }

    /// The client a failure counts against. The socket is reachable only by
    /// the proxy (its group), so the proxy's X-Forwarded-For is the client.
    static func client(_ request: HTTPRequest) -> String {
        request.header("x-forwarded-for")?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "socket"
    }

    static func bearer(_ request: HTTPRequest) -> String? {
        guard let value = request.header("authorization"), value.lowercased().hasPrefix("bearer ") else { return nil }
        return value.dropFirst(7).trimmingCharacters(in: .whitespaces)
    }

    static func isPublic(_ request: HTTPRequest) -> Bool {
        (request.method == "GET" && request.path == "/api/health") || (request.method == "POST" && request.path == "/api/devices/claim")
    }

    public func gate(_ request: inout HTTPRequest) -> RouteResult? {
        if let origin = request.header("origin"), !origin.isEmpty {
            return .response(.error(403, "forbidden: cross-origin request"))
        }
        if request.path.hasPrefix("/api/internal/") { return .response(.error(404, "not found")) }
        let client = Self.client(request)
        if limiter.isBlocked(client) { return .response(.error(429, "too many failed attempts — try again in a few minutes")) }
        if Self.isPublic(request) { return nil }
        guard let token = Self.bearer(request), let device = devices.authenticate(token) else {
            limiter.fail(client)
            return .response(.error(401, "unauthorized"))
        }
        request.deviceId = device
        if Self.localOnly.contains(where: { request.path.range(of: $0, options: .regularExpression) != nil }) {
            return .response(.error(501, Self.unavailable))
        }
        return nil
    }

    /// `/api/health`, `/api/devices*` and `/api/push/*`; nil for everything else.
    public func route(_ request: HTTPRequest) -> RouteResult? {
        let path = request.path, method = request.method
        if let answer = push.route(request) { return answer }
        if method == "GET", path == "/api/health" {
            return .response(.json(200, ["app": "swarmebot", "engine": "swift", "remote": true, "contract": .number(Double(RemoteContract.version))]))
        }
        guard path == "/api/devices" || path.hasPrefix("/api/devices/") else { return nil }
        do {
            switch (method, path) {
            case ("GET", "/api/devices"):
                return .response(.json(200, ["devices": .array(devices.list().map { .object(DeviceRegistry.wire($0)) }),
                                             "current": .from(request.deviceId)]))
            case ("POST", "/api/devices/pairing"):
                let issued = pairing.issue()
                return .response(.json(201, ["code": .string(issued.code), "expiresAt": .number(issued.expiresAt), "chatUrl": .from(publicURL)]))
            case ("POST", "/api/devices/claim"):
                let body = try request.json()
                guard pairing.redeem(body["code"]?.string ?? "") else {
                    limiter.fail(Self.client(request))
                    return .response(.error(401, "invalid or expired pairing code"))
                }
                let added = try devices.add(name: body["name"]?.string, kind: body["kind"]?.string)
                return .response(.json(201, ["token": .string(added.token), "device": .object(DeviceRegistry.wire(added.device))]))
            default:
                break
            }
            if method == "DELETE", path.hasPrefix("/api/devices/") {
                let id = String(path.dropFirst("/api/devices/".count))
                guard try devices.revoke(id) else { return .response(.error(404, "no such device")) }
                push.remove(deviceId: id)
                onRevoke?(id)
                return .response(.json(200, ["ok": true]))
            }
            return .response(.error(404, "not found"))
        } catch let error as DeviceRegistry.InputError {
            return .response(.error(400, error.message))
        } catch let error as HTTPError {
            return .response(.error(error.status, error.message))
        } catch {
            return .response(.error(500, error.localizedDescription))
        }
    }
}
