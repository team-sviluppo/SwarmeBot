import CompanionCore
import SwarmeKit
import SwiftUI

/// The chat list (`Sidebar.tsx`, compact rail): 272 pt, `panel`, a search
/// field beside the traffic lights, sections of 46 pt rows, rooms, and the
/// footer (Automazioni, Vai a…, profile + settings). A section is only a
/// label each bot carries, so renaming one is patching every bot under it.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var confirmingDelete: Bot?
    @State private var collapsed: Set<String> = []
    @State private var layout = SectionLayout.shared
    @State private var naming: SectionNaming?
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            EngineSwitcher()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(filteredSections.enumerated()), id: \.element.name) { index, section in
                        let key = section.name ?? ""
                        if section.name != nil || filteredSections.count > 1 {
                            sectionHeader(section.name, count: section.bots.count, first: index == 0)
                        }
                        if section.bots.isEmpty, let name = section.name, !collapsed.contains(key) {
                            Text("Trascina qui un bot")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                                    .strokeBorder(dropTarget == name ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                .dropDestination(for: String.self) { items, _ in drop(items, on: name) } isTargeted: { dropTarget = $0 ? name : nil }
                        }
                        if !collapsed.contains(key) {
                            ForEach(section.bots) { bot in
                                row(for: bot).padding(.bottom, bot.chiefOfStaff == true ? 5 : 0)
                            }
                        }
                    }
                    if !filteredRooms.isEmpty {
                        SectionHeader(title: "Canali", count: filteredRooms.count, first: filteredSections.isEmpty,
                                      collapsed: collapsed.contains("#rooms")) { flip("#rooms") }
                        if !collapsed.contains("#rooms") {
                            ForEach(filteredRooms) { room in
                                RoomRow(room: room, selected: model.selection == .room(room.id))
                                    .onTapGesture { model.selection = .room(room.id) }
                            }
                        }
                    }
                    let hidden = model.state.bots.filter { $0.hidden == true }
                    if !hidden.isEmpty, query.isEmpty {
                        SectionHeader(title: "Nascosti", count: hidden.count, first: false,
                                      collapsed: !collapsed.contains("#hidden-open")) { flip("#hidden-open") }
                        if collapsed.contains("#hidden-open") {
                            ForEach(hidden) { bot in
                                BotRow(bot: bot, selected: model.selection == .bot(bot.id))
                                    .opacity(0.6)
                                    .onTapGesture { model.selection = .bot(bot.id) }
                                    .contextMenu {
                                        Button("Mostra") { Task { await model.patch(bot, BotPatch(hidden: false)) } }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            footer
        }
        .background(Theme.panel)
        .sheet(item: $naming) { naming in
            SectionNameSheet(naming: naming) { name in commit(naming, name) }
        }
        .onAppear { layout.sync(model.sections.compactMap(\.name)) }
        .onChange(of: model.sections.compactMap(\.name)) { _, names in layout.sync(names) }
        .confirmationDialog(
            "Eliminare \(confirmingDelete?.name ?? "")?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { bot in
            Button("Elimina", role: .destructive) { Task { await model.delete(bot) } }
        } message: { _ in
            Text("La conversazione e i suoi task vengono cancellati. Non si può annullare.")
        }
    }

    // MARK: Sections

    /// Header with its menu; a bot dropped on it moves in, a header dropped
    /// on it moves above it.
    private func sectionHeader(_ name: String?, count: Int, first: Bool) -> some View {
        let key = name ?? ""
        return SectionHeader(title: name ?? "Non assegnati", count: count, first: first,
                             collapsed: collapsed.contains(key)) { flip(key) }
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dropTarget == key ? Theme.accent.opacity(0.18) : .clear))
            .draggable(name.map { "section:\($0)" } ?? "section:") {
                Text(name ?? "Non assegnati").font(.system(size: 12)).padding(6)
            }
            .dropDestination(for: String.self) { items, _ in drop(items, on: name) } isTargeted: { dropTarget = $0 ? key : nil }
            .contextMenu {
                if let name {
                    Button("Rinomina sezione…") { naming = .rename(name) }
                    Button("Sposta su") { layout.move(name, by: -1) }.disabled(!layout.canMove(name, by: -1))
                    Button("Sposta giù") { layout.move(name, by: 1) }.disabled(!layout.canMove(name, by: 1))
                    Divider()
                }
                Button("Nuova sezione…") { naming = .new }
                if let name {
                    Divider()
                    Button("Elimina sezione", role: .destructive) { deleteSection(name) }
                        .help("I bot tornano tra i non assegnati")
                }
            }
    }

    /// `bot:<id>` moves that bot into `section` (nil clears it);
    /// `section:<name>` reorders.
    private func drop(_ items: [String], on section: String?) -> Bool {
        var handled = false
        for item in items {
            if item.hasPrefix("bot:"), let bot = model.state.bot(String(item.dropFirst(4))) {
                if (bot.section ?? "") != (section ?? "") { Task { await model.patch(bot, BotPatch(section: section ?? "")) } }
                handled = true
            } else if item.hasPrefix("section:"), let section {
                let moving = String(item.dropFirst(8))
                if !moving.isEmpty { layout.move(moving, before: section) }
                handled = true
            }
        }
        dropTarget = nil
        return handled
    }

    private func commit(_ naming: SectionNaming, _ name: String) {
        switch naming {
        case .new:
            layout.add(name)
        case let .rename(old):
            guard name != old else { return }
            layout.rename(old, to: name)
            for bot in model.state.bots where bot.section == old {
                Task { await model.patch(bot, BotPatch(section: name)) }
            }
        case let .move(botId):
            layout.add(name)
            if let bot = model.state.bot(botId) { Task { await model.patch(bot, BotPatch(section: name)) } }
        }
    }

    private func deleteSection(_ name: String) {
        layout.remove(name)
        for bot in model.state.bots where bot.section == name {
            Task { await model.patch(bot, BotPatch(section: "")) }
        }
    }

    private func flip(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    /// 56 pt for the traffic lights, then the search field and "+".
    private var header: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 56, height: 1)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                TextField("", text: $query, prompt: Text("Cerca").foregroundStyle(Theme.secondary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .onExitCommand { query = "" }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.raised.opacity(0.7)))
            Menu {
                Button("Nuovo bot") { Task { await model.createBot() } }
                Button("Nuovo canale…") { model.showNewRoom = true }
                Button("Nuova sezione…") { naming = .new }
                Divider()
                Button("Libreria team…") { openWindow(id: "teams") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Nuovo bot (⌘N) o canale (⇧⌘N)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            FooterRow(icon: "calendar", title: "Automazioni") { openWindow(id: "automations") }
                .help("Automazioni (⇧⌘R)")
            FooterRow(icon: "command", title: "Vai a…") { model.showPalette = true }
                .help("Cerca chat, comandi e messaggi (⌘K)")
            HStack(spacing: 8) {
                InitialsAvatar(name: userName, size: 22)
                Text(userName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(IconButtonStyle(size: 27, iconSize: 15))
                    .help("Impostazioni (⌘,)")
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var userName: String { NSFullUserName().isEmpty ? NSUserName() : NSFullUserName() }

    @ViewBuilder
    private func row(for bot: Bot) -> some View {
        BotRow(bot: bot, selected: model.selection == .bot(bot.id))
            .onTapGesture { model.selection = .bot(bot.id) }
            .draggable("bot:\(bot.id)") {
                HStack(spacing: 6) {
                    BotAvatar(bot: bot, size: 20, animated: false)
                    Text(bot.name).font(.system(size: 13, weight: .medium))
                }
                .padding(6)
            }
            .contextMenu {
                Button(bot.pinned == true ? "Rimuovi dai fissati" : "Fissa in alto") {
                    Task { await model.patch(bot, BotPatch(pinned: !(bot.pinned ?? false))) }
                }
                Menu("Sposta in") {
                    ForEach(layout.names, id: \.self) { name in
                        Button {
                            Task { await model.patch(bot, BotPatch(section: name)) }
                        } label: {
                            if bot.section == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                    if bot.section?.isEmpty == false {
                        Divider()
                        Button("Nessuna sezione") { Task { await model.patch(bot, BotPatch(section: "")) } }
                    }
                    Divider()
                    Button("Nuova sezione…") { naming = .move(bot.id) }
                }
                Button(bot.unread ? "Segna come letto" : "Segna come non letto") {
                    Task { await model.patch(bot, BotPatch(unread: !bot.unread)) }
                }
                Divider()
                Button("Copia ID conversazione") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bot.threadId, forType: .string)
                }
                Divider()
                Button("Nascondi") { Task { await model.patch(bot, BotPatch(hidden: true)) } }
                Button("Elimina…", role: .destructive) { confirmingDelete = bot }
            }
    }

    private var filteredSections: [(name: String?, bots: [Bot])] {
        guard !query.isEmpty else { return layout.arrange(model.sections) }
        return layout.arrange(model.sections).compactMap { section in
            let bots = section.bots.filter { matches($0.name) || matches($0.title) }
            return bots.isEmpty ? nil : (section.name, bots)
        }
    }
    private var filteredRooms: [Room] {
        let rooms = model.state.rooms.filter { $0.dm != true }
        guard !query.isEmpty else { return rooms }
        return rooms.filter { matches($0.name) }
    }
    private func matches(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains(query)
    }
}

/// Grok Bot's section label: 12 pt secondary, title case, no rule. The
/// chevron shows on hover, and stays while the section is collapsed.
private struct SectionHeader: View {
    let title: String
    var count: Int = 0
    var first = false
    var collapsed = false
    var toggle: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .fixedSize()
                if collapsed { Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .opacity(hovering || collapsed ? 1 : 0)
                    .animation(Theme.quick, value: collapsed)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.secondary)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, first ? 4 : 14)
        .padding(.bottom, 4)
    }
}

private struct FooterRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Theme.secondary).frame(width: 18)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}

