// A chat with one of the phone's bots: private, stored on this phone only,
// with its older chats a tap on the title away — as the remote ones.
import CompanionCore
import PhotosUI
import SwiftUI

struct LocalChatView: View {
    @Environment(AppModel.self) private var model
    let botId: String

    @State private var draft = ""
    @State private var images: [(data: Data, mime: String)] = []
    @State private var photo: PhotosPickerItem?
    @State private var documents: [AttachedDocument] = []
    @State private var attachError: String?
    @State private var editing = false
    @State private var showChats = false
    @State private var deleting: LocalBot?
    /// Bots picked from the `@` list: two bots may share a name.
    @State private var pickedTags: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var bot: LocalBot? { model.local.bot(botId) }
    private var chat: LocalChat { model.local.chat(botId) }
    private var color: String { bot?.paletteColor ?? "blue" }
    private var targets: [TagTarget] { model.tagTargets(excluding: .phone(botId)) }

    private var mentionOptions: [MentionOption] {
        guard let partial = BotTagging.partial(in: draft) else { return [] }
        return targets.filter { partial.isEmpty || $0.name.localizedCaseInsensitiveContains(partial) }
            .map { MentionOption(id: $0.id, name: $0.name, detail: $0.title.isEmpty ? $0.placeName : "\($0.title) · \($0.placeName)", color: $0.color) }
    }

    private func pick(_ option: MentionOption) {
        pickedTags.insert(option.id)
        draft = BotTagging.completing(draft, with: option.name)
    }

    private func send() {
        let tagged = BotTagging.mentioned(in: draft, among: targets, preferred: pickedTags)
        if !tagged.isEmpty {
            if let busyTarget = tagged.first(where: model.isBusy) {
                attachError = tr("%@ sta lavorando: riprova quando il turno finisce", busyTarget.name)
                return
            }
            attachError = nil
            let (text, pictures, docs) = (draft, images, documents)
            draft = ""
            images = []
            documents = []
            pickedTags = []
            Task { await model.handOff(text: text, documents: docs, attachments: .pictures(pictures), from: .phone(botId), to: tagged) }
            return
        }
        chat.send(draft, images: images, documents: documents)
        draft = ""
        images = []
        documents = []
        pickedTags = []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if chat.messages.isEmpty, !chat.busy {
                    VStack(spacing: 12) {
                        if let bot { LocalBotAvatar(bot: bot, size: 96) }
                        Text(tr("Questa chat resta su questo telefono.")).font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
                ForEach(chat.messages) { message in
                    LocalMessageRow(message: message, color: color, image: chat.image).id(message.id)
                }
                if chat.busy {
                    if chat.streaming.isEmpty {
                        ActivityLine(text: tr("Sta pensando…"), running: true).id("live")
                    } else {
                        ChatBubble(text: chat.streaming, isUser: false, color: color).id("live")
                    }
                }
                if let error = chat.lastError {
                    ActivityLine(text: error, failed: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .stickToBottom(last: chat.messages.last?.id)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if let attachError {
                    Text(verbatim: attachError).font(.caption).foregroundStyle(Theme.danger).padding(.horizontal, 16)
                }
                ComposerBar(text: $draft, placeholder: tr("Chiedi a %@", bot?.name ?? ""), takesImages: takesImages, photo: $photo,
                            attachPDF: attachPDF,
                            attached: images.map { _ in "🖼 " + tr("Immagine") } + documents.map { "📄 " + $0.name },
                            detach: { index in
                                if index < images.count { images.remove(at: index) } else { documents.remove(at: index - images.count) }
                            },
                            busy: chat.busy,
                            mentions: mentionOptions, pickMention: pick,
                            send: send,
                            stop: { chat.stop() })
            }
        }
        .background(Theme.app)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitlePill(title: bot?.name ?? tr("Chat"), action: { showChats = true }) {
                    if let bot { LocalBotAvatar(bot: bot, size: 30, busy: chat.busy) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(tr("Nuova chat"), systemImage: "square.and.pencil") { model.local.newChat(botId) }
                    Button(tr("Chat precedenti"), systemImage: "clock.arrow.circlepath") { showChats = true }
                    Button(tr("Modifica il bot"), systemImage: "slider.horizontal.3") { editing = true }
                    Divider()
                    Button(tr("Elimina il bot"), systemImage: "trash", role: .destructive) { deleting = bot }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .deleteBotDialog($deleting)
        .onAppear {
            Notifier.shared.onScreen = Notifier.key(phoneBot: botId)
            model.local.markRead(botId)
        }
        .onDisappear { if Notifier.shared.onScreen == Notifier.key(phoneBot: botId) { Notifier.shared.onScreen = nil } }
        // back in front on this chat: what came meanwhile is read now
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.local.markRead(botId) } }
        // deleted here or from its settings: back to the list
        .onChange(of: bot == nil) { _, gone in if gone { dismiss() } }
        .sheet(isPresented: $editing) {
            if let bot { LocalBotEditor(existing: bot) }
        }
        .sheet(isPresented: $showChats) {
            if let bot {
                ChatsSheet(botName: bot.name,
                           items: (bot.chats ?? []).map { .init(id: $0.id, title: $0.title, date: $0.createdAt, current: $0.id == bot.currentChatKey) },
                           onNew: { model.local.newChat(botId) },
                           onOpen: { model.local.openChat(botId, key: $0) },
                           onDelete: { model.local.deleteChat(botId, key: $0) })
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                defer { photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let picture = UIImage(data: data),
                      let jpeg = picture.jpegData(compressionQuality: 0.85) else { return }
                images.append((jpeg, "image/jpeg"))
            }
        }
    }

    private func attachPDF(_ url: URL) {
        do {
            documents.append(try AttachedDocument.pdf(at: url))
            attachError = nil
        } catch {
            attachError = error.localizedDescription
        }
    }

    private var takesImages: Bool {
        guard let bot else { return false }
        switch bot.kind {
        case .gemma: return true
        case .endpoint: return bot.endpoint?.images == true
        case .apple: return false
        }
    }
}

private struct LocalMessageRow: View {
    let message: LocalMessage
    let color: String
    let image: (String) -> Data?

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(message.images, id: \.self) { name in
                    if let data = image(name), let picture = UIImage(data: data) {
                        Image(uiImage: picture).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                ForEach(message.documents ?? [], id: \.self) { document in
                    Label(document.name, systemImage: "doc.text")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.pill, in: Capsule())
                }
                let handed = BotTagging.split(message.text)
                if let from = handed.from {
                    ActivityLine(text: tr("Cronologia della chat con %@", from), symbol: "arrowshape.turn.up.right")
                }
                if !handed.rest.isEmpty { ChatBubble(text: handed.rest, isUser: true, color: color) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .bot:
            ChatBubble(text: message.text, isUser: false, color: color, footnote: message.interrupted ? tr("Interrotto") : nil)
        case .tool:
            if let tool = message.tool {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        if let input = tool.input, !input.isEmpty { Text(verbatim: input).font(.caption.monospaced()) }
                        if let output = tool.output { Text(verbatim: output).font(.caption.monospaced()).lineLimit(12) }
                    }
                    .foregroundStyle(Theme.secondary)
                } label: {
                    ActivityLine(text: tool.name, failed: tool.ok == false, running: tool.ok == nil)
                }
                .tint(Theme.secondary)
            }
        case .note:
            ActivityLine(text: message.text, symbol: "info.circle")
        }
    }
}
