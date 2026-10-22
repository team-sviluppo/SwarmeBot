// The phone's bots, observable (plan §4): the list, their chats and the
// connectors, over LocalStore; turns run in-process through a driver per
// kind. Nothing here leaves the phone except the requests to the bot's own
// endpoint and connectors (D5).
import AgentCore
import CompanionCore
import Foundation
import Observation

@MainActor
@Observable
final class LocalBots {
    private(set) var bots: [LocalBot] = []
    private(set) var connectors: [LocalConnector] = []
    var lastError: String?

    @ObservationIgnored let store: LocalStore?
    @ObservationIgnored let pool = ConnectorPool()
    @ObservationIgnored private var chats: [String: LocalChat] = [:]
    @ObservationIgnored private lazy var endpointDriver = EndpointDriver()
    @ObservationIgnored private lazy var appleDriver = AppleDriver()
    @ObservationIgnored lazy var gemma = GemmaModel()

    init(store: LocalStore? = try? LocalStore()) {
        self.store = store
        bots = store?.bots() ?? []
        connectors = store?.connectors() ?? []
        // bots from before several chats: their one chat becomes the first of the list
        for var bot in bots where bot.chats == nil {
            let first = store?.messages(bot: bot.id).first { $0.role == .user }
            bot.chats = [LocalChatSummary(id: bot.id, title: first.map { Self.title($0.text) } ?? "", createdAt: bot.createdAt,
                                          sessionId: bot.sessionId)]
            save(bot)
        }
    }

    static func title(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(60) ?? "")
    }

    func bot(_ id: String) -> LocalBot? { bots.first { $0.id == id } }

    /// The chat a bot shows now.
    func chat(_ botId: String) -> LocalChat {
        let key = bot(botId)?.currentChatKey ?? botId
        if let known = chats[key] { return known }
        let chat = LocalChat(key: key, botId: botId, owner: self)
        chats[key] = chat
        return chat
    }

    // MARK: Chats of a bot

    /// A new chat on top; the shown one stays when it is still empty.
    func newChat(_ botId: String) {
        guard var bot = bot(botId), !chat(botId).messages.isEmpty else { return }
        let summary = LocalChatSummary(id: newId(), title: "", createdAt: Date())
        bot.chats = [summary] + (bot.chats ?? [])
        bot.currentChat = summary.id
        save(bot)
    }

    func openChat(_ botId: String, key: String) {
        guard var bot = bot(botId) else { return }
        bot.currentChat = key == bot.id ? nil : key
        save(bot)
    }

    func deleteChat(_ botId: String, key: String) {
        guard var bot = bot(botId) else { return }
        chats.removeValue(forKey: key)?.stop()
        store?.clear(bot: key)
        bot.chats = (bot.chats ?? []).filter { $0.id != key }
        if bot.currentChatKey == key { bot.currentChat = bot.chats?.first.map { $0.id == bot.id ? nil : $0.id } ?? nil }
        if bot.chats?.isEmpty != false {
            // never without a chat: a fresh first one
            bot.chats = [LocalChatSummary(id: bot.id, title: "", createdAt: Date())]
            bot.currentChat = nil
            bot.sessionId = nil
        }
        save(bot)
    }

    /// The chat's Hermes session and title, kept on its summary.
    func update(_ botId: String, chat key: String, title: String? = nil, sessionId: String? = nil) {
        guard var bot = bot(botId), var list = bot.chats, let index = list.firstIndex(where: { $0.id == key }) else { return }
        if let title, list[index].title.isEmpty { list[index].title = Self.title(title) }
        if let sessionId { list[index].sessionId = sessionId }
        bot.chats = list
        if key == bot.id, let sessionId { bot.sessionId = sessionId }
        save(bot)
    }

    func driver(_ kind: LocalBotKind) -> LocalDriver {
        switch kind {
        case .endpoint: return endpointDriver
        case .apple: return appleDriver
        case .gemma: return gemma
        }
    }

    // MARK: Bots

    func save(_ bot: LocalBot, apiKey: String? = nil) {
        if let apiKey {
            if apiKey.isEmpty { Keychain.remove(bot.apiKeyAccount) } else {
                do { try Keychain.set(apiKey, for: bot.apiKeyAccount) } catch { lastError = error.localizedDescription }
            }
        }
        store?.save(bot)
        if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot } else { bots.append(bot) }
    }

    func delete(_ bot: LocalBot) {
        for summary in bot.chats ?? [] {
            chats.removeValue(forKey: summary.id)?.stop()
            if summary.id != bot.id { store?.delete(bot: summary.id) }
        }
        chats.removeValue(forKey: bot.id)?.stop()
        store?.delete(bot: bot.id)
        Keychain.remove(bot.apiKeyAccount)
        bots.removeAll { $0.id == bot.id }
    }


    // MARK: Connectors

    func save(_ connector: LocalConnector, headers: [String: String]? = nil) {
        if let headers {
            do { try ConnectorSecrets.setHeaders(headers, for: connector) } catch { lastError = error.localizedDescription }
        }
        store?.save(connector)
        pool.reset(connector.id)
        if let index = connectors.firstIndex(where: { $0.id == connector.id }) { connectors[index] = connector } else { connectors.append(connector) }
    }

    func delete(_ connector: LocalConnector) {
        pool.reset(connector.id)
        ConnectorSecrets.remove(connector)
        store?.delete(connector: connector.id)
        connectors.removeAll { $0.id == connector.id }
        for var bot in bots where bot.connectorIds.contains(connector.id) {
            bot.connectorIds.removeAll { $0 == connector.id }
            save(bot)
        }
    }

    // MARK: From the Mac

    /// What the Mac sent (plan §7): an endpoint becomes a bot, with its key in
    /// the Keychain and the endpoint's first model when none came along; a
    /// connector arrives as it is, an OAuth one without tokens.
    func importConfig(_ config: PhoneConfig) async {
        for endpoint in config.endpoints {
            var bot = LocalBot(id: newId(), name: endpoint.name, kind: .endpoint, createdAt: Date())
            var model = endpoint.model ?? ""
            if model.isEmpty { model = await Self.firstModel(endpoint) ?? "" }
            bot.endpoint = EndpointConfig(baseUrl: endpoint.baseUrl, model: model, headers: endpoint.headers ?? [:])
            save(bot, apiKey: endpoint.apiKey ?? "")
        }
        for incoming in config.connectors {
            let auth = LocalConnector.Auth(rawValue: incoming.auth) ?? .none
            let connector = LocalConnector(id: newId(), name: incoming.name, url: incoming.url, auth: auth,
                                           headerNames: (incoming.headers ?? [:]).keys.sorted(), oauthClientId: incoming.oauthClientId,
                                           createdAt: Date())
            save(connector, headers: incoming.headers ?? [:])
        }
    }

    private static func firstModel(_ endpoint: PhoneConfig.Endpoint) async -> String? {
        guard let url = URL(string: endpoint.baseUrl.trimmingSuffix("/") + "/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if let key = endpoint.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSON.parse(data))?["data"]?.array?.first?["id"]?.string
    }

    func toolBox(for bot: LocalBot) -> ToolBox? {
        guard bot.kind.takesTools else { return nil }
        let chosen = connectors.filter { bot.connectorIds.contains($0.id) }
        return chosen.isEmpty ? nil : ToolBox(connectors: chosen, pool: pool)
    }
}

