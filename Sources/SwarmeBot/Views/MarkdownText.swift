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
import SwarmeKit

struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(source).enumerated()), id: \.offset) { item in
                view(for: item.element)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inline(text)
                .font(.system(size: Theme.bodySize))
                .lineSpacing(Theme.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .linkCursor(Self.parsed(text), size: Theme.bodySize, lineSpacing: Theme.bodyLineSpacing)

        case let .heading(level, text):
            // Three sizes, not six. A chat bubble is not a document, and an
            // h4 that looks exactly like body text is a heading that failed.
            inline(text)
                .font(.system(size: [16, 15, 14.5, 14, 14, 13.5, 13][min(level, 6)], weight: .semibold))
                .foregroundStyle(level >= 6 ? Theme.ink.opacity(0.85) : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .linkCursor(Self.parsed(text), size: [16, 15, 14.5, 14, 14, 13.5, 13][min(level, 6)], weight: .semibold, lineSpacing: 0)
                .padding(.top, level <= 2 ? 8 : 6)

        case let .bullet(indent, text):
            marker("•", indent: indent, text: text)

        case let .ordered(indent, number, text):
            marker("\(number).", indent: indent, text: text)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Theme.ink.opacity(0.45))
                    .frame(width: 2)
                inline(text)
                    .font(.system(size: Theme.bodySize))
                    .lineSpacing(Theme.bodyLineSpacing)
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .linkCursor(Self.parsed(text), size: Theme.bodySize, lineSpacing: Theme.bodyLineSpacing)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(language, text):
            CodeBlock(language: language, text: text)

        case .rule:
            Rectangle().fill(Theme.ink.opacity(0.3)).frame(height: 1).padding(.vertical, 2)

        case let .table(header, alignments, rows):
            // At its natural width when it fits; otherwise long cells wrap,
            // at narrower and narrower caps, and only a table that still
            // does not fit scrolls sideways, like a code block.
            ViewThatFits(in: .horizontal) {
                table(header: header, alignments: alignments, rows: rows, cap: nil)
                table(header: header, alignments: alignments, rows: rows, cap: 220)
                table(header: header, alignments: alignments, rows: rows, cap: 150)
                ScrollView(.horizontal, showsIndicators: false) {
                    table(header: header, alignments: alignments, rows: rows, cap: 150)
                }
            }
        }
    }

    private func table(header: [String], alignments: [MarkdownAlignment], rows: [[String]], cap: CGFloat?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, text in
                    cell(text, alignment: alignments[column], cap: cap)
                        .fontWeight(.semibold)
                        .background(Theme.ink.opacity(0.08))
                        .gridColumnAlignment(alignments[column].horizontal)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                Rectangle().fill(Theme.ink.opacity(0.25)).frame(height: 1)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                        cell(text, alignment: alignments[column], cap: cap)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).stroke(Theme.ink.opacity(0.3)))
        .fixedSize()
    }

    /// Every cell fills its column and its row, so the header's tint and
    /// the alignment cover the whole cell, not just its text.
    private func cell(_ text: String, alignment: MarkdownAlignment, cap: CGFloat?) -> some View {
        CappedWidth(cap: cap ?? .infinity) {
            inline(text)
                .font(.system(size: Theme.bodySize))
                .lineSpacing(Theme.bodyLineSpacing)
                .multilineTextAlignment(alignment.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment.horizontal, vertical: .top))
    }

    private func marker(_ symbol: String, indent: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(symbol)
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.ink)
                .frame(width: 14, alignment: .trailing)
            inline(text)
                .font(.system(size: Theme.bodySize))
                .lineSpacing(Theme.bodyLineSpacing)
                .linkCursor(Self.parsed(text), size: Theme.bodySize, lineSpacing: Theme.bodyLineSpacing)
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
    private func inline(_ text: String) -> Text {
        if let attributed = Self.parsed(text) {
            return Text(attributed)
        }
        return Text(text)
    }

    /// The inline run as drawn, nil when it does not parse (yet).
    private static func parsed(_ text: String) -> AttributedString? {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map(styled)
    }

    /// Inline code in bold, in the text's own font: a dark mono chip on a
    /// coloured bubble read as a separate, confusing thing. Links in ink,
    /// bold and underlined. The bubble is the bot's colour darkened to 4.5:1
    /// against ink, so no tint of it (nor the accent blue, on a blue bot)
    /// would still read: weight and underline set links apart instead.
    private static func styled(_ input: AttributedString) -> AttributedString {
        var out = input
        for run in out.runs {
            if var intent = run.inlinePresentationIntent, intent.contains(.code) {
                intent.remove(.code)
                out[run.range].inlinePresentationIntent = intent.union(.stronglyEmphasized)
            }
            if run.link != nil {
                out[run.range].foregroundColor = Theme.ink
                // bold through the intent, so a link in a heading keeps the heading's size
                out[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                out[run.range].underlineStyle = .single
            }
        }
        return out
    }
}

