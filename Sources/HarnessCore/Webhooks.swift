// Webhook triggers — `server/webhooks.ts` and `server/webhook-ingress.ts`.
//
// Management lives on the app server (`/api/webhooks*`); deliveries land on
// a second, webhook-only loopback listener (127.0.0.1:8800, OMB_WEBHOOK_PORT)
// so a tunnel or a hosted relay never exposes the rest of the control
// surface. Each hook has a capability URL `/hooks/<endpointId>/<secret>` (or
// the secret as a bearer); only its SHA-256 is stored.
//
// A delivery is queued as a routine run (RoutineManager.enqueueWebhook). The
// payload reaches the bot inside an UNTRUSTED WEBHOOK EVENT DATA block, the
// instructions come from the user's configuration, and the turn runs
// unattended, so auto mode does not apply to it.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

@MainActor
public final class WebhookManager {
    static let maxDeliveries = 2_000
    static let maxAttempts = 2_000
    static let maxEventChars = 48_000
    static let rateWindowMillis = 60_000.0
    static let rateLimit = 10
    static let maxPendingRuns = 3
    public static let maxBodyBytes = 256 * 1024

    public struct Host {
        public var emit: (JSONObject) -> Void
        public var botState: (String) -> String
        public var enqueue: (_ webhookId: String, _ name: String, _ prompt: String, _ botId: String, _ runOn: String,
                             _ deliveryId: String, _ receivedAt: Double) throws -> JSONObject
        public var cancelQueued: (_ webhookId: String, _ message: String) -> Void
        public var pendingRuns: (_ webhookId: String) -> Int
    }

    /// What the ingress hands over for one request.
    public struct Event {
        public var payload: JSON?
        public var contentType: String?
        public var eventName: String?
        public var userAgent: String?
        public var deliveryId: String?
    }

    private let file: URL
    private let host: Host
    private(set) var webhooks: [JSONObject] = []
    private var deliveries: [JSONObject] = []
    private(set) var attempts: [JSONObject] = []
    private var rate: [String: [Double]] = [:]

