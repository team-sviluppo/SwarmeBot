import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI

// Find in chat (⌘F): a bar over the transcript that counts what the open
// chat shows, steps through it from the newest match up (⏎, ⌘G) and back
// down (⇧⏎, ⇧⌘G), and highlights every occurrence in the bubbles, the
// current one stronger.
//
// It searches the text as drawn, not the markdown source: a bot reply is
// split the way `MarkdownText` draws it, one piece per view that highlights
// itself (a run of prose, a code block, a table cell). A message's count is
// the sum of its pieces' counts, so a piece knows which of its occurrences is
// the current one from how many come before it.

/// One occurrence: the message it is in and which of that message's.
struct FindMatch: Equatable {
    let messageId: String
    let occurrence: Int
}

/// What a message's bubble highlights; `current` is the index of the
/// current occurrence among this message's (or this piece's), when it is here.
struct FindHighlight: Equatable {
    let query: String
    var current: Int?

    /// The same highlight for a piece whose occurrences start at `offset`.
    func shifted(by offset: Int) -> FindHighlight {
        FindHighlight(query: query, current: current.map { $0 - offset })
    }
}

@MainActor
@Observable
final class ChatFind {
    static let shared = ChatFind()

    var isOpen = false
    var query = ""
    /// Every occurrence in the open chat, oldest first.
    private(set) var matches: [FindMatch] = []
    /// Index into `matches` of the current one.
    private(set) var current: Int?
    /// Bumped by ⌘F while the bar is already open, to focus and select the field.
    private(set) var focusRequest = 0

    /// Pieces by message id, with the text they were made from.
    @ObservationIgnored private var cache: [String: (text: String, pieces: [String])] = [:]

    var currentMatch: FindMatch? { current.map { matches[$0] } }

    /// "1 of 12" counts from the newest match, where the search starts.
    var position: (index: Int, total: Int)? {
        guard let current else { return nil }
        return (matches.count - current, matches.count)
    }

    func open() {
        if isOpen { focusRequest += 1 } else { isOpen = true }
    }

    func close() {
        isOpen = false
        matches = []
        current = nil
    }

    /// Up the transcript, to older messages; from the oldest back to the newest.
    func older() {
        if !isOpen { return open() }
        guard !matches.isEmpty else { return }
        current = ((current ?? matches.count) - 1 + matches.count) % matches.count
    }

    /// Down the transcript, to newer messages.
    func newer() {
        if !isOpen { return open() }
        guard !matches.isEmpty else { return }
        current = ((current ?? -1) + 1) % matches.count
    }

    /// Count again, after the query or the chat changed. The current match
    /// stays where it was when it is still there; otherwise the newest is.
    func update(_ messages: [Message]) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : query
        let previous = currentMatch
        var found: [FindMatch] = []
        var seen = Set<String>()
        if !needle.isEmpty {
            for message in messages {
                guard let pieces = pieces(message) else { continue }
                seen.insert(message.id)
                let count = pieces.reduce(0) { $0 + FindText.ranges(of: needle, in: $1).count }
                for occurrence in 0..<count { found.append(FindMatch(messageId: message.id, occurrence: occurrence)) }
            }
            cache = cache.filter { seen.contains($0.key) }
        }
        let next = previous.flatMap { found.firstIndex(of: $0) } ?? (found.isEmpty ? nil : found.count - 1)
        if found != matches { matches = found }
        if next != current { current = next }
    }

    /// What `message`'s bubble shows, or nil when the find does not cover it.
    func highlight(for messageId: String) -> FindHighlight? {
        guard isOpen, !query.isEmpty, !matches.isEmpty else { return nil }
        let match = currentMatch
        return FindHighlight(query: query, current: match?.messageId == messageId ? match?.occurrence : nil)
    }

    private func pieces(_ message: Message) -> [String]? {
        guard FindText.searchable(message) else { return nil }
        let text = message.text ?? ""
        if let hit = cache[message.id], hit.text == text { return hit.pieces }
        let pieces = message.role == .user ? [PromptParts(text).display] : FindText.pieces(markdown: text)
        cache[message.id] = (text, pieces)
        return pieces
    }
}

