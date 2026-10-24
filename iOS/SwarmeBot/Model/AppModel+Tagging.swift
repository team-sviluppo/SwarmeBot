// Tagging another bot from a bot's chat (Sources/CompanionCore/BotTagging.swift).
//
// `@Name` hands the chat over: the tagged bot — on a paired server or on this
// phone — gets a new chat that opens with the history so far and the message,
// and answers as if written to directly. The first bot's chat only gets the
// line "Message sent to <bot>. Check their chat".
import CompanionCore
import Foundation

/// A bot an `@` can hand a chat to, and where it lives.
struct TagTarget: Identifiable, Hashable, TagCandidate {
    enum Place: Hashable {
        case phone
        case server(String)
    }

    let place: Place
    let botId: String
    let name: String
    let color: String
    let title: String
    /// "Questo telefono" or the server's name.
    let placeName: String

    var id: String {
        switch place {
        case .phone: return "phone:\(botId)"
        case let .server(id): return "\(id):\(botId)"
        }
    }

    var tagId: String { id }
    var tagName: String { name }
}

/// The chat a message is handed over from.
enum TagSource {
    case server(RemoteSession, Bot)
    case phone(String)
}

/// What goes with the message: pictures as the shown chat holds them.
enum TagAttachments {
    /// Tags of pictures already uploaded to the source's server (`<attached-image path=…/>`).
    case uploaded([String])
    /// Pictures on this phone, from a phone bot's chat.
    case pictures([(data: Data, mime: String)])
}

extension AppModel {
    /// Every other bot, on the paired servers and on this phone.
    func tagTargets(excluding source: TagSource) -> [TagTarget] {
        var targets: [TagTarget] = []
        for session in sessions {
            for bot in session.visibleBots {
                if case let .server(from, current) = source, from.id == session.id, current.id == bot.id { continue }
                targets.append(TagTarget(place: .server(session.id), botId: bot.id, name: bot.name, color: bot.color, title: bot.title,
                                         placeName: session.server.name))
            }
        }
        for bot in local.bots {
            if case let .phone(id) = source, id == bot.id { continue }
            targets.append(TagTarget(place: .phone, botId: bot.id, name: bot.name, color: bot.paletteColor, title: "", placeName: tr("Questo telefono")))
        }
        return targets
    }

    func isBusy(_ target: TagTarget) -> Bool {
        switch target.place {
        case .phone: return local.chat(target.botId).busy
        case let .server(id): return session(id)?.state.bot(target.botId).flatMap { session(id)?.isBusy($0) } ?? false
        }
    }

    /// Hand the shown chat over to each tagged bot. Returns whether every one
    /// got it; the ones that did not are reported in `lastError`.
    @discardableResult
    func handOff(text: String, documents: [AttachedDocument], attachments: TagAttachments, from source: TagSource, to targets: [TagTarget]) async -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName: String
        let history: [BotTagging.Line]
        switch source {
        case let .server(session, bot):
            sourceName = bot.name
            history = BotTagging.lines(from: session.transcript(bot.threadId))
        case let .phone(id):
            sourceName = local.bot(id)?.name ?? ""
            history = local.chat(id).messages.compactMap { message in
                guard message.role == .user || message.role == .bot, !message.text.isEmpty else { return nil }
                return BotTagging.Line(isUser: message.role == .user, text: message.text)
            }
        }
        let title = Self.handoffTitle(from: sourceName, message: typed)
        var failures: [String] = []
        for target in targets {
            do {
                switch target.place {
                case .phone:
                    try handOffToPhone(target, typed: typed, documents: documents, attachments: attachments, source: source,
                                       sourceName: sourceName, history: history, title: title)
                case let .server(id):
                    try await handOffToServer(target, session: id, typed: typed, documents: documents, attachments: attachments, source: source,
                                              sourceName: sourceName, history: history, title: title)
                }
                let note = tr("Messaggio inviato a %@. Verifica nella sua chat", target.name)
                switch source {
                case let .server(session, bot): await session.addNote(note, botId: bot.id)
                case let .phone(id): local.chat(id).addNote(note)
                }
            } catch {
                failures.append("\(target.name): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
        return failures.isEmpty
    }

    private func handOffToServer(_ target: TagTarget, session id: String, typed: String, documents: [AttachedDocument], attachments: TagAttachments,
                                 source: TagSource, sourceName: String, history: [BotTagging.Line], title: String) async throws {
        guard let session = session(id) else { throw TagError.unreachable(target.placeName) }
        var parts = documents.map(\.promptBlock)
        switch attachments {
        case let .uploaded(tags):
            // the pictures sit on the source's server: only that one can open them
            if !tags.isEmpty {
                guard case let .server(from, _) = source, from.id == id else { throw TagError.pictures }
                parts += tags
            }
        case let .pictures(pictures):
            for picture in pictures {
                guard let tag = await session.attach(picture.data, mime: picture.mime) else { throw TagError.pictures }
                parts.append(tag)
            }
        }
        parts.append(typed)
        let message = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = BotTagging.handoffPrompt(sourceName: sourceName, history: history, message: message)
        try await session.startChat(botId: target.botId, title: title, text: prompt)
    }

    private func handOffToPhone(_ target: TagTarget, typed: String, documents: [AttachedDocument], attachments: TagAttachments, source: TagSource,
                                sourceName: String, history: [BotTagging.Line], title: String) throws {
        var pictures: [(data: Data, mime: String)] = []
        switch attachments {
        case let .uploaded(tags): if !tags.isEmpty { throw TagError.pictures }
        case let .pictures(list): pictures = list
        }
        // a model on the phone has a small context window: a shorter history
        let prompt = BotTagging.handoffPrompt(sourceName: sourceName, history: history, message: typed, maxMessages: 12, maxCharacters: 8_000)
        local.newChat(target.botId)
        let chat = local.chat(target.botId)
        // the first title wins: set it before the prompt, which would name the chat after its history
        local.update(target.botId, chat: chat.key, title: title)
        chat.send(prompt, images: pictures, documents: documents)
    }

    static func handoffTitle(from sourceName: String, message: String) -> String {
        let flat = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let snippet = flat.count > 40 ? String(flat.prefix(39)) + "…" : flat
        return snippet.isEmpty ? tr("Da %@", sourceName) : tr("Da %@: %@", sourceName, snippet)
    }

    enum TagError: LocalizedError {
        case unreachable(String)
        case pictures

        var errorDescription: String? {
            switch self {
            case let .unreachable(place): return tr("%@ non raggiungibile", place)
            case .pictures: return tr("Le immagini non passano da un motore a un altro: toglile o scrivi di nuovo il messaggio.")
            }
        }
    }
}
