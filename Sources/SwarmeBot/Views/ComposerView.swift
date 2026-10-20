import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI
import UniformTypeIdentifiers

/// The pill at the bottom: text, the model, send or stop.
///
/// ⏎ sends and ⇧⏎ is a newline, which `TextEditor` cannot tell apart, hence
/// the `NSTextView` underneath. Drafts are kept per thread for the session,
/// so switching chats does not throw away a half-written message.
struct ComposerView: View {
    let threadId: String
    @Environment(AppModel.self) private var model
    @State private var drafts: [String: String] = [:]
    @State private var attachments: [String: [ComposerAttachment]] = [:]
    /// One 20 pt line: taller, the field outgrows the bottom-aligned buttons
    /// and its first line rides above the "+".
    @State private var height: CGFloat = 20
    @State private var dropTargeted = false
    /// Bumped to put the caret in the text field.
    @State private var focusRequest = 0
    /// The server path being edited, for a bot on a remote engine.
    @State private var remoteFolder: String?
    /// Pastes longer than this become a chip, like the web composer.
    private let pasteChipThreshold = 1200

    var body: some View {
        let draft = Binding(
            get: { drafts[threadId] ?? "" },
            set: { drafts[threadId] = $0 }
        )
        VStack(alignment: .leading, spacing: 8) {
            if let candidates = mentionCandidates, !candidates.isEmpty {
                MentionList(bots: candidates) { insertMention($0) }
            }
            PendingApprovalSlot(threadId: threadId)
            if !(attachments[threadId] ?? []).isEmpty {
                AttachmentChips(items: attachments[threadId] ?? []) { id in
                    attachments[threadId]?.removeAll { $0.id == id }
                }
            }
            // `rounded-full`, `raised/70`, 1 pt `hairline/30`, 6 / 16 / 8.
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pickFiles) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(CircleButtonStyle(fill: .clear, hoverFill: Theme.raised, ink: Theme.secondary))
                .help("Allega file o immagini (oppure trascinali qui, o incolla)")
                ComposerTextView(
                    text: draft, height: $height, placeholder: placeholder, focusRequest: focusRequest, onSubmit: submit,
                    onPasteImage: { data, mime in add(.init(name: "Immagine incollata", kind: .image(data, mime: mime))) },
                    onLongPaste: { text in
                        guard text.utf8.count > pasteChipThreshold else { return false }
                        add(.init(name: "Testo incollato", kind: .paste(text)))
                        return true
                    }
                )
                    .frame(height: min(max(height, 20), 160))
                    // 20 + 2 × 6 = the 32 pt buttons, so one line sits on their centre
                    .padding(.vertical, 6)
                if busy {
                    Button {
                        Task { await model.interrupt() }
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 12))
                    }
                    // red, so a running turn is obvious from the composer alone
                    .buttonStyle(CircleButtonStyle(fill: Theme.danger, hoverFill: Theme.danger, ink: Theme.dangerInk, brighten: true))
                    .help("Interrompi (⌘.)")
                }
                if canSend {
                    Button(action: submit) {
                        Image(systemName: busy ? "clock" : "arrow.up")
                            .font(.system(size: busy ? 14 : 15, weight: busy ? .regular : .semibold))
                    }
                    .buttonStyle(busy ? CircleButtonStyle(fill: Theme.raised, hoverFill: Theme.raisedHover, ink: Theme.secondary)
                                      : CircleButtonStyle(fill: Theme.accent, hoverFill: Theme.accent, ink: Theme.accentInk, brighten: true))
                    .help(busy ? "Accoda il messaggio: parte quando il turno finisce" : "Invia (⏎)")
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(Theme.quick, value: canSend)
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.raised.opacity(0.7)))
            // a click anywhere on the pill, not only on the line of text, starts typing
            .contentShape(Capsule())
            .onTapGesture { focusRequest += 1 }
            .overlay(
                Capsule().stroke(dropTargeted ? Theme.accent : Theme.hairline.opacity(0.3), lineWidth: dropTargeted ? 2 : 1)
            )
            .contextMenu {
                Button("Allega file o immagini…", action: pickFiles)
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: drop)
            if let bot = model.selectedBot {
                HStack(spacing: 8) {
                    ModelPickerButton(bot: bot)
                    let folder = workingFolder(bot)
                    // a server's folder cannot be checked, or picked, from this Mac
                    let missing = !model.isRemote && !folderExists(folder)
                    Button(action: { model.isRemote ? (remoteFolder = folder) : pickWorkingFolder(bot) }) {
                        HStack(spacing: 6) {
                            Image(systemName: missing ? "exclamationmark.triangle.fill" : "folder").font(.system(size: 12))
                            Text(chipText((folder as NSString).lastPathComponent, 28))
                                .font(.system(size: Theme.uiSize, weight: .medium))
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.vertical, 1)
                        .foregroundStyle(missing ? Theme.warning : Theme.secondary)
                    }
                    .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
                    .help(missing ? "La cartella \(folder) non esiste più: clicca per sceglierne un'altra"
                          : model.isRemote ? "Cartella di lavoro sul server: \(folder)" : "Cartella di lavoro: \(folder)")
                    .popover(isPresented: Binding(get: { remoteFolder != nil }, set: { if !$0 { remoteFolder = nil } })) {
                        RemoteFolderEditor(path: remoteFolder ?? folder) { path in
                            remoteFolder = nil
                            Task { await model.setWorkingFolder(path) }
                        }
                    }
                    LibraryChip(bot: bot)
                    ConnectorsChip(bot: bot)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
            }
        }
    }

    private var busy: Bool {
        if let bot = model.selectedBot { return model.isBusy(bot) }
        return model.selectedRoom?.busyBotId != nil
    }

    private var placeholder: String {
        if busy, let bot = model.selectedBot { return "\(bot.name) sta lavorando — invia quando il turno finisce" }
        if let bot = model.selectedBot { return "Scrivi a \(bot.name)" }
        if let room = model.selectedRoom { return "Scrivi in #\(room.name) — @nome per chiamare un bot" }
        return "Scrivi…"
    }

    private var canSend: Bool {
        !(drafts[threadId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(attachments[threadId] ?? []).isEmpty
    }

    private func submit() {
        let text = drafts[threadId] ?? ""
        let pending = attachments[threadId] ?? []
        guard canSend else { return }
        if pending.contains(where: { if case .image = $0.kind { return true } else { return false } }), !model.selectedAcceptsImages {
            model.lastError = "Il motore di questa chat non legge immagini: rimuovile o cambia modello."
            return
        }
        if let refused = unreadableForEndpoint(pending) {
            model.lastError = "Il Local Endpoint riceve i file come testo: \(refused) non si può leggere. Allega testo, codice, CSV, JSON, Markdown, PDF o immagini."
            return
        }
        drafts[threadId] = ""
        attachments[threadId] = []
        Task {
            if pending.isEmpty { await model.send(text) } else { await model.send(text, attachments: pending) }
        }
    }

    /// An HTTP model has no filesystem: the harness inlines text and PDF
    /// text, so a folder or a binary file would arrive as a bare name.
    private func unreadableForEndpoint(_ pending: [ComposerAttachment]) -> String? {
        guard let bot = model.selectedBot, model.instance(bot.modelSelection.instanceId)?.driverKind == "localEndpoint" else { return nil }
        for attachment in pending {
            guard case let .file(path) = attachment.kind else { continue }
            if !Self.isTextLike(URL(fileURLWithPath: path)) { return attachment.name }
        }
        return nil
    }

    static func isTextLike(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        if let type = UTType(filenameExtension: url.pathExtension) {
            if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .sourceCode)
                || type.conforms(to: .json) || type.conforms(to: .xml) || type.conforms(to: .commaSeparatedText) { return true }
            if type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .archive)
                || type.conforms(to: .executable) { return false }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return !head.contains(0) && String(data: head, encoding: .utf8) != nil
    }

    private func add(_ attachment: ComposerAttachment) {
        attachments[threadId, default: []].append(attachment)
    }

    // MARK: Files

    /// Task folder, else the bot default, else the home directory.
    private func workingFolder(_ bot: Bot) -> String {
        if let cwd = bot.tasks?.first(where: { $0.threadId == bot.threadId })?.cwd, !cwd.isEmpty { return cwd }
        if let cwd = bot.cwd, !cwd.isEmpty { return cwd }
        // on a server the engine picks its own default; this Mac's home means nothing there
        return model.isRemote ? "~" : FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func pickWorkingFolder(_ bot: Bot) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Scegli"
        panel.message = "Cartella di lavoro"
        let current = URL(fileURLWithPath: workingFolder(bot), isDirectory: true)
        if FileManager.default.fileExists(atPath: current.path) { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setWorkingFolder(url.path) }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addFile)
    }

    /// Images go up as attachments the engine can see; anything else is
    /// passed by path, which every engine here can open itself.
    private func addFile(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, let mime = Self.imageMime(type), let data = try? Data(contentsOf: url), data.count <= 10_000_000 {
            add(.init(name: url.lastPathComponent, kind: .image(data, mime: mime)))
        } else if model.isRemote {
            // a file goes by path, and this Mac's paths do not exist on the server
            model.lastError = "Su un server remoto si allegano solo immagini: copia \(url.lastPathComponent) sul server e indica il percorso nel messaggio"
        } else {
            add(.init(name: url.lastPathComponent, kind: .file(url.path)))
        }
    }

    static func imageMime(_ type: UTType) -> String? {
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .gif) { return "image/gif" }
        if type.conforms(to: .webP) { return "image/webp" }
        return nil
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { addFile(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { add(.init(name: "Immagine", kind: .image(data, mime: "image/png"))) }
                }
            }
        }
        return handled
    }

    // MARK: Mentions

    /// Room members matching the `@word` being typed at the end of the draft.
    private var mentionCandidates: [Bot]? {
        guard let room = model.selectedRoom else { return nil }
        let text = drafts[threadId] ?? ""
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let partial = text[text.index(after: at)...]
        guard !partial.contains(where: \.isWhitespace) else { return nil }
        return room.memberIds.compactMap { model.state.bot($0) }.filter {
            partial.isEmpty || $0.name.localizedCaseInsensitiveContains(partial)
        }
    }

    private func insertMention(_ bot: Bot) {
        var text = drafts[threadId] ?? ""
        guard let at = text.lastIndex(of: "@") else { return }
        text.replaceSubrange(at..., with: "@\(bot.name) ")
        drafts[threadId] = text
    }
}

