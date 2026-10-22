// The pieces both chats share, in the Mac app's look (Grok style): mascot
// avatars, the user's bubble in the bot's colour, the bot's in grey, the
// activity line, the floating composer pill.
import CompanionCore
import PhotosUI
import SwiftUI

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

/// A phone bot's mascot: its colour, the default shape.
struct LocalBotAvatar: View {
    let bot: LocalBot
    var size: CGFloat = 52
    var busy = false

    var body: some View {
        SwarmeAvatar(color: bot.paletteColor, size: size, state: busy ? .working : .idle, animated: true, trackPointer: false)
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

/// The floating composer: "+" for a picture, the field, send (or stop).
struct ComposerBar: View {
    @Binding var text: String
    let placeholder: String
    var canAttach = true
    @Binding var photo: PhotosPickerItem?
    var attachedCount = 0
    var busy = false
    var enabled = true
    let send: () -> Void
    var stop: (() -> Void)? = nil

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachedCount == 0 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if canAttach {
                PhotosPicker(selection: $photo, matching: .images) {
                    Image(systemName: attachedCount > 0 ? "photo.badge.checkmark" : "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 50, height: 50)
                        .background(Theme.pill, in: Circle())
                }
                .accessibilityLabel(tr("Allega un'immagine"))
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
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

extension LocalBot {
    /// The mascot's colour: a palette name (older bots kept a hex).
    var paletteColor: String { color.hasPrefix("#") ? "blue" : color }
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
