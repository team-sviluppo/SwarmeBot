// A chat with a remote bot or room (plan §5.2), in the Mac app's look: the
// title pill opens the bot's chats, bubbles in the bot's colour, the reply as
// it streams, the cards that wait for an answer, the floating composer.
import CompanionCore
import PhotosUI
import SwiftUI

struct ChatView: View {
    let session: RemoteSession
    let chat: ChatRef

    @State private var draft = ""
    @State private var attachments: [String] = []
    @State private var photo: PhotosPickerItem?
    @State private var documents: [AttachedDocument] = []
    @State private var attachError: String?
    @State private var sending = false
    @State private var showChats = false
    @Environment(\.scenePhase) private var scenePhase

    private var bot: Bot? {
        if case let .bot(id) = chat { return session.state.bot(id) }
        return nil
    }

    private var room: Room? {
        if case let .room(id) = chat { return session.state.rooms.first { $0.id == id } }
        return nil
    }

    private var threadId: String? { bot?.threadId ?? room?.threadId }
    private var title: String { bot?.name ?? room?.name ?? tr("Chat") }
    private var busy: Bool { bot.map(session.isBusy) ?? (room?.busyBotId != nil) }
    private var color: String { bot?.color ?? "blue" }
    private var screenKey: String { Notifier.key(server: session.id, chat: chat) }

