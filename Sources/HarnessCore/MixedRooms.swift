// Mixed channels: a room whose members live on more than one engine.
//
// A channel lives on one host — an engine, or the phone — and the members
// from other engines are its guests (`guests` on the host's room). For a
// guest's turn the host calls the guest's engine, `POST /api/guest-turns`,
// with the channel's recent conversation. There the bot speaks in a mirror
// room (`guest` set): it copies the host's conversation, keeps the bot's
// tools and approvals, and only its host writes in it. Each member works in
// its own engine's folders: a folder is shared only within one engine.
//
// The engines a host may call are handed over by the Mac app
// (`PUT /api/peer-engines`) and kept in memory only, so the device tokens
// they carry never land on this engine's disk.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PeerEngine: Sendable {
    public var id: String
    public var name: String
    /// The engine's chat URL (`https://…/<prefix>`): routes go after it.
    public var url: String
    public var token: String
}

/// A guest member's id in its host room: `peer:<peerId>:<botId>`.
enum GuestId {
    static func make(peer: String, bot: String) -> String { "peer:\(peer):\(bot)" }

    static func parse(_ id: String) -> (peer: String, bot: String)? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "peer", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (parts[1], parts[2])
    }
}

extension Harness {
    static let maxGuestMessages = 60
    static let maxGuestRoster = 40

    // MARK: Members

    /// A room's members as its turns see them: its bots, then its guests
    /// (`id`, `name`, `color`, `title`, enough for mentions and prompts).
    func roomMembers(_ group: JSONObject) -> [JSONObject] {
        let bots = (group["memberIds"]?.array ?? []).compactMap { $0.string.flatMap { store.bot($0) } }
        let guests = (group["guests"]?.array ?? []).compactMap { guest -> JSONObject? in
            guard let peer = guest["peerId"]?.string, let bot = guest["botId"]?.string else { return nil }
            return JSONObject([("id", .string(GuestId.make(peer: peer, bot: bot))), ("name", guest["name"] ?? "Bot"),
                               ("color", guest["color"] ?? "blue"), ("title", guest["title"] ?? "")])
        }
        return bots + guests
    }

    /// `@Name (title)` for every member: a mirror room has the host's list.
    func roomRoster(_ group: JSONObject) -> [String] {
        if let roster = group["guest"]?["roster"]?.array { return roster.compactMap(\.string) }
        return roomMembers(group).map { member in
            let title = member["title"]?.string ?? ""
            return "@\(member["name"]?.string ?? "")\(title.isEmpty ? "" : " (\(title))")"
        }
    }

    /// The human's name in a room's prompts: the host's, in a mirror room.
    func roomUserName(_ group: JSONObject) -> String {
        let name = group["guest"]?["userName"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? userName : name
    }

    /// `guests` of a create or patch body, checked against the known engines.
    func parseGuests(_ value: JSON?) -> [JSON]? {
        guard let list = value?.array else { return nil }
        return list.compactMap { guest -> JSON? in
            guard let peer = guest["peerId"]?.string, peerEngines[peer] != nil,
                  let bot = guest["botId"]?.string, !bot.isEmpty, !bot.contains(":") else { return nil }
            let name = guest["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var out = JSONObject([("peerId", .string(peer)), ("botId", .string(bot)), ("name", .string(name.isEmpty ? "Bot" : name)),
                                  ("color", .string(guest["color"]?.string ?? "blue"))])
            if let title = guest["title"]?.string, !title.isEmpty { out["title"] = .string(title) }
            return .object(out)
        }
    }

    // MARK: Engines a host may call

    /// `PUT /api/peer-engines` `{name?, engines: [{id, name, url, token}]}`: the whole list, replaced.
    func setPeerEngines(_ body: JSONObject) -> HTTPResponse {
        var engines: [String: PeerEngine] = [:]
        for item in body["engines"]?.array ?? [] {
            guard let id = item["id"]?.string, !id.isEmpty, !id.contains(":"),
                  let url = item["url"]?.string, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? ""),
                  let token = item["token"]?.string, !token.isEmpty else { return .error(400, "every engine needs id, url and token") }
            engines[id] = PeerEngine(id: id, name: item["name"]?.string ?? id, url: url.trimmingSuffix("/"), token: token)
        }
        peerEngines = engines
        if let name = body["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { hostName = name }
        return .json(200, ["engines": .array(engines.values.sorted { $0.name < $1.name }.map { ["id": .string($0.id), "name": .string($0.name)] })])
    }

    // MARK: Host side

    enum GuestOutcome {
        case reply(text: String, ref: String?)
        case busy
        case failed(String)
        case cancelled
    }

