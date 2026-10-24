// Tagging another bot from a bot's chat, shared by the Mac and the iOS app.
//
// `@Name` in a 1:1 chat hands the conversation over: the tagged bot gets a new
// chat that opens with the history so far and the message, and answers as if
// the user had written to it directly. The first bot is asked nothing; its
// chat only records where the message went. Who delivers is up to the app
// (it knows the engines); this is what both apps agree on: who is tagged, and
// what the tagged bot receives.
import Foundation

/// A bot an `@` can name.
public protocol TagCandidate {
    var tagId: String { get }
    var tagName: String { get }
}

public enum BotTagging {
    /// One message of the conversation handed over.
    public struct Line: Equatable, Sendable {
        public var isUser: Bool
        public var text: String

        public init(isUser: Bool, text: String) {
            self.isUser = isUser
            self.text = text
        }
    }

    public static let maxMessages = 60
    public static let maxMessageCharacters = 4_000
    public static let maxCharacters = 60_000

    /// The spoken text of a transcript: no tool lines, cards or screens.
    public static func lines(from messages: [Message]) -> [Line] {
        messages.compactMap { message in
            guard message.kind == .text, let text = message.text, !text.isEmpty else { return nil }
            return Line(isUser: message.role == .user, text: text)
        }
    }

    /// The candidates `@Name` tags in `text`: after whitespace or at the start,
    /// longest names first, `user@host` is no tag. When two bots share a name
    /// the one whose id is in `preferred` (picked from the list) wins.
    public static func mentioned<T: TagCandidate>(in text: String, among candidates: [T], preferred: Set<String> = []) -> [T] {
        let named = candidates
            .filter { !$0.tagName.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted {
                if $0.tagName.count != $1.tagName.count { return $0.tagName.count > $1.tagName.count }
                return preferred.contains($0.tagId) && !preferred.contains($1.tagId)
            }
        var found: [T] = []
        var index = text.startIndex
        while index < text.endIndex {
            let here = index
            index = text.index(after: index)
            guard text[here] == "@", here == text.startIndex || text[text.index(before: here)].isWhitespace else { continue }
            let rest = text[index...]
            for candidate in named {
                guard let range = rest.range(of: candidate.tagName, options: [.caseInsensitive, .anchored]) else { continue }
                if range.upperBound < text.endIndex, text[range.upperBound].isLetter || text[range.upperBound].isNumber { continue }
                if !found.contains(where: { $0.tagName.caseInsensitiveCompare(candidate.tagName) == .orderedSame }) { found.append(candidate) }
                index = range.upperBound
                break
            }
        }
        return found
    }

    /// The name being typed after a trailing `@` ("" right after it), nil when
    /// the end of the text is not a tag in the making.
    public static func partial(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let partial = text[text.index(after: at)...]
        return partial.contains(where: \.isWhitespace) ? nil : String(partial)
    }

    /// `text` with the `@word` being typed replaced by `@name `.
    public static func completing(_ text: String, with name: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@\(name) "
    }

    /// What the tagged bot receives: the conversation so far, then the message.
    /// The history sits in a tag, so a transcript can fold it away (`split`).
    /// A bot that runs on the phone has a small context window: it gets a
    /// shorter history.
    public static func handoffPrompt(sourceName: String, history: [Line], message: String,
                                     maxMessages: Int = maxMessages, maxCharacters: Int = maxCharacters) -> String {
        let spoken = history.compactMap { line -> (speaker: String, text: String)? in
            let text = clean(line.text)
            return text.isEmpty ? nil : (line.isUser ? "User" : sourceName, String(text.prefix(maxMessageCharacters)))
        }
        var kept = Array(spoken.suffix(maxMessages))
        while kept.count > 1, kept.reduce(0, { $0 + $1.text.count + $1.speaker.count + 2 }) > maxCharacters { kept.removeFirst() }
        guard !kept.isEmpty else { return message }
        let transcript = kept.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n\n")
        return """
        The user was chatting with \(sourceName) and has just tagged you in that conversation. \
        What was said so far is below, for context only. Answer the user's message at the end \
        directly, as if they had written it to you in a new chat.

        <conversation-history with="\(escape(sourceName))">
        \(transcript)
        </conversation-history>

        \(message)
        """
    }

    /// A handed-over message split back into the bot it came from and what the
    /// user typed, for a transcript to show a line instead of the history.
    public static func split(_ prompt: String) -> (from: String?, rest: String) {
        guard prompt.hasPrefix("The user was chatting with "),
              let open = prompt.range(of: "<conversation-history with=\""),
              let nameEnd = prompt.range(of: "\">\n", range: open.upperBound..<prompt.endIndex),
              let close = prompt.range(of: "\n</conversation-history>\n\n", range: nameEnd.upperBound..<prompt.endIndex)
        else { return (nil, prompt) }
        let name = unescape(String(prompt[open.upperBound..<nameEnd.lowerBound]))
        return (name, String(prompt[close.upperBound...]))
    }

    /// Attachments name files of the first bot's engine: the other one cannot open them.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<attached-(?:image|file)\b[^>]*/>"#, with: "[attachment]", options: .regularExpression)
            .replacingOccurrences(of: #"<attached-file name="[^"]*"[^>]*>[\s\S]*?</attached-file>"#, with: "[attachment]", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
