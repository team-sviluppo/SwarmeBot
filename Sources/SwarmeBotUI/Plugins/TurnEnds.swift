import CompanionCore

/// What ends a turn: the messages that close a turn (a bot text followed by
/// the next user message, by another speaker's text in a channel, or by nothing),
/// and the newest of them. Plugins hang their footer on these (`AppPlugin.replyFooter`).
struct TurnEnds {
    var ids: Set<String> = []
    var latest: String?

    init(_ messages: [Message]) {
        var pending: String?
        var speaker: String?
        for message in messages {
            guard message.kind == .text else { continue }
            if message.role == .user {
                if let pending { ids.insert(pending) }
                pending = nil
                speaker = nil
            } else {
                // in a channel each member answers on its own turn: a new speaker closes the last one's
                if let pending, let speaker, let next = message.from?.botId, next != speaker { ids.insert(pending) }
                pending = message.id
                speaker = message.from?.botId ?? speaker
            }
        }
        if let pending {
            ids.insert(pending)
            latest = pending
        }
    }
}
