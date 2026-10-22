// The phone's channels: several bots in one conversation, as the engine's
// rooms (HarnessCore/Rooms.swift) — a message goes to the channel's default
// responder unless it @mentions members; responders speak one at a time,
// each a fresh turn with the channel's recent conversation in the prompt; a
// reply that @mentions a teammate brings it in, one hop only.
//
// Members are the phone's bots and, in a mixed channel, bots of the paired
// servers: a guest's turn runs on its server (`POST /api/guest-turns`,
// HarnessCore/MixedRooms.swift), which keeps a mirror of the channel. Nothing
// is shared but the conversation: each bot keeps its own model, connectors
// and, on a server, its own folders.
import AgentCore
import CompanionCore
import Foundation
import Observation
import UIKit

/// One member of a phone channel.
enum RoomMember {
    case phone(LocalBot)
    case guest(RoomGuest)

    var id: String {
        switch self {
        case let .phone(bot): return bot.id
        case let .guest(guest): return guest.memberId
        }
    }

    var name: String {
        switch self {
        case let .phone(bot): return bot.name
        case let .guest(guest): return guest.name
        }
    }

    /// A mascot palette name.
    var color: String {
        switch self {
        case let .phone(bot): return bot.paletteColor
        case let .guest(guest): return guest.color.hasPrefix("#") ? "blue" : guest.color
        }
    }
}

extension LocalBots {
    func room(_ id: String) -> LocalRoom? { rooms.first { $0.id == id } }

    /// A room's members, in order: the phone's bots, then the guests.
    func members(of room: LocalRoom) -> [RoomMember] {
        room.memberIds.compactMap(bot).map(RoomMember.phone) + (room.guests ?? []).map(RoomMember.guest)
    }

    @discardableResult
    func addRoom(name: String, memberIds: [String], guests: [RoomGuest] = []) -> LocalRoom {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = memberIds.compactMap { bot($0)?.name } + guests.map(\.name)
        let room = LocalRoom(id: newId(), name: trimmed.isEmpty ? names.joined(separator: ", ") : trimmed, memberIds: memberIds,
                             guests: guests.isEmpty ? nil : guests, createdAt: Date())
        save(room)
        return room
    }

    func save(_ room: LocalRoom) {
        store?.save(room)
        if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = room } else { rooms.append(room) }
    }

    func delete(_ room: LocalRoom) {
        roomChats.removeValue(forKey: room.id)?.stop()
        store?.delete(room: room.id)
        rooms.removeAll { $0.id == room.id }
    }

    func roomChat(_ id: String) -> LocalRoomChat {
        if let known = roomChats[id] { return known }
        let chat = LocalRoomChat(roomId: id, owner: self)
        roomChats[id] = chat
        return chat
    }

    func markRead(room id: String) {
        guard var room = room(id), room.unread == true else { return }
        room.unread = nil
        save(room)
    }

    /// A channel's turn ended with replies: unread and told about, unless it is on screen.
    func roomReplied(_ id: String, speaker: String, text: String) {
        guard var room = room(id) else { return }
        let notifier = Notifier.shared
        guard !(notifier.active && notifier.onScreen == Notifier.key(phoneRoom: id)) else { return }
        room.unread = true
        save(room)
        notifier.deliver(phoneRoom: room, speaker: speaker, reply: text)
    }
}

/// One channel's conversation: the messages, the reply streaming, who speaks.
@MainActor
@Observable
final class LocalRoomChat {
    static let contextMessages = 30
    static let maxHops = 1

    let roomId: String
    private(set) var messages: [LocalMessage] = []
    private(set) var streaming = ""
    /// The member speaking now (`RoomMember.id`).
    private(set) var speaker: String?
    private(set) var busy = false
    var lastError: String?

    @ObservationIgnored private weak var owner: LocalBots?
    @ObservationIgnored private var turn: Task<Void, Never>?
    /// The server a guest is speaking on, to stop its turn there too.
    @ObservationIgnored private var guestSpeaking: RemoteSession?

    init(roomId: String, owner: LocalBots) {
        self.roomId = roomId
        self.owner = owner
        messages = owner.store?.messages(bot: roomId) ?? []
    }

    private func append(_ message: LocalMessage) {
        messages.append(message)
        owner?.store?.save(message)
    }