/// One phone bot's chat: the messages, the reply as it streams, the turn.
@MainActor
@Observable
final class LocalChat {
    /// Where the messages are kept: the chat's id.
    let key: String
    let botId: String
    private(set) var messages: [LocalMessage] = []
    /// The reply so far while a turn runs.
    private(set) var streaming = ""
    private(set) var busy = false
    var lastError: String?

    @ObservationIgnored private weak var owner: LocalBots?
    @ObservationIgnored private var turn: Task<Void, Never>?

    init(key: String, botId: String, owner: LocalBots) {
        self.key = key
        self.botId = botId
        self.owner = owner
        reload()
    }

    func reload() {
        messages = owner?.store?.messages(bot: key) ?? []
    }

    private func append(_ message: LocalMessage) {
        messages.append(message)
        owner?.store?.save(message)
    }

    private func update(_ message: LocalMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
        owner?.store?.save(message)
    }

    func image(_ name: String) -> Data? { owner?.store?.image(name) }

    func send(_ text: String, images: [(data: Data, mime: String)] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty || !images.isEmpty, let owner, var bot = owner.bot(botId) else { return }
        // the driver continues this chat's Hermes session
        bot.sessionId = bot.chats?.first { $0.id == key }?.sessionId ?? (key == bot.id ? bot.sessionId : nil)
        let chatKey = key
        owner.update(botId, chat: chatKey, title: trimmed.isEmpty ? tr("Immagine") : trimmed)
        let history = messages
        var names: [String] = []
        for image in images {
            if let name = try? owner.store?.saveImage(image.data, ext: image.mime == "image/png" ? "png" : "jpg") { names.append(name) }
        }
        let latest = LocalMessage(id: newId(), botId: key, role: .user, text: trimmed, at: Date(), images: names)
        append(latest)
        busy = true
        streaming = ""
        lastError = nil
        let input = TurnInput(bot: bot, history: history, latest: latest, images: images, tools: owner.toolBox(for: bot))
        let driver = owner.driver(bot.kind)
        turn = Task { [weak self] in
            guard let self else { return }
            let sink = TurnSink(
                delta: { [weak self] piece in self?.streaming += piece },
                toolStarted: { [weak self] title, arguments in
                    let message = LocalMessage(id: newId(), botId: chatKey, role: .tool, text: "", at: Date(),
                                               tool: LocalToolCall(name: title, ok: nil, input: arguments, output: nil))
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
                    self?.append(LocalMessage(id: newId(), botId: chatKey, role: .note, text: text, at: Date()))
                })
            do {
                let outcome = try await driver.run(input, sink: sink)
                self.finish(text: outcome.text, interrupted: false)
                if let sessionId = outcome.sessionId, sessionId != bot.sessionId {
                    self.owner?.update(bot.id, chat: chatKey, sessionId: sessionId)
                }
            } catch {
                let aborted = error is CancellationError || (error as? URLError)?.code == .cancelled
                self.finish(text: self.streaming, interrupted: true)
                if !aborted { self.lastError = error.localizedDescription }
            }
        }
    }

    private func finish(text: String, interrupted: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty || interrupted && !streaming.isEmpty {
            append(LocalMessage(id: newId(), botId: key, role: .bot, text: trimmed, at: Date(), interrupted: interrupted))
        }
        streaming = ""
        busy = false
        turn = nil
    }

    func stop() {
        turn?.cancel()
    }
}