private struct MentionList: View {
    let bots: [Bot]
    let pick: (Bot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(bots.prefix(6)) { bot in
                Button {
                    pick(bot)
                } label: {
                    HStack(spacing: 8) {
                        BotAvatar(bot: bot, size: 24, animated: false)
                        Text(bot.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                        Text(bot.title.isEmpty ? "Agente" : bot.title).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .hoverHighlight(radius: 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 288)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.hairline.opacity(0.4)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
    }
}

private struct AttachmentChips: View {
    let items: [ComposerAttachment]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        preview(item)
                        Text(item.name).font(.system(size: 11.5)).foregroundStyle(Theme.ink).lineLimit(1)
                        Button { remove(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.inset))
                }
            }
            .padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private func preview(_ item: ComposerAttachment) -> some View {
        switch item.kind {
        case let .image(data, _):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        case .file:
            Image(systemName: "doc").foregroundStyle(Theme.secondary)
        case .paste:
            Image(systemName: "text.alignleft").foregroundStyle(Theme.secondary)
        }
    }
}

/// 32 pt circle: send (accent, white arrow, `brightness-110` on hover),
/// queued (raised + clock), stop (clear, raised on hover).
private struct CircleButtonStyle: ButtonStyle {
    let fill: Color
    let hoverFill: Color
    let ink: Color
    var brighten = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, style: self)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let style: CircleButtonStyle
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(style.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering ? style.hoverFill : style.fill))
                .brightness(style.brighten && hovering ? 0.1 : 0)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(Theme.quick, value: hovering)
        }
    }
}

