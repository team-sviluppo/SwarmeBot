// Bot replies, rendered. Ported from the iOS companion; sizes are the
// desktop's (14pt body) and colours come from `Theme`.
//
// `Markdown.blocks` does the splitting; this draws each block and hands the
// inline run to Foundation, which knows emphasis, code spans, strikethrough
// and links. SwiftUI makes the links tappable on its own, which is most of
// why this is worth doing at all — a reply full of sources was previously a
// wall of bracketed URLs.
//
// Only bot messages get this. The desktop makes the same split: what you
// typed is shown as you typed it, because markdown you did not intend is
// worse than markdown you did.
import SwiftUI
import CompanionCore

struct MarkdownText: View {
    let source: String
    /// Draws a caret after the last block. The streaming bubble sets this so
    /// the live reply and the settled one are the same view with the same
    /// layout — a caret bolted on outside would put it on its own line the
    /// moment the reply ends in a list item.
    var caret: Bool = false

    var body: some View {
        let blocks = Markdown.blocks(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                view(for: item.element, tail: caret && item.offset == blocks.count - 1)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, tail: Bool) -> some View {
        switch block {
        case let .paragraph(text):
            inline(text, tail: tail)
                .font(.system(size: Theme.bodySize))
                .lineSpacing(Theme.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            // Three sizes, not six. A chat bubble is not a document, and an
            // h4 that looks exactly like body text is a heading that failed.
            inline(text, tail: tail)
                .font(.system(size: [16, 15, 14.5, 14, 14, 13.5, 13][min(level, 6)], weight: .semibold))
                .foregroundStyle(level >= 6 ? Theme.secondary : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 8 : 6)

        case let .bullet(indent, text):
            marker("•", indent: indent, text: text, tail: tail)

        case let .ordered(indent, number, text):
            marker("\(number).", indent: indent, text: text, tail: tail)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 2)
                inline(text, tail: tail)
                    .font(.system(size: Theme.bodySize))
                    .lineSpacing(Theme.bodyLineSpacing)
                    .foregroundStyle(Theme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(language, text):
            CodeBlock(language: language, text: text, caret: caretText(tail))

        case .rule:
            Rectangle().fill(Theme.hairline.opacity(0.4)).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func marker(_ symbol: String, indent: Int, text: String, tail: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(symbol)
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.ink)
                .frame(width: 14, alignment: .trailing)
            inline(text, tail: tail)
                .font(.system(size: Theme.bodySize))
                .lineSpacing(Theme.bodyLineSpacing)
        }
        .padding(.leading, CGFloat(indent) * 20)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Inline markdown via Foundation. `.inlineOnlyPreservingWhitespace`
    /// because the blocks are already split — asking for `.full` here would
    /// have it re-interpret list markers this has already consumed.
    ///
    /// Falling back to the raw string on a parse failure is the point: a
    /// half-typed link mid-stream should show as the characters the model has
    /// sent so far, not vanish until it closes the bracket.
    private func inline(_ text: String, tail: Bool = false) -> Text {
        let rendered: Text
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            rendered = Text(Self.styled(attributed))
        } else {
            rendered = Text(text)
        }
        return rendered + caretText(tail)
    }

    /// A figure space then a block, so the caret sits off the last glyph
    /// rather than touching it. Empty when not streaming — an empty `Text`
    /// concatenated in costs nothing and keeps the callers branch-free.
    /// Inline code 13 pt mono on `inset`; links in accent, underlined.
    private static func styled(_ input: AttributedString) -> AttributedString {
        var out = input
        for run in out.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                out[run.range].font = .system(size: 13, design: .monospaced)
                out[run.range].backgroundColor = Theme.inset
            }
            if run.link != nil {
                out[run.range].foregroundColor = Theme.accent
                out[run.range].underlineStyle = .single
            }
        }
        return out
    }

    private func caretText(_ tail: Bool) -> Text {
        tail ? Text("\u{2007}▍").foregroundStyle(Color.secondary) : Text("")
    }
}

/// `rounded-lg` bordered `inset` block: a header with the language (11
/// uppercase) and copy, then 13 pt mono, scrolling sideways.
private struct CodeBlock: View {
    let language: String?
    let text: String
    let caret: Text
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "").uppercased())
                    .font(.system(size: 11))
                    .tracking(0.28)
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Copia")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline.opacity(0.3)).frame(height: 1) }
            ScrollView(.horizontal, showsIndicators: false) {
                (Text(text) + caret)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.inset))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).stroke(Theme.hairline.opacity(0.4)))
    }
}