    private func update(_ message: LocalMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
        owner?.store?.save(message)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty, let owner, let room = owner.room(roomId) else { return }
        Notifier.shared.requestPermission()
        append(LocalMessage(id: newId(), botId: roomId, role: .user, text: trimmed, at: Date()))
        let responders = Self.responders(trimmed, members: owner.members(of: room), room: room)
        guard !responders.isEmpty else { return }
        busy = true
        lastError = nil
        turn = Task { [weak self] in
            guard let self else { return }
            var spoken = Set<String>()
            var last: (String, String)?
            for member in responders where !spoken.contains(member.id) {
                guard await self.speak(member, hop: 0, spoken: &spoken, last: &last) else { break }
            }
            self.streaming = ""
            self.speaker = nil
            self.busy = false
            self.turn = nil
            if let (name, reply) = last { self.owner?.roomReplied(self.roomId, speaker: name, text: reply) }
        }
    }

    func stop() {
        turn?.cancel()
        if let session = guestSpeaking {
            let roomId = roomId
            Task { await session.interruptGuestTurn(conversationId: roomId) }
        }
    }

    /// One member's turn, then the teammates its reply mentions. False stops
    /// the round (stopped by the user).
    private func speak(_ member: RoomMember, hop: Int, spoken: inout Set<String>, last: inout (String, String)?) async -> Bool {
        guard !Task.isCancelled, let owner, let room = owner.room(roomId) else { return false }
        spoken.insert(member.id)
        speaker = member.id
        streaming = ""
        let reply: String?
        switch member {
        case let .phone(bot): reply = await speakHere(bot, in: room)
        case let .guest(guest): reply = await speakThere(guest, in: room)
        }
        streaming = ""
        guard let reply else { return false }
        guard !reply.isEmpty else { return true }
        last = (member.name, reply)
        if hop < Self.maxHops {
            let teammates = owner.members(of: room).filter { $0.id != member.id }
            for next in Self.mentioned(reply, teammates) where !spoken.contains(next.id) {
                guard await speak(next, hop: hop + 1, spoken: &spoken, last: &last) else { return false }
            }
        }
        return true
    }

