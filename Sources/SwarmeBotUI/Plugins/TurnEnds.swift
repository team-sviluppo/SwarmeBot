import CompanionCore

/// What ends a turn: the messages that close a turn (a bot text followed by
/// the next user message or by nothing), and the newest of them. Plugins hang
/// their footer on these (`AppPlugin.replyFooter`).
struct TurnEnds {
    var ids: Set<String> = []
    var latest: String?

    init(_ messages: [Message]) {
        var pending: String?
        for message in messages {
            guard message.kind == .text else { continue }
            if message.role == .user {
                if let pending { ids.insert(pending) }
                pending = nil
            } else {
                pending = message.id
            }
        }
        if let pending {
            ids.insert(pending)
            latest = pending
        }
    }
}
