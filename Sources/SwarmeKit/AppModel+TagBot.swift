// Tagging another bot from a bot's chat.
//
// `@Name` in a 1:1 chat hands the conversation over: the tagged bot — on this
// Mac or on a server — gets a new chat that opens with the history so far and
// the message, and answers as if the user had written to it directly. The
// first bot is not asked anything; its chat only records where the message
// went. The Mac is the one place that knows every engine, so it does the
// handing over with the ordinary routes (new task, message) plus a note.
import CompanionCore
import Foundation

/// A bot an `@` can hand a chat to, and the engine it lives on.
public struct TagTarget: Identifiable, Hashable, Sendable, TagCandidate {
    public let engine: EngineChoice
    public let engineName: String
    public let bot: Bot

    public var id: String { "\(engine.saved):\(bot.id)" }
    public var tagId: String { id }
    public var tagName: String { bot.name }
}

extension AppModel {
    /// Bots the selected bot's chat can tag: those of the shown engine, then
    /// this Mac's, then the servers', never the bot itself.
    public var tagTargets: [TagTarget] {
        guard let current = selectedBot else { return [] }
        var targets = visibleBots.filter { $0.id != current.id }
            .map { TagTarget(engine: engineChoice, engineName: engineDisplayName(engineChoice), bot: $0) }
        var order: [EngineChoice] = [.local] + remoteEngines.map { .remote($0.id) }
        order.removeAll { $0 == engineChoice }
        for choice in order {
            guard let peer = peers[choice] else { continue }
            targets += peer.visibleBots.map { TagTarget(engine: choice, engineName: engineDisplayName(choice), bot: $0) }
        }
        return targets
    }

    func engineDisplayName(_ choice: EngineChoice) -> String {
        switch choice {
        case .local: return tr("Questo Mac")
        case let .remote(id): return remoteEngines.first { $0.id == id }?.name ?? id
        }
    }

    /// Whether a bot of another engine, or of this one, is mid-turn right now.
    public func isBusy(_ target: TagTarget) -> Bool {
        if target.engine == engineChoice { return state.bot(target.bot.id).map(isBusy) ?? false }
        return peers[target.engine].map { peer in peer.state.bot(target.bot.id).map(peer.isBusy) ?? false } ?? false
    }

    /// Hand the selected chat over to each tagged bot. True when every one
    /// got it; a bot that cannot be reached or is busy is reported in `lastError`
    /// and the others still go.
    @discardableResult
    public func sendTagged(_ text: String, attachments: [ComposerAttachment], to targets: [TagTarget]) async -> Bool {
        guard let source = selectedBot, let sourceClient = client else { return false }
        let history = BotTagging.lines(from: visibleTranscript(source.threadId))
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var failures: [String] = []
        for target in targets {
            do {
                let targetClient = target.engine == engineChoice ? sourceClient : peerClient(target.engine)
                guard let targetClient else { throw TagError.unreachable(target.engineName) }
                if case .remote = target.engine, attachments.contains(where: { if case .file = $0.kind { return true } else { return false } }) {
                    throw TagError.files
                }
                let body = try await composePrompt(message, attachments: attachments, uploadingTo: targetClient)
                let prompt = BotTagging.handoffPrompt(sourceName: source.name, history: history, message: body)
                _ = try await targetClient.createTask(botId: target.bot.id, title: Self.handoffTitle(from: source, message: message))
                try await targetClient.send(text: prompt, toBot: target.bot.id)
                try? await sourceClient.addNote(tr("Messaggio inviato a %@. Verifica nella sua chat", target.bot.name), toBot: source.id)
            } catch {
                failures.append("\(target.bot.name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
        return failures.isEmpty
    }

    static func handoffTitle(from source: Bot, message: String) -> String {
        let flat = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let snippet = flat.count > 40 ? String(flat.prefix(39)) + "…" : flat
        return snippet.isEmpty ? tr("Da %@", source.name) : tr("Da %@: %@", source.name, snippet)
    }

    enum TagError: LocalizedError {
        case unreachable(String)
        case files

        var errorDescription: String? {
            switch self {
            case let .unreachable(engine): return tr("%@ non raggiungibile", engine)
            case .files: return tr("Su un server remoto si allegano solo immagini")
            }
        }
    }
}