    /// A phone bot's turn. Nil when stopped; empty when it said nothing.
    private func speakHere(_ bot: LocalBot, in room: LocalRoom) async -> String? {
        guard let owner else { return nil }
        var member = bot
        member.instructions = Self.system(for: bot, in: room, roster: roster(room))
        // the conversation is in the prompt: no session to continue
        member.sessionId = nil
        let prompt = LocalMessage(id: newId(), botId: roomId, role: .user,
                                  text: "\(context())\n\n(Reply to the conversation above as \(bot.name).)", at: Date())
        let input = TurnInput(bot: member, server: owner.server(for: bot), history: [], latest: prompt, images: [],
                              tools: owner.toolBox(for: bot))
        let roomId = roomId
        let sink = TurnSink(
            delta: { [weak self] piece in self?.streaming += piece },
            toolStarted: { [weak self] title, arguments in
                let message = LocalMessage(id: newId(), botId: roomId, role: .tool, text: "", at: Date(),
                                           tool: LocalToolCall(name: title, ok: nil, input: arguments, output: nil), from: bot.id)
                self?.append(message)
                return message.id
            },
            toolDone: { [weak self] id, ok, output in
                guard let self, var message = self.messages.first(where: { $0.id == id }) else { return }
                message.tool?.ok = ok
                message.tool?.output = String(output.prefix(4_000))
                self.update(message)
            },
            note: { [weak self] text in
                self?.append(LocalMessage(id: newId(), botId: roomId, role: .note, text: text, at: Date(), from: bot.id))
            })
        do {
            let outcome = try await owner.driver(bot.kind).run(input, sink: sink)
            let reply = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty { append(LocalMessage(id: newId(), botId: roomId, role: .bot, text: reply, at: Date(), from: bot.id)) }
            return reply
        } catch {
            let aborted = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            let partial = streaming.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                append(LocalMessage(id: newId(), botId: roomId, role: .bot, text: partial, at: Date(), interrupted: true, from: bot.id))
            }
            if aborted { return nil }
            append(LocalMessage(id: newId(), botId: roomId, role: .note, text: "\(bot.name): \(error.localizedDescription)", at: Date(),
                                from: bot.id))
            return ""
        }
    }

    /// A guest's turn, on its server. Nil when stopped; empty when it said nothing.
    private func speakThere(_ guest: RoomGuest, in room: LocalRoom) async -> String? {
        let note = { (text: String) in
            self.append(LocalMessage(id: newId(), botId: self.roomId, role: .note, text: text, at: Date(), from: guest.memberId))
        }
        guard let session = owner?.remoteSession?(guest.peerId) else {
            note(tr("%@: il suo server non è più abbinato a questo telefono.", guest.name))
            return ""
        }
        guestSpeaking = session
        defer { guestSpeaking = nil }
        let outcome = await session.guestTurn(conversationId: roomId, name: room.name, botId: guest.botId, roster: roster(room),
                                              userName: "User", hostName: UIDevice.current.name, messages: guestMessages())
        if Task.isCancelled { return nil }
        switch outcome {
        case let .success(.reply(text, messageId)):
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                append(LocalMessage(id: newId(), botId: roomId, role: .bot, text: reply, at: Date(), from: guest.memberId, guestRef: messageId))
            }
            return reply
        case .success(.busy):
            note(tr("%@ è occupato in un'altra conversazione: salta questo giro.", guest.name))
            return ""
        case let .failure(error):
            note("\(guest.name): \(error.localizedDescription)")
            return ""
        }
    }

    /// The recent conversation as a guest's engine wants it.
    private func guestMessages() -> [GuestMessage] {
        messages.filter { ($0.role == .user || $0.role == .bot) && !$0.text.isEmpty }
            .suffix(Self.contextMessages)
            .map { message in
                if message.role == .user { return GuestMessage(id: message.id, isUser: true, name: "User", text: message.text) }
                let member = message.from.flatMap(member)
                return GuestMessage(id: message.id, isUser: false, name: member?.name ?? "Bot", color: member?.color, text: message.text,
                                    ref: message.guestRef)
            }
    }

    /// A member of this channel by id, also one that has left (for old messages).
    func member(_ id: String) -> RoomMember? {
        guard let owner else { return nil }
        if let bot = owner.bot(id) { return .phone(bot) }
        return owner.room(roomId)?.guests?.first { $0.memberId == id }.map(RoomMember.guest)
    }

    private func roster(_ room: LocalRoom) -> [String] {
        (owner?.members(of: room) ?? []).map { "@\($0.name)" }
    }

    /// The recent conversation, one line per message: "Name: text".
    private func context() -> String {
        messages.filter { ($0.role == .user || $0.role == .bot) && !$0.text.isEmpty }
            .suffix(Self.contextMessages)
            .map { message in
                let name = message.role == .user ? "User" : message.from.flatMap(member)?.name ?? "Bot"
                return "\(name): \(message.text)"
            }
            .joined(separator: "\n")
    }

    /// The engine's room prompt, after the bot's own instructions.
    static func system(for bot: LocalBot, in room: LocalRoom, roster: [String]) -> String {
        [
            bot.instructions.isEmpty ? nil : bot.instructions,
            "You are \(bot.name), a bot in the room \"\(room.name)\" in SwarmeBot.",
            "Room members: \(roster.joined(separator: ", ")), and User (the human).",
            "Reply as yourself, briefly and conversationally. To bring a teammate in, mention them like @Name — they'll see the conversation and respond.",
        ].compactMap { $0 }.joined(separator: "\n")
    }

    /// Explicit tags win (`@everyone` is all of them), else the channel's default.
    static func responders(_ text: String, members: [RoomMember], room: LocalRoom) -> [RoomMember] {
        if text.range(of: #"(?i)(?:^|\s)@everyone\b"#, options: .regularExpression) != nil { return members }
        let tagged = mentioned(text, members)
        if !tagged.isEmpty { return tagged }
        return room.defaultResponders.compactMap { id in members.first { $0.id == id } }
    }

    /// @Name tags, longest names first; `user@host` is no tag (PeerText.mentioned).
    static func mentioned(_ text: String, _ members: [RoomMember]) -> [RoomMember] {
        let candidates = members.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.name.count > $1.name.count }
        let chars = Array(text)
        let lower = Array(text.lowercased())
        var found: [RoomMember] = []
        for at in lower.indices where lower[at] == "@" {
            if at > 0, !chars[at - 1].isWhitespace { continue }
            let rest = String(lower[(at + 1)...])
            let hit = candidates.first { member in
                let name = member.name.lowercased()
                guard rest.hasPrefix(name) else { return false }
                guard let after = rest.dropFirst(name.count).first else { return true }
                return !(after.isASCII && (after.isLetter || after.isNumber))
            }
            if let hit, !found.contains(where: { $0.id == hit.id }) { found.append(hit) }
        }
        return found
    }
}
