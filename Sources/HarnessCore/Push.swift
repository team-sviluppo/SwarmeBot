// Push notifications for the phones paired with a remote engine
// (docs/plans/2026-10-22-app-ios.md §6).
//
// The engine never holds a push provider's key. A phone registers with a
// push relay (swarme-push-relay, Amazon SNS behind it), gets a `pushToken`
// bound to its device, and hands that token to the engine; the engine can
// then push to that phone, and only to it, through the relay:
//
//   phone → relay  POST /v1/register {deviceToken, …}  → {pushToken}
//   phone → engine POST /api/push/subscriptions {pushToken, relayUrl, kinds?}
//   engine → relay POST /v1/notify {pushToken, …}
//
// Subscriptions live in `push.json` (0600), one list per device; revoking a
// device drops them, and so does a relay that no longer knows the token (401
// or 410: the phone registers again when the app opens). A push says which bot and what happened, never the chat
// text: the relay and the push provider see no conversation (§6.3).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class PushRegistry: @unchecked Sendable {
    public let file: URL
    /// Sends finish on their own tasks: the read-modify-write of `push.json` is one at a time.
    private let lock = NSLock()
    public static let kinds: [String] = ["approval", "question", "done", "takeover", "routine-failed"]

    public init(paths: DataPaths) {
        file = paths.root.appendingPathComponent("push.json")
    }

    public struct InputError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public func list() -> [JSONObject] {
        FileIO.readJSON(file)?["subscriptions"]?.array?.compactMap(\.object) ?? []
    }

    private func save(_ subscriptions: [JSONObject]) throws {
        try FileIO.writeAtomic(JSON.object(["subscriptions": .array(subscriptions.map(JSON.object))]).data, to: file, mode: 0o600)
    }

    /// What the API shows: everything but the token.
    public static func wire(_ subscription: JSONObject) -> JSONObject {
        var out = subscription
        out["pushToken"] = nil
        return out
    }

    /// Add or replace this device's subscription with the same token.
    public func add(deviceId: String, body: JSONObject) throws -> JSONObject {
        guard let token = body["pushToken"]?.string?.trimmingCharacters(in: .whitespaces), !token.isEmpty, token.count <= 512 else {
            throw InputError(message: "pushToken required")
        }
        // the relay belongs with the app build that registered with it (§6.5), so the app names it
        let relay = body["relayUrl"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let url = URL(string: relay), url.scheme == "https" || url.scheme == "http", url.host != nil else {
            throw InputError(message: "relayUrl must be an http(s) URL")
        }
        var kinds = Self.kinds
        if let asked = body["kinds"]?.array {
            kinds = asked.compactMap(\.string).filter(Self.kinds.contains)
        }
        lock.lock()
        defer { lock.unlock() }
        var subscriptions = list().filter { !($0["deviceId"]?.string == deviceId && $0["pushToken"]?.string == token) }
        let subscription = JSONObject([
            ("id", .string("push_" + String(newId().replacingOccurrences(of: "-", with: "").prefix(16)))),
            ("deviceId", .string(deviceId)), ("pushToken", .string(token)), ("relayUrl", .string(relay)),
            ("kinds", .strings(kinds)), ("createdAt", .number(nowMillis())),
        ])
        subscriptions.append(subscription)
        try save(subscriptions)
        return subscription
    }

    public func remove(_ id: String, deviceId: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let subscriptions = list()
        let kept = subscriptions.filter { !($0["id"]?.string == id && $0["deviceId"]?.string == deviceId) }
        guard kept.count != subscriptions.count else { return false }
        try save(kept)
        return true
    }

    public func remove(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        let subscriptions = list()
        let kept = subscriptions.filter { $0["deviceId"]?.string != deviceId }
        if kept.count != subscriptions.count { try? save(kept) }
    }

    /// A subscription the relay does not know any more, whoever's it is.
    func remove(subscriptionId: String) {
        lock.lock()
        defer { lock.unlock() }
        let subscriptions = list()
        let kept = subscriptions.filter { $0["id"]?.string != subscriptionId }
        if kept.count != subscriptions.count { try? save(kept) }
    }

    // MARK: Sending

    /// The two languages the app speaks; the push provider picks the phone's.
    /// The one place engine text is not English only: a push is read on the
    /// phone's lock screen, where the app cannot translate it.
    static func text(_ kind: String, bot: String) -> (en: String, it: String) {
        switch kind {
        case "approval": return ("\(bot) needs your approval", "\(bot) chiede un'approvazione")
        case "question": return ("\(bot) has a question", "\(bot) ha una domanda")
        case "takeover": return ("\(bot) needs your hands", "\(bot) ha bisogno di te")
        case "routine-failed": return ("A routine of \(bot) failed", "Una routine di \(bot) non è riuscita")
        default: return ("\(bot) finished", "\(bot) ha finito")
        }
    }

    /// The relay request for one notification, or nil when the kind is off.
    static func payload(_ subscription: JSONObject, notification: JSONObject, requestId: String?, server: String?) -> (URL, JSON)? {
        let kind = notification["kind"]?.string ?? "done"
        guard subscription["kinds"]?.array?.contains(.string(kind)) == true,
              let token = subscription["pushToken"]?.string,
              let relay = subscription["relayUrl"]?.string, let url = URL(string: relay.trimmingSuffix("/") + "/v1/notify") else { return nil }
        let text = Self.text(kind, bot: notification["botName"]?.string ?? "Bot")
        var data: JSONObject = ["kind": .string(kind), "botId": notification["botId"] ?? "", "threadId": notification["threadId"] ?? ""]
        if let requestId { data["requestId"] = .string(requestId) }
        if let server { data["server"] = .string(server) }
        let body: JSON = ["pushToken": .string(token), "title": ["en": .string(text.en), "it": .string(text.it)],
                          "category": .string(kind == "approval" && requestId != nil ? "approval" : "chat"), "data": .object(data)]
        return (url, body)
    }

    /// Fire and forget: a relay that is down costs a push, never a turn.
    public func send(_ notification: JSONObject, requestId: String?, server: String?, session: URLSession = .shared) {
        for subscription in list() {
            guard let (url, body) = Self.payload(subscription, notification: notification, requestId: requestId, server: server) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.data
            let id = subscription["id"]?.string
            Task.detached { [self] in
                guard let (_, response) = try? await session.data(for: request) else { return }
                guard let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) else { return }
                FileHandle.standardError.write(Data("push relay answered HTTP \(status)\n".utf8))
                // 401: not a token of this relay (its secret changed, or it is an old one); 410: the phone's endpoint is gone
                if let id, status == 401 || status == 410 { remove(subscriptionId: id) }
            }
        }
    }

    // MARK: Routes

    /// `/api/push/subscriptions*` for the calling device; nil for other paths.
    public func route(_ request: HTTPRequest) -> RouteResult? {
        let path = request.path, method = request.method
        guard path == "/api/push/subscriptions" || path.hasPrefix("/api/push/subscriptions/") else { return nil }
        guard let deviceId = request.deviceId else { return .response(.error(401, "unauthorized")) }
        do {
            switch (method, path) {
            case ("GET", "/api/push/subscriptions"):
                let mine = list().filter { $0["deviceId"]?.string == deviceId }
                return .response(.json(200, ["subscriptions": .array(mine.map { .object(Self.wire($0)) }), "kinds": .strings(Self.kinds)]))
            case ("POST", "/api/push/subscriptions"):
                let added = try add(deviceId: deviceId, body: try request.json())
                return .response(.json(201, ["subscription": .object(Self.wire(added))]))
            default:
                break
            }
            if method == "DELETE", path.hasPrefix("/api/push/subscriptions/") {
                let id = String(path.dropFirst("/api/push/subscriptions/".count))
                guard try remove(id, deviceId: deviceId) else { return .response(.error(404, "no such subscription")) }
                return .response(.json(200, ["ok": true]))
            }
            return .response(.error(404, "not found"))
        } catch let error as InputError {
            return .response(.error(400, error.message))
        } catch let error as HTTPError {
            return .response(.error(error.status, error.message))
        } catch {
            return .response(.error(500, error.localizedDescription))
        }
    }
}