/// `flex gap-2 rounded-lg px-2 py-1.5 pr-8`, avatar 32 → 46 pt rows.
struct BotRow: View {
    let bot: Bot
    let selected: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let busy = model.isBusy(bot)
        let last = model.visibleTranscript(bot.threadId).last
        let chief = bot.chiefOfStaff == true
        HStack(spacing: 8) {
            BotAvatar(bot: bot, size: 32, state: MausState.forBot(bot, last: last), priority: selected || busy)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(bot.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if bot.pinned == true {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    if selected, let last {
                        Text(last.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .opacity(hovering ? 0 : 1)
                    }
                }
                .frame(height: 19.5)
                HStack(spacing: 6) {
                    if chief {
                        Text("Chief of Staff").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                    Text(preview)
                        .font(.system(size: Theme.captionSize))
                        .foregroundStyle(busy ? Theme.accent.opacity(0.9) : Theme.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if bot.unread { Circle().fill(Theme.accent).frame(width: 8, height: 8) }
                }
                .frame(height: 14.4)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, hovering ? 32 : 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .fill(chief ? Theme.accent.opacity(selected ? 0.15 : hovering ? 0.10 : 0.05)
                      : selected ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .stroke(chief ? Theme.accent.opacity(selected ? 0.4 : 0.25) : .clear, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering, bot.hidden != true {
                Button { Task { await model.patch(bot, BotPatch(hidden: true)) } } label: {
                    Image(systemName: "archivebox").font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card.opacity(0.9))
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1))
                }
                .buttonStyle(.plain)
                .help("Nascondi")
                .padding(.trailing, 4)
                .padding(.top, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }

    private var preview: String {
        if bot.activity == "waiting-on-you" { return "Ti sta aspettando" }
        if model.isBusy(bot) { return "Sta lavorando…" }
        let transcript = model.visibleTranscript(bot.threadId)
        guard let message = transcript.last(where: { $0.kind == .text && !($0.text ?? "").isEmpty }) else {
            return bot.description.isEmpty ? " " : bot.description
        }
        let text = (message.text ?? "").replacingOccurrences(of: "\n", with: " ")
        return (message.role == .user ? "Tu: " : "") + text
    }
}

/// Rooms wear their members: one mascot at 32, or up to three at 18
/// overlapping by 8 plus a "+N" chip.
private struct RoomRow: View {
    let room: Room
    let selected: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let members = room.memberIds.compactMap { model.state.bot($0) }
        HStack(spacing: 8) {
            Group {
                if members.count == 1, let only = members.first {
                    BotAvatar(bot: only, size: 32, animated: false)
                } else if members.isEmpty {
                    ZStack {
                        Circle().fill(Theme.raised)
                        Image(systemName: "number").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                } else {
                    HStack(spacing: -8) {
                        ForEach(members.prefix(3)) { BotAvatar(bot: $0, size: 18, animated: false) }
                        if members.count > 3 {
                            Text("+\(members.count - 3)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Theme.raised))
                                .overlay(Circle().stroke(Theme.hairline.opacity(0.4)))
                        }
                    }
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(room.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 19.5)
                HStack {
                    Text(members.map(\.name).joined(separator: ", "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if room.unread { Circle().fill(Theme.accent).frame(width: 8, height: 8) }
                }
                .frame(height: 14.4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .hoverHighlight(selected: selected)
    }
}

/// What the name sheet is for.
enum SectionNaming: Identifiable {
    case new
    case rename(String)
    /// New section, and this bot goes in it.
    case move(String)

    var id: String {
        switch self {
        case .new: return "new"
        case let .rename(name): return "rename:\(name)"
        case let .move(bot): return "move:\(bot)"
        }
    }
}

private struct SectionNameSheet: View {
    let naming: SectionNaming
    let save: (String) -> Void
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Nome sezione", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                Button(action: commit) { Text(isRename ? "Rinomina" : "Crea") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || name.count > 60)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { if case let .rename(old) = naming { draft = old } }
    }

    private var isRename: Bool { if case .rename = naming { return true } else { return false } }
    private var title: String { isRename ? "Rinomina sezione" : "Nuova sezione" }
    private var name: String { draft.trimmingCharacters(in: .whitespaces) }

    private func commit() {
        guard !name.isEmpty, name.count <= 60 else { return }
        save(name)
        dismiss()
    }
}
