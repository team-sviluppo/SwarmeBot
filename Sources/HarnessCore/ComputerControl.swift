// Who is driving a bot's computer, and the live screen while it works —
// `server/computer-control.ts` and the screen poller of `server/index.ts`.
//
// Control: only the person takes and releases, from the panel; a bot can
// only ASK for hands. While the person holds control the bot's computer
// actions are refused, not queued (a queued click lands on whatever is under
// it later). Releasing also settles an open help request. In memory on
// purpose: a hold that survived a restart would silently brick a computer.
//
// Screen: frames go out as SSE `screen` while the bot works; the last one
// becomes a `screen` message when the turn settles — only if the turn
// actually reached for the screen.
import Foundation

@MainActor
public final class ComputerControl {
    struct Entry {
        var heldSince: Double?
        var helpReason: String?
        var helpRequestId: String?
    }

    private var entries: [String: Entry] = [:]
    private var sequence = 0
    var onChange: (String, JSONObject) -> Void = { _, _ in }

    public func snapshot(_ botId: String) -> JSONObject {
        let entry = entries[botId]
        return ["held": .bool(entry?.heldSince != nil), "helpReason": JSON.from(entry?.helpReason),
                "heldSinceMs": entry?.heldSince.map(JSON.number) ?? .null]
    }

    private func changed(_ botId: String) -> JSONObject {
        let snapshot = snapshot(botId)
        onChange(botId, snapshot)
        return snapshot
    }

    /// Idempotent: a second click must not make the hold look newer.
    public func take(_ botId: String) -> JSONObject {
        if entries[botId]?.heldSince != nil { return snapshot(botId) }
        var entry = entries[botId] ?? Entry()
        entry.heldSince = nowMillis()
        entries[botId] = entry
        return changed(botId)
    }

    public func release(_ botId: String) -> JSONObject {
        guard entries.removeValue(forKey: botId) != nil else { return snapshot(botId) }
        return changed(botId)
    }

    /// A plea shouted while one is open keeps the first, which the person may still be reading.
    public func requestHelp(_ botId: String, reason: JSON?) -> (snapshot: JSONObject, requestId: String) {
        let text = String((reason?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        var entry = entries[botId] ?? Entry()
        if entry.helpReason == nil {
            sequence += 1
            entry.helpReason = text.isEmpty ? "the bot asked you to take over" : text
            entry.helpRequestId = "\(botId)-\(sequence)"
        }
        entries[botId] = entry
        return (changed(botId), entry.helpRequestId!)
    }

    public func dismissHelp(_ botId: String) -> JSONObject {
        guard var entry = entries[botId], entry.helpReason != nil else { return snapshot(botId) }
        entry.helpReason = nil
        entry.helpRequestId = nil
        entries[botId] = entry.heldSince == nil ? nil : entry
        return changed(botId)
    }

    /// The id check keeps an old proxy's timeout from dismissing a newer plea.
    public func expireHelp(_ botId: String, requestId: JSON?) -> JSONObject {
        guard var entry = entries[botId], entry.helpRequestId != nil, requestId?.string == entry.helpRequestId else { return snapshot(botId) }
        entry.helpReason = nil
        entry.helpRequestId = nil
        entries[botId] = entry.heldSince == nil ? nil : entry
        return changed(botId)
    }

    public func forget(_ botId: String) {
        if entries.removeValue(forKey: botId) != nil { onChange(botId, snapshot(botId)) }
    }
}

/// One bot's live screen for one turn.
@MainActor
final class ScreenPoller {
    static let interval: TimeInterval = 6
    static let minGap: TimeInterval = 3

    let capture: () async throws -> (png: String, format: String)
    let publish: (JSONObject) -> Void
    var last: JSONObject?
    /// Did this turn reach for the screen? Otherwise nothing settles.
    var touched: Bool
    private var current: Task<Void, Never>?
    private var lastAt = Date.distantPast
    private var ticker: Task<Void, Never>?

    init(touched: Bool, capture: @escaping () async throws -> (png: String, format: String), publish: @escaping (JSONObject) -> Void) {
        self.touched = touched
        self.capture = capture
        self.publish = publish
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.grab()
            }
        }
    }

    /// One capture at a time, shared by the ticks, the pokes and the final
    /// grab; the floor keeps previews off the box's single command endpoint.
    func grab() async {
        if current == nil, Date().timeIntervalSince(lastAt) < Self.minGap { return }
        if current == nil {
            current = Task { @MainActor in
                if let frame = try? await self.capture() {
                    let shot: JSONObject = ["png": .string(frame.png), "mime": .string(frame.format == "jpeg" ? "image/jpeg" : "image/png")]
                    self.last = shot
                    self.publish(shot)
                }
                self.lastAt = Date()
                self.current = nil
            }
        }
        await current?.value
    }

    func stop() { ticker?.cancel() }
}

extension Harness {
    func startScreenPoller(_ botId: String, screenIsTheWork: Bool, capture: @escaping () async throws -> (png: String, format: String)) {
        guard screenPollers[botId] == nil else { return }
        screenPollers[botId] = ScreenPoller(touched: screenIsTheWork, capture: capture) { [weak self] frame in
            self?.broadcast(JSONObject([("kind", "screen"), ("botId", .string(botId))]).merging(frame))
        }
    }

    /// The bot just acted on its screen: refresh now, and count the turn as screen work.
    func pokeScreenPoller(_ botId: String) {
        guard let poller = screenPollers[botId] else { return }
        poller.touched = true
        Task { await poller.grab() }
    }

    func stopScreenPoller(_ botId: String) {
        screenPollers.removeValue(forKey: botId)?.stop()
    }

    /// Turn end: one last fresh frame (after any in-flight poke), if the turn touched the screen.
    func finalScreenFrame(_ botId: String) async -> JSONObject? {
        guard let poller = screenPollers.removeValue(forKey: botId) else { return nil }
        poller.stop()
        guard poller.touched else { return nil }
        await poller.grab()
        return poller.last
    }

    /// `/api/internal/computer-control`: the proxies read the hold, bots plead for help.
    func computerControlRoute(_ request: HTTPRequest, body: JSONObject) -> HTTPResponse {
        let botId = request.query["botId"] ?? ""
        guard let bot = store.bot(botId) else { return .error(404, "no such bot") }
        let state = { (snapshot: JSONObject) -> JSONObject in ["held": snapshot["held"] ?? false, "helpOpen": .bool(!(snapshot["helpReason"]?.isNull ?? true))] }
        switch request.method {
        case "GET":
            return .json(200, .object(state(computerControl.snapshot(botId))))
        case "POST":
            let (snapshot, requestId) = computerControl.requestHelp(botId, reason: body["reason"])
            // worth a buzz: the bot is blocked on the person's hands
            notify("takeover", bot: bot, threadId: bot["threadId"]?.string ?? "", detail: snapshot["helpReason"]?.string ?? "asked you to take over")
            var out = state(snapshot)
            out["requestId"] = .string(requestId)
            return .json(200, .object(out))
        case "DELETE":
            return .json(200, .object(state(computerControl.expireHelp(botId, requestId: body["requestId"]))))
        default:
            return .error(405, "method not allowed")
        }
    }
}
