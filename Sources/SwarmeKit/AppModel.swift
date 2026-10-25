// The app's state, observable.
//
// `CompanionState` is the pure fold; this is the thing that feeds it — owns
// the harness, the event stream and its reconnects — and the place every
// view action goes through. It mirrors the iOS companion's `Session`, minus
// pairing (the Mac talks to its own harness on loopback, no token) and plus
// what only a desktop does (edit bots, pick models, sections).
import CompanionCore
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.swarmebot.mac", category: "stream")

/// A chat in the sidebar: a bot or a room. Both are addressed by id; the
/// thread id is what the transcript is keyed by.
public enum ChatID: Hashable, Sendable {
    case bot(String)
    case room(String)
}

@MainActor
@Observable
public final class AppModel {
    public enum Status: Equatable {
        case starting(String)
        case connecting
        case live
        case offline(String)
        case failed(String)
    }

    public internal(set) var status: Status = .starting(tr("Avvio…"))
    public internal(set) var state = CompanionState()
    /// Live reply text, apart from `state` so a delta redraws only the
    /// bubble it belongs to. See LiveText.swift.
    public let live = LiveText()
    public internal(set) var instances: [Instance] = []
    public internal(set) var config: ConfigStatus?
    /// Settings › Connettori: MCP servers bots can be given.
    public internal(set) var mcpConnectors: [MCPConnector] = []
    /// Settings › Skill: instruction folders bots can be given, and where the engine keeps them.
    public internal(set) var skills: [Skill] = []
    public internal(set) var skillsFolder: SkillsFolder?
    /// The engine's secrets vault, without values (AppModel+Vault.swift).
    public internal(set) var vault: VaultState?
    /// Where the transcript should land after a search jump.
    public var focusMessageId: String?
    public internal(set) var webhookIngress: WebhookIngress?
    /// UI routing that menu commands need to reach.
    public var showPalette = false
    public var showNewRoom = false
    public var selection: ChatID?
    /// The last error an action produced, for a transient banner.
    public var lastError: String?
    /// Config or engines could not be read: settings would show empty fields.
    public var loadError: String?

    @ObservationIgnored private let launcher = HarnessLauncher()
    @ObservationIgnored public internal(set) var client: CompanionClient?
    /// The files each settled reply points at, by thread and message (AppModel+Desktop.swift).
    @ObservationIgnored var replyFileCache: [String: [ReplyFile]] = [:]
    /// Code mode: the git state of each chat's folder, by thread (AppModel+CodeMode.swift).
    public internal(set) var gitStates: [String: ThreadGitState] = [:]
    /// Which engine the window shows: this Mac's, or a remote one (AppModel+Remote.swift).
    public internal(set) var engineChoice: EngineChoice = .local
    public internal(set) var remoteEngines: [RemoteEngine] = []
    /// The engines not shown, streaming for the sidebar (EnginePeer.swift).
    public internal(set) var peers: [EngineChoice: EnginePeer] = [:]
    @ObservationIgnored let remoteStore = RemoteEngineStore()
    @ObservationIgnored let identityStore = SSHIdentityStore()
    /// The local engine's port once it runs, so switching back needs no restart.
    @ObservationIgnored var localPort: Int?
    @ObservationIgnored var streamTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectDelay: UInt64 = 0
    @ObservationIgnored private var screenWatchers = 0
    /// The stream position, kept outside `state` for the same reason as
    /// `live`: it moves on every frame, and nothing on screen shows it.
    @ObservationIgnored var cursor: String?
    @ObservationIgnored var stateVersion = 0
    @ObservationIgnored var visibleCache: [String: (version: Int, messages: [Message])] = [:]
    /// Hooks the app layer sets: system notifications and the Dock badge.
    @ObservationIgnored public var onNotify: ((NotificationFrame) -> Void)?
    @ObservationIgnored public var onUnreadChange: ((Int) -> Void)?
    /// A settings window's model (AppModel+Settings.swift): config, engines,
    /// connectors and skills of one engine, no chats, no harness of its own.
    @ObservationIgnored public private(set) var settingsOnly = false
    @ObservationIgnored weak var owner: AppModel?
    /// The settings-only models of the engines the window does not show.
    @ObservationIgnored var settingsModels: [EngineChoice: AppModel] = [:]

