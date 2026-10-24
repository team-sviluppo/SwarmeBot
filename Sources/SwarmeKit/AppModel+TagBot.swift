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
public struct TagTarget: Identifiable, Hashable, Sendable {
    public let engine: EngineChoice
    public let engineName: String
    public let bot: Bot

    public var id: String { "\(engine.saved):\(bot.id)" }
}

public enum BotTagging {
    /// Messages of the history that travel with the first one.
    static let maxHistoryMessages = 60
    static let maxMessageCharacters = 4_000
    static let maxHistoryCharacters = 60_000

    /// The targets `@Name` tags in `text`: after whitespace or at the start,
    /// longest names first, `user@host` is no tag. When two bots share a name
    /// the one in `preferred` (picked from the list) wins.
    public static func mentioned(in text: String, among targets: [TagTarget], preferred: Set<String> = []) -> [TagTarget] {
        let candidates = targets
            .filter { !$0.bot.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted {
                if $0.bot.name.count != $1.bot.name.count { return $0.bot.name.count > $1.bot.name.count }
                return preferred.contains($0.id) && !preferred.contains($1.id)
            }
        var found: [TagTarget] = []
        var index = text.startIndex
        while index < text.endIndex {
            let here = index
            index = text.index(after: index)
            guard text[here] == "@", here == text.startIndex || text[text.index(before: here)].isWhitespace else { continue }
            let rest = text[index...]
            for target in candidates {
                guard let range = rest.range(of: target.bot.name, options: [.caseInsensitive, .anchored]) else { continue }
                if range.upperBound < text.endIndex, text[range.upperBound].isLetter || text[range.upperBound].isNumber { continue }
                if !found.contains(where: { $0.bot.name.caseInsensitiveCompare(target.bot.name) == .orderedSame }) { found.append(target) }
                index = range.upperBound
                break
            }
        }
        return found
    }

    /// What the tagged bot receives: the conversation so far, then the message.
    /// The history is wrapped in a tag so the transcript can fold it away.
    public static func handoffPrompt(from source: Bot, history: [Message], message: String) -> String {
        var lines: [(speaker: String, text: String)] = []
        for item in history where item.kind == .text {
            let text = clean(item.text ?? "")
            if !text.isEmpty { lines.append((item.role == .user ? "User" : source.name, String(text.prefix(maxMessageCharacters)))) }
        }
        var kept = Array(lines.suffix(maxHistoryMessages))
        while kept.count > 1, kept.reduce(0, { $0 + $1.text.count + $1.speaker.count + 2 }) > maxHistoryCharacters { kept.removeFirst() }
        guard !kept.isEmpty else { return message }
        let transcript = kept.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n")
        return """
        The user was chatting with \(source.name) and has just tagged you in that conversation. \
        What was said so far is below, for context only. Answer the user's message at the end \
        directly, as if they had written it to you in a new chat.

        <conversation-history with="\(AppModel.escapeAttribute(source.name))">
        \(transcript)
        </conversation-history>

        \(message)
        """
    }

    /// Attachments name files of the first bot's engine: the other one cannot open them.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<attached-(?:image|file)\b[^>]*/>"#, with: "[attachment]", options: .regularExpression)
            .replacingOccurrences(of: #"<attached-file name="[^"]*"[^>]*>[\s\S]*?</attached-file>"#, with: "[attachment]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
        let history = visibleTranscript(source.threadId)
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
                let prompt = BotTagging.handoffPrompt(from: source, history: history, message: body)
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
