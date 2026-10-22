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
    }

    func bot(_ id: String) -> LocalBot? { bots.first { $0.id == id } }

    func chat(_ botId: String) -> LocalChat {
        if let known = chats[botId] { return known }
        let chat = LocalChat(botId: botId, owner: self)
        chats[botId] = chat
        return chat
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
        chats.removeValue(forKey: bot.id)?.stop()
        store?.delete(bot: bot.id)
        Keychain.remove(bot.apiKeyAccount)
        bots.removeAll { $0.id == bot.id }
    }

    /// A new chat: the messages go, and so does the Hermes session.
    func clearChat(_ bot: LocalBot) {
        chats[bot.id]?.stop()
        store?.clear(bot: bot.id)
        chats[bot.id]?.reload()
        var updated = bot
        updated.sessionId = nil
        save(updated)
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
    let botId: String
    private(set) var messages: [LocalMessage] = []
    /// The reply so far while a turn runs.
    private(set) var streaming = ""
    private(set) var busy = false
    var lastError: String?

    @ObservationIgnored private weak var owner: LocalBots?
    @ObservationIgnored private var turn: Task<Void, Never>?

    init(botId: String, owner: LocalBots) {
        self.botId = botId
        self.owner = owner
        reload()
    }

    func reload() {
        messages = owner?.store?.messages(bot: botId) ?? []
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
        guard !busy, !trimmed.isEmpty || !images.isEmpty, let owner, let bot = owner.bot(botId) else { return }
        let history = messages
        var names: [String] = []
        for image in images {
            if let name = try? owner.store?.saveImage(image.data, ext: image.mime == "image/png" ? "png" : "jpg") { names.append(name) }
        }
        let latest = LocalMessage(id: newId(), botId: botId, role: .user, text: trimmed, at: Date(), images: names)
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
                    let message = LocalMessage(id: newId(), botId: bot.id, role: .tool, text: "", at: Date(),
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
                    self?.append(LocalMessage(id: newId(), botId: bot.id, role: .note, text: text, at: Date()))
                })
            do {
                let outcome = try await driver.run(input, sink: sink)
                self.finish(text: outcome.text, interrupted: false)
                if let sessionId = outcome.sessionId, sessionId != bot.sessionId, var current = self.owner?.bot(bot.id) {
                    current.sessionId = sessionId
                    self.owner?.save(current)
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
            append(LocalMessage(id: newId(), botId: botId, role: .bot, text: trimmed, at: Date(), interrupted: interrupted))
        }
        streaming = ""
        busy = false
        turn = nil
    }

    func stop() {
        turn?.cancel()
    }
}