    public init() {
        launcher.onChange = { [weak self] state in self?.harnessChanged(state) }
        remoteEngines = remoteStore.all()
        engineChoice = EngineChoice.restored(from: remoteEngines)
    }

    init(settingsFor choice: EngineChoice, owner: AppModel) {
        settingsOnly = true
        self.owner = owner
        remoteEngines = owner.remoteEngines
        engineChoice = choice
        localPort = owner.localPort
    }

    // MARK: - Lifecycle

    public func start() {
        // a remote engine does not wait for the local one to boot
        if case .remote = engineChoice { connectToChoice() }
        syncPeers()
        Task { await launcher.start() }
    }

    public func shutdown() {
        streamTask?.cancel()
        streamTask = nil
        for peer in peers.values { peer.stop() }
        launcher.stop()
    }

    public var engine: HarnessEngine { HarnessEngine.selected }

    public func retry() {
        // restarting this Mac's engine is the window's model's job
        if settingsOnly, let owner { return owner.retry() }
        streamTask?.cancel()
        streamTask = nil
        start()
    }

    private func harnessChanged(_ harness: HarnessState) {
        // the local engine's progress only matters while it is the one shown
        if case let .running(port, _) = harness { localEngineRunning(on: port) }
        guard engineChoice == .local else {
            if case let .running(port, _) = harness {
                localPort = port
                syncPeers()
            }
            return
        }
        switch harness {
        case .idle:
            break
        case let .starting(message):
            status = .starting(message)
        case let .failed(message):
            status = .failed(message)
        case let .running(port, _):
            localPort = port
            handOverPeerEngines()
            if engineChoice == .local { connectToChoice() }
        }
    }

