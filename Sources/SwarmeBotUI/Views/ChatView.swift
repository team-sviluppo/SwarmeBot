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
                ForEach(Array(PluginHost.shared.bottomPanels(ChatContext.current(model)).enumerated()), id: \.offset) { $0.element }
                if let host = model.selectedRoom?.guest {
                    // a mirror of a mixed channel: written where it lives
                    Text(tr("Canale misto di %@: si scrive da lì.", host.hostName ?? tr("un altro dispositivo")))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .padding(.bottom, 24).padding(.top, 8)
                } else {
                    ComposerView(threadId: threadId)
                        .frame(maxWidth: Theme.transcriptMaxWidth)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                        .padding(.top, 8)
                }
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

    /// Whether a plugin is on for the open chat, so its turns are worked out.
    private var transcriptPlugins: Bool {
        PluginHost.shared.hasActive(for: ChatContext(model: model, bot: model.selectedBot, room: model.selectedRoom, threadId: threadId, isBusy: false))
    }

    var body: some View {
        let all = model.state.chatMessages(model.visibleTranscript(threadId), forThread: threadId)
        let messages = Array(all.suffix(window))
        let hiddenLocally = all.count - messages.count
        // a plugin may put its own footer, not a card per file, where a turn ends
        let turnEnds = transcriptPlugins ? TurnEnds(messages) : nil
        GeometryReader { geo in
        let column = min(geo.size.width - 40, Theme.transcriptMaxWidth)
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if hiddenLocally > 0 || model.state.hasMore[threadId] == true {
                    Button(loadingOlder ? tr("Caricamento…") : tr("Carica messaggi precedenti")) {
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
                    MessageRow(message: message, threadId: threadId, isRoom: model.selectedRoom != nil,
                               turn: turnEnds.map { .init(isTurnEnd: $0.ids.contains(message.id), isLatest: $0.latest == message.id) })
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
        let time = date.appFormatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return tr("Oggi %@", time) }
        if calendar.isDateInYesterday(date) { return tr("Ieri %@", time) }
        return date.appFormatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " \(time)"
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

/// Copy (and edit) plus the time, revealed on hover beside the bubble's
/// bottom edge, towards the middle of the column (`transition-opacity` 150 ms).
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

    /// The meta row sits beside the bubble and is always in the layout, only
    /// faded: under the bubble it pushed every message below down on hover.
    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 0) }
            HStack(alignment: .bottom, spacing: 6) {
                if isUser { meta; content } else { content; meta }
            }
            .onHover(perform: hover)
            if !isUser { Spacer(minLength: 0) }
        }
    }

    private var meta: some View {
        HStack(alignment: .center, spacing: 4) {
            if isUser { time; actions } else { actions; time }
        }
        .fixedSize()
        .padding(.bottom, 2)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .animation(Theme.quick, value: hovering)
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
        Text(message.date.appFormatted(date: .omitted, time: .shortened))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.ink.opacity(0.42))
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if let onEdit {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(IconButtonStyle(size: 22, iconSize: 12))
                    .help(tr("Modifica e reinvia"))
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(IconButtonStyle(size: 22, iconSize: 12))
                .help(tr("Copia"))
        }
    }
}

struct MessageRow: View {
    let message: Message
    let threadId: String
    let isRoom: Bool
    /// Where a reply stands in its turn; nil when no plugin is on for this chat.
    var turn: TurnPosition? = nil
    @Environment(AppModel.self) private var model

    private var chatContext: ChatContext {
        ChatContext(model: model, bot: model.selectedBot, room: model.selectedRoom, threadId: threadId,
                    isBusy: model.selectedBot.map(model.isBusy) ?? (model.selectedRoom?.busyBotId != nil))
    }

