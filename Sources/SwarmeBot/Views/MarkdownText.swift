// Bot replies, rendered. Ported from the iOS companion; sizes are the
// desktop's (14pt body) and colours come from `Theme`.
//
// `Markdown.blocks` does the splitting; this draws each block and hands the
// inline run to Foundation, which knows emphasis, code spans, strikethrough
// and links — a reply full of sources was previously a wall of bracketed
// URLs. Prose blocks in a row share one text view (`ProseText`) so that a
// selection can run across them; code blocks and tables stand alone.
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
            ForEach(Array(Self.segments(Markdown.blocks(source)).enumerated()), id: \.offset) { item in
                switch item.element {
                case let .prose(blocks):
                    ProseText(blocks: blocks)
                case let .block(block):
                    view(for: block)
                }
            }
        }
    }

    /// Runs of prose blocks, which one text view draws so that a selection
    /// can cross them, and the blocks that need a view of their own.
    private enum Segment {
        case prose([MarkdownBlock])
        case block(MarkdownBlock)
    }

    private static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var out: [Segment] = []
        var run: [MarkdownBlock] = []
        for block in blocks {
            switch block {
            case .paragraph, .heading, .bullet, .ordered, .quote:
                run.append(block)
            case .code, .rule, .table:
                if !run.isEmpty { out.append(.prose(run)) }
                run = []
                out.append(.block(block))
            }
        }
        if !run.isEmpty { out.append(.prose(run)) }
        return out
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
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

        case .paragraph, .heading, .bullet, .ordered, .quote:
            ProseText(blocks: [block])
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
    fileprivate static func parsed(_ text: String) -> AttributedString? {
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

// MARK: - Prose

/// Paragraphs, headings, list items and quotes in a row, in one AppKit text
/// view. A SwiftUI `Text` keeps its selection to itself, so with one `Text`
/// per block a drag could not go past the end of a paragraph; one text view
/// lets it run across all of them. Links get the pointing hand from AppKit
/// and open through SwiftUI's `openURL`, which the reply's file links hook.
private struct ProseText: NSViewRepresentable {
    let blocks: [MarkdownBlock]

    func makeNSView(context: Context) -> ProseTextView {
        let view = ProseTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.linkTextAttributes = [
            .foregroundColor: Theme.nsInk,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: ProseTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        view.show(blocks)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ProseTextView, context: Context) -> CGSize? {
        view.size(fitting: proposal.width)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let openURL, let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            openURL(url)
            return true
        }
    }
}

private extension NSAttributedString.Key {
    /// Marks a quote's characters, for the bar drawn beside them.
    static let markdownQuote = NSAttributedString.Key("SwarmeMarkdownQuote")
}

private final class ProseTextView: NSTextView {
    private var blocks: [MarkdownBlock] = []
    /// Sizes by proposed width; SwiftUI asks the same few widths many times.
    private var sizes: [CGFloat: CGSize] = [:]

    func show(_ new: [MarkdownBlock]) {
        guard new != blocks else { return }
        blocks = new
        sizes = [:]
        textStorage?.setAttributedString(Self.render(new))
        needsDisplay = true
    }

    /// Laid out on its own TextKit stack, not the view's: measuring a width
    /// SwiftUI then does not pick must not rewrap what is on screen.
    func size(fitting proposed: CGFloat?) -> CGSize {
        let width = proposed.flatMap { $0.isFinite ? max($0, 1) : nil } ?? 100_000
        if let size = sizes[width] { return size }
        let storage = NSTextStorage(attributedString: textStorage ?? NSAttributedString())
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        let size = CGSize(width: min(ceil(used.width), width), height: ceil(used.height))
        if sizes.count > 16 { sizes = [:] }
        sizes[width] = size
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return }
        Theme.nsQuoteBar.setFill()
        storage.enumerateAttribute(.markdownQuote, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = manager.boundingRect(forGlyphRange: glyphs, in: container)
            NSRect(x: textContainerOrigin.x, y: box.minY + textContainerOrigin.y, width: 2, height: box.height).fill()
        }
    }

    // MARK: Rendering

    private static func render(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            let paragraph = NSMutableParagraphStyle()
            // the 8 pt the blocks had between them in a VStack
            paragraph.paragraphSpacing = last ? 0 : 8
            let piece: NSMutableAttributedString
            switch block {
            case let .paragraph(text):
                paragraph.lineSpacing = Theme.bodyLineSpacing
                piece = inline(text, size: Theme.bodySize, weight: .regular, color: Theme.nsInk)

            case let .heading(level, text):
                // Three sizes, not six. A chat bubble is not a document, and an
                // h4 that looks exactly like body text is a heading that failed.
                let size: CGFloat = [16, 15, 14.5, 14, 14, 13.5, 13][min(level, 6)]
                paragraph.paragraphSpacingBefore = index == 0 ? 0 : (level <= 2 ? 8 : 6)
                piece = inline(text, size: size, weight: .semibold, color: level >= 6 ? Theme.nsInkSoft : Theme.nsInk)

            case let .bullet(indent, text):
                piece = item("•", indent: indent, text: text, paragraph: paragraph)

            case let .ordered(indent, number, text):
                piece = item("\(number).", indent: indent, text: text, paragraph: paragraph)

            case let .quote(text):
                paragraph.lineSpacing = Theme.bodyLineSpacing
                paragraph.firstLineHeadIndent = 10
                paragraph.headIndent = 10
                piece = inline(text, size: Theme.bodySize, weight: .regular, color: Theme.nsInkSoft)
                piece.addAttribute(.markdownQuote, value: true, range: NSRange(location: 0, length: piece.length))

            case .code, .rule, .table:
                continue
            }
            if !last { piece.append(NSAttributedString(string: "\n", attributes: piece.length > 0 ? piece.attributes(at: piece.length - 1, effectiveRange: nil) : [:])) }
            piece.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: piece.length))
            out.append(piece)
        }
        return out
    }

    /// The marker right-aligned in a 14 pt column, the text 6 pt after it,
    /// wrapped lines lined up under the text: tab stops and a hanging indent.
    private static func item(_ marker: String, indent: Int, text: String, paragraph: NSMutableParagraphStyle) -> NSMutableAttributedString {
        let start = CGFloat(indent) * 20
        paragraph.lineSpacing = Theme.bodyLineSpacing
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: start + 14), NSTextTab(textAlignment: .left, location: start + 20)]
        paragraph.headIndent = start + 20
        let font = NSFont.systemFont(ofSize: Theme.bodySize)
        let piece = NSMutableAttributedString(string: "\t\(marker)\t", attributes: [.font: font, .foregroundColor: Theme.nsInk])
        piece.append(inline(text, size: Theme.bodySize, weight: .regular, color: Theme.nsInk))
        return piece
    }

    /// The inline run, parsed as `MarkdownText` parses it, in AppKit fonts;
    /// the raw characters while it does not parse yet.
    private static func inline(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSMutableAttributedString {
        guard let attributed = MarkdownText.parsed(text) else {
            return NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(attributed[run.range].characters), attributes: attributes))
        }
        return out
    }
}