    public init(file: URL, host: Host) {
        self.file = file
        self.host = host
        // a file that does not validate is ignored, as zod would
        if let disk = FileIO.readJSON(file), disk["version"]?.double == 1, let hooks = disk["webhooks"]?.array, let receipts = disk["deliveries"]?.array,
           hooks.allSatisfy({ ($0["secretHash"]?.string ?? "").range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) {
            webhooks = hooks.compactMap(\.object)
            deliveries = Array(receipts.compactMap(\.object).suffix(Self.maxDeliveries))
            attempts = Array((disk["attempts"]?.array ?? []).compactMap(\.object).suffix(Self.maxAttempts))
        }
    }

    // MARK: Pure pieces

    public static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time on the digests: the comparison never leaks a prefix.
    public static func secretMatches(_ secret: String, _ expectedHex: String) -> Bool {
        guard !secret.isEmpty else { return false }
        let actual = Array(hash(secret).utf8), expected = Array(expectedHex.utf8)
        return actual.count == expected.count && zip(actual, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func base64url(_ count: Int) -> String {
        // the system CSPRNG on every platform (arc4random / getrandom)
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The payload as the bot reads it, capped at 48 000 characters.
    public static func serialize(_ payload: JSON?) -> String {
        let text: String
        switch payload {
        case let .string(value)?: text = value
        case nil: text = "undefined"
        case let value?: text = value.pretty()
        }
        guard text.count > maxEventChars else { return text }
        return "\(text.prefix(maxEventChars))\n\n[Payload truncated by SwarmeBot]"
    }

    public static func preview(_ payload: JSON?) -> String {
        String(serialize(payload).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(2_000))
    }

    static func task(from payload: JSON?) -> String {
        guard let object = payload?.object else { return "" }
        let task = object["task"], message = object["message"]
        // zod: task and message, when present, must be strings
        if let task, task.string == nil { return "" }
        if let message, message.string == nil { return "" }
        return String((task?.string ?? message?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
    }

    static func iso(_ millis: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }

    static func prompt(_ trigger: JSONObject, _ event: Event, receivedAt: Double, deliveryId: String) -> String {
        var metadata = ["Received: \(iso(receivedAt))", "Delivery ID: \(deliveryId)"]
        if let name = event.eventName, !name.isEmpty { metadata.append("Event: \(name.prefix(200))") }
        if let type = event.contentType, !type.isEmpty { metadata.append("Content-Type: \(type.prefix(200))") }
        if let agent = event.userAgent, !agent.isEmpty { metadata.append("Sender: \(agent.prefix(300))") }
        let configured = (trigger["prompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = configured.isEmpty ? task(from: event.payload) : ""
        let instructions: [String] = !configured.isEmpty
            ? ["[USER-CONFIGURED WEBHOOK INSTRUCTIONS]", configured, "[/USER-CONFIGURED WEBHOOK INSTRUCTIONS]"]
            : !requested.isEmpty ? ["[AUTHENTICATED WEBHOOK TASK]", requested, "[/AUTHENTICATED WEBHOOK TASK]"]
            : ["[DEFAULT WEBHOOK INSTRUCTIONS]",
               "Review the incoming event and summarize what happened. Do not take external actions unless the event clearly requires them and existing permissions allow them.",
               "[/DEFAULT WEBHOOK INSTRUCTIONS]"]
        return (instructions + ["", "[UNTRUSTED WEBHOOK EVENT DATA]"] + metadata + ["", serialize(event.payload), "[/UNTRUSTED WEBHOOK EVENT DATA]"])
            .joined(separator: "\n")
    }

    // MARK: Definitions

    static func publicTrigger(_ trigger: JSONObject) -> JSONObject { trigger.removing("secretHash") }

    /// The schema check zod runs on create/patch bodies.
    static func check(_ body: JSONObject, partial: Bool) throws {
        for key in ["name", "prompt", "botId"] {
            if let value = body[key] { guard value.string != nil else { throw HTTPError(400, "\(key): Invalid input: expected string, received \(typeName(value))") } }
            else if !partial { throw HTTPError(400, "\(key): Invalid input: expected string, received undefined") }
        }
        if let runOn = body["runOn"], !["maus", "cloud"].contains(runOn.string ?? "") {
            throw HTTPError(400, "runOn: Invalid option: expected one of \"maus\"|\"cloud\"")
        }
        for key in ["enabled", "verificationPending"] {
            if let value = body[key], value.bool == nil { throw HTTPError(400, "\(key): Invalid input: expected boolean, received \(typeName(value))") }
        }
        if let types = body["eventTypes"] {
            guard let list = types.array, list.allSatisfy({ $0.string != nil }) else { throw HTTPError(400, "eventTypes: Invalid input") }
            if list.count > 20 { throw HTTPError(400, "eventTypes: Too big: expected array to have <=20 items") }
        }
    }

    static func typeName(_ value: JSON) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    func clean(name: String, prompt: String, botId: String, runOn: String, enabled: Bool, verificationPending: Bool?, eventTypes: [String]?) throws -> JSONObject {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let prompt = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
        let botId = botId.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw HTTPError(400, "Give the webhook a name") }
        if botId.isEmpty { throw HTTPError(400, "Choose a Bot") }
        var seen = Set<String>()
        let types = (eventTypes ?? []).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(20)
        var clean = JSONObject([
            ("name", .string(name)), ("prompt", .string(prompt)), ("botId", .string(botId)), ("runOn", .string(runOn)),
            ("enabled", .bool(enabled)), ("verificationPending", .bool(enabled ? false : verificationPending == true)),
        ])
        if !types.isEmpty { clean["eventTypes"] = .strings(Array(types)) }
        return clean
    }

    public func create(_ body: JSONObject) throws -> (webhook: JSONObject, secret: String) {
        try Self.check(body, partial: false)
        let clean = try clean(name: body["name"]?.string ?? "", prompt: body["prompt"]?.string ?? "", botId: body["botId"]?.string ?? "",
                              runOn: body["runOn"]?.string ?? "maus", enabled: body["enabled"]?.bool != false,
                              verificationPending: body["verificationPending"]?.bool, eventTypes: body["eventTypes"]?.array?.compactMap(\.string))
        if host.botState(clean["botId"]?.string ?? "") == "missing" { throw HTTPError(400, "That SWARMEno longer exists") }
        let now = nowMillis()
        let secret = "whsec_\(Self.base64url(32))"
        var trigger = JSONObject([("id", .string(newId())), ("endpointId", .string("wh_\(Self.base64url(12))"))]).merging(clean)
        trigger["secretHash"] = .string(Self.hash(secret))
        trigger["createdAt"] = .number(now)
        trigger["updatedAt"] = .number(now)
        trigger["deliveryCount"] = 0
        webhooks.insert(trigger, at: 0)
        save()
        emit(trigger)
        return (Self.publicTrigger(trigger), secret)
    }

    public func update(_ id: String, _ body: JSONObject) throws -> JSONObject? {
        guard let index = webhooks.firstIndex(where: { $0["id"]?.string == id }) else { return nil }
        try Self.check(body, partial: true)
        let current = webhooks[index]
        let clean = try clean(
            name: body["name"]?.string ?? current["name"]?.string ?? "", prompt: body["prompt"]?.string ?? current["prompt"]?.string ?? "",
            botId: body["botId"]?.string ?? current["botId"]?.string ?? "", runOn: body["runOn"]?.string ?? current["runOn"]?.string ?? "maus",
            enabled: body["enabled"]?.bool ?? current["enabled"]?.bool ?? true,
            verificationPending: body["verificationPending"]?.bool ?? current["verificationPending"]?.bool,
            eventTypes: (body["eventTypes"] ?? current["eventTypes"])?.array?.compactMap(\.string))
        if host.botState(clean["botId"]?.string ?? "") == "missing" { throw HTTPError(400, "That SWARMEno longer exists") }
        for (key, value) in clean { webhooks[index][key] = value }
        webhooks[index]["updatedAt"] = .number(nowMillis())
        if clean["eventTypes"] == nil { webhooks[index]["eventTypes"] = Optional<JSON>.none }
        if body["enabled"]?.bool == false { host.cancelQueued(id, "The webhook was paused before this delivery started") }
        save()
        emit(webhooks[index])
        return Self.publicTrigger(webhooks[index])
    }

    public func remove(_ id: String) -> Bool {
        guard let index = webhooks.firstIndex(where: { $0["id"]?.string == id }) else { return false }
        let trigger = webhooks.remove(at: index)
        let endpoint = trigger["endpointId"]?.string ?? ""
        deliveries.removeAll { ($0["key"]?.string ?? "").hasPrefix("\(endpoint):") }
        attempts.removeAll { $0["webhookId"]?.string == id }
        rate[endpoint] = nil
        host.cancelQueued(id, "The webhook was deleted before this delivery started")
        save()
        host.emit(["kind": "webhook.deleted", "webhookId": .string(id)])
        return true
    }

    public func rotateSecret(_ id: String) -> (webhook: JSONObject, secret: String)? {
        guard let index = webhooks.firstIndex(where: { $0["id"]?.string == id }) else { return nil }
        let secret = "whsec_\(Self.base64url(32))"
        webhooks[index]["secretHash"] = .string(Self.hash(secret))
        webhooks[index]["updatedAt"] = .number(nowMillis())
        save()
        emit(webhooks[index])
        return (Self.publicTrigger(webhooks[index]), secret)
    }

    public func disableForBot(_ botId: String) {
        var changed = false
        for index in webhooks.indices where webhooks[index]["botId"]?.string == botId && webhooks[index]["enabled"]?.bool == true {
            webhooks[index]["enabled"] = false
            webhooks[index]["updatedAt"] = .number(nowMillis())
            host.cancelQueued(webhooks[index]["id"]?.string ?? "", "The assigned SWARME Bot was deleted")
            emit(webhooks[index])
            changed = true
        }
        if changed { save() }
    }

    public func list() -> [JSONObject] { webhooks.map(Self.publicTrigger) }

    // MARK: Deliveries

    public func authorize(_ endpointId: String, _ secret: String) -> Bool {
        webhooks.first { $0["endpointId"]?.string == endpointId }.map { Self.secretMatches(secret, $0["secretHash"]?.string ?? "") } ?? false
    }

    public func receive(_ endpointId: String, secret: String, event: Event) throws -> JSONObject {
        guard let index = webhooks.firstIndex(where: { $0["endpointId"]?.string == endpointId }),
              Self.secretMatches(secret, webhooks[index]["secretHash"]?.string ?? "") else { throw HTTPError(401, "Invalid webhook URL or secret") }
        if webhooks[index]["verificationPending"]?.bool == true, webhooks[index]["enabled"]?.bool != true { return capture(index, event) }
        do {
            return try dispatch(index, event)
        } catch {
            let status = (error as? HTTPError)?.status ?? 500
            _ = recordRejected(index, status, (error as? HTTPError)?.message ?? error.localizedDescription, event)
            throw error
        }
    }

    public func test(_ id: String, payload: JSON?) throws -> JSONObject? {
        guard let index = webhooks.firstIndex(where: { $0["id"]?.string == id }) else { return nil }
        let name = webhooks[index]["eventTypes"]?.array?.first?.string ?? "swarme.test"
        return try dispatch(index, Event(payload: payload ?? ["event": "swarme.test", "message": "Test webhook delivery"],
                                         contentType: "application/json", eventName: name, userAgent: "SwarmeBot webhook tester",
                                         deliveryId: "test-\(newId())"))
    }

    public func recordRejected(endpointId: String, status: Int, reason: String, event: Event) {
        guard let index = webhooks.firstIndex(where: { $0["endpointId"]?.string == endpointId }) else { return }
        _ = recordRejected(index, status, reason, event)
    }

    private func dispatch(_ index: Int, _ event: Event) throws -> JSONObject {
        let trigger = webhooks[index]
        let id = trigger["id"]?.string ?? "", endpoint = trigger["endpointId"]?.string ?? ""
        if trigger["enabled"]?.bool != true { throw HTTPError(409, "This webhook is paused") }
        if host.botState(trigger["botId"]?.string ?? "") == "missing" { throw HTTPError(410, "The assigned SWARMEno longer exists") }
        let requested = String((event.deliveryId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))

        let allowed = trigger["eventTypes"]?.array?.compactMap(\.string) ?? []
        if !allowed.isEmpty, event.eventName.map({ !allowed.contains($0) }) ?? true {
            let deliveryId = requested.isEmpty ? newId() : requested
            appendAttempt(trigger, event, outcome: "ignored", status: 202, deliveryId: deliveryId,
                          reason: event.eventName.map { "Event type “\($0)” is not enabled" } ?? "Event type is missing")
            save()
            return ["deliveryId": .string(deliveryId), "duplicate": false, "ignored": true]
        }
        let now = nowMillis()
        if !requested.isEmpty, let duplicate = deliveries.first(where: { $0["key"]?.string == "\(endpoint):\(requested)" }) {
            appendAttempt(trigger, event, outcome: "duplicate", status: 202, deliveryId: requested,
                          runId: duplicate["runId"]?.string, reason: "Duplicate delivery ignored")
            save()
            return ["runId": duplicate["runId"] ?? .null, "deliveryId": .string(requested), "duplicate": true]
        }
        // a sender retrying an accepted delivery stays idempotent even when the queue is full
        if host.pendingRuns(id) >= Self.maxPendingRuns { throw HTTPError(429, "This webhook already has too many unfinished tasks") }
        var recent = (rate[endpoint] ?? []).filter { now - $0 < Self.rateWindowMillis }
        if recent.count >= Self.rateLimit { throw HTTPError(429, "Webhook rate limit exceeded") }
        recent.append(now)
        rate[endpoint] = recent

        let deliveryId = requested.isEmpty ? newId() : requested
        let run = try host.enqueue(id, trigger["name"]?.string ?? "", Self.prompt(trigger, event, receivedAt: now, deliveryId: deliveryId),
                                   trigger["botId"]?.string ?? "", trigger["runOn"]?.string ?? "maus", deliveryId, now)
        let runId = run["id"]?.string ?? ""
        deliveries.append(["key": .string("\(endpoint):\(deliveryId)"), "runId": .string(runId), "at": .number(now)])
        if deliveries.count > Self.maxDeliveries { deliveries.removeFirst(deliveries.count - Self.maxDeliveries) }
        webhooks[index]["lastReceivedAt"] = .number(now)
        webhooks[index]["lastRunId"] = .string(runId)
        webhooks[index]["deliveryCount"] = .number((trigger["deliveryCount"]?.double ?? 0) + 1)
        webhooks[index]["updatedAt"] = .number(now)
        appendAttempt(webhooks[index], event, outcome: "accepted", status: 202, deliveryId: deliveryId, runId: runId)
        save()
        emit(webhooks[index])
        return ["runId": .string(runId), "deliveryId": .string(deliveryId), "duplicate": false]
    }

    /// A UI-created hook captures one authenticated request before it may run.
    private func capture(_ index: Int, _ event: Event) -> JSONObject {
        let at = nowMillis()
        let requested = String((event.deliveryId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let deliveryId = requested.isEmpty ? newId() : requested
        webhooks[index]["verificationPending"] = false
        webhooks[index]["verifiedAt"] = .number(at)
        webhooks[index]["lastReceivedAt"] = .number(at)
        webhooks[index]["updatedAt"] = .number(at)
        var sample = JSONObject([("receivedAt", .number(at)), ("preview", .string(Self.preview(event.payload)))])
        if let name = event.eventName, !name.isEmpty { sample["eventName"] = .string(String(name.prefix(200))) }
        if let type = event.contentType, !type.isEmpty { sample["contentType"] = .string(String(type.prefix(200))) }
        webhooks[index]["verificationSample"] = .object(sample)
        appendAttempt(webhooks[index], event, outcome: "captured", status: 202, deliveryId: deliveryId,
                      reason: "Test event captured; enable the webhook to start SWARMEtasks")
        save()
        emit(webhooks[index])
        return ["deliveryId": .string(deliveryId), "duplicate": false, "captured": true]
    }

    private func recordRejected(_ index: Int, _ status: Int, _ reason: String, _ event: Event) -> JSONObject {
        let attempt = appendAttempt(webhooks[index], event, outcome: "rejected", status: status, deliveryId: event.deliveryId,
                                    reason: String(reason.prefix(500)))
        save()
        return attempt
    }

    @discardableResult
    private func appendAttempt(_ trigger: JSONObject, _ event: Event, outcome: String, status: Int, deliveryId: String? = nil,
                               runId: String? = nil, reason: String? = nil) -> JSONObject {
        var attempt = JSONObject([
            ("id", .string(newId())), ("webhookId", trigger["id"] ?? .null), ("receivedAt", .number(nowMillis())),
            ("outcome", .string(outcome)), ("statusCode", .number(Double(status))),
        ])
        if let name = event.eventName, !name.isEmpty { attempt["eventName"] = .string(String(name.prefix(200))) }
        if event.payload != nil { attempt["preview"] = .string(Self.preview(event.payload)) }
        if let deliveryId, !deliveryId.isEmpty { attempt["deliveryId"] = .string(String(deliveryId.prefix(200))) }
        if let runId, !runId.isEmpty { attempt["runId"] = .string(runId) }
        if let reason, !reason.isEmpty { attempt["reason"] = .string(reason) }
        attempts.append(attempt)
        if attempts.count > Self.maxAttempts { attempts.removeFirst(attempts.count - Self.maxAttempts) }
        host.emit(["kind": "webhook.attempt", "attempt": .object(attempt)])
        return attempt
    }

    private func emit(_ trigger: JSONObject) { host.emit(["kind": "webhook", "webhook": .object(Self.publicTrigger(trigger))]) }

    private func save() {
        let disk: JSON = ["version": 1, "webhooks": .array(webhooks.map(JSON.object)), "deliveries": .array(deliveries.map(JSON.object)),
                          "attempts": .array(attempts.map(JSON.object))]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileIO.writeAtomic(Data(disk.pretty().utf8), to: file, mode: 0o600)
    }
}

// MARK: - Ingress

public enum WebhookIngress {
    static func header(_ request: HTTPRequest, _ names: [String]) -> String? {
        for name in names { if let value = request.header(name) { return value.trimmingCharacters(in: .whitespaces).nilIfEmpty } }
        return nil
    }

    static func deliveryId(_ r: HTTPRequest) -> String? { header(r, ["idempotency-key", "x-webhook-id", "x-github-delivery", "webhook-id"]) }
    static func eventName(_ r: HTTPRequest) -> String? { header(r, ["x-github-event", "x-webhook-event", "x-event-type", "ce-type"]) }

    static func bearer(_ r: HTTPRequest) -> String {
        let authorization = r.header("authorization") ?? ""
        if let range = authorization.range(of: #"(?i)^Bearer\s+(.+)$"#, options: .regularExpression) {
            let value = authorization[range].replacingOccurrences(of: #"(?i)^Bearer\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return r.header("x-swarme-secret")?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? r.header("x-openmaus-secret")?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func respond(_ status: Int, _ body: JSON) -> RouteResult {
        .response(HTTPResponse(status: status, headers: [
            ("content-type", "application/json"), ("cache-control", "no-store"), ("x-content-type-options", "nosniff"),
        ], body: body.data))
    }

    /// Form bodies decode like URLSearchParams: `+` is a space, last key wins.
    static func form(_ raw: String) -> JSON {
        var object = JSONObject()
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            object[parts[0]] = .string(parts.count > 1 ? parts[1] : "")
        }
        return .object(object)
    }

    @MainActor
    public static func handle(_ r: HTTPRequest, manager: WebhookManager) -> RouteResult {
        if r.method == "GET", r.path == "/health" { return respond(200, ["app": "swarmebot-webhooks", "ready": true]) }
        guard let match = r.path.range(of: #"^/hooks/(wh_[A-Za-z0-9_-]+)(?:/([^/]+))?$"#, options: .regularExpression) else {
            return respond(404, ["error": "Unknown webhook endpoint"])
        }
        _ = match
        if r.method != "POST" { return respond(405, ["error": "Webhooks accept POST requests"]) }
        let parts = r.path.dropFirst("/hooks/".count).split(separator: "/", maxSplits: 1).map(String.init)
        let endpoint = parts[0]
        let pathSecret = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
        let secret = pathSecret.isEmpty ? bearer(r) : pathSecret
        let meta = WebhookManager.Event(contentType: r.header("content-type"), eventName: eventName(r), deliveryId: deliveryId(r))
        // bad capability URLs are refused before parsing anything
        guard manager.authorize(endpoint, secret) else {
            manager.recordRejected(endpointId: endpoint, status: 401, reason: "Invalid webhook URL or secret", event: meta)
            return respond(401, ["error": "Invalid webhook URL or secret"])
        }
        do {
            if r.body.count > WebhookManager.maxBodyBytes { throw HTTPError(413, "Webhook body is too large") }
            let raw = String(decoding: r.body, as: UTF8.self)
            let contentType = r.header("content-type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
            let payload: JSON
            if raw.isEmpty { payload = .object(JSONObject()) }
            else if contentType.contains("application/json") || contentType.contains("+json") {
                guard let parsed = try? JSON.parse(raw) else { throw HTTPError(400, "Invalid JSON webhook body") }
                payload = parsed
            } else if contentType.contains("application/x-www-form-urlencoded") { payload = form(raw) }
            else { payload = .string(raw) }
            let result = try manager.receive(endpoint, secret: secret, event: WebhookManager.Event(
                payload: payload, contentType: contentType, eventName: eventName(r), userAgent: r.header("user-agent"), deliveryId: deliveryId(r)))
            return respond(202, .object(JSONObject([("accepted", true)]).merging(result)))
        } catch {
            let status = (error as? HTTPError)?.status ?? 500
            let message = (error as? HTTPError)?.message ?? error.localizedDescription
            // receiver-level failures happen before the manager saw the payload
            if status == 400 || status == 413 { manager.recordRejected(endpointId: endpoint, status: status, reason: message, event: meta) }
            return respond(status, ["error": .string(message)])
        }
    }

    public static func credential(baseUrl: String, endpointId: String, secret: String) -> JSON {
        var base = baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        let endpointUrl = "\(base)/hooks/\(endpointId)"
        let encoded = secret.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")) ?? secret
        return ["endpointUrl": .string(endpointUrl), "secret": .string(secret), "url": .string("\(endpointUrl)/\(encoded)")]
    }
}