    func connect() {
        streamTask?.cancel()
        reconnectDelay = 0
        streamTask = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let client else { return }
            status = .connecting
            do {
                for try await frame in try client.events(since: cursor, screens: screenWatchers > 0) {
                    if Task.isCancelled { return }
                    reconnectDelay = 0
                    if case let .hello(helloCursor, resumed) = frame.frame {
                        if !resumed {
                            if !settingsOnly { try await hydrate() }
                            cursor = helloCursor
                        }
                        status = .live
                        Task { await self.refreshInstances() }
                        Task { await self.refreshConfig() }
                        if !settingsOnly { Task { await self.refreshAutomations() } }
                        Task { await self.refreshMCPConnectors() }
                        Task { await self.refreshSkills() }
                        continue
                    }
                    advance(to: frame.seq)
                    if settingsOnly {
                        settingsFrame(frame.frame)
                        continue
                    }
                    switch frame.frame {
                    case let .runtime(event):
                        // the hot path: never touches `state`
                        live.apply(event)
                        continue
                    case let .message(threadId, message) where message.role == .bot && message.kind == .text:
                        live.clear(threadId)
                    case let .thread(threadId, _):
                        live.clear(threadId)
                    default:
                        break
                    }
                    // a run that just started: show its chat (read before the frame lands)
                    var started: RoutineRun?
                    if case let .routineRun(run) = frame.frame, run.status == "running", run.threadId != nil,
                       state.routineRuns.first(where: { $0.id == run.id })?.status != "running" {
                        started = run
                    }
                    state.apply(frame)
                    stateVersion &+= 1
                    if let started { Task { await self.show(run: started) } }
                    if case .config = frame.frame {
                        Task { await self.refreshInstances() }
                        Task { await self.refreshConfig() }
                    }
                    if case let .usageLimit(instanceId, limit) = frame.frame,
                       let index = instances.firstIndex(where: { $0.instanceId == instanceId }) {
                        instances[index].usageLimit = limit
                    }
                    if case .mcpConnectors = frame.frame {
                        Task { await self.refreshMCPConnectors() }
                    }
                    if case .skills = frame.frame {
                        Task { await self.refreshSkills() }
                    }
                    if case .vault = frame.frame {
                        Task { await self.refreshVault() }
                    }
                    if case let .notify(notification) = frame.frame { onNotify?(notification) }
                    onUnreadChange?(state.unreadCount)
                }
                status = .offline(tr("Connessione al motore persa."))
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                log.error("stream failed: \(error.localizedDescription, privacy: .public)")
                status = .offline(offlineReason(error))
            }
            if Task.isCancelled { return }
            reconnectDelay = reconnectDelay == 0 ? 1 : min(reconnectDelay * 2, 8)
            try? await Task.sleep(nanoseconds: reconnectDelay * 1_000_000_000)
        }
    }

    func hydrate() async throws {
        guard let client else { return }
        // The desktop shows long threads; 200 is a first screenful with room
        // to scroll before the first scrollback fetch.
        let fleet = try await client.fleet(messages: 200)
        // switched to another engine meanwhile: this fleet is not the one shown
        try Task.checkCancellation()
        state.hydrate(fleet)
        stateVersion &+= 1
        // a chat this engine does not have (gone, or of another engine) would
        // leave "Nessuna chat selezionata" with the list full of bots
        if selection == nil || (selectedBot == nil && selectedRoom == nil) { selection = defaultSelection }
    }

    public func refreshInstances() async {
        guard let client else { return }
        do {
            instances = try await client.instances()
            loadError = nil
        } catch {
            loadError = tr("Non riesco a leggere i motori di %@: %@", engineName, error.localizedDescription)
        }
    }

    private func advance(to seq: Int?) {
        guard let seq, let cursor, let streamId = cursor.split(separator: ":").first else { return }
        self.cursor = "\(streamId):\(seq)"
    }

    /// The visible branch of a thread, computed once per change to the
    /// state rather than once per view per render — walking a 5,000-message
    /// branch is cheap once and expensive sixty times a second.
    public func visibleTranscript(_ threadId: String) -> [Message] {
        let current = state // registers the observation, as a direct read would
        if let cached = visibleCache[threadId], cached.version == stateVersion { return cached.messages }
        let messages = current.visibleTranscript(forThread: threadId)
        visibleCache[threadId] = (stateVersion, messages)
        return messages
    }

    /// Any local change to `state` outside the stream must call this.
    func stateDidChange() {
        stateVersion &+= 1
    }

    /// Ask the stream to carry screen frames while something shows them.
    public func watchScreens(_ on: Bool) {
        screenWatchers = max(0, screenWatchers + (on ? 1 : -1))
        if (on && screenWatchers == 1) || (!on && screenWatchers == 0) { connect() }
    }

    // MARK: - Reading

    private var defaultSelection: ChatID? {
        if let pinned = visibleBots.first { return .bot(pinned.id) }
        return state.rooms.first.map { .room($0.id) }
    }

    /// Bots the sidebar shows: not hidden, pinned first, then newest.
    public var visibleBots: [Bot] {
        state.bots.filter { $0.hidden != true }
    }

    /// Sidebar sections, in first-seen order; unlabeled bots go last.
    public var sections: [(name: String?, bots: [Bot])] { Self.sections(of: visibleBots) }

    public static func sections(of visibleBots: [Bot]) -> [(name: String?, bots: [Bot])] {
        var order: [String?] = []
        var grouped: [String?: [Bot]] = [:]
        for bot in visibleBots {
            let key = bot.section?.isEmpty == false ? bot.section : nil
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(bot)
        }
        order.sort { a, b in a != nil && b == nil }
        return order.map { key in
            let bots = grouped[key] ?? []
            return (key, bots.filter { $0.pinned == true } + bots.filter { $0.pinned != true })
        }
    }

    public var selectedBot: Bot? {
        guard case let .bot(id) = selection else { return nil }
        return state.bot(id)
    }

    public var selectedRoom: Room? {
        guard case let .room(id) = selection else { return nil }
        return state.rooms.first { $0.id == id }
    }

    public var selectedThreadId: String? {
        selectedBot?.threadId ?? selectedRoom?.threadId
    }

    public func instance(_ id: String) -> Instance? {
        instances.first { $0.instanceId == id }
    }

    /// The label a bot's model shows in the composer.
    public func modelLabel(for bot: Bot) -> String {
        guard let instance = instance(bot.modelSelection.instanceId) else {
            return bot.modelSelection.model.isEmpty ? tr("Nessun modello") : bot.modelSelection.model
        }
        let model = instance.models.options.first { $0.id == bot.modelSelection.model }?.label ?? bot.modelSelection.model
        return model
    }

    public func isBusy(_ bot: Bot) -> Bool {
        bot.busy == true || ["working", "waiting-on-you", "no-signal"].contains(bot.activity ?? "")
    }

    // MARK: - Doing

    func perform(_ body: (CompanionClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await body(client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch selection {
        case let .bot(id): await perform { try await $0.send(text: trimmed, toBot: id) }
        case let .room(id): await perform { try await $0.send(text: trimmed, toRoom: id) }
        case nil: break
        }
    }

    public func interrupt() async {
        switch selection {
        case let .bot(id): await perform { try await $0.interrupt(botId: id) }
        case let .room(id): await perform { try await $0.interrupt(roomId: id) }
        case nil: break
        }
    }

    /// Answer a card. Permission cards answer allow/deny; questions answer
    /// with the chosen option as the message.
    public func answer(threadId: String, card: OptionCard, choice: String) async {
        guard let requestId = card.requestId else { return }
        // Permission cards answer allow/deny; a question answers with the
        // chosen text. The harness tells them apart by `behavior`.
        if card.isPermission {
            let allow = choice.lowercased() == "allow"
            await perform {
                try await $0.respond(threadId: threadId, requestId: requestId, behavior: allow ? "allow" : "deny")
            }
        } else {
            await perform {
                try await $0.respond(threadId: threadId, requestId: requestId, behavior: "answer", message: choice)
            }
        }
    }

    public func alwaysAllow(threadId: String, card: OptionCard) async {
        guard let key = card.allowKey, let bot = state.bot(forThread: threadId) ?? selectedBot else { return }
        await perform { try await $0.alwaysAllow(botId: bot.id, key: key) }
        await answer(threadId: threadId, card: card, choice: "Allow")
    }


    public func patch(_ bot: Bot, _ patch: BotPatch) async {
        await perform { try await $0.patchBot(bot.id, patch) }
    }

    public func delete(_ bot: Bot) async {
        await perform { try await $0.deleteBot(bot.id) }
        if selection == .bot(bot.id) { selection = defaultSelection }
    }

    public func setModel(_ bot: Bot, instanceId: String, model: String, effort: String? = nil) async {
        await patch(bot, BotPatch(modelSelection: ModelSelection(instanceId: instanceId, model: model, effort: effort)))
    }

    public func markRead(_ chat: ChatID) async {
        switch chat {
        case let .bot(id):
            guard state.bot(id)?.unread == true else { return }
            await perform { try await $0.markRead(botId: id) }
        case let .room(id):
            guard state.rooms.first(where: { $0.id == id })?.unread == true else { return }
            await perform { try await $0.markRead(roomId: id) }
        }
    }

    public func loadOlder(threadId: String) async {
        guard let client, state.hasMore[threadId] == true,
              let first = state.transcript(forThread: threadId).first else { return }
        do {
            let page = try await client.messages(threadId: threadId, before: first.id, limit: 100)
            state.prepend(page, toThread: threadId)
            stateDidChange()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func search(_ query: String) async -> [SearchHit] {
        guard let client, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return (try? await client.search(query)) ?? []
    }

    public func image(threadId: String, messageId: String) async -> Data? {
        try? await client?.image(threadId: threadId, messageId: messageId)
    }

    public func react(threadId: String, messageId: String, emoji: String) async {
        await perform { _ = try await $0.toggleReaction(threadId: threadId, messageId: messageId, emoji: emoji) }
    }

    public func export(threadId: String) async -> TranscriptExport? {
        try? await client?.export(threadId: threadId, format: "markdown")
    }
}

extension Instance {
    /// The name the app shows: the engine's, except for the OpenAI-compatible
    /// server, named as on the phone (the engine keeps "Local Endpoint" on the wire).
    public var shownName: String {
        driverKind == "localEndpoint" ? tr("Server compatibile OpenAI") : displayName ?? driverKind
    }
}
