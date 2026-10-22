// One paired remote engine, live: its event stream folded into
// `CompanionState`, and every action on its bots and rooms (plan §5).
//
// The phone loses the stream all the time — the app goes to the background,
// the screen locks, Wi-Fi hands over to cellular — so resuming is the normal
// path, not the exception (plan §5.4, D14):
// - the cursor survives a drop, and the next connection resumes from it
//   (`since`); the engine replays what was missed, or says `resumed:false`
//   and the session hydrates from REST;
// - going to the background closes the stream on purpose (iOS would kill it
//   anyway); coming back, or the network returning, reconnects at once;
// - the last fleet is cached, so the chats show before the first answer.
import CompanionCore
import Foundation
import Network
import Observation
import OSLog

private let log = Logger(subsystem: "it.hextra.swarmebot", category: "remote")

@MainActor
@Observable
final class RemoteSession: Identifiable {
    enum Status: Equatable {
        /// Showing the cached fleet, the stream not open yet.
        case cached
        case connecting
        case live
        case offline(String)
        /// The engine refused the token: revoked, or the engine was reset.
        case unpaired
    }

    let server: PairedServer
    nonisolated var id: String { server.id }
    private(set) var status: Status = .connecting
    private(set) var state = CompanionState()
    /// When the shown fleet was saved, while it is the cached one.
    private(set) var cachedAt: Date?
    var lastError: String?

    @ObservationIgnored private let client: CompanionClient?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var reconnectDelay: UInt64 = 0
    @ObservationIgnored private var active = false
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var lastPathSatisfied = true
    /// Hooks the app layer sets: a turn settled, a request opened.
    @ObservationIgnored var onNotify: ((NotificationFrame) -> Void)?

