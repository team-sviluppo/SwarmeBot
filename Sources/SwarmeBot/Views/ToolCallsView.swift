// Tool calls in the transcript: a run of calls folds into one line that
// stays closed unless opened; open, it lists the calls, and a click on one
// shows what it was asked and what it answered.
import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI

/// A tool's raw name as people read it: `mcp__aws_documentation__search_table`
/// becomes "aws_documentation" · "search_table"; "Fake · echo" (the Local
/// Endpoint's own titles) splits the same way.
enum ToolName {
    static func parts(_ raw: String) -> (server: String?, tool: String) {
        if raw.hasPrefix("mcp__") {
            let rest = raw.dropFirst(5).components(separatedBy: "__")
            if rest.count >= 2 { return (rest[0], rest.dropFirst().joined(separator: "__")) }
        }
        if let range = raw.range(of: " · ") {
            return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        return (nil, raw)
    }

    /// Calls that fold into a group: real tools, not the error lines a
    /// turn leaves (those stay visible on their own).
    static func folds(_ message: Message) -> Bool {
        message.isToolCall
    }
}

struct ToolCallsGroup: View {
    let messages: [Message]
    @Binding var expanded: Bool

    private var tools: [ToolActivity] { messages.compactMap(\.tool) }
    private var running: Bool { tools.contains { $0.ok == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Theme.quick) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.tertiary)
                    if running {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                    }
                    // Just the count: failed attempts are normal while the bot
                    // explores, so the closed line never flags them; opening it
                    // shows each call.
                    Text(tools.count == 1 ? tr("1 strumento") : tr("%@ strumenti", String(tools.count)))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.panel))
                .overlay(Capsule().stroke(Theme.hairline.opacity(0.4), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(expanded ? tr("Nascondi le chiamate") : tr("Mostra le chiamate"))

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(messages) { message in
                        if let tool = message.tool { ToolCallRow(tool: tool) }
                    }
                }
                .padding(.leading, 18)
                .transition(.opacity)
            }
        }
    }
}

/// One call: status, server, tool. A click shows its details.
private struct ToolCallRow: View {
    let tool: ToolActivity
    @State private var open = false

    var body: some View {
        let parts = ToolName.parts(tool.name)
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: tool.ok == true ? "checkmark" : tool.ok == false ? "xmark" : "circle.dotted")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tool.ok == true ? Theme.success : tool.ok == false ? Theme.danger : Theme.tertiary)
                    .frame(width: 12)
                if let server = parts.server {
                    Text(server).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    Text("·").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                Text(parts.tool)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if tool.output != nil || tool.input != nil {
                    Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(open ? Theme.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("Dettagli della chiamata"))
        .popover(isPresented: $open, arrowEdge: .trailing) { ToolCallDetail(tool: tool) }
    }
}

/// What the tool was asked and what it answered, as the harness kept them.
private struct ToolCallDetail: View {
    let tool: ToolActivity

    var body: some View {
        let parts = ToolName.parts(tool.name)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: tool.ok == true ? "checkmark.circle.fill" : tool.ok == false ? "xmark.circle.fill" : "clock")
                    .foregroundStyle(tool.ok == true ? Theme.success : tool.ok == false ? Theme.danger : Theme.tertiary)
                Text(parts.tool).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if let server = parts.server { Text(server).font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
                Spacer()
            }
            if tool.input == nil, tool.output == nil {
                Text(tool.ok == nil ? tr("La chiamata è ancora in corso.") : tr("Nessun dettaglio registrato per questa chiamata."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if let input = tool.input { DetailBlock(title: tr("Richiesta"), text: Self.readable(input), maxHeight: 140) }
            if let output = tool.output { DetailBlock(title: tool.ok == false ? tr("Errore") : tr("Risposta"), text: Self.readable(output), maxHeight: 360) }
        }
        .padding(14)
        .frame(width: 540)
    }

    /// JSON is shown indented; anything else as it came.
    static func readable(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[", let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let out = String(data: pretty, encoding: .utf8) else { return text }
        return out
    }
}

private struct DetailBlock: View {
    let title: String
    let text: String
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .help(tr("Copia"))
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.inset))
        }
    }
}
