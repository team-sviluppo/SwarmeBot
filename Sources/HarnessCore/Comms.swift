// Bot-to-bot comms — `server/{comms-visibility,peer-approval,delegations,
// chief-of-staff}.ts`, the `/api/internal/*` endpoints and `askBotAndWait`
// of `server/index.ts`.
//
// A bot reaches its peers through the `agents` MCP server (list_bots,
// ask_bot, delegate_bot; `swarme-harness mcp-agents`), which calls back
// into these loopback endpoints with the boot token. The harness stays the
// single owner of turns, permissions and recursion: depth 0 is a person's
// turn and may ask a peer; the peer runs at depth 1 and gets no tools.
//
// Every exchange is mirrored into a bot⇄bot channel and chipped into both
// 1:1 threads — those turns cost the user tokens, so none is invisible. A bot
// with `approvePeerComms` waits for a human card before each contact.
import Foundation

public enum PeerText {
    /// `mentionedBots`: @Name tags, longest names first, `user@host` is no tag.
    public static func mentioned(_ text: String, _ peers: [JSONObject]) -> [JSONObject] {
        let candidates = peers.filter { $0["hidden"]?.truthy != true && !($0["name"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0["name"]?.string ?? "").count > ($1["name"]?.string ?? "").count }
        let chars = Array(text)
        let lower = Array(text.lowercased())
        var found: [JSONObject] = []
        var at = 0
        while at < lower.count {
            defer { at += 1 }
            guard lower[at] == "@" else { continue }
            if at > 0, !chars[at - 1].isWhitespace { continue }
            let rest = String(lower[(at + 1)...])
            let hit = candidates.first { peer in
                let name = (peer["name"]?.string ?? "").lowercased()
                guard rest.hasPrefix(name) else { return false }
                let after = rest.dropFirst(name.count).first
                return after == nil || !(after!.isASCII && (after!.isLetter || after!.isNumber))
            }
            if let hit, !found.contains(where: { $0["id"] == hit["id"] }) { found.append(hit) }
        }
        return found
    }

    /// `roomResponders`: explicit tags win, else the room's policy.
    public static func responders(_ text: String, members: [JSONObject], policy: JSON?) -> [JSONObject] {
        let available = members.filter { $0["hidden"]?.truthy != true }
        if text.range(of: #"(?i)(?:^|\s)@everyone\b"#, options: .regularExpression) != nil { return available }
        let tagged = mentioned(text, available)
        if !tagged.isEmpty { return tagged }
        switch policy?["kind"]?.string {
        case "everyone": return available
        case "member":
            return available.first { $0["id"] == policy?["botId"] }.map { [$0] } ?? []
        default: return []
        }
    }

    static func clip(_ value: String, _ max: Int) -> String { value.count > max ? String(value.prefix(max - 1)) + "…" : value }

    /// `chiefOfStaffSystemPrompt`: the roster is user-editable (and imported)
    /// text in a trusted prompt, so it is capped.
    public static func chiefOfStaff(chiefId: String, bots: [JSONObject], canDelegate: Bool) -> String {
        let team = bots.filter { $0["id"]?.string != chiefId && $0["hidden"]?.truthy != true }
        let listed = team.prefix(40)
        let roster: String
        if team.isEmpty {
            roster = "- No other visible bots are available yet."
        } else {
            roster = listed.map { bot in
                let name = clip(bot["name"]?.string ?? "", 80)
                let title = (bot["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let role = clip(title.isEmpty ? "General assistant" : title, 120)
                let about = (bot["description"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return "- \(name) — \(role)\(about.isEmpty ? "" : ": \(clip(about, 200))") (\(bot["busy"]?.truthy == true ? "working right now" : "available"))"
            }.joined(separator: "\n") + (team.count > listed.count ? "\n- …and \(team.count - listed.count) more (use list_bots for the full roster)." : "")
        }
        let delegation = canDelegate
            ? ["Use list_bots to confirm the live roster and IDs. Use ask_bot when a teammate is better suited to part of the request.",
               "Delegate with a clear, self-contained brief and wait for the teammate's actual reply before claiming its work is complete.",
               "You may consult more than one teammate when the request genuinely benefits, then combine their results into one coherent answer."].joined(separator: " ")
            : "Your current engine cannot contact teammates. Be honest about that limitation and ask the user to choose a delegation-compatible engine before promising coordinated work."
        return [
            "You are the workspace's one Chief of Staff. You are the user's primary contact across their team of bots.",
            "Own the outcome: understand the request, decide what to handle yourself, coordinate the right specialists when useful, and return one concise consolidated answer.",
            "Do not delegate trivial work merely to appear busy. Never invent a teammate's progress or result. Normal permission and approval rules still apply.",
            delegation, "Current workspace team:", roster,
        ].joined(separator: "\n")
    }

    static func from(_ bot: JSONObject) -> JSON {
        ["botId": bot["id"] ?? .null, "name": bot["name"] ?? .null, "color": bot["color"] ?? .null]
    }
}

/// Peer-contact approvals: a card in the source thread, answered through the
/// ordinary respond routes, which ask here first (`resolve`).
@MainActor
public final class PeerApprovals {
    struct Pending {
        var resolve: (Bool) -> Void
        var timer: Task<Void, Never>
        var fromBotId: String
        var toBotId: String
        var threadId: String
        var messageId: String
    }

    private var pending: [String: Pending] = [:]
    private unowned let store: Store
    let timeout: TimeInterval

    init(store: Store, timeout: TimeInterval = 15 * 60) {
        self.store = store
        self.timeout = timeout
    }

    public static func allowKey(_ action: String, _ targetId: String) -> String { "\(action):\(targetId)" }

    /// A harness-native card never gets a request.resolved: it settles itself.
    private func settleCard(_ entry: Pending, _ behavior: String, user: Bool) {
        guard let message = store.messages(entry.threadId).first(where: { $0["id"]?.string == entry.messageId }),
              var card = message["card"]?.object, card["answered"]?.truthy != true else { return }
        card["answered"] = .string(behavior)
        card["dismissed"] = .bool(!user)
        store.patchMessage(entry.threadId, entry.messageId, ["card": .object(card)])
    }

    /// True = allowed. An `alwaysAllow` grant for (action, target) skips the card.
    func request(from: JSONObject, target: JSONObject, message: String, action: String, threadId: String) async -> Bool {
        let targetId = target["id"]?.string ?? ""
        if from["alwaysAllow"]?.array?.contains(.string(Self.allowKey(action, targetId))) == true { return true }
        return await withCheckedContinuation { continuation in
            let requestId = newId()
            let subtitle = message.count > 200 ? String(message.prefix(200)) + "…" : message
            // the card exists before the entry, so a timeout or answer can always find it
            let card = store.appendMessage(threadId, ["role": "bot", "kind": "options", "card": [
                "title": .string("@\(from["name"]?.string ?? "") wants to \(action == "ask_bot" ? "contact" : "delegate to") @\(target["name"]?.string ?? "")"),
                "subtitle": .string(subtitle), "options": ["Allow", "Deny", "Always allow"], "requestId": .string(requestId),
                "tool": .string(action), "allowKey": .string(Self.allowKey(action, targetId)),
            ]])
            let seconds = timeout
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self, let entry = self.pending.removeValue(forKey: requestId) else { return }
                self.settleCard(entry, "deny", user: false)
                entry.resolve(false)
            }
            pending[requestId] = Pending(resolve: { continuation.resume(returning: $0) }, timer: timer,
                                         fromBotId: from["id"]?.string ?? "", toBotId: targetId,
                                         threadId: threadId, messageId: card["id"]?.string ?? "")
        }
    }

    /// The respond routes call this first: true when the id was a peer card.
    public func resolve(_ requestId: String, behavior: String) -> Bool {
        guard let entry = pending.removeValue(forKey: requestId) else { return false }
        entry.timer.cancel()
        let allow = behavior == "allow"
        settleCard(entry, allow ? "allow" : "deny", user: true)
        entry.resolve(allow)
        return true
    }

    private func cancel(where predicate: (Pending) -> Bool) {
        for (requestId, entry) in pending where predicate(entry) {
            pending[requestId] = nil
            entry.timer.cancel()
            settleCard(entry, "deny", user: false)
            entry.resolve(false)
        }
    }

    public func cancelFor(botId: String) { cancel { $0.fromBotId == botId || $0.toBotId == botId } }
    public func cancelFor(threadId: String) { cancel { $0.threadId == threadId } }

    /// Cards a previous run left open can never be answered: settle them at boot.
    @discardableResult
    func dismissStale() -> Int {
        var dismissed = 0
        for bot in store.bots {
            var threads = [bot["threadId"]?.string].compactMap { $0 }
            threads += (bot["tasks"]?.array ?? []).compactMap { $0["threadId"]?.string }
            for threadId in Set(threads) {
                for message in store.messages(threadId) {
                    guard var card = message["card"]?.object, let requestId = card["requestId"]?.string,
                          card["answered"]?.truthy != true, card["dismissed"]?.truthy != true,
                          ["ask_bot", "delegate_bot"].contains(card["tool"]?.string ?? ""), pending[requestId] == nil,
                          let id = message["id"]?.string else { continue }
                    card["answered"] = "deny"
                    card["dismissed"] = true
                    if store.patchMessage(threadId, id, ["card": .object(card)]) != nil { dismissed += 1 }
                }
            }
        }
        return dismissed
    }
}

/// Queued async handoffs (delegate_bot), per source thread, persisted to
/// delegations.json so a handoff queued before a restart still runs after it.
@MainActor
public final class DelegationQueue {
    public struct Item {
        var id: String
        var toBotId: String
        var message: String
        var reason: String?
        var depth: Int

        var json: JSON {
            var o = JSONObject([("toBotId", .string(toBotId)), ("message", .string(message))])
            if let reason { o["reason"] = .string(reason) }
            o["depth"] = .number(Double(depth))
            o["id"] = .string(id)
            return .object(o)
        }
    }

    /// How many handoffs one turn may queue: the only thing between a
    /// confused bot and a fan-out of real turns.
    static let maxPerThread = 4

    private(set) var pending: [(threadId: String, items: [Item])] = []
    var draining: Set<String> = []
    private let file: URL

    init(file: URL) {
        self.file = file
        load()
    }

    private func load() {
        guard let raw = FileIO.readJSON(file)?.object else { return }
        for (threadId, list) in raw {
            let items: [Item] = (list.array ?? []).compactMap { value in
                guard let to = value["toBotId"]?.string, let message = value["message"]?.string,
                      let depth = value["depth"]?.double, depth.isFinite else { return nil }
                let id = value["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? newId()
                return Item(id: id, toBotId: to, message: message, reason: value["reason"]?.string, depth: max(0, Int(depth)))
            }
            if !items.isEmpty { pending.append((threadId, items)) }
        }
    }

    private func save() {
        var object = JSONObject()
        for entry in pending { object[entry.threadId] = .array(entry.items.map(\.json)) }
        try? FileIO.writeAtomic(Data(JSON.object(object).pretty().utf8), to: file)
    }

    func items(_ threadId: String) -> [Item] { pending.first { $0.threadId == threadId }?.items ?? [] }

    var threads: [String] { pending.map(\.threadId) }

    func append(_ threadId: String, _ item: Item) {
        if let index = pending.firstIndex(where: { $0.threadId == threadId }) { pending[index].items.append(item) }
        else { pending.append((threadId, [item])) }
        save()
    }

    func acknowledge(_ threadId: String, _ itemId: String) {
        guard let index = pending.firstIndex(where: { $0.threadId == threadId }) else { return }
        pending[index].items.removeAll { $0.id == itemId }
        if pending[index].items.isEmpty { pending.remove(at: index) }
        save()
    }

    @discardableResult
    func remove(_ threadId: String) -> [Item] {
        guard let index = pending.firstIndex(where: { $0.threadId == threadId }) else { return [] }
        let items = pending.remove(at: index).items
        save()
        return items
    }
}

// MARK: - The harness side

extension Harness {
    static let maxCommsDepth = 1

    /// The `agents` integration: this engine binary as an MCP server.
    func agentsIntegration(botId: String, threadId: String, depth: Int) -> MCPServer {
        MCPServer(command: HelperCommand.executable, args: ["mcp-agents"], env: [
            "OMB_HARNESS_URL": .string(harnessURL), "OMB_BOT_ID": .string(botId), "OMB_THREAD_ID": .string(threadId),
            "OMB_COMMS_TOKEN": .string(commsToken), "OMB_TURN_DEPTH": .string(String(depth)),
        ])
    }

    // MARK: Visibility

    func channel(_ from: JSONObject, _ target: JSONObject) -> JSONObject {
        let a = from["id"]?.string ?? "", b = target["id"]?.string ?? ""
        return store.dmGroup(a, b) ?? store.createGroup(name: "\(from["name"]?.string ?? "") ⇄ \(target["name"]?.string ?? "")",
                                                       memberIds: [a, b], dm: true)
    }

    private func comm(_ channel: JSONObject, with bot: JSONObject) -> JSON {
        ["groupId": channel["id"] ?? .null, "withBotId": bot["id"] ?? .null, "withName": bot["name"] ?? .null, "withColor": bot["color"] ?? .null]
    }

    /// The outgoing message in the channel, a chip in both 1:1 threads.
    func mirrorExchange(_ from: JSONObject, _ target: JSONObject, _ message: String, _ channel: JSONObject, sourceThreadId: String) {
        let channelThread = channel["threadId"]?.string ?? ""
        store.appendMessage(channelThread, ["role": "bot", "kind": "text", "text": .string(message), "from": PeerText.from(from)])
        store.appendMessage(sourceThreadId, ["role": "bot", "kind": "activity", "tool": ["name": .string("Messaged @\(target["name"]?.string ?? "")")],
                                             "comm": comm(channel, with: target)])
        store.appendMessage(target["threadId"]?.string ?? "", ["role": "bot", "kind": "activity",
                                                               "tool": ["name": .string("Message from @\(from["name"]?.string ?? "")")],
                                                               "comm": comm(channel, with: from)])
        store.patchGroup(channel["id"]?.string ?? "", ["unread": true])
    }

    func mirrorReply(_ target: JSONObject, _ reply: String, _ channel: JSONObject?) {
        guard let channel, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.appendMessage(channel["threadId"]?.string ?? "", ["role": "bot", "kind": "text", "text": .string(reply), "from": PeerText.from(target)])
        store.patchGroup(channel["id"]?.string ?? "", ["unread": true])
    }

    func mirrorActivity(_ bot: JSONObject, _ channel: JSONObject?, _ name: String, ok: Bool) {
        guard let channel else { return }
        store.appendMessage(channel["threadId"]?.string ?? "", ["role": "bot", "kind": "activity",
                                                                "tool": ["name": .string(name), "ok": .bool(ok)], "from": PeerText.from(bot)])
        store.patchGroup(channel["id"]?.string ?? "", ["unread": true])
    }

    // MARK: ask_bot

    /// The synchronous half of ask_bot: run a turn on the target and resolve
    /// with its text, on turn.completed or after 4 minutes.
    func askBotAndWait(_ targetId: String, _ message: String, depth: Int, fromBotId: String?) async -> String {
        guard let target = store.bot(targetId), let threadId = target["threadId"]?.string else { return "(no such bot)" }
        return await withCheckedContinuation { continuation in
            var text = ""
            var done = false
            var unsubscribe: () -> Void = {}
            var timer: Task<Void, Never>?
            let finish: (String) -> Void = { out in
                guard !done else { return }
                done = true
                timer?.cancel()
                unsubscribe()
                continuation.resume(returning: out)
            }
            unsubscribe = bus.subscribe { event in
                guard event.threadId == threadId else { return }
                if case let .textCompleted(reply) = event.body { text += (text.isEmpty ? "" : "\n") + reply }
                if case .turnCompleted = event.body { finish(text.isEmpty ? "(the bot finished without a text reply)" : text) }
            }
            timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                finish(text.isEmpty ? "(timed out waiting for the bot to reply)" : text)
            }
            do {
                try startTurn(botId: targetId, text: message, options: TurnOptions(commsDepth: depth + 1, unattended: isUnattended(fromBotId)))
            } catch {
                finish("(couldn't start that bot: \(error.localizedDescription))")
            }
        }
    }

    // MARK: Internal endpoints

    /// `/api/internal/*`: loopback + the boot token only. Nil = not ours.
    public func internalRoute(_ request: HTTPRequest) async -> HTTPResponse? {
        guard request.path.hasPrefix("/api/internal/") else { return nil }
        // constant-time compare: cheap to make safe
        let expected = Array("Bearer \(commsToken)".utf8), got = Array((request.header("authorization") ?? "").utf8)
        guard got.count == expected.count, zip(got, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .error(401, "unauthorized")
        }
        let body = (try? request.json()) ?? JSONObject()
        if request.path == "/api/internal/computer-control" { return computerControlRoute(request, body: body) }
        if request.path.hasPrefix("/api/internal/mcp-connectors/") { return await connectorInternalRoute(request, body: body) }
        switch (request.method, request.path) {
        case ("GET", "/api/internal/agents"):
            let me = request.query["self"]
            let bots: [JSON] = store.bots.filter { $0["id"]?.string != me && $0["hidden"]?.truthy != true }.map { bot in
                var row = JSONObject([("id", bot["id"] ?? .null), ("name", bot["name"] ?? .null),
                                      ("model", bot["modelSelection"]?["model"] ?? .null), ("busy", .bool(Store.isBusy(bot)))])
                if let title = bot["title"]?.string, !title.isEmpty { row["title"] = .string(title) }
                if let about = bot["description"]?.string, !about.isEmpty { row["description"] = .string(about) }
                return .object(row)
            }
            return .json(200, ["bots": .array(bots)])
        case ("POST", "/api/internal/ask-bot"):
            return Self.answer(await askBot(body))
        case ("POST", "/api/internal/delegate-bot"):
            return Self.answer(delegateBot(body))
        default:
            return .error(404, "not found")
        }
    }

    private func askBot(_ body: JSONObject) async -> JSON {
        let fromId = body["fromBotId"].flatMap(Self.text) ?? "", toId = body["toBotId"].flatMap(Self.text) ?? ""
        let message = (body["message"].flatMap(Self.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let depth = body["depth"]?.int ?? 0
        if toId.isEmpty || message.isEmpty { return ["error": "toBotId and message required", "__status": 400] }
        if toId == fromId { return ["error": "a bot cannot message itself", "__status": 400] }
        if depth >= Self.maxCommsDepth { return ["error": "message chains are limited to one hop"] }
        guard let target = store.bot(toId) else { return ["error": "no such bot", "__status": 404] }
        if Store.isBusy(target) { return ["busy": true] }
        // every peer turn has an accountable sender
        guard let from = store.bot(fromId) else { return ["error": "unknown sender", "__status": 403] }
        let sourceThread = body["fromThreadId"].flatMap(Self.text) ?? from["threadId"]?.string ?? ""
        guard store.taskByThread(fromId, sourceThread) != nil else { return ["error": "source thread does not belong to sender", "__status": 403] }
        var currentFrom = from, currentTarget = target
        if from["approvePeerComms"]?.truthy == true {
            guard await peerApprovals.request(from: from, target: target, message: message, action: "ask_bot", threadId: sourceThread) else {
                return ["error": "denied by user"]
            }
            // the card may have been open for minutes: re-read both
            guard let freshFrom = store.bot(fromId), let freshTarget = store.bot(toId) else { return ["error": "no such bot", "__status": 404] }
            guard store.taskByThread(fromId, sourceThread) != nil else { return ["error": "source task no longer exists", "__status": 404] }
            if Store.isBusy(freshTarget) { return ["busy": true] }
            currentFrom = freshFrom
            currentTarget = freshTarget
        }
        let room = channel(currentFrom, currentTarget)
        mirrorExchange(currentFrom, currentTarget, message, room, sourceThreadId: sourceThread)
        let prefixed = "[Message from @\(currentFrom["name"]?.string ?? ""), another bot in this SwarmeBot workspace. Reply to them.]\n\n\(message)"
        let reply = await askBotAndWait(toId, prefixed, depth: depth, fromBotId: fromId)
        mirrorReply(currentTarget, reply, room)
        return ["botName": currentTarget["name"] ?? .null, "text": .string(reply)]
    }

    private func delegateBot(_ body: JSONObject) -> JSON {
        let fromId = body["fromBotId"].flatMap(Self.text) ?? "", toId = body["toBotId"].flatMap(Self.text) ?? ""
        let message = (body["message"].flatMap(Self.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = body["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let depth = body["depth"]?.int ?? 0
        if toId.isEmpty || message.isEmpty { return ["error": "toBotId and message required", "__status": 400] }
        guard let from = store.bot(fromId) else { return ["error": "no such bot", "__status": 404] }
        let sourceThread = body["fromThreadId"].flatMap(Self.text) ?? from["threadId"]?.string ?? ""
        guard store.taskByThread(fromId, sourceThread) != nil else { return ["error": "source thread does not belong to sender", "__status": 403] }
        // the agent reads this string: a bare enum tells it nothing
        if toId == fromId { return ["error": "a bot cannot delegate to itself"] }
        if depth >= Self.maxCommsDepth { return ["error": "delegation chains are limited to one hop — do this one yourself"] }
        guard let target = store.bot(toId) else { return ["error": "no such bot"] }
        if delegations.items(sourceThread).count >= DelegationQueue.maxPerThread {
            return ["error": "too many delegations queued on this turn — finish some first"]
        }
        delegations.append(sourceThread, .init(id: newId(), toBotId: toId, message: message, reason: reason, depth: depth))
        let name = target["name"]?.string ?? toId
        store.appendMessage(sourceThread, ["role": "bot", "kind": "activity", "tool": ["name": .string("Delegated to @\(name)\(reason.map { ": \($0)" } ?? "")")]])
        return ["queued": true, "message": .string(from["approvePeerComms"]?.truthy == true
            ? "Queued for review — @\(name) will only pick it up if the user approves after your turn finishes."
            : "Delegation queued — @\(name) will pick it up after your current turn finishes.")]
    }

    /// Results carry their status in `__status` (absent = 200).
    nonisolated static func answer(_ result: JSON) -> HTTPResponse {
        var object = result.object ?? JSONObject()
        let status = object["__status"]?.int ?? 200
        object["__status"] = Optional<JSON>.none
        return status == 200 ? .json(200, .object(object)) : .error(status, object["error"]?.string ?? "")
    }

    nonisolated public static func text(_ value: JSON) -> String? {
        switch value {
        case let .string(s): return s
        case .null: return nil
        default: return value.serialized()
        }
    }

    // MARK: delegate_bot drain

    /// On the source turn's successful turn.completed. Each item on its own:
    /// a deny, a busy target or an error never stops the rest.
    func drainDelegations(_ threadId: String) {
        guard !delegations.draining.contains(threadId) else { return }
        let snapshot = delegations.items(threadId)
        guard !snapshot.isEmpty else { return }
        guard let from = store.botByThread(threadId) else {
            delegations.remove(threadId)
            return
        }
        delegations.draining.insert(threadId)
        Task { @MainActor in
            for item in snapshot {
                await self.processDelegation(from: from, sourceThreadId: threadId, item: item)
                self.delegations.acknowledge(threadId, item.id)
            }
            self.delegations.draining.remove(threadId)
            // a later turn may have queued while this one waited on approval
            if !self.delegations.items(threadId).isEmpty { self.drainDelegations(threadId) }
        }
    }

    /// The queueing turn failed or was stopped: drop its handoffs, say so.
    func discardDelegations(_ threadId: String) {
        let dropped = delegations.remove(threadId)
        guard !dropped.isEmpty, store.botByThread(threadId) != nil else { return }
        store.appendMessage(threadId, ["role": "bot", "kind": "activity", "tool": [
            "name": .string("\(dropped.count) queued delegation\(dropped.count > 1 ? "s" : "") dropped — the turn did not finish"), "ok": false,
        ]])
    }

    private func processDelegation(from: JSONObject, sourceThreadId: String, item: DelegationQueue.Item) async {
        let chip: (String) -> Void = { name in
            self.store.appendMessage(sourceThreadId, ["role": "bot", "kind": "activity", "tool": ["name": .string(name), "ok": false]])
        }
        var sender = from
        guard var target = store.bot(item.toBotId) else { return chip("error: delegation to \(item.toBotId) failed — no such bot") }
        let targetName = { (bot: JSONObject) in bot["name"]?.string ?? "" }
        if Store.isBusy(target) { return chip("Delegation to @\(targetName(target)) canceled — @\(targetName(target)) is busy") }
        if sender["approvePeerComms"]?.truthy == true {
            guard await peerApprovals.request(from: sender, target: target, message: item.message, action: "delegate_bot", threadId: sourceThreadId) else {
                return chip("Delegation to @\(targetName(target)) denied by user")
            }
            // up to 15 minutes may have passed: everything above is stale
            guard let current = store.bot(item.toBotId), let currentSender = store.bot(from["id"]?.string ?? ""),
                  store.taskByThread(currentSender["id"]?.string ?? "", sourceThreadId) != nil else { return }
            if Store.isBusy(current) { return chip("Delegation to @\(targetName(current)) canceled — @\(targetName(current)) is busy") }
            sender = currentSender
            target = current
        }
        let room = channel(sender, target)
        mirrorExchange(sender, target, item.message, room, sourceThreadId: sourceThreadId)
        let prefixed = "[Delegated by @\(targetName(sender)), another bot in this SwarmeBot workspace. Do the work and reply directly.]\n\n\(item.message)"
            + (item.reason.map { "\n\n[Reason: \($0)]" } ?? "")
        runDelegatedTurn(item.toBotId, prefixed, depth: item.depth + 1, sourceThreadId: sourceThreadId, channel: room)
    }

    /// Every failure of a delegated start lands as a chip, never as a crash.
    func runDelegatedTurn(_ toBotId: String, _ text: String, depth: Int, sourceThreadId: String, channel: JSONObject?) {
        let targetThread = store.bot(toBotId)?["threadId"]?.string
        if let targetThread { delegationWatch[targetThread] = (channel?["id"]?.string, toBotId) }
        var reported = false
        let report: (String) -> Void = { why in
            guard !reported else { return }
            reported = true
            if let targetThread { _ = self.finalizeDelegationWatch(targetThread, ok: false, failure: "Delegated turn could not start — \(why.prefix(120))") }
            guard self.store.botByThread(sourceThreadId) != nil else { return }
            let name = self.store.bot(toBotId)?["name"]?.string ?? toBotId
            self.store.appendMessage(sourceThreadId, ["role": "bot", "kind": "activity", "tool": [
                "name": .string("error: delegation to @\(name) could not start — \(why.prefix(120))"), "ok": false,
            ]])
        }
        do {
            try startTurn(botId: toBotId, text: text, options: TurnOptions(
                commsDepth: depth, unattended: isUnattended(store.botByThread(sourceThreadId)?["id"]?.string), onDispatchError: report
            ))
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Mirror exactly one terminal state of a delegated turn into its channel.
    @discardableResult
    func finalizeDelegationWatch(_ threadId: String, ok: Bool, reply: String = "", failure: String = "Delegated turn did not finish") -> Bool {
        guard let watched = delegationWatch.removeValue(forKey: threadId) else { return false }
        guard let target = store.bot(watched.toBotId), let room = watched.channelId.flatMap({ store.group($0) }) else { return true }
        if ok, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { mirrorReply(target, reply, room) }
        else if ok { mirrorActivity(target, room, "Delegated turn completed", ok: true) }
        else { mirrorActivity(target, room, failure, ok: false) }
        return true
    }

    // MARK: Unattended

    /// Bots working with nobody at the keyboard (a webhook turn, or a turn
    /// such a bot handed over). Auto mode does not apply to them. Keyed by bot;
    /// an idle mark expires after 30 minutes, a busy bot never ages out.
    func markUnattended(_ botId: String) { unattendedBots[botId] = Date() }
    func clearUnattended(_ botId: String) { unattendedBots[botId] = nil }

    func isUnattended(_ botId: String?) -> Bool {
        guard let botId, let at = unattendedBots[botId] else { return false }
        if Date().timeIntervalSince(at) > 30 * 60, !Store.isBusy(store.bot(botId)) {
            unattendedBots[botId] = nil
            return false
        }
        unattendedBots[botId] = Date()
        return true
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