/// Its own view so that only it, not the whole composer, re-reads the
/// transcript when a message lands.
private struct PendingApprovalSlot: View {
    let threadId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.visibleTranscript(threadId).suffix(60).compactMap { message -> OptionCard? in
            guard message.kind == .options, let card = message.card, card.isPermission, card.isPending else { return nil }
            return card
        }
        if let last = pending.last {
            PendingApprovalPanel(card: last, count: pending.count, threadId: threadId)
        }
    }
}

/// `PendingApproval.tsx`: the live permission request, answered here.
/// ⏎ allows once, ⎋ denies — the same keys as the web app.
private struct PendingApprovalPanel: View {
    let card: OptionCard
    let count: Int
    let threadId: String
    @Environment(AppModel.self) private var model
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("RICHIESTA IN ATTESA")
                        .font(.system(size: 11))
                        .tracking(1.98)
                        .foregroundStyle(Theme.secondary)
                    if count > 1 {
                        Text("\(count)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.raised))
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.title).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(2)
                    if let tool = card.tool {
                        Text(tool).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                    }
                }
                if !card.subtitle.isEmpty {
                    ScrollView {
                        Text(card.subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised.opacity(0.4))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline.opacity(0.5)).frame(height: 1) }
            HStack(spacing: 8) {
                Spacer()
                Button("Interrompi turno") { Task { await model.interrupt() } }
                    .buttonStyle(ApprovalButtonStyle(kind: .plain))
                Button("Nega") { answer("Deny") }
                    .buttonStyle(ApprovalButtonStyle(kind: .danger))
                    .keyboardShortcut(.escape, modifiers: [])
                if card.allowKey != nil {
                    Button("Consenti sempre") {
                        sending = true
                        Task {
                            await model.alwaysAllow(threadId: threadId, card: card)
                            sending = false
                        }
                    }
                    .buttonStyle(ApprovalButtonStyle(kind: .outline))
                    .help(card.allowKey ?? "")
                }
                Button("Consenti una volta") { answer("Allow") }
                    .buttonStyle(ApprovalButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(8)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).stroke(Theme.accent.opacity(0.4)))
        .disabled(sending)
    }

    private func answer(_ choice: String) {
        sending = true
        Task {
            await model.answer(threadId: threadId, card: card, choice: choice)
            sending = false
        }
    }
}

