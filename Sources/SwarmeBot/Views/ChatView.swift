import CompanionCore
import SwarmeKit
import SwiftUI

/// One conversation: the transcript, anchored to the bottom, and the
/// composer under it.
struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let threadId = model.selectedThreadId {
            VStack(spacing: 0) {
                ChatHeader()
                TranscriptView(threadId: threadId)
                    .id(threadId)
                ComposerView(threadId: threadId)
                    .frame(maxWidth: Theme.transcriptMaxWidth)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct TranscriptView: View {
    let threadId: String
    @Environment(AppModel.self) private var model
    @State private var loadingOlder = false
    /// How many of the newest messages are rendered. SwiftUI diffs every
    /// row identity on each change, so a 5,000-row ForEach makes every new
    /// message cost 5,000 comparisons (R1 benchmark: p95 84 ms per append).
    /// The web transcript windows for the same reason.
    @State private var window = TranscriptView.page
    static let page = 300
    /// Tool groups the user opened, by their first call's id.
    @State private var openToolGroups: Set<String> = []

    var body: some View {
        let all = model.visibleTranscript(threadId)
        let messages = Array(all.suffix(window))
        let hiddenLocally = all.count - messages.count
        GeometryReader { geo in
        let column = min(geo.size.width - 40, Theme.transcriptMaxWidth)
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if hiddenLocally > 0 || model.state.hasMore[threadId] == true {
                    Button(loadingOlder ? "Caricamento…" : "Carica messaggi precedenti") {
                        if hiddenLocally > 0 {
                            window += TranscriptView.page
                            return
                        }
                        Task {
                            loadingOlder = true
                            await model.loadOlder(threadId: threadId)
                            window += TranscriptView.page
                            loadingOlder = false
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .disabled(loadingOlder)
                }
                ForEach(TranscriptRow.rows(messages)) { row in
                    if let stamp = TimeStamp.label(for: row.first, after: row.index > 0 ? messages[row.index - 1] : nil) {
                        Text(stamp)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    if row.messages.count > 1 || ToolName.folds(row.first) {
                        ToolCallsGroup(messages: row.messages, expanded: Binding(
                            get: { openToolGroups.contains(row.id) },
                            set: { if $0 { openToolGroups.insert(row.id) } else { openToolGroups.remove(row.id) } }
                        ))
                        .id(row.id)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    } else {
                    let message = row.first
                    MessageRow(message: message, threadId: threadId, isRoom: model.selectedRoom != nil)
                        .id(message.id)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Theme.accent.opacity(model.focusMessageId == message.id ? 0.18 : 0))
                                .padding(-4)
                        )
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                LiveTail(threadId: threadId, working: isWorking)
            }
            .padding(.bottom, 16)
            .frame(maxWidth: Theme.transcriptMaxWidth)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .environment(\.transcriptColumn, column)
        }
        .defaultScrollAnchor(.bottom)
        .scrollContentBackground(.hidden)
        .animation(Theme.appear, value: messages.count)
        .onChange(of: model.focusMessageId, initial: true) { _, id in
            guard let id else { return }
            // a search hit above the window: widen it to include the hit
            if let index = all.firstIndex(where: { $0.id == id }) {
                if index < all.count - window {
                    window = all.count - index + 20
                } else if index >= all.count - TranscriptView.page {
                    // back among the newest: shrink to the cheap window again
                    window = TranscriptView.page
                }
            }
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                if model.focusMessageId == id { model.focusMessageId = nil }
            }
        }
        }
        }
    }

    private var isWorking: Bool {
        if let bot = model.selectedBot { return model.isBusy(bot) }
        return model.selectedRoom?.busyBotId != nil
    }
}

/// One line of the transcript: a message, or a run of tool calls folded
/// together. Its id is the first message's, so it stays put as calls are added.
struct TranscriptRow: Identifiable {
    let index: Int
    let messages: [Message]
    var first: Message { messages[0] }
    var id: String { first.id }

    static func rows(_ messages: [Message]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var index = 0
        while index < messages.count {
            var end = index + 1
            if ToolName.folds(messages[index]) {
                while end < messages.count, ToolName.folds(messages[end]) { end += 1 }
            }
            rows.append(TranscriptRow(index: index, messages: Array(messages[index..<end])))
            index = end
        }
        return rows
    }
}

/// "Oggi 15:06" when the calendar day changes from the previous message.
enum TimeStamp {
    static func label(for message: Message, after previous: Message?) -> String? {
        let calendar = Calendar.current
        let date = message.date
        if let previous, calendar.isDate(previous.date, inSameDayAs: date) { return nil }
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Oggi \(time)" }
        if calendar.isDateInYesterday(date) { return "Ieri \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " \(time)"
    }
}

private struct TranscriptColumnKey: EnvironmentKey {
    static let defaultValue: CGFloat = Theme.transcriptMaxWidth
}

extension EnvironmentValues {
    /// Width of the transcript column; bubbles cap at 88% (bot) / 70% (user).
    var transcriptColumn: CGFloat {
        get { self[TranscriptColumnKey.self] }
        set { self[TranscriptColumnKey.self] = newValue }
    }
}

/// Copy (and edit) plus the time, revealed on hover under the bubble, on
/// the bubble's own side (`transition-opacity` 150 ms).
struct HoverActions<Content: View>: View {
    let message: Message
    let threadId: String
    let isUser: Bool
    var onEdit: (() -> Void)? = nil
    var copyText: String
    @ViewBuilder let content: Content
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    @State private var hideToken = 0

    /// The actions hang outside the bubble in an overlay, so a row costs no
    /// extra layout; they are built only while hovered.
    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 0) }
            content
                .overlay(alignment: isUser ? .bottomTrailing : .bottomLeading) {
                    if hovering {
                        HStack(alignment: .center, spacing: 4) {
                            if isUser { time; actions } else { actions; time }
                        }
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .alignmentGuide(.bottom) { d in d[.top] - 2 }
                        .onHover(perform: hover)
                        .zIndex(1)
                    }
                }
                .onHover(perform: hover)
            if !isUser { Spacer(minLength: 0) }
        }
    }

    private func hover(_ inside: Bool) {
        hideToken += 1
        if inside { hovering = true; return }
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if token == hideToken { hovering = false }
        }
    }

    private var time: some View {
        Text(message.date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.ink.opacity(0.42))
            .transition(.opacity.animation(Theme.quick))
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if let onEdit {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(IconButtonStyle(size: 22, iconSize: 12))
                    .help("Modifica e reinvia")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(IconButtonStyle(size: 22, iconSize: 12))
                .help("Copia")
        }
        .transition(.opacity.animation(Theme.quick))
    }
}

