import CompanionCore
import SwarmeKit
import SwiftUI

/// The right column: who the bot is (Dettagli), the documents it knows
/// (Libreria), and the computer it drives.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var ui = UIState.shared

    enum Tab: String, CaseIterable, Identifiable {
        case details = "Dettagli"
        case library = "Libreria"
        case computer = "Computer"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { ui.showInspector = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 26, iconSize: 14))
                    .help("Chiudi (⌥⌘I)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            if let bot = model.selectedBot {
                if ui.inspectorTab != .details {
                    HStack(spacing: 10) {
                        BotAvatar(bot: bot, size: 32, state: SwarmeState.forBot(bot, last: model.visibleTranscript(bot.threadId).last))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bot.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                            if !bot.title.isEmpty {
                                Text(bot.title).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                SegmentedPicker(options: Tab.allCases.map { ($0, $0.rawValue) }, selection: Binding(
                    get: { ui.inspectorTab }, set: { ui.inspectorTab = $0 }
                ))
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

                ScrollView {
                    switch ui.inspectorTab {
                    case .details: BotDetails(bot: bot)
                    case .library: LibraryTab(bot: bot)
                    case .computer: ComputerTab(bot: bot)
                    }
                }
            } else if let room = model.selectedRoom {
                RoomDetails(room: room)
            } else {
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private var title: String {
        if model.selectedRoom != nil { return "Canale" }
        switch ui.inspectorTab {
        case .details: return "Impostazioni bot"
        case .library: return "Libreria"
        case .computer: return "Computer"
        }
    }

    private var icon: String {
        if model.selectedRoom != nil { return "number" }
        switch ui.inspectorTab {
        case .details: return "slider.horizontal.3"
        case .library: return "books.vertical"
        case .computer: return "display"
        }
    }
}

private struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
    }
}

private struct RoomDetails: View {
    let room: Room
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("#\(room.name)").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            if !room.bulletin.isEmpty {
                Text(room.bulletin).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Text("Membri").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
            ForEach(room.memberIds, id: \.self) { id in
                if let bot = model.state.bot(id) {
                    HStack(spacing: 8) {
                        BotAvatar(bot: bot, size: 24, animated: false)
                        Text(bot.name).font(.system(size: 13)).foregroundStyle(Theme.ink)
                        if room.busyBotId == id {
                            Text("sta scrivendo…").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
