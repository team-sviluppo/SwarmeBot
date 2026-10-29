import CompanionCore
import SwarmeKit
import SwiftUI

/// ⌘K: jump to a chat, run a command, or search every transcript.
/// ↑/↓ move, ⏎ opens, ⎋ closes.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var pluginCommands: [PluginCommand] = []
    @State private var cursor = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        var section = tr("Chat")
        let id: String
        let icon: String
        let title: String
        let detail: String
        let action: () -> Void
    }

    private func dismiss() { model.showPalette = false }

    var body: some View {
        let items = self.items
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                TextField(tr("Cerca chat, comandi e messaggi"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { run(items) }
                Text(verbatim: "esc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline.opacity(0.5)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.hairline.opacity(0.5)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].section != item.section {
                                Text(item.section.uppercased())
                                    .font(.system(size: 11, weight: .medium))
                                    .tracking(0.88)
                                    .foregroundStyle(Theme.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, index == 0 ? 4 : 10)
                                    .padding(.bottom, 4)
                            }
                            Button {
                                item.action()
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.icon).font(.system(size: 15)).frame(width: 18).foregroundStyle(Theme.secondary)
                                    Text(item.title).font(.system(size: 14)).foregroundStyle(Theme.ink).lineLimit(1)
                                    if !item.detail.isEmpty {
                                        Text(item.detail).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(index == cursor ? Theme.raised : .clear))
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: cursor) { _, value in
                    if items.indices.contains(value) { proxy.scrollTo(items[value].id) }
                }
            }
        }
        .frame(maxWidth: 560, maxHeight: 480)
        .fixedSize(horizontal: false, vertical: false)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Theme.shadow.opacity(0.6), radius: 25, y: 25)
        .padding(.horizontal, 24)
        .onAppear { focused = true }
        .task { pluginCommands = await PluginHost.shared.commands(model) }
        .onExitCommand { dismiss() }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
        .onChange(of: query) { _, _ in cursor = 0 }
        .task(id: query) {
            guard query.count >= 2 else { hits = []; return }
            try? await Task.sleep(for: .milliseconds(200))
            hits = await model.search(query)
        }
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(cursor) else { return }
        items[cursor].action()
        dismiss()
    }

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func matches(_ text: String) -> Bool { q.isEmpty || text.localizedCaseInsensitiveContains(q) }
        var out: [Item] = []
        out += pluginCommands.filter { matches($0.title) || matches($0.detail) }.map { command in
            Item(section: command.section, id: command.id, icon: command.icon, title: command.title, detail: command.detail, action: command.action)
        }
        for bot in model.state.bots where bot.hidden != true && (matches(bot.name) || matches(bot.title)) {
            out.append(Item(id: "bot-\(bot.id)", icon: "bubble.left", title: bot.name, detail: bot.title) {
                model.selection = .bot(bot.id)
            })
        }
        for room in model.state.rooms where room.dm != true && matches(room.name) {
            out.append(Item(section: tr("Canali"), id: "room-\(room.id)", icon: "number", title: room.name, detail: tr("Canale")) {
                model.selection = .room(room.id)
            })
        }
        let remoteBots = model.remoteEngines.map { engine in
            Item(section: tr("Comandi"), id: "cmd-new-bot-\(engine.id)", icon: "server.rack", title: tr("Nuovo bot su %@", engine.name), detail: tr("Server remoto")) {
                Task { await model.createBot(on: .remote(engine.id)) }
            }
        }
        let commands: [Item] = [
            Item(section: tr("Comandi"), id: "cmd-new-bot", icon: "plus", title: tr("Nuovo bot"), detail: "⌘N") { Task { await model.createBot() } },
        ] + remoteBots + [
            Item(section: tr("Comandi"), id: "cmd-new-room", icon: "person.3", title: tr("Nuovo canale"), detail: "") { model.showNewRoom = true },
            Item(section: tr("Comandi"), id: "cmd-automations", icon: "clock.arrow.circlepath", title: tr("Automazioni"), detail: tr("Routine e webhook")) {
                openWindow(id: "automations")
            },
            Item(section: tr("Comandi"), id: "cmd-teams", icon: "books.vertical", title: tr("Libreria team"), detail: tr("Importa o esporta un team")) {
                openWindow(id: "teams")
            },
            Item(section: tr("Comandi"), id: "cmd-settings", icon: "gearshape", title: tr("Impostazioni"), detail: "⌘,") { openSettings() },
        ]
        out += commands.filter { matches($0.title) }
        for hit in hits {
            out.append(Item(section: tr("Messaggi"), id: "hit-\(hit.id)", icon: "text.magnifyingglass", title: hit.name + (hit.task.map { " · \($0)" } ?? ""), detail: hit.snippet) {
                Task { await model.open(hit) }
            })
        }
        return out
    }
}