struct MessageRow: View {
    let message: Message
    let threadId: String
    let isRoom: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        switch message.kind {
        case .text, .unknown:
            if message.role == .user {
                UserMessage(message: message, threadId: threadId, editable: !isRoom)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if isRoom, let from = message.from {
                        HStack(spacing: 6) {
                            if let bot = model.state.bot(from.botId) {
                                BotAvatar(bot: bot, size: 24, animated: false)
                            } else {
                                MausAvatar(color: from.color, size: 24, animated: false)
                            }
                            Text(from.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                        }
                    }
                    HoverActions(message: message, threadId: threadId, isUser: false, copyText: message.text ?? "") {
                        BotBubble { MarkdownText(source: message.text ?? "") }
                            .contextMenu { messageMenu }
                    }
                    if message.interrupted == true {
                        Label("Interrotto", systemImage: "stop.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        case .activity:
            ActivityChip(tool: message.tool, text: message.text)
        case .options:
            if let card = message.card {
                OptionCardView(card: card, threadId: threadId)
            }
        case .screen:
            ScreenMessageView(message: message, threadId: threadId)
        }
    }

    @ViewBuilder
    private var messageMenu: some View {
        Button("Copia") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text ?? "", forType: .string)
        }
    }
}

/// A user message: its text without the attachment tags, the images it
/// attached, and — on bots — edit and the version switcher.
struct UserMessage: View {
    let message: Message
    let threadId: String
    let editable: Bool
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let parts = PromptParts(message.text ?? "")
        VStack(alignment: .trailing, spacing: 4) {
            if !parts.images.isEmpty {
                HStack(spacing: 6) {
                    Spacer()
                    ForEach(parts.images, id: \.self) { AttachmentThumb(path: $0) }
                }
            }
            if !parts.files.isEmpty || parts.pastes > 0 {
                HStack(spacing: 6) {
                    Spacer()
                    ForEach(parts.files, id: \.self) { path in
                        Label((path as NSString).lastPathComponent, systemImage: "doc")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.raised))
                            .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    if parts.pastes > 0 {
                        Label("\(parts.pastes) testo incollato", systemImage: "text.alignleft")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            if editing {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $draft)
                        .font(.system(size: Theme.bodySize))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 60, maxHeight: 200)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.inset))
                    HStack {
                        Button("Annulla") { editing = false }.buttonStyle(PillButtonStyle())
                        Button("Invia di nuovo") {
                            editing = false
                            Task { await model.edit(message, text: draft) }
                        }
                        .buttonStyle(PillButtonStyle(prominent: true))
                    }
                }
                .frame(maxWidth: Theme.bubbleMaxWidth)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else if !parts.display.isEmpty {
                HoverActions(message: message, threadId: threadId, isUser: true,
                             onEdit: editable ? { draft = message.text ?? ""; editing = true } : nil,
                             copyText: parts.display) {
                UserBubble(text: parts.display, queued: message.queued == true)
                    .contextMenu {
                        Button("Copia") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(parts.display, forType: .string)
                        }
                        if editable {
                            Button("Modifica e reinvia") {
                                draft = message.text ?? ""
                                editing = true
                            }
                        }
                    }
                }
            }
            if editable { VersionSwitcher(message: message) }
        }
    }
}