    var body: some View {
        Group {
            if let threadId {
                transcript(threadId)
            } else {
                ContentUnavailableView(tr("Chat non trovata"), systemImage: "bubble.left.and.exclamationmark.bubble.right")
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .background(Theme.app)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatTitlePill(title: title, action: { if bot != nil { showChats = true } }) {
                    if let bot { RemoteBotAvatar(bot: bot, size: 30) } else { RoomAvatar(members: members, size: 30) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let bot {
                        Button(tr("Nuova chat"), systemImage: "square.and.pencil") { Task { await session.newChat(bot.id) } }
                        Button(tr("Chat precedenti"), systemImage: "clock.arrow.circlepath") { showChats = true }
                    }
                    if busy {
                        Button(tr("Ferma"), systemImage: "stop.circle") { Task { await session.interrupt(chat) } }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sheet(isPresented: $showChats) {
            if let bot {
                ChatsSheet(botName: bot.name,
                           items: session.chats(of: bot).map { .init(id: $0.threadId, title: $0.title, date: Date(timeIntervalSince1970: $0.createdAt / 1000),
                                                                     current: $0.threadId == bot.threadId) },
                           onNew: { Task { await session.newChat(bot.id) } },
                           onOpen: { id in Task { await session.openChat(bot.id, threadId: id) } },
                           onDelete: { id in Task { await session.deleteChat(bot.id, threadId: id) } })
            }
        }
        .task(id: threadId) {
            guard let threadId else { return }
            await session.ensureLoaded(threadId)
            await session.markRead(chat)
        }
        // a reply that ends here is read: no notification, no badge
        .onChange(of: busy) { _, working in
            if !working, scenePhase == .active { Task { await session.markRead(chat) } }
        }
        // back in front on this chat: what came meanwhile is read now
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.markRead(chat) } }
        }
        .onAppear { Notifier.shared.onScreen = screenKey }
        .onDisappear { if Notifier.shared.onScreen == screenKey { Notifier.shared.onScreen = nil } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await attach(item) }
        }
    }

    private var members: [Bot] {
        (room?.memberIds ?? []).compactMap { session.state.bot($0) }
    }

    // MARK: Transcript

    private func transcript(_ threadId: String) -> some View {
        let messages = session.transcript(threadId)
        let live = session.state.streaming[threadId]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if session.state.hasMore[threadId] == true {
                    Button(tr("Messaggi precedenti")) { Task { await session.loadOlder(threadId) } }
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(messages) { message in
                    MessageRow(message: message, color: message.from?.color ?? color, inRoom: room != nil) { card, choice in
                        Task { await session.answer(threadId: threadId, card: card, choice: choice) }
                    }
                    .id(message.id)
                }
                if let live, !live.isEmpty {
                    ChatBubble(text: live, isUser: false, color: color).id("live")
                } else if busy {
                    ActivityLine(text: tr("Sta lavorando…"), running: true).id("live")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .stickToBottom(last: messages.last?.id)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 4) {
            if !session.isLive {
                Text(tr("Senza connessione al server: l'invio torna quando la connessione riprende."))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            if let attachError {
                Text(verbatim: attachError).font(.caption).foregroundStyle(Theme.danger)
            }
            ComposerBar(text: $draft, placeholder: tr("Chiedi a %@", title), photo: $photo, attachPDF: attachPDF,
                        attached: attachments.map { _ in "🖼 " + tr("Immagine") } + documents.map { "📄 " + $0.name },
                        detach: { index in
                            if index < attachments.count { attachments.remove(at: index) } else { documents.remove(at: index - attachments.count) }
                        },
                        busy: busy, enabled: session.isLive && !sending,
                        send: { Task { await send() } }, stop: { Task { await session.interrupt(chat) } })
        }
    }

    private func attach(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        if let tag = await session.attach(jpeg, mime: "image/jpeg") { attachments.append(tag) }
    }

    /// The PDF's text goes in the prompt: the engine takes only images as files.
    private func attachPDF(_ url: URL) {
        do {
            documents.append(try AttachedDocument.pdf(at: url))
            attachError = nil
        } catch {
            attachError = error.localizedDescription
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let text = (documents.map(\.promptBlock) + attachments + [draft]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        attachments = []
        documents = []
        await session.send(text, to: chat)
    }
}

/// One transcript entry.
struct MessageRow: View {
    let message: Message
    /// The bot's palette name (in a room, the sender's).
    let color: String
    let inRoom: Bool
    let answer: (OptionCard, String) -> Void

    var body: some View {
        switch message.kind {
        case .text, .unknown:
            ChatBubble(text: message.role == .user ? Self.visibleText(message.text ?? "") : message.text ?? "",
                       isUser: message.role == .user, color: color,
                       header: inRoom && message.role == .bot ? message.from?.name : nil, headerColor: message.from?.color,
                       footnote: message.interrupted == true ? tr("Interrotto") : nil)
        case .activity:
            if let tool = message.tool {
                ActivityLine(text: tool.name, failed: tool.ok == false)
            }
        case .options:
            if let card = message.card { CardView(card: card, answer: answer) }
        case .screen:
            ActivityLine(text: tr("Schermata del computer"), symbol: "display")
        }
    }

    /// The prompt as the user typed it: attachment tags become a picture.
    static func visibleText(_ text: String) -> String {
        AttachedDocument.displayed(text).replacingOccurrences(of: #"<attached-image path="[^"]*"/>"#, with: "🖼", options: .regularExpression)
    }
}

/// A permission or a question. Answerable while it is pending.
struct CardView: View {
    let card: OptionCard
    let answer: (OptionCard, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: card.title).font(.subheadline.bold()).foregroundStyle(Theme.ink)
            if !card.subtitle.isEmpty {
                Text(verbatim: card.subtitle).font(.footnote).foregroundStyle(Theme.secondary).lineLimit(8)
            }
            if card.isPending {
                if card.isPermission {
                    HStack {
                        Button(tr("Consenti")) { answer(card, "Allow") }.buttonStyle(.borderedProminent).tint(Theme.accent)
                        Button(tr("Nega"), role: .destructive) { answer(card, "Deny") }.buttonStyle(.bordered)
                    }
                } else {
                    ForEach(card.options, id: \.self) { option in
                        Button { answer(card, option) } label: {
                            Text(verbatim: option).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if let answered = card.answered {
                Text(verbatim: answered).font(.footnote).foregroundStyle(Theme.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
