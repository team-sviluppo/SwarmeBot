// A chat with one of the phone's bots: private, stored on this phone only.
import PhotosUI
import SwiftUI

struct LocalChatView: View {
    @Environment(AppModel.self) private var model
    let botId: String

    @State private var draft = ""
    @State private var images: [(data: Data, mime: String)] = []
    @State private var photo: PhotosPickerItem?
    @State private var editing = false
    @State private var confirmClear = false

    private var bot: LocalBot? { model.local.bot(botId) }
    private var chat: LocalChat { model.local.chat(botId) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty, !chat.busy {
                            Text(tr("Questa chat resta su questo telefono."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(chat.messages) { message in
                            LocalMessageRow(message: message, image: chat.image).id(message.id)
                        }
                        if chat.busy {
                            if chat.streaming.isEmpty {
                                ProgressView().id("live")
                            } else {
                                MarkdownView(source: chat.streaming).frame(maxWidth: .infinity, alignment: .leading).id("live")
                            }
                        }
                        if let error = chat.lastError {
                            Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: chat.messages.last?.id) { _, id in withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                .onChange(of: chat.streaming.count) { _, _ in proxy.scrollTo("live", anchor: .bottom) }
            }
            composer
        }
        .navigationTitle(bot?.name ?? tr("Chat"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(tr("Modifica il bot"), systemImage: "slider.horizontal.3") { editing = true }
                    Button(tr("Nuova chat"), systemImage: "square.and.pencil", role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let bot { LocalBotEditor(existing: bot) }
        }
        .confirmationDialog(tr("Cancellare questa chat?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(tr("Cancella la chat"), role: .destructive) { if let bot { model.local.clearChat(bot) } }
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                HStack {
                    Label(tr("%@ immagini allegate", String(images.count)), systemImage: "photo")
                    Spacer()
                    Button(tr("Togli"), role: .destructive) { images = [] }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if takesImages {
                    PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "paperclip").font(.title3) }
                        .accessibilityLabel(tr("Allega un'immagine"))
                }
                TextField(tr("Scrivi un messaggio"), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                if chat.busy {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .accessibilityLabel(tr("Ferma"))
                } else {
                    Button {
                        chat.send(draft, images: images)
                        draft = ""
                        images = []
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                    .accessibilityLabel(tr("Invia"))
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct LocalMessageRow: View {
    let message: LocalMessage
    let image: (String) -> Data?

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(message.images, id: \.self) { name in
                    if let data = image(name), let picture = UIImage(data: data) {
                        Image(uiImage: picture).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                if !message.text.isEmpty {
                    Text(verbatim: message.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .bot:
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(source: message.text)
                if message.interrupted { Text(tr("Interrotto")).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            if let tool = message.tool {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        if let input = tool.input, !input.isEmpty { Text(verbatim: input).font(.caption.monospaced()) }
                        if let output = tool.output { Text(verbatim: output).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(12) }
                    }
                } label: {
                    Label {
                        Text(verbatim: tool.name).font(.footnote.monospaced())
                    } icon: {
                        if tool.ok == nil { ProgressView().controlSize(.mini) } else {
                            Image(systemName: tool.ok == false ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                        }
                    }
                    .foregroundStyle(tool.ok == false ? .red : .secondary)
                }
            }
        case .note:
            Text(verbatim: message.text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