    init(server: PairedServer, session: URLSession = .shared) {
        self.server = server
        if let connection = server.connection {
            client = CompanionClient(connection: connection, token: Keychain.get(server.tokenAccount), session: session)
        } else {
            client = nil
            status = .offline(tr("Indirizzo del server non valido."))
        }
        if let cached = FleetCache.load(server.id) {
            state.hydrate(Fleet(bots: cached.bots, groups: cached.rooms))
            cachedAt = cached.savedAt
            status = .cached
        }
        path.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied) }
        }
        path.start(queue: .main)
    }

    // MARK: - Lifecycle

    /// The app is in the foreground: open the stream, resuming if it can.
    func resume() {
        active = true
        guard streamTask == nil, client != nil, status != .unpaired else { return }
        reconnectDelay = 0
        streamTask = Task { [weak self] in await self?.run() }
    }

    /// The app went to the background: close the stream, keep the cursor.
    func pause() {
        active = false
        streamTask?.cancel()
        streamTask = nil
        FleetCache.save(state, serverId: server.id)
    }

    func stop() {
        pause()
        path.cancel()
    }

    private func networkChanged(_ satisfied: Bool) {
        defer { lastPathSatisfied = satisfied }
        // back on a network: don't wait out the backoff
        guard satisfied, !lastPathSatisfied, active else { return }
        streamTask?.cancel()
        streamTask = nil
        resume()
    }

    private func run() async {
        defer { if !Task.isCancelled { streamTask = nil } }
        while !Task.isCancelled {
            guard let client else { return }
            if status != .cached { status = .connecting }
            do {
                for try await frame in try client.events(since: cursor) {
                    if Task.isCancelled { return }
                    reconnectDelay = 0
                    if case let .hello(helloCursor, resumed) = frame.frame {
                        if !resumed {
                            try await hydrate()
                            cursor = helloCursor
                        }
                        status = .live
                        cachedAt = nil
                        continue
                    }
                    advance(to: frame.seq)
                    state.apply(frame)
                    if case let .notify(notification) = frame.frame { onNotify?(notification) }
                }
                status = .offline(tr("Connessione al server persa."))
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                if (error as? APIError)?.isUnauthorized == true {
                    status = .unpaired
                    return
                }
                log.error("stream failed: \(error.localizedDescription, privacy: .public)")
                status = .offline(error.localizedDescription)
            }
            if Task.isCancelled { return }
            reconnectDelay = reconnectDelay == 0 ? 1 : min(reconnectDelay * 2, 15)
            try? await Task.sleep(nanoseconds: reconnectDelay * 1_000_000_000)
        }
    }

    private func hydrate() async throws {
        guard let client else { return }
        let fleet = try await client.fleet(messages: 100)
        try Task.checkCancellation()
        state.hydrate(fleet)
        FleetCache.save(state, serverId: server.id)
    }

    private func advance(to seq: Int?) {
        guard let seq, let cursor, let streamId = cursor.split(separator: ":").first else { return }
        self.cursor = "\(streamId):\(seq)"
    }

    // MARK: - Reading

    var isLive: Bool { status == .live }

    /// Bots the list shows: not hidden, pinned first.
    var visibleBots: [Bot] {
        let bots = state.bots.filter { $0.hidden != true }
        return bots.filter { $0.pinned == true } + bots.filter { $0.pinned != true }
    }

    func isBusy(_ bot: Bot) -> Bool {
        bot.busy == true || ["working", "waiting-on-you", "no-signal"].contains(bot.activity ?? "")
    }

    func transcript(_ threadId: String) -> [Message] {
        state.visibleTranscript(forThread: threadId)
    }

    // MARK: - Doing

    private func perform(_ body: (CompanionClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await body(client)
        } catch {
            if (error as? APIError)?.isUnauthorized == true { status = .unpaired }
            lastError = error.localizedDescription
        }
    }

    func send(_ text: String, to chat: ChatRef) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform { client in
            switch chat {
            case let .bot(id): try await client.send(text: trimmed, toBot: id)
            case let .room(id): try await client.send(text: trimmed, toRoom: id)
            }
        }
    }

    /// An image for the next message: the engine keeps it and the prompt
    /// carries its path (`<attached-image path="…"/>`).
    func attach(_ data: Data, mime: String) async -> String? {
        guard let client else { return nil }
        do {
            let saved = try await client.uploadAttachment(data, mime: mime)
            return "<attached-image path=\"\(saved.path)\"/>"
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Answer a card: a permission with allow/deny, a question with the
    /// chosen option as the message (the engine tells them apart by `behavior`).
    func answer(threadId: String, card: OptionCard, choice: String) async {
        guard let requestId = card.requestId else { return }
        await perform { client in
            if card.isPermission {
                let allow = choice.lowercased() == "allow"
                try await client.respond(threadId: threadId, requestId: requestId, behavior: allow ? "allow" : "deny")
            } else {
                try await client.respond(threadId: threadId, requestId: requestId, behavior: "answer", message: choice)
            }
        }
    }

    /// An approval answered from a notification: no card at hand, only its ids.
    func respond(threadId: String, requestId: String, allow: Bool) async {
        await perform { try await $0.respond(threadId: threadId, requestId: requestId, behavior: allow ? "allow" : "deny") }
    }

    /// This phone's relay token, so the engine can push to it (plan §6.1).
    func subscribePush(token: String, relayUrl: String) async {
        guard let client else { return }
        _ = try? await client.subscribePush(token: token, relayUrl: relayUrl)
    }

    func interrupt(_ chat: ChatRef) async {
        await perform { client in
            switch chat {
            case let .bot(id): try await client.interrupt(botId: id)
            case let .room(id): try await client.interrupt(roomId: id)
            }
        }
    }

    func markRead(_ chat: ChatRef) async {
        await perform { client in
            switch chat {
            case let .bot(id): try await client.markRead(botId: id)
            case let .room(id): try await client.markRead(roomId: id)
            }
        }
    }

    // MARK: - Chats of a bot (the engine's tasks)

    /// A bot's chats, newest first; the shown one is `bot.threadId`.
    func chats(of bot: Bot) -> [BotTask] {
        (bot.tasks ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    func newChat(_ botId: String) async {
        await perform { client in
            let bot = try await client.createTask(botId: botId)
            self.state.apply(.bot(bot))
        }
    }

    /// Show an older chat; its messages come from the engine when they are not here yet.
    func openChat(_ botId: String, threadId: String) async {
        await perform { client in
            let bot = try await client.switchTask(botId: botId, threadId: threadId)
            self.state.apply(.bot(bot))
            if self.state.messages[threadId]?.isEmpty != false {
                let page = try await client.messages(threadId: threadId)
                self.state.merge(page, intoThread: threadId)
            }
        }
    }

    func deleteChat(_ botId: String, threadId: String) async {
        await perform { client in
            let bot = try await client.deleteTask(botId: botId, threadId: threadId)
            self.state.apply(.bot(bot))
        }
    }

    /// The shown chat's messages, fetched if a switch made elsewhere left them out.
    func ensureLoaded(_ threadId: String) async {
        guard let client, state.messages[threadId]?.isEmpty != false else { return }
        if let page = try? await client.messages(threadId: threadId) { state.merge(page, intoThread: threadId) }
    }

    func loadOlder(_ threadId: String) async {
        guard let client, state.hasMore[threadId] == true else { return }
        let before = state.messages[threadId]?.first?.id
        do {
            let page = try await client.messages(threadId: threadId, before: before)
            state.prepend(page, toThread: threadId)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// A chat on a server: a bot or a room.
enum ChatRef: Hashable, Sendable {
    case bot(String)
    case room(String)
}
