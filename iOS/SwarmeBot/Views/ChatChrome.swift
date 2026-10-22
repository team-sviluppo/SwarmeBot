// The pieces both chats share, in the Mac app's look (Grok style): mascot
// avatars, the user's bubble in the bot's colour, the bot's in grey, the
// activity line, the floating composer pill.
import CompanionCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A remote bot's mascot. Uploaded pictures are not shown yet: the mascot
/// in the bot's colour and shape stands in.
struct RemoteBotAvatar: View {
    let bot: Bot
    var size: CGFloat = 52
    var animated = true

    var body: some View {
        SwarmeAvatar(color: bot.color, size: size, state: SwarmeState.forBot(bot, last: nil),
                     silhouette: bot.mascotSilhouette, animated: animated, trackPointer: false)
    }
}

/// A phone bot's mascot: its colour and shape, its own resting face.
struct LocalBotAvatar: View {
    let bot: LocalBot
    var size: CGFloat = 52
    var busy = false

    var body: some View {
        SwarmeAvatar(color: bot.paletteColor, size: size, state: busy ? .working : SwarmeState.restingFace(for: bot.id),
                     silhouette: bot.shape, animated: true, trackPointer: false)
    }
}

/// A room: the first members' mascots, overlapping.
struct RoomAvatar: View {
    let members: [Bot]
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            if let first = members.first {
                RemoteBotAvatar(bot: first, size: size * 0.7, animated: false).offset(x: -size * 0.15, y: -size * 0.12)
            }
            if members.count > 1 {
                RemoteBotAvatar(bot: members[1], size: size * 0.7, animated: false).offset(x: size * 0.15, y: size * 0.12)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The title in the middle of a chat's bar: avatar and name in a pill; a tap shows the chats.
struct ChatTitlePill<Avatar: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let avatar: () -> Avatar

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                avatar()
                Text(verbatim: title).font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

/// One message as a bubble: the user's in the bot's colour on the right, the bot's grey on the left.
struct ChatBubble: View {
    let text: String
    let isUser: Bool
    /// The bot's palette name.
    let color: String
    var header: String? = nil
    var headerColor: String? = nil
    var footnote: String? = nil

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                if let header {
                    Text(verbatim: header).font(.caption.bold())
                        .foregroundStyle(headerColor.map(SwarmePalette.color) ?? Theme.secondary)
                }
                if isUser {
                    Text(verbatim: text).foregroundStyle(Theme.ink)
                } else {
                    MarkdownView(source: text).foregroundStyle(Theme.ink)
                }
                if let footnote { Text(verbatim: footnote).font(.caption).foregroundStyle(Theme.secondary) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(isUser ? SwarmePalette.bubble(color) : Theme.bubbleBot, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            if !isUser { Spacer(minLength: 32) }
        }
    }
}

/// A tool call, a routine, a note: a quiet line between the bubbles.
struct ActivityLine: View {
    let text: String
    var symbol = "wrench.and.screwdriver"
    var failed = false
    var running = false

    var body: some View {
        HStack(spacing: 6) {
            if running { ProgressView().controlSize(.mini) } else { Image(systemName: failed ? "exclamationmark.triangle" : symbol) }
            Text(verbatim: text).lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(failed ? Theme.danger : Theme.secondary)
        .padding(.horizontal, 4)
    }
}

/// The floating composer: "+" for a picture or a PDF, what is attached, the field, send (or stop).
struct ComposerBar: View {
    @Binding var text: String
    let placeholder: String
    var takesImages = true
    @Binding var photo: PhotosPickerItem?
    /// A PDF the user picked; nil when the chat takes none.
    var attachPDF: ((URL) -> Void)? = nil
    /// What goes with the next message, as chips ("📄 report.pdf").
    var attached: [String] = []
    var detach: (Int) -> Void = { _ in }
    var busy = false
    var enabled = true
    let send: () -> Void
    var stop: (() -> Void)? = nil

    @State private var pickingPhoto = false
    @State private var pickingPDF = false
    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attached.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attached.isEmpty { chips }
            bar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .fileImporter(isPresented: $pickingPDF, allowedContentTypes: [.pdf]) { result in
            if case let .success(url) = result { attachPDF?(url) }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(attached.enumerated()), id: \.offset) { index, label in
                    HStack(spacing: 6) {
                        Text(verbatim: label).lineLimit(1)
                        Button { detach(index) } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel(tr("Togli"))
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.pill, in: Capsule())
                }
            }
        }
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if takesImages || attachPDF != nil {
                Menu {
                    if takesImages {
                        Button(tr("Foto"), systemImage: "photo") { pickingPhoto = true }
                    }
                    if attachPDF != nil {
                        Button(tr("PDF"), systemImage: "doc.text") { pickingPDF = true }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 50, height: 50)
                        .background(Theme.pill, in: Circle())
                }
                .accessibilityLabel(tr("Allega"))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 14)
                if busy, let stop {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.body.weight(.bold)).foregroundStyle(.black)
                            .frame(width: 38, height: 38).background(Color.white, in: Circle())
                    }
                    .padding(.bottom, 6)
                    .accessibilityLabel(tr("Ferma"))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.black)
                            .frame(width: 38, height: 38).background(Color.white.opacity(empty || !enabled ? 0.35 : 1), in: Circle())
                    }
                    .disabled(empty || !enabled)
                    .padding(.bottom, 6)
                    .accessibilityLabel(tr("Invia"))
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .background(Theme.pill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

/// A transcript that stays on its last line while the reader is there: when
/// the room for it changes (the keyboard, the composer growing) or the content
/// does (a reply streaming, a bubble laid out again), and when a message
/// arrives. Scrolled up to read, it stays put until the next message.
private struct StickToBottom<Last: Equatable>: ViewModifier {
    let last: Last
    @State private var position = ScrollPosition(edge: .bottom)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                let resized = old.contentSize != new.contentSize || old.containerSize != new.containerSize
                    || old.contentInsets != new.contentInsets
                if resized, Self.atBottom(old) { position.scrollTo(edge: .bottom) }
            }
            .onChange(of: last) { _, _ in withAnimation { position.scrollTo(edge: .bottom) } }
    }

    private static func atBottom(_ geometry: ScrollGeometry) -> Bool {
        let end = geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
        return geometry.contentOffset.y >= end - 32
    }
}

extension View {
    func stickToBottom<Last: Equatable>(last: Last) -> some View {
        modifier(StickToBottom(last: last))
    }
}

extension LocalBot {
    /// The mascot's colour: a palette name (older bots kept a hex).
    var paletteColor: String { color.hasPrefix("#") ? "blue" : color }

    /// The mascot's shape; older bots get one from their id, so they differ too.
    var shape: String {
        if let silhouette, SwarmeSilhouette.ids.contains(silhouette) { return silhouette }
        let ids = SwarmeSilhouette.ids
        return ids[Int(id.utf8.reduce(UInt32(5381)) { $0 &* 33 &+ UInt32($1) } % UInt32(ids.count))]
    }
}

extension Date {
    /// "12:26", "Yesterday", "Monday", "3 Oct" — as the list shows times.
    func listStamp() -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return appFormatted(.dateTime.hour().minute()) }
        if calendar.isDateInYesterday(self) { return tr("Ieri") }
        if let days = calendar.dateComponents([.day], from: self, to: Date()).day, days < 7 { return appFormatted(.dateTime.weekday(.wide)) }
        return appFormatted(.dateTime.day().month(.abbreviated))
    }
}