struct ApprovalButtonStyle: ButtonStyle {
    enum Kind { case plain, danger, outline, primary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, kind: kind)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let kind: Kind
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13.5, weight: kind == .primary ? .medium : .regular))
                .foregroundStyle(ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(fill))
                .overlay(Capsule().stroke(stroke, lineWidth: 1))
                .brightness(kind == .primary && hovering ? 0.1 : 0)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Theme.quick, value: hovering)
        }

        private var ink: Color {
            switch kind {
            case .plain: return hovering ? Theme.ink : Theme.secondary
            case .danger: return Theme.danger
            case .outline: return Theme.ink
            case .primary: return Theme.accentInk
            }
        }
        private var fill: Color {
            switch kind {
            case .plain, .outline: return hovering ? Theme.raised : .clear
            case .danger: return hovering ? Theme.danger.opacity(0.1) : .clear
            case .primary: return Theme.accent
            }
        }
        private var stroke: Color {
            switch kind {
            case .plain, .primary: return .clear
            case .danger: return Theme.danger.opacity(0.4)
            case .outline: return Theme.hairline.opacity(0.5)
            }
        }
    }
}

/// An `NSTextView` that sends on ⏎ and breaks the line on ⇧⏎, growing with
/// its content up to the cap the caller sets.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    /// A new value puts the caret in the field.
    var focusRequest = 0
    let onSubmit: () -> Void
    var onPasteImage: ((Data, String) -> Void)? = nil
    /// Return true to take the paste out of the text field (a chip instead).
    var onLongPaste: ((String) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        let field = PlaceholderTextView(frame: textView.frame, textContainer: textView.textContainer)
        // as tall as the visible area at least: clicks under a short line
        // used to land on the clip view and never reach the text
        field.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.placeholder = placeholder
        field.delegate = context.coordinator
        field.drawsBackground = false
        field.isRichText = false
        field.allowsUndo = true
        field.font = .systemFont(ofSize: Theme.bodySize)
        field.defaultParagraphStyle = PlaceholderTextView.paragraph
        field.typingAttributes = [
            .font: NSFont.systemFont(ofSize: Theme.bodySize),
            .foregroundColor: NSColor(Theme.ink),
            .paragraphStyle: PlaceholderTextView.paragraph,
            .baselineOffset: PlaceholderTextView.baselineOffset,
        ]
        field.textColor = NSColor(Theme.ink)
        field.insertionPointColor = NSColor(Theme.accent)
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.autoresizingMask = [.width]
        scroll.documentView = field
        context.coordinator.focusRequest = focusRequest
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let field = scroll.documentView as? PlaceholderTextView else { return }
        context.coordinator.parent = self
        let clip = scroll.contentSize.height
        if abs(field.minSize.height - clip) > 0.5 { field.minSize.height = clip }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        // Closures capture the current thread. Setting them only in
        // makeNSView left every later chat pasting into the first bot.
        field.onPasteImage = onPasteImage
        field.onLongPaste = onLongPaste
        if field.string != text {
            field.string = text
            context.coordinator.measure(field)
        }
        if field.placeholder != placeholder {
            field.placeholder = placeholder
            field.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusRequest = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextView else { return }
            parent.text = field.string
            measure(field)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // an IME composition owns ⏎ until it is committed
            if textView.hasMarkedText() { return false }
            parent.onSubmit()
            return true
        }

        func measure(_ field: NSTextView) {
            guard let container = field.textContainer, let layout = field.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            let next = max(used, 20)
            if abs(next - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = next }
            }
        }
    }
}