/// Proposes its content the width it is offered, but never more than `cap`,
/// and takes the content's own size: a short cell stays short, a long one
/// wraps at the cap. A `frame(maxWidth:)` cannot do this inside a sideways
/// scroll view, which offers no width at all.
private struct CappedWidth: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? cap, cap), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private extension MarkdownAlignment {
    var horizontal: HorizontalAlignment {
        switch self {
        case .none, .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .none, .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}

/// `rounded-lg` bordered `inset` block: a header with the language (11
/// uppercase) and copy, then 13 pt mono, scrolling sideways.
private struct CodeBlock: View {
    let language: String?
    let text: String
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
                .help(tr("Copia"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline.opacity(0.3)).frame(height: 1) }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
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

// MARK: - The hand over links

/// SwiftUI makes links in a `Text` clickable but keeps the arrow over them,
/// and a `Text` cannot tell which characters are under the pointer. This lays
/// the same run out again with TextKit, at the width SwiftUI gave it, and
/// shows the pointing hand while the pointer is on a link.
private struct LinkCursor: ViewModifier {
    let layout: LinkLayout
    @State private var width: CGFloat = 0
    @State private var onLink = false

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in width = new }
            })
            .onContinuousHover { phase in
                // set, not push/pop: rows come and go while the transcript
                // scrolls, and an unbalanced push would keep the hand forever
                switch phase {
                case let .active(point):
                    let hit = layout.isLink(at: point, width: width)
                    if hit {
                        NSCursor.pointingHand.set()
                    } else if onLink {
                        NSCursor.arrow.set()
                    }
                    onLink = hit
                case .ended:
                    if onLink { NSCursor.arrow.set() }
                    onLink = false
                }
            }
    }
}

/// The run as TextKit sees it: the characters, the font they are drawn in
/// (bold where the markdown says so) and which ranges are links.
private struct LinkLayout {
    let string: NSAttributedString
    let links: [NSRange]

    init?(_ attributed: AttributedString, size: CGFloat, weight: NSFont.Weight, lineSpacing: CGFloat) {
        let out = NSMutableAttributedString()
        var links: [NSRange] = []
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let strong = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            var font = NSFont.systemFont(ofSize: size, weight: strong ? .bold : weight)
            if run.inlinePresentationIntent?.contains(.emphasized) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            let start = (out.string as NSString).length
            out.append(NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph]))
            if run.link != nil { links.append(NSRange(location: start, length: (text as NSString).length)) }
        }
        guard !links.isEmpty else { return nil }
        string = out
        self.links = links
    }

    func isLink(at point: CGPoint, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyph = manager.glyphIndex(for: point, in: container)
        // glyphIndex answers the nearest glyph: only a hit inside its box counts
        guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -1, dy: -1).contains(point) else {
            return false
        }
        let index = manager.characterIndexForGlyph(at: glyph)
        return links.contains { NSLocationInRange(index, $0) }
    }
}

extension View {
    /// The pointing hand over the links of this markdown run; nothing when it has none.
    @ViewBuilder
    func linkCursor(_ attributed: AttributedString?, size: CGFloat, weight: NSFont.Weight = .regular, lineSpacing: CGFloat) -> some View {
        if let attributed, let layout = LinkLayout(attributed, size: size, weight: weight, lineSpacing: lineSpacing) {
            modifier(LinkCursor(layout: layout))
        } else {
            self
        }
    }
}