    /// A guest member speaks: its engine runs the turn, the reply lands here.
    /// False = stopped by the user: nobody else speaks this round.
    func runPeerMemberTurn(groupId: String, memberId: String, hop: Int, spoken: inout Set<String>) async -> Bool {
        guard let group = store.group(groupId), let threadId = group["threadId"]?.string,
              let member = roomMembers(group).first(where: { $0["id"]?.string == memberId }),
              let (peerId, botId) = GuestId.parse(memberId) else { return true }
        spoken.insert(memberId)
        let name = member["name"]?.string ?? "Bot"
        let from: JSON = ["botId": .string(memberId), "name": .string(name), "color": member["color"] ?? "blue"]
        let chip = { (text: String) in
            _ = self.store.appendMessage(threadId, ["role": "bot", "kind": "activity", "from": from, "tool": ["name": .string(text), "ok": false]])
        }
        guard let peer = peerEngines[peerId] else {
            chip("\(name)'s server is not connected to this engine — open SwarmeBot on this Mac to reconnect it")
            return true
        }
        store.patchGroup(groupId, ["busyBotId": .string(memberId)])
        let body = guestTurnBody(group, botId: botId)
        let timeout = Double(config.roomTurnTimeoutMinutes) * 60 + 30
        let call = Task { await Self.callGuest(peer, body: body, timeout: timeout) }
        peerTurns[groupId] = (peer, groupId, call)
        let outcome = await call.value
        peerTurns[groupId] = nil
        if store.group(groupId)?["busyBotId"]?.string == memberId { store.patchGroup(groupId, ["busyBotId": .null, "unread": true]) }

        switch outcome {
        case .cancelled:
            return false
        case .busy:
            chip("\(name) is busy in another conversation — skipped this round")
            return true
        case let .failed(message):
            chip("error: \(name): \(String(message.prefix(140)))")
            return true
        case let .reply(text, ref):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            var message: JSONObject = ["role": "bot", "kind": "text", "text": .string(text), "from": from]
            if let ref { message["guestRef"] = .string(ref) }
            store.appendMessage(threadId, message)
            return await chainMentions(groupId: groupId, speakerId: memberId, reply: text, hop: hop, spoken: &spoken)
        }
    }

    /// A reply can bring teammates in, here or on other engines: one hop only.
    func chainMentions(groupId: String, speakerId: String, reply: String, hop: Int, spoken: inout Set<String>) async -> Bool {
        guard hop < Self.maxRoomHops, let group = store.group(groupId), group["guest"] == nil,
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let teammates = roomMembers(group).filter { $0["id"]?.string != speakerId }
        for next in PeerText.responders(reply, members: teammates, policy: ["kind": "mentions"]) {
            guard let nextId = next["id"]?.string, !spoken.contains(nextId) else { continue }
            if !(await runGroupMemberTurn(groupId: groupId, botId: nextId, hop: hop + 1, spoken: &spoken)) { return false }
        }
        return true
    }

    /// What the guest's engine needs: who is in the channel and its recent text.
    func guestTurnBody(_ group: JSONObject, botId: String) -> JSON {
        let threadId = group["threadId"]?.string ?? ""
        let messages: [JSON] = store.messages(threadId)
            .filter { $0["kind"]?.string == "text" && !($0["text"]?.string ?? "").isEmpty }
            .suffix(Self.roomContextMessages)
            .map { message in
                let user = message["role"]?.string == "user"
                var out = JSONObject([("id", message["id"] ?? .null), ("role", .string(user ? "user" : "bot")),
                                      ("name", .string(user ? userName : message["from"]?["name"]?.string ?? "Bot")),
                                      ("text", message["text"] ?? "")])
                if !user, let color = message["from"]?["color"] { out["color"] = color }
                if let ref = message["guestRef"] { out["ref"] = ref }
                return .object(out)
            }
        return .object(JSONObject([
            ("conversationId", group["id"] ?? .null), ("name", group["name"] ?? ""), ("botId", .string(botId)),
            ("roster", .strings(roomRoster(group))), ("userName", .string(userName)), ("hostName", .string(hostName)),
            ("messages", .array(messages)),
        ]))
    }

    nonisolated static func callGuest(_ peer: PeerEngine, body: JSON, timeout: Double, session: URLSession = .shared) async -> GuestOutcome {
        guard let url = URL(string: peer.url + "/api/guest-turns") else { return .failed("bad server address") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body.data
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSON.parse(data)
            if status == 409, json?["busy"]?.truthy == true { return .busy }
            guard status == 200 else { return .failed(json?["error"]?.string ?? "HTTP \(status)") }
            return .reply(text: json?["text"]?.string ?? "", ref: json?["messageId"]?.string)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .failed(error.localizedDescription)
        }
    }