    var body: some View {
        switch message.kind {
        case .text, .unknown:
            if message.role == .user {
                UserMessage(message: message, threadId: threadId, editable: !isRoom)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // a review comes from another bot, also in a chat that is one bot's
                    let speaker = isRoom || message.review != nil ? message.from : nil
                    if let from = speaker {
                        HStack(spacing: 6) {
                            if let bot = model.state.bot(from.botId) {
                                BotAvatar(bot: bot, size: 24, animated: false)
                            } else {
                                SwarmeAvatar(color: from.color, size: 24, animated: false)
                            }
                            Text(from.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                            if message.review != nil {
                                Text(tr("Revisione")).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                    HoverActions(message: message, threadId: threadId, isUser: false, copyText: message.text ?? "") {
                        BotBubble(color: speaker != nil ? message.from?.color : model.selectedBot?.color) {
                            MarkdownText(source: message.text ?? "")
                        }
                            .contextMenu { messageMenu }
                    }
                    .replyFileLinks(threadId: threadId, model: model)
                    if !chatContext.isBusy, model.selectedRoom?.guest == nil, message.interrupted != true, message.review == nil,
                       model.visibleTranscript(threadId).last(where: { $0.kind == .text || $0.kind == .options })?.id == message.id {
                        let options = SuggestedChoices.parse(message.text ?? "")
                        if !options.isEmpty {
                            QuestionChoicesView(options: options) { selected, custom in
                                guard model.selectedThreadId == threadId else { return }
                                await model.send(custom ?? selected.first ?? "")
                            }.id(message.id)
                            .frame(maxWidth: 600)
                        }
                    }
                    if let turn, let footer = PluginHost.shared.replyFooter(message, chatContext, turn) {
                        footer
                    } else {
                        ReplyFileCards(message: message, threadId: threadId)
                    }
                    if message.interrupted == true {
                        Label(tr("Interrotto"), systemImage: "stop.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        case .activity:
            if message.sessionDivider == true {
                HStack {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Text(tr("Nuova sessione · %@", message.date.appFormatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize()
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }.padding(.vertical, 16)
            } else {
                ActivityChip(tool: message.tool, text: message.text)
            }
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
        Button(tr("Copia")) {
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
            if let from = parts.historyFrom {
                HStack(spacing: 6) {
                    Spacer()
                    Label(tr("Cronologia della chat con %@", from), systemImage: "arrow.turn.up.right")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.raised))
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
                        Label(tr("%@ testo incollato", String(parts.pastes)), systemImage: "text.alignleft")
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
                        Button(tr("Annulla")) { editing = false }.buttonStyle(PillButtonStyle())
                        Button(tr("Invia di nuovo")) {
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
                        Button(tr("Copia")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(parts.display, forType: .string)
                        }
                        if editable {
                            Button(tr("Modifica e reinvia")) {
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
                Text(verbatim: "\(index + 1)/\(versions.count)").font(.system(size: 11, design: .monospaced))
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
    /// The bot whose chat this message was handed over from.
    var historyFrom: String?

    init(_ text: String) {
        // the conversation a tagged bot is handed folds into a line
        let handed = BotTagging.split(text)
        historyFrom = handed.from
        var rest = handed.rest
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
        // a PDF's text the phone extracted and put in the prompt: shown as its name
        extract(#"<attached-file name="([^"]*)"[^>]*>[\s\S]*?</attached-file>\n*"#, into: &files)
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
                Button(expanded ? tr("Mostra meno") : tr("Mostra tutto il messaggio")) { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            }
            if queued {
                Label(tr("In coda…"), systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .modifier(WidthCap(cap: column * 0.7))
    }
}

/// At most `cap` wide, but never wider than the content: a short bubble
/// stays short, so what sits beside it (time, copy) stays next to it.
/// `.frame(maxWidth:)` would grow to the cap and push those away.
struct WidthCap: ViewModifier {
    let cap: CGFloat

    func body(content: Content) -> some View {
        CapLayout(cap: cap) { content }
    }

    private struct CapLayout: Layout {
        let cap: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            return child.sizeThatFits(capped(proposal))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: capped(ProposedViewSize(bounds.size)))
        }

        private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
            ProposedViewSize(width: min(proposal.width ?? cap, cap), height: proposal.height)
        }
    }
}

/// The bot's colour (darkened for contrast, see `SwarmePalette.bubble`),
/// radius 14, 12/9, at most 88% of the column.
struct BotBubble<Content: View>: View {
    /// Palette name; nil (a sender no longer known) keeps the neutral grey.
    let color: String?
    @ViewBuilder let content: Content
    @Environment(\.transcriptColumn) private var column

    var body: some View {
        content
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.radiusBubble, style: .continuous).fill(color.map(SwarmePalette.bubble) ?? Theme.bubbleBot))
            .modifier(WidthCap(cap: column * 0.88))
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
                        ShimmerText(text: tr("Sta ragionando…"))
                    } else {
                        Text(tr("Ragionamento")).font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
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

/// "Working": `raised` bubble, the working bot's mascot pacing left and
/// right, and elapsed time in seconds, minutes and hours as needed.
struct TypingIndicator: View {
    var bot: Bot?
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            HStack(spacing: 10) {
                if let bot {
                    // 1.6 s there and back over 24 pt, eased at the ends
                    BotAvatar(bot: bot, size: 22, state: .working, priority: true, trackPointer: false)
                        .offset(x: 12 * CGFloat(sin(t * .pi / 0.8)))
                        .frame(width: 46)
                } else {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(Theme.secondary)
                                .frame(width: 6, height: 6)
                                .offset(y: Self.bounce((t + 1 - Double(i) * 0.15).truncatingRemainder(dividingBy: 1)))
                        }
                    }
                }
                Text(Self.elapsedLabel(t))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, bot == nil ? 12 : 7)
            .background(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.raised))
        }
    }

    private static func elapsedLabel(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        if seconds < 60 { return tr("Al lavoro da %@ s", String(seconds)) }
        if seconds < 3600 {
            return tr("Al lavoro da %@ min %@ s", String(seconds / 60), String(seconds % 60))
        }
        return tr("Al lavoro da %@ h %@ min %@ s", String(seconds / 3600), String((seconds % 3600) / 60), String(seconds % 60))
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
            BotBubble(color: speaker?.color) { MarkdownText(source: streaming) }
        }
        // under the streaming reply too: text arriving does not mean the
        // turn is over, and the indicator keeps one identity (and its clock)
        if working {
            TypingIndicator(bot: speaker)
        }
    }

    /// Who is typing: the selected bot, or the room's busy member.
    private var speaker: Bot? {
        if let bot = model.selectedBot { return bot }
        return model.selectedRoom?.busyBotId.flatMap { model.state.bot($0) }
    }
}