final class PlaceholderTextView: NSTextView {
    /// 14 pt text on a 20 pt line, the same rhythm as Grok Bot's composer.
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 20
        style.maximumLineHeight = 20
        return style
    }()
    /// TextKit puts a line's extra height above the glyphs; this lifts them
    /// until the capitals sit on the line's middle, level with the "+".
    /// The placeholder needs it too, or it sits low.
    static let baselineOffset: CGFloat = 2

    var placeholder = ""
    var onPasteImage: ((Data, String) -> Void)?
    var onLongPaste: ((String) -> Bool)?

    /// Images on the pasteboard become attachments; very long text becomes
    /// a chip; everything else pastes as plain text.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let onPasteImage, board.string(forType: .string) == nil {
            if let png = board.data(forType: .png) {
                onPasteImage(png, "image/png")
                return
            }
            if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                onPasteImage(png, "image/png")
                return
            }
        }
        if let text = board.string(forType: .string), onLongPaste?(text) == true { return }
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: Theme.bodySize),
            .foregroundColor: NSColor(Theme.secondary),
            .paragraphStyle: Self.paragraph,
            .baselineOffset: Self.baselineOffset,
        ]
        // drawn like the first line of text: same rect, so the same baseline
        let line = NSRect(x: textContainerInset.width, y: textContainerInset.height,
                          width: max(bounds.width - textContainerInset.width * 2, 0), height: 20)
        (placeholder as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// A folder on the server, typed: there is no Finder for it on this Mac.
private struct RemoteFolderEditor: View {
    @State var path: String
    let save: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cartella di lavoro sul server").font(.headline)
            TextField("/home/utente/progetto", text: $path)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { save(path) }
            Text("Un percorso del server, non di questo Mac.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Usa") { save(path) }.keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }
}