/// The text the transcript draws, as find sees it.
enum FindText {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Messages drawn as a bubble of text: not tool calls, cards or screens.
    static func searchable(_ message: Message) -> Bool {
        (message.kind == .text || message.kind == .unknown) && !ToolName.folds(message)
    }

    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: options, range: start..<text.endIndex) {
            out.append(range)
            start = range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound
        }
        return out
    }

    static func count(_ query: String, in text: String) -> Int { ranges(of: query, in: text).count }

    /// A bot reply in the order `MarkdownText` draws it, one string per view:
    /// a run of prose, a code block, each table cell.
    static func pieces(markdown: String) -> [String] {
        MarkdownText.segments(Markdown.blocks(markdown)).flatMap(pieces(of:))
    }

    static func pieces(of segment: MarkdownText.Segment) -> [String] {
        switch segment {
        case let .prose(blocks): [prose(blocks)]
        case let .block(.code(_, text)): [text]
        case let .block(.table(header, _, rows)): (header + rows.flatMap { $0 }).map(inline)
        case let .block(block): [prose([block])]
        }
    }

    /// The characters `ProseTextView` lays out for these blocks.
    static func prose(_ blocks: [MarkdownBlock]) -> String {
        var out = ""
        for (index, block) in blocks.enumerated() {
            switch block {
            case let .paragraph(text), let .heading(_, text), let .quote(text): out += inline(text)
            case let .bullet(_, text): out += "\t•\t" + inline(text)
            case let .ordered(_, number, text): out += "\t\(number).\t" + inline(text)
            case .code, .rule, .table: continue
            }
            if index < blocks.count - 1 { out += "\n" }
        }
        return out
    }

    /// An inline run without its markdown: what it reads as.
    static func inline(_ text: String) -> String {
        MarkdownText.parsed(text).map { String($0.characters) } ?? text
    }

    // MARK: Drawing

    /// Every occurrence yellow, the current one orange, both under black text
    /// (bubbles come in every colour: no tint would read on all of them).
    static let matchColor = NSColor(srgbRed: 1, green: 0.92, blue: 0.23, alpha: 1)
    static let currentColor = NSColor(srgbRed: 1, green: 0.59, blue: 0.2, alpha: 1)

    /// `text` with its occurrences marked, for a SwiftUI `Text`.
    static func marked(_ text: AttributedString, _ highlight: FindHighlight?) -> AttributedString {
        guard let highlight else { return text }
        let plain = String(text.characters)
        let found = ranges(of: highlight.query, in: plain)
        guard !found.isEmpty else { return text }
        var out = text
        for (index, range) in found.enumerated() {
            let lower = out.characters.index(out.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let upper = out.characters.index(lower, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            out[lower..<upper].backgroundColor = Color(nsColor: index == highlight.current ? currentColor : matchColor)
            out[lower..<upper].foregroundColor = .black
        }
        return out
    }
}

private struct FindHighlightKey: EnvironmentKey {
    static let defaultValue: FindHighlight? = nil
}

extension EnvironmentValues {
    /// The find's marks for the message being drawn; nil when nothing is searched.
    var findHighlight: FindHighlight? {
        get { self[FindHighlightKey.self] }
        set { self[FindHighlightKey.self] = newValue }
    }
}

/// The bar at the top right of the transcript.
struct FindBar: View {
    let threadId: String
    @Environment(AppModel.self) private var model
    @State private var find = ChatFind.shared
    @FocusState private var focused: Bool

    /// What makes a count stale: the query, the chat, a message arriving or growing.
    private struct Key: Equatable {
        let query: String
        let threadId: String
        let count: Int
        let lastId: String?
        let lastLength: Int
    }

    var body: some View {
        @Bindable var find = find
        let messages = model.state.chatMessages(model.visibleTranscript(threadId), forThread: threadId)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            TextField(tr("Trova nella chat"), text: $find.query)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.uiSize))
                .focused($focused)
                .frame(minWidth: 140)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { find.newer() } else { find.older() }
                    return .handled
                }
                .onKeyPress(.upArrow) { find.older(); return .handled }
                .onKeyPress(.downArrow) { find.newer(); return .handled }
                .onKeyPress(.escape) { find.close(); return .handled }
            if !find.query.isEmpty {
                Text(label)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(find.matches.isEmpty ? Theme.danger : Theme.secondary)
                    .fixedSize()
            }
            Button { find.older() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(IconButtonStyle(size: 22, iconSize: 11))
                .disabled(find.matches.isEmpty)
                .help(tr("Risultato successivo (⏎)"))
            Button { find.newer() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(IconButtonStyle(size: 22, iconSize: 11))
                .disabled(find.matches.isEmpty)
                .help(tr("Risultato precedente (⇧⏎)"))
            Button { find.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22, iconSize: 11))
                .help(tr("Chiudi (esc)"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.hairline.opacity(0.6)))
        .shadow(color: Theme.shadow.opacity(0.25), radius: 10, y: 4)
        .onAppear { focused = true }
        .onChange(of: find.focusRequest) {
            focused = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        .onChange(of: Key(query: find.query, threadId: threadId, count: messages.count,
                          lastId: messages.last?.id, lastLength: messages.last?.text?.count ?? 0), initial: true) {
            find.update(messages)
        }
    }

    private var label: String {
        guard let position = find.position else { return tr("Nessun risultato") }
        return tr("%@ di %@", String(position.index), String(position.total))
    }
}