/// "‹ 2/3 ›" under a user message that was edited and retried.
private struct VersionSwitcher: View {
    let message: Message
    @Environment(AppModel.self) private var model

    var body: some View {
        let versions = model.versions(of: message)
        if versions.count > 1, let index = versions.firstIndex(where: { $0.id == message.id }) {
            HStack(spacing: 6) {
                Button { Task { await model.switchVersion(to: versions[index - 1]) } } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                Text("\(index + 1)/\(versions.count)").font(.system(size: 11, design: .monospaced))
                Button { Task { await model.switchVersion(to: versions[index + 1]) } } label: { Image(systemName: "chevron.right") }
                    .disabled(index == versions.count - 1)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondary)
        }
    }
}

/// Split a stored prompt into what was typed and what was attached — the
/// inverse of the composer's tag format.
struct PromptParts {
    var display: String
    var images: [String] = []
    var files: [String] = []
    var pastes = 0

    init(_ text: String) {
        var rest = text
        func extract(_ pattern: String, into list: inout [String]) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let ns = rest as NSString
            for match in regex.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
                list.append(Self.unescape(ns.substring(with: match.range(at: 1))))
            }
            rest = regex.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        var images: [String] = []
        var files: [String] = []
        extract(#"<attached-image\s+path="([^"]*)"\s*/?>\n?"#, into: &images)
        extract(#"<attached-file\s+path="([^"]*)"\s*/?>\n?"#, into: &files)
        var pasted: [String] = []
        extract(#"<pasted-text index="(\d+)">[\s\S]*?</pasted-text>"#, into: &pasted)
        self.images = images
        self.files = files
        pastes = pasted.count
        display = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "\r")
            .replacingOccurrences(of: "&#9;", with: "\t")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private struct AttachmentThumb: View {
    let path: String
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.inset
            }
        }
        .frame(width: 120, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        .task(id: path) {
            if let data = await model.attachmentData(path: path) { image = NSImage(data: data) }
        }
    }
}

/// `bg-bubble-user`, radius 16, 16/10, at most 70% of the column; long
/// messages collapse at 160 pt behind "Mostra tutto".
struct UserBubble: View {
    let text: String
    var queued = false
    @Environment(\.transcriptColumn) private var column
    @State private var expanded = false

