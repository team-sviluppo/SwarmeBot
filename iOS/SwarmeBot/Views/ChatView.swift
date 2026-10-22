// A chat with a remote bot or room: the transcript, the reply as it streams,
// the cards that wait for an answer, and the composer (plan §5.2).
import CompanionCore
import PhotosUI
import SwiftUI

struct ChatView: View {
    let session: RemoteSession
    let chat: ChatRef

    @State private var draft = ""
    @State private var attachments: [String] = []
    @State private var photo: PhotosPickerItem?
    @State private var sending = false

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

    var body: some View {
        VStack(spacing: 0) {
            if let threadId {
                transcript(threadId)
            } else {
                ContentUnavailableView(tr("Chat non trovata"), systemImage: "bubble.left.and.exclamationmark.bubble.right")
            }
            composer
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if busy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("Ferma"), systemImage: "stop.circle") { Task { await session.interrupt(chat) } }
                }
            }
        }
        .task(id: threadId) { await session.markRead(chat) }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await attach(item) }
        }
    }

    // MARK: Transcript

    private func transcript(_ threadId: String) -> some View {
        let messages = session.transcript(threadId)
        let live = session.state.streaming[threadId]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.state.hasMore[threadId] == true {
                        Button(tr("Messaggi precedenti")) { Task { await session.loadOlder(threadId) } }
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(messages) { message in
                        MessageRow(message: message, inRoom: room != nil) { card, choice in
                            Task { await session.answer(threadId: threadId, card: card, choice: choice) }
                        }
                        .id(message.id)
                    }
                    if let live, !live.isEmpty {
                        MarkdownView(source: live)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("live")
                    } else if busy {
                        ProgressView().padding(.vertical, 4).id("live")
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: live?.count) { _, _ in proxy.scrollTo("live", anchor: .bottom) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                Label(tr("%@ immagini allegate", String(attachments.count)), systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Image(systemName: "paperclip").font(.title3)
                }
                .accessibilityLabel(tr("Allega un'immagine"))
                TextField(tr("Scrivi un messaggio"), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(sending || !session.isLive || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                .accessibilityLabel(tr("Invia"))
            }
            if !session.isLive {
                Text(tr("Senza connessione al server: l'invio torna quando la connessione riprende."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func attach(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        if let tag = await session.attach(jpeg, mime: "image/jpeg") { attachments.append(tag) }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let text = (attachments + [draft]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        attachments = []
        await session.send(text, to: chat)
    }
}

/// One transcript entry.
struct MessageRow: View {
    let message: Message
    let inRoom: Bool
    let answer: (OptionCard, String) -> Void

    var body: some View {
        switch message.kind {
        case .text, .unknown:
            if message.role == .user {
                Text(Self.visibleText(message.text ?? ""))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if inRoom, let from = message.from {
                        Text(verbatim: from.name).font(.caption.bold()).foregroundStyle(Color(hex: from.color) ?? .secondary)
                    }
                    MarkdownView(source: message.text ?? "")
                    if message.interrupted == true {
                        Text(tr("Interrotto")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .activity:
            if let tool = message.tool {
                Label {
                    Text(verbatim: tool.name).font(.system(.footnote, design: .monospaced))
                } icon: {
                    Image(systemName: tool.ok == false ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                }
                .font(.footnote)
                .foregroundStyle(tool.ok == false ? .red : .secondary)
            }
        case .options:
            if let card = message.card { CardView(card: card, answer: answer) }
        case .screen:
            Label(tr("Schermata del computer"), systemImage: "display").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The prompt as the user typed it: attachment tags become a word.
    static func visibleText(_ text: String) -> String {
        text.replacingOccurrences(of: #"<attached-image path="[^"]*"/>"#, with: "🖼", options: .regularExpression)
    }
}

/// A permission or a question. Answerable while it is pending.
struct CardView: View {
    let card: OptionCard
    let answer: (OptionCard, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: card.title).font(.subheadline.bold())
            if !card.subtitle.isEmpty {
                Text(verbatim: card.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(8)
            }
            if card.isPending {
                if card.isPermission {
                    HStack {
                        Button(tr("Consenti")) { answer(card, "Allow") }.buttonStyle(.borderedProminent)
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
                Text(verbatim: answered).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Color {
    /// `#RRGGBB`, as bots and room members carry their color.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
