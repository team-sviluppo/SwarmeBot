// A chat with one of the phone's bots: private, stored on this phone only,
// with its older chats a tap on the title away — as the remote ones.
import PhotosUI
import SwiftUI

struct LocalChatView: View {
    @Environment(AppModel.self) private var model
    let botId: String

    @State private var draft = ""
    @State private var images: [(data: Data, mime: String)] = []
    @State private var photo: PhotosPickerItem?
    @State private var editing = false
    @State private var showChats = false

    private var bot: LocalBot? { model.local.bot(botId) }
    private var chat: LocalChat { model.local.chat(botId) }
    private var color: String { bot?.paletteColor ?? "blue" }

    var body: some View {
        ScrollViewReader { proxy in
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
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.last?.id) { _, id in withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: chat.streaming.count) { _, _ in proxy.scrollTo("live", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if !images.isEmpty {
                    HStack {
                        Label(tr("%@ immagini allegate", String(images.count)), systemImage: "photo")
                        Button(tr("Togli"), role: .destructive) { images = [] }
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                }
                ComposerBar(text: $draft, placeholder: tr("Chiedi a %@", bot?.name ?? ""), canAttach: takesImages, photo: $photo,
                            attachedCount: images.count, busy: chat.busy,
                            send: {
                                chat.send(draft, images: images)
                                draft = ""
                                images = []
                            },
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
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
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
                if !message.text.isEmpty { ChatBubble(text: message.text, isUser: true, color: color) }
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