    /// Stop a guest's turn: the call here, the turn on its engine.
    func interruptPeerTurn(_ groupId: String) async {
        guard let turn = peerTurns[groupId] else { return }
        turn.task.cancel()
        guard let url = URL(string: turn.peer.url + "/api/guest-turns/interrupt") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(turn.peer.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = JSON.object(["conversationId": .string(turn.conversationId)]).data
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: Guest side

    /// The mirror of a host's channel, for the device that hosts it.
    func mirrorRoom(deviceId: String, conversationId: String) -> JSONObject? {
        store.groups.first { $0["guest"]?["deviceId"]?.string == deviceId && $0["guest"]?["conversationId"]?.string == conversationId }
    }

    /// `POST /api/guest-turns`: one of this engine's bots speaks in a channel
    /// hosted elsewhere. Answers when the turn is over: `{text, messageId}`.
    func guestTurn(_ body: JSONObject, deviceId: String) async -> HTTPResponse {
        let conversationId = body["conversationId"]?.string ?? ""
        guard conversationId.range(of: #"^[\w:.-]{1,128}$"#, options: .regularExpression) != nil else {
            return .error(400, "conversationId required")
        }
        guard let botId = body["botId"]?.string, let bot = store.bot(botId) else { return .error(404, "no such bot") }
        let incoming = (body["messages"]?.array ?? []).suffix(Self.maxGuestMessages)
        let name = String((body["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }?.prefix(200)
                          ?? "Channel")
        var guest = JSONObject([("conversationId", .string(conversationId)), ("deviceId", .string(deviceId))])
        if let host = body["hostName"]?.string, !host.isEmpty { guest["hostName"] = .string(String(host.prefix(120))) }
        if let user = body["userName"]?.string, !user.isEmpty { guest["userName"] = .string(String(user.prefix(120))) }
        guest["roster"] = .strings((body["roster"]?.array ?? []).compactMap(\.string).prefix(Self.maxGuestRoster).map { String($0.prefix(200)) })

        var room = mirrorRoom(deviceId: deviceId, conversationId: conversationId)
            ?? store.createGroup(name: name, memberIds: [botId])
        let groupId = room["id"]?.string ?? ""
        var members = room["memberIds"]?.array?.compactMap(\.string) ?? []
        if !members.contains(botId) { members.append(botId) }
        room = store.patchGroup(groupId, ["name": .string(name), "memberIds": .strings(members), "guest": .object(guest),
                                          "defaultResponder": ["kind": "mentions"]]) ?? room
        if Store.isBusy(bot) { return .json(409, ["busy": true, "error": "bot is busy"]) }
        if let busy = room["busyBotId"]?.string, !busy.isEmpty { return .json(409, ["busy": true, "error": "the channel is busy"]) }

        // the host's conversation, once: by its ids, and our own replies by `ref`
        let threadId = room["threadId"]?.string ?? ""
        let known = store.messages(threadId)
        let hostIds = Set(known.compactMap { $0["hostId"]?.string })
        let ownIds = Set(known.compactMap { $0["id"]?.string })
        for message in incoming {
            guard let id = message["id"]?.string, !hostIds.contains(id) else { continue }
            if let ref = message["ref"]?.string, ownIds.contains(ref) { continue }
            let text = String((message["text"]?.string ?? "").prefix(20_000))
            guard !text.isEmpty else { continue }
            if message["role"]?.string == "user" {
                store.appendMessage(threadId, ["role": "user", "kind": "text", "text": .string(text), "hostId": .string(id)])
            } else {
                let from: JSON = ["botId": .string("host:" + (message["name"]?.string ?? "")), "name": message["name"] ?? "Bot",
                                  "color": message["color"] ?? "blue"]
                store.appendMessage(threadId, ["role": "bot", "kind": "text", "text": .string(text), "from": from, "hostId": .string(id)])
            }
        }

        let before = store.messages(threadId).count
        var spoken = Set<String>()
        _ = await runGroupMemberTurn(groupId: groupId, botId: botId, hop: 0, spoken: &spoken)
        let said = store.messages(threadId).dropFirst(before).filter { $0["from"]?["botId"]?.string == botId }
        let replies = said.filter { $0["kind"]?.string == "text" && !($0["text"]?.string ?? "").isEmpty }
        if replies.isEmpty, let failure = said.last(where: { $0["kind"]?.string == "activity" && $0["tool"]?["ok"]?.bool == false }) {
            return .error(502, failure["tool"]?["name"]?.string ?? "the bot did not reply")
        }
        return .json(200, ["text": .string(replies.compactMap { $0["text"]?.string }.joined(separator: "\n\n")),
                           "messageId": replies.last?["id"] ?? .null])
    }

    /// `POST /api/guest-turns/interrupt` `{conversationId}`.
    func interruptGuestTurn(_ body: JSONObject, deviceId: String) async -> HTTPResponse {
        guard let room = mirrorRoom(deviceId: deviceId, conversationId: body["conversationId"]?.string ?? ""),
              let id = room["id"]?.string else { return .error(404, "no such channel") }
        _ = await interruptGroup(id)
        return .json(200, ["ok": true])
    }
}
