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

        var title: String {
            switch self {
            case .details: return tr("Dettagli")
            case .library: return tr("Libreria")
            case .computer: return tr("Computer")
            }
        }
    }

    /// A core tab, or one a plugin added, as the segmented picker holds them.
    enum Choice: Hashable {
        case core(Tab)
        case plugin(String)
    }

    /// The plugins' tabs for the open chat.
    @MainActor
    static func pluginTabs(_ model: AppModel) -> [PluginTab] {
        guard model.selectedBot != nil else { return [] }
        return PluginHost.shared.inspectorTabs(ChatContext.current(model))
    }

    /// The plugin tab that is open, if the chat still has it.
    @MainActor
    static func openPluginTab(_ model: AppModel) -> PluginTab? {
        guard let id = UIState.shared.pluginTab else { return nil }
        return pluginTabs(model).first { $0.id == id }
    }

    /// The column is as wide as its open tab asks, 400 otherwise.
    @MainActor
    static func width(_ model: AppModel) -> CGFloat {
        openPluginTab(model)?.width ?? 400
    }

    private var pluginTabs: [PluginTab] { Self.pluginTabs(model) }
    private var openPlugin: PluginTab? { Self.openPluginTab(model) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { ui.showInspector = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 26, iconSize: 14))
                    .help(tr("Chiudi (⌥⌘I)"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            if let bot = model.selectedBot {
                if ui.inspectorTab != .details || openPlugin != nil {
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

                SegmentedPicker(options: Tab.allCases.map { (Choice.core($0), $0.title) } + pluginTabs.map { (Choice.plugin($0.id), $0.title) }, selection: Binding(
                    get: { openPlugin.map { Choice.plugin($0.id) } ?? .core(ui.inspectorTab) },
                    set: {
                        switch $0 {
                        case let .core(tab): ui.pluginTab = nil; ui.inspectorTab = tab
                        case let .plugin(id): ui.pluginTab = id
                        }
                    }
                ))
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

                if let openPlugin {
                    // a plugin's tab lays itself out and scrolls what it needs to
                    openPlugin.content
                } else {
                ScrollView {
                    switch ui.inspectorTab {
                    case .details: BotDetails(bot: bot)
                    case .library: LibraryTab(bot: bot)
                    case .computer: ComputerTab(bot: bot)
                    }
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
        if model.selectedRoom != nil { return tr("Canale") }
        if let openPlugin { return openPlugin.title }
        switch ui.inspectorTab {
        case .details: return tr("Impostazioni bot")
        case .library: return tr("Libreria")
        case .computer: return tr("Computer")
        }
    }

    private var icon: String {
        if model.selectedRoom != nil { return "number" }
        if let openPlugin { return openPlugin.icon }
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
            Text(verbatim: "#\(room.name)").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            if !room.bulletin.isEmpty {
                Text(room.bulletin).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Text(tr("Membri")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
            ForEach(room.memberIds, id: \.self) { id in
                if let bot = model.state.bot(id) {
                    HStack(spacing: 8) {
                        BotAvatar(bot: bot, size: 24, animated: false)
                        Text(bot.name).font(.system(size: 13)).foregroundStyle(Theme.ink)
                        if room.busyBotId == id {
                            Text(tr("sta scrivendo…")).font(.system(size: 11)).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            // guests: from a server, they answer from there
            ForEach(room.guests ?? [], id: \.memberId) { guest in
                HStack(spacing: 8) {
                    SwarmeAvatar(color: guest.color, size: 24, state: .idle, animated: false)
                    Text(guest.name).font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Text(model.remoteEngines.first { $0.id == guest.peerId }?.name ?? tr("server")).font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                    if room.busyBotId == guest.memberId {
                        Text(tr("sta scrivendo…")).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                }
            }
            if let host = room.guest {
                Text(tr("Canale misto di %@: si scrive da lì. Qui ci sono le risposte e le richieste di permesso dei bot di questo server.",
                        host.hostName ?? tr("un altro dispositivo")))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            // what a plugin adds to a channel's settings (a mirror of a channel hosted elsewhere is read there)
            if room.guest == nil {
                ForEach(Array(PluginHost.shared.settingsSections(.room(room), on: model).enumerated()), id: \.offset) { $0.element }
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
