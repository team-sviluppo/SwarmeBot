// Everything the desktop does beyond chatting: settings, automations,
// attachments, branches, tasks, rooms, computers. Kept apart from the
// stream plumbing in AppModel.swift.
import CompanionCore
import Foundation

extension AppModel {
    // MARK: - Refreshing

    public func refreshConfig() async {
        guard let client else { return }
        do {
            config = try await client.config()
            loadError = nil
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            loadError = tr("Non riesco a leggere la configurazione di %@: %@", engineName, error.localizedDescription)
        }
    }

    public func refreshAutomations() async {
        guard let client else { return }
        if let list = try? await client.routines() {
            state.routines = list.routines
            state.routineRuns = list.runs
        }
        if let list = try? await client.webhooks() {
            state.webhooks = list.webhooks
            state.webhookAttempts = list.attempts
            webhookIngress = list.ingress
        }
    }

    // MARK: - Composer

    /// Upload images, then send text plus one tag per attachment — the exact
    /// prompt shape `src/lib/composer-attachments.ts` builds.
    public func send(_ text: String, attachments: [ComposerAttachment]) async {
        guard let client else { return }
        do {
            await send(try await composePrompt(text, attachments: attachments, uploadingTo: client))
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The text and one tag per attachment, images uploaded to `client`'s engine.
    func composePrompt(_ text: String, attachments: [ComposerAttachment], uploadingTo client: CompanionClient) async throws -> String {
        var parts = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        for (index, attachment) in attachments.enumerated() {
            switch attachment.kind {
            case let .image(data, mime):
                let saved = try await client.uploadAttachment(data, mime: mime)
                parts.append("<attached-image path=\"\(Self.escapeAttribute(saved.path))\" />")
            case let .file(path):
                parts.append("<attached-file path=\"\(Self.escapeAttribute(path))\" />")
            case let .paste(pasted):
                parts.append("<pasted-text index=\"\(index + 1)\">\n\(pasted)\n</pasted-text>")
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Paths are untrusted prompt content: keep them inside the attribute.
    nonisolated public static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\t", with: "&#9;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// Whether the selected chat's engine can read images — the composer
    /// refuses an image an engine cannot open rather than burn a turn.
    public var selectedAcceptsImages: Bool {
        if let bot = selectedBot { return instance(bot.modelSelection.instanceId)?.capabilities?.images == true }
        if let room = selectedRoom {
            return room.memberIds.compactMap { state.bot($0) }.allSatisfy {
                instance($0.modelSelection.instanceId)?.capabilities?.images == true
            }
        }
        return false
    }

    public func uploadAvatar(_ bot: Bot, data: Data, mime: String) async {
        await perform { _ = try await $0.uploadAvatar(botId: bot.id, data, mime: mime) }
    }

    public func attachmentData(path: String) async -> Data? {
        let name = (path as NSString).lastPathComponent
        return try? await client?.attachment(named: name)
    }

    // MARK: - Files in replies

    /// The files a settled reply points at that the engine can hand over;
    /// asked once per message. An engine without the route shows none.
    public func replyFiles(threadId: String, messageId: String, text: String) async -> [ReplyFile] {
        let key = "\(threadId)/\(messageId)"
        if let cached = replyFileCache[key] { return cached }
        let references = ReplyFiles.candidates(in: text)
        guard !references.isEmpty, let client else { return [] }
        guard let found = try? await client.replyFiles(threadId: threadId, references: references) else { return [] }
        // the same file named twice (a link and its full path) is one card
        var seen = Set<String>()
        let files = found.filter { seen.insert($0.path).inserted }
        replyFileCache[key] = files
        return files
    }

    /// One reference, e.g. a link clicked in a reply.
    public func replyFile(threadId: String, reference: String) async -> ReplyFile? {
        guard let client else { return nil }
        do {
            return try await client.replyFiles(threadId: threadId, references: [reference]).first
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// A file on this Mac to open or copy: the file itself on this Mac's
    /// engine, a copy fetched into a temporary folder on a remote one.
    public func localURL(for file: ReplyFile, threadId: String) async -> URL? {
        guard isRemote else { return URL(fileURLWithPath: file.path) }
        guard let client else { return nil }
        do {
            let data = try await client.replyFileContent(threadId: threadId, path: file.path)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwarmeBot Files", isDirectory: true)
                .appendingPathComponent(String(file.path.hashValue.magnitude), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Cards

    public func answer(threadId: String, card: OptionCard, selected: [String], custom: String?) async {
        guard let requestId = card.requestId else { return }
        await perform { try await $0.respond(threadId: threadId, requestId: requestId, selected: selected, custom: custom) }
    }

    // MARK: - Branches and tasks

    public func edit(_ message: Message, text: String) async {
        guard let bot = selectedBot else { return }
        await perform { try await $0.edit(botId: bot.id, messageId: message.id, text: text) }
    }

    public func switchVersion(to message: Message) async {
        guard let bot = selectedBot else { return }
        await perform { _ = try await $0.setActiveBranch(botId: bot.id, messageId: message.id) }
    }

    public func versions(of message: Message) -> [Message] {
        guard let threadId = selectedThreadId else { return [] }
        return state.versions(of: message, inThread: threadId)
    }

    public func createTask(title: String?) async {
        guard let bot = selectedBot else { return }
        await perform { _ = try await $0.createTask(botId: bot.id, title: title) }
    }

    public func switchTask(_ task: BotTask) async {
        guard let bot = selectedBot, task.threadId != bot.threadId else { return }
        await perform { _ = try await $0.switchTask(botId: bot.id, threadId: task.threadId) }
    }

    /// A routine or webhook run that starts gets a task of its own, not the
    /// chat on screen: open that task, so what the bot does is in view.
    /// A frame replayed after a reconnect, long after the start, moves nothing.
    func show(run: RoutineRun) async {
        guard let threadId = run.threadId, state.bot(run.botId) != nil else { return }
        if let startedAt = run.startedAt, Date().timeIntervalSince1970 * 1000 - startedAt > 60_000 { return }
        selection = .bot(run.botId)
        guard state.bot(run.botId)?.threadId != threadId else { return }
        await perform { _ = try await $0.switchTask(botId: run.botId, threadId: threadId) }
    }

    public func renameTask(_ task: BotTask, title: String) async {
        guard let bot = selectedBot else { return }
        await perform { try await $0.renameTask(botId: bot.id, threadId: task.threadId, title: title) }
    }

    public func deleteTask(_ task: BotTask) async {
        guard let bot = selectedBot else { return }
        await perform { _ = try await $0.deleteTask(botId: bot.id, threadId: task.threadId) }
    }

    /// Folder for this chat, and the default for chats opened afterwards.
    public func setWorkingFolder(_ path: String) async {
        guard let bot = selectedBot else { return }
        let threadId = bot.threadId
        await perform { client in
            try await client.patchBot(bot.id, BotPatch(cwd: path))
            try await client.setTaskCwd(botId: bot.id, threadId: threadId, cwd: path)
        }
    }

    // MARK: - Library

    public func library(_ bot: Bot) async -> [LibraryDoc] {
        (try? await client?.library(botId: bot.id)) ?? []
    }

    public func addToLibrary(_ bot: Bot, _ urls: [URL]) async {
        await perform { client in
            for url in urls { try await client.addLibraryDoc(botId: bot.id, path: url.path) }
        }
    }

    public func removeFromLibrary(_ bot: Bot, _ doc: LibraryDoc) async {
        await perform { try await $0.deleteLibraryDoc(botId: bot.id, docId: doc.id) }
    }

    /// Switches a document on or off for the chat that is open.
    public func setLibraryDoc(_ bot: Bot, _ doc: LibraryDoc, on: Bool) async {
        let current = bot.tasks?.first { $0.threadId == bot.threadId }?.libraryOff ?? []
        let off = on ? current.filter { $0 != doc.id } : Array(Set(current + [doc.id])).sorted()
        await perform { try await $0.setTaskLibraryOff(botId: bot.id, threadId: bot.threadId, off: off) }
    }

    public func setTaskPinned(_ task: BotTask, _ pinned: Bool) async {
        guard let bot = selectedBot else { return }
        await perform { try await $0.setTaskPinned(botId: bot.id, threadId: task.threadId, pinned: pinned) }
    }

    // MARK: - Search

    /// Open a hit: select its chat and make sure the message is loaded.
    public func open(_ hit: SearchHit) async {
        if let botId = hit.botId {
            selection = .bot(botId)
            if let bot = state.bot(botId), bot.threadId != hit.threadId,
               let task = bot.tasks?.first(where: { $0.threadId == hit.threadId }) {
                await perform { _ = try await $0.switchTask(botId: botId, threadId: task.threadId) }
            }
        } else if let groupId = hit.groupId {
            selection = .room(groupId)
        }
        if !state.transcript(forThread: hit.threadId).contains(where: { $0.id == hit.messageId }),
           let page = try? await client?.messages(threadId: hit.threadId, around: hit.messageId, limit: 60) {
            state.merge(page, intoThread: hit.threadId)
            stateDidChange()
        }
        focusMessageId = hit.messageId
    }

    // MARK: - Rooms

    public func createRoom(name: String?, memberIds: [String], cwd: String? = nil, guests: [RoomGuest] = []) async {
        await perform { client in
            let room = try await client.createRoom(name: name, memberIds: memberIds, cwd: cwd, guests: guests)
            self.selection = .room(room.id)
        }
    }

    public func patch(_ room: Room, _ patch: RoomPatch) async {
        await perform { try await $0.patchRoom(room.id, patch) }
    }

    public func delete(_ room: Room) async {
        await perform { try await $0.deleteRoom(room.id) }
        if selection == .room(room.id) { selection = nil }
    }

    // MARK: - Settings

    public func saveCredential(_ credential: WorkspaceCredential, _ value: String) async {
        // a server keeps its keys in its own secrets.json, never in this Mac's Keychain
        if isRemote {
            await saveConfig(credential.configPatch(value.trimmingCharacters(in: .whitespacesAndNewlines)), externalSecrets: true)
            return
        }
        do {
            try CredentialStore.set(credential, value)
        } catch {
            lastError = error.localizedDescription
            return
        }
        await saveConfig(credential.configPatch(value.trimmingCharacters(in: .whitespacesAndNewlines)), externalSecrets: true)
    }

    public func saveConfig(_ patch: [String: Any], externalSecrets: Bool = false) async {
        await perform { client in
            self.config = try await client.saveConfig(patch, externalSecrets: externalSecrets)
        }
    }

    public func patchInstance(_ instance: Instance, cli: String? = nil, pickerVisible: Bool?? = nil) async {
        await perform { client in
            self.instances = try await client.patchInstance(instance.instanceId, cli: cli, pickerVisible: pickerVisible)
        }
    }

    public func testCLI(_ cli: String, driver: String) async -> CLITestResult? {
        do {
            return try await client?.testCLI(cli, driver: driver)
        } catch {
            return CLITestResult(ok: false, version: nil, message: error.localizedDescription)
        }
    }

    // MARK: - Automations

    public func save(routine input: RoutineInput, id: String?) async {
        await perform { client in
            if let id { try await client.updateRoutine(id, input) } else { try await client.createRoutine(input) }
        }
    }

    public func setEnabled(_ routine: Routine, _ enabled: Bool) async {
        await perform { try await $0.setRoutineEnabled(routine.id, enabled) }
    }

    public func delete(_ routine: Routine) async {
        await perform { try await $0.deleteRoutine(routine.id) }
    }

    public func run(_ routine: Routine) async {
        await perform { try await $0.runRoutine(routine.id) }
    }

    public func cancel(_ run: RoutineRun) async {
        await perform { try await $0.cancelRun(run.id) }
    }

    /// Returns the one-time credential to show.
    public func create(webhook input: WebhookInput) async -> WebhookCredential? {
        guard let client else { return nil }
        do {
            let created = try await client.createWebhook(input)
            if !state.webhooks.contains(where: { $0.id == created.webhook.id }) { state.webhooks.append(created.webhook) }
            return created.credential
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func update(_ webhook: WebhookTrigger, _ body: [String: Any]) async {
        await perform { try await $0.updateWebhook(webhook.id, body) }
    }

    public func delete(_ webhook: WebhookTrigger) async {
        await perform { try await $0.deleteWebhook(webhook.id) }
        state.webhooks.removeAll { $0.id == webhook.id }
    }

    public func rotate(_ webhook: WebhookTrigger) async -> WebhookCredential? {
        do {
            return try await client?.rotateWebhook(webhook.id).credential
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func test(_ webhook: WebhookTrigger) async {
        await perform { try await $0.testWebhook(webhook.id) }
    }

    // MARK: - Teams

    public func exportTeam(name: String?) async -> Data? {
        do {
            return try await client?.exportTeam(name: name)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func importTeam(_ manifest: Data, mode: String) async -> Bool {
        guard let client else { return false }
        do {
            try await client.importTeam(manifest: manifest, mode: mode)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

/// Something waiting in the composer to go out with the next message.
public struct ComposerAttachment: Identifiable, Sendable {
    public enum Kind: Sendable {
        case image(Data, mime: String)
        /// A file on disk: engines open it by path.
        case file(String)
        /// A long paste, kept out of the text field.
        case paste(String)
    }

    public let id = UUID()
    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

// MARK: - Connectors

extension AppModel {
    public func refreshMCPConnectors() async {
        guard let client else { return }
        if let list = try? await client.mcpConnectors() { mcpConnectors = list }
    }

    /// Create or replace. Returns the saved connector, or the harness's
    /// message when it refused the definition.
    public func save(connector input: MCPConnectorInput, existing: Bool) async -> Result<MCPConnector, Error> {
        guard let client else { return .failure(CancellationError()) }
        do {
            let saved = existing ? try await client.updateMCPConnector(input.id, input) : try await client.createMCPConnector(input)
            upsert(saved)
            return .success(saved)
        } catch {
            return .failure(error)
        }
    }

    public func delete(connector: MCPConnector) async {
        await perform { client in
            try await client.deleteMCPConnector(connector.id)
            self.mcpConnectors.removeAll { $0.id == connector.id }
        }
    }

    /// "Prova connessione": the result lands in the connector's `lastCheck`.
    public func test(connector: MCPConnector) async {
        await perform { client in self.upsert(try await client.testMCPConnector(connector.id)) }
    }

    /// The URL to open in the browser for an OAuth connector's login.
    public func oauthLogin(_ connector: MCPConnector) async -> Result<(url: URL, redirect: String), Error> {
        guard let client else { return .failure(CancellationError()) }
        do {
            let started = try await client.startMCPOAuth(connector.id)
            return .success((started.authorizationURL, started.redirectURI))
        } catch {
            return .failure(error)
        }
    }

    public func oauthRedirect() async -> String? {
        try? await client?.mcpOAuthRedirect()
    }

    public func oauthLogout(_ connector: MCPConnector) async {
        await perform { client in self.upsert(try await client.logoutMCPOAuth(connector.id)) }
    }

    /// Paste of a Claude Desktop / `.mcp.json` config.
    public func importConnectors(_ text: String) async -> Result<MCPConnectorImport, Error> {
        guard let client else { return .failure(CancellationError()) }
        do {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                return .failure(APIError.status(code: 400, message: tr("Non è un JSON valido: incolla un oggetto come {\"mcpServers\": {…}}")))
            }
            let result = try await client.importMCPConnectors(object)
            await refreshMCPConnectors()
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    public func setConnectors(_ bot: Bot, _ connectors: [BotConnector]) async {
        await perform { try await $0.setBotConnectors(botId: bot.id, connectors) }
    }

    /// Whether a connector is on in the chat that is open: the chat's own
    /// switch, else the bot's default.
    public func connectorIsOn(_ bot: Bot, _ id: String) -> Bool {
        let task = bot.tasks?.first { $0.threadId == bot.threadId }
        return task?.connectors?[id] ?? bot.connectors?.first { $0.id == id }?.defaultOn ?? false
    }

    /// Flip a connector for the chat that is open; a switch back to the
    /// default is dropped, so the chat follows the bot again.
    public func setConnector(_ bot: Bot, _ id: String, on: Bool) async {
        var overrides = bot.tasks?.first { $0.threadId == bot.threadId }?.connectors ?? [:]
        let fallback = bot.connectors?.first { $0.id == id }?.defaultOn ?? false
        overrides[id] = on == fallback ? nil : on
        await perform { try await $0.setTaskConnectors(botId: bot.id, threadId: bot.threadId, overrides) }
    }

    /// Back to the bot's defaults for the chat that is open.
    public func resetConnectors(_ bot: Bot) async {
        await perform { try await $0.setTaskConnectors(botId: bot.id, threadId: bot.threadId, [:]) }
    }

    /// Why the bot's engine and model cannot use connectors, or nil when
    /// they can — or when the engines are not known yet, so nothing is
    /// claimed early.
    public func connectorBlock(_ bot: Bot) -> String? {
        guard let instance = instances.first(where: { $0.instanceId == bot.modelSelection.instanceId }) else { return nil }
        guard (instance.capabilities?.connectors ?? "none") != "none" else {
            return tr("Il motore scelto per questo bot non usa i connettori: valgono con Claude, Codex, gli agenti ACP e il server compatibile OpenAI.")
        }
        if instance.models.options.first(where: { $0.id == bot.modelSelection.model })?.clientTools == false {
            return tr("Questo modello è un profilo Hermes: usa i suoi strumenti e ignora i connettori di SwarmeBot.")
        }
        return nil
    }

    private func upsert(_ connector: MCPConnector) {
        if let index = mcpConnectors.firstIndex(where: { $0.id == connector.id }) {
            mcpConnectors[index] = connector
        } else {
            mcpConnectors.append(connector)
        }
    }
}