    var body: some View {
        let long = text.count > 900 || text.filter { $0 == "\n" }.count > 8
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(.system(size: Theme.bodySize))
                .lineSpacing(Theme.bodyLineSpacing)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: long && !expanded ? 160 : nil, alignment: .top)
                .mask {
                    if long && !expanded {
                        LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    } else {
                        Color.black
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: Theme.radiusBubble, style: .continuous).fill(Theme.bubbleUser))
                .opacity(queued ? 0.6 : 1)
            if long {
                Button(expanded ? "Mostra meno" : "Mostra tutto il messaggio") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            }
            if queued {
                Label("In coda…", systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: column * 0.7, alignment: .trailing)
    }
}

/// `bg-card`, radius 16, 16/10, at most 88% of the column.
struct BotBubble<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.transcriptColumn) private var column

    var body: some View {
        content
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.radiusBubble, style: .continuous).fill(Theme.bubbleBot))
            .frame(maxWidth: column * 0.88, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Tool call: capsule, `hairline/40` border on `panel`, icon 13, mono name.
struct ActivityChip: View {
    let tool: ToolActivity?
    let text: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text(tool?.name ?? text ?? "")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 480, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(Theme.hairline.opacity(0.4), lineWidth: 1))
        .help(tool?.name ?? "")
    }

    private var icon: String {
        switch tool?.ok {
        case true: return "checkmark"
        case false: return tool?.setup == true ? "wrench.and.screwdriver" : "xmark"
        default: return "gearshape"
        }
    }

    private var color: Color {
        switch tool?.ok {
        case true: return Theme.success
        case false: return Theme.danger
        default: return Theme.secondary
        }
    }
}

/// The "Thinking" strip: label with the 2 s shimmer while it streams,
/// expandable to the text (12.5 pt).
struct ReasoningView: View {
    let text: String
    var live = false
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 4) {
                    if live {
                        ShimmerText(text: "Sta ragionando…")
                    } else {
                        Text("Ragionamento").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .animation(Theme.quick, value: open)
                }
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(.system(size: 12.5))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
            }
        }
        .frame(minWidth: 200, alignment: .leading)
    }
}

/// `shimmer`: secondary → ink → secondary band sweeping across in 2 s.
struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
            // background-position 200% → -200% over a 200%-wide gradient
            let centre = 1.5 - 2 * phase
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(LinearGradient(
                    stops: [
                        .init(color: Theme.secondary, location: centre - 0.1),
                        .init(color: Theme.ink, location: centre),
                        .init(color: Theme.secondary, location: centre + 0.1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                ))
        }
    }
}

/// "Working": `raised` bubble, three 6 pt dots bouncing (Tailwind
/// `animate-bounce`, delays 0/150/300 ms) and "Al lavoro da Ns".
struct TypingIndicator: View {
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Theme.secondary)
                            .frame(width: 6, height: 6)
                            .offset(y: Self.bounce((t + 1 - Double(i) * 0.15).truncatingRemainder(dividingBy: 1)))
                    }
                }
                Text("Al lavoro da \(Int(t))s")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.raised))
        }
    }

    /// translateY −25% (of 6 pt) at 0/100% easing in, 0 at 50% easing out.
    static func bounce(_ p: Double) -> CGFloat {
        let up: CGFloat = -1.5
        if p < 0.5 {
            let u = p / 0.5 // cubic-bezier(.8,0,1,1) ≈ ease-in
            return up * (1 - CGFloat(u * u * u))
        }
        let u = (p - 0.5) / 0.5 // cubic-bezier(0,0,.2,1) ≈ ease-out
        return up * CGFloat(1 - pow(1 - u, 3))
    }
}

/// A computer screenshot. Paged transcripts carry only a flag; the pixels
/// are fetched on demand.
struct ScreenMessageView: View {
    let message: Message
    let threadId: String
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 420)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(Theme.inset)
                    .frame(width: 320, height: 200)
                    .overlay(Image(systemName: "display").foregroundStyle(Theme.tertiary))
            }
        }
        .padding(.vertical, 2)
        .task(id: message.id) {
            if let png = message.png, let data = Data(base64Encoded: png) {
                image = NSImage(data: data)
            } else if message.hasImage == true, let data = await model.image(threadId: threadId, messageId: message.id) {
                image = NSImage(data: data)
            }
        }
    }
}

/// The reply being typed. Its own view so that a delta — which changes only
/// `model.live` — re-renders this and not the transcript above it.
private struct LiveTail: View {
    let threadId: String
    let working: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if let reasoning = model.live.reasoning[threadId], !reasoning.isEmpty {
            ReasoningView(text: reasoning, live: model.live.text[threadId]?.isEmpty ?? true)
        }
        if let streaming = model.live.text[threadId], !streaming.isEmpty {
            BotBubble { MarkdownText(source: streaming, caret: true) }
        } else if working {
            TypingIndicator()
        }
    }
}
