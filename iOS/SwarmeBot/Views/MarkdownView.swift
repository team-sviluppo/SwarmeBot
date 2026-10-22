// A bot reply's Markdown: blocks from CompanionCore's `Markdown`, inline runs
// (emphasis, code, links) from Foundation's `AttributedString`.
import CompanionCore
import SwiftUI

struct MarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(Self.inline(text))
        case let .bullet(indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .ordered(indent, number, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(number).").foregroundStyle(.secondary).monospacedDigit()
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 4)
        case let .code(_, text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        case let .quote(text):
            HStack(spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 3)
                Text(Self.inline(text)).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        case let .table(header, _, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { Text(Self.inline($0.element)).bold() } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(Array(row.enumerated()), id: \.offset) { Text(Self.inline($0.element)) } }
                    }
                }
                .font(.footnote)
            }
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
