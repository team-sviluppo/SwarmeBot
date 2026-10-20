// Markdown, split into blocks.
//
// The desktop renders bot replies with react-markdown + GFM. The phone was
// showing the source: `**bold**`, `- ` bullets and `[text](url)` arriving as
// literal characters, which is worse than no markdown at all — it is the
// author's intent visible but not applied.
//
// Foundation can already do the *inline* half. `AttributedString(markdown:)`
// handles emphasis, code spans, strikethrough and links, and SwiftUI renders
// the links tappable for free. What it will not do is lay out blocks: with
// `.full` it records a presentation intent and leaves you to draw the bullet,
// the indent and the spacing yourself. So this splits the text into blocks
// and the view draws each one, handing the inline run back to Foundation.
//
// Deliberately not a full CommonMark implementation. It covers what a model
// actually emits into a chat bubble — paragraphs, lists, headings, fences,
// quotes, rules, GFM tables — and treats anything it does not recognise as text, which is
// the failure mode that loses nothing.
import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    /// `indent` is nesting depth, 0 for a top-level item.
    case bullet(indent: Int, text: String)
    case ordered(indent: Int, number: Int, text: String)
    case heading(level: Int, text: String)
    /// A fenced block. `language` is whatever followed the opening fence.
    case code(language: String?, text: String)
    case quote(String)
    case rule
    /// A GFM table. Every row has exactly `header.count` cells, padded with
    /// "" or cut, and `alignments` has one entry per column.
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
}

/// A table column's alignment, from the colons of its delimiter cell.
public enum MarkdownAlignment: Equatable, Sendable {
    case none, left, center, right
}

public enum Markdown {
    /// Split into blocks. Never throws and never drops input: an unparseable
    /// line ends up in a paragraph, which is what the reader wanted anyway.
    public static func blocks(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // GFM: a single newline inside a paragraph is a soft break, which
            // renders as a space. The desktop does not enable `breaks`, so
            // neither does this — the two should wrap the same way.
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        // Normalise the line endings before splitting, because
        // `CharacterSet.newlines` contains \r and \n *separately* and
        // `components(separatedBy:)` breaks on each of them: "a\r\nb" comes
        // back as ["a", "", "b"], one phantom empty line per CRLF. That empty
        // line is not cosmetic — it calls `flushParagraph`, so a paragraph
        // written across several lines arrives as one paragraph per line, and
        // a fenced block gains a blank line between every line of code. Tool
        // output and pasted text reach chat bubbles with CRLF intact, so this
        // is a path real messages take.
        let normalised = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalised.components(separatedBy: "\n")[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fence runs to its closing fence, or to the end — a reply still
            // streaming has an open one, and showing it as code beats showing
            // three backticks and waiting.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(marker) { break }
                    body.append(next)
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // A row of cells, then the delimiter row: a table, running to the
            // first line that is blank or has no pipe. GFM lets it follow a
            // paragraph line directly, so it ends the paragraph.
            if let next = lines.first,
               let header = tableCells(trimmed),
               let alignments = delimiterRow(next, columns: header.count, last: lines.count == 1) {
                flushParagraph()
                lines = lines.dropFirst()
                var rows: [[String]] = []
                while let row = lines.first, let cells = tableCells(row.trimmingCharacters(in: .whitespaces)) {
                    lines = lines.dropFirst()
                    rows.append((cells + Array(repeating: "", count: max(0, header.count - cells.count))).prefix(header.count).map { $0 })
                }
                blocks.append(.table(header: header, alignments: alignments, rows: rows))
                continue
            }

            // --- or *** or ___, three or more, nothing else on the line
            if trimmed.count >= 3, "-*_".contains(trimmed.first!),
               trimmed.allSatisfy({ $0 == trimmed.first! }) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            paragraph.append(trimmed)
        }
        flushParagraph()
        return blocks
    }

    /// The cells of a table line, nil when it has no pipe. Outer pipes are
    /// optional, `\|` is a literal pipe inside a cell.
    private static func tableCells(_ trimmed: String) -> [String]? {
        guard trimmed.contains("|") else { return nil }
        var body = Substring(trimmed)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for char in body {
            if escaped {
                if char != "|" { cell.append("\\") }
                cell.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(char)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// `|---|:--:|--:|`, one cell per column. When it is the last line of the
    /// source it may be short: a reply still streaming has sent only part of
    /// it, and drawing the table already beats a flash of pipes and dashes.
    private static func delimiterRow(_ line: String, columns: Int, last: Bool) -> [MarkdownAlignment]? {
        guard let cells = tableCells(line.trimmingCharacters(in: .whitespaces)),
              cells.count == columns || (last && cells.count < columns) else { return nil }
        var alignments: [MarkdownAlignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":") && cell.count > 1
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
            // streaming: the cell being typed may still be empty or a lone colon
            let typing = last && alignments.count == cells.count - 1
            guard !dashes.isEmpty ? dashes.allSatisfy({ $0 == "-" }) : typing else { return nil }
            alignments.append(left && right ? .center : right ? .right : left ? .left : .none)
        }
        return alignments + Array(repeating: .none, count: columns - alignments.count)
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = String(trimmed.dropFirst(hashes))
        // "#hashtag" is not a heading; ATX requires the space
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        // two spaces per level, which is what a model emits and what GFM
        // treats as nesting for a tight list
        let indent = min(leading / 2, 4)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return .bullet(indent: indent, text: String(trimmed.dropFirst(2)))
        }

        // "1. " / "12) "
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .ordered(indent: indent, number: Int(digits) ?? 1, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }
}
