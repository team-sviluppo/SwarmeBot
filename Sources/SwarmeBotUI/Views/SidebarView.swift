import CompanionCore
import SwarmeKit
import SwiftUI

/// The chat list (`Sidebar.tsx`, compact rail): 272 pt, `panel`, a search
/// field beside the traffic lights, sections of 46 pt rows, rooms, and the
/// footer (Automazioni, profile + settings; "Vai a…" lives on ⌘K and in the
/// menu). A section is only a label each bot carries, so renaming one is
/// patching every bot under it.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var confirmingDelete: Bot?
    @State private var collapsed: Set<String> = []
    @State private var layout = SectionLayout.shared
    @State private var botOrder = BotOrder.shared
    @State private var naming: SectionNaming?
    @State private var dropTarget: String?
    @State private var moving: BotTransferRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let blocks = visibleBlocks
                    // ids of their own while this Mac is a peer (see peerSection)
                    let mode = model.engineChoice == .local ? "local|" : "peer|"
                    ForEach(blocks.indices.map { (id: mode + blocks[$0].stored, index: $0) }, id: \.id) { entry in
                        block(blocks[entry.index], first: entry.index == 0, blocks: blocks)
                    }
                    if model.engineChoice == .local { hiddenBots }
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
        .sheet(item: $moving) { request in BotTransferSheet(request: request) }
        // a server's bots have no sections here, whatever label they carry
        .onAppear {
            if model.engineChoice == .local { layout.sync(model.sections.compactMap(\.name)) }
            layout.syncEngines(model.remoteEngines.map(\.id))
        }
        .onChange(of: model.sections.compactMap(\.name)) { _, names in
            if model.engineChoice == .local { layout.sync(names) }
        }
        .onChange(of: model.remoteEngines.map(\.id)) { _, ids in layout.syncEngines(ids) }
        .confirmationDialog(
            tr("Eliminare %@?", confirmingDelete?.name ?? ""),
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { bot in
            Button(tr("Elimina"), role: .destructive) { Task { await model.delete(bot) } }
        } message: { _ in
            Text(tr("La conversazione e i suoi task vengono cancellati. Non si può annullare."))
        }
    }

    // MARK: Blocks

    /// The blocks with something to show, in the order the user gave them:
    /// this Mac's sections (from its peer while a server's chat is open),
    /// its channels, and every server.
    private var visibleBlocks: [SidebarItem] {
        var visible: [SidebarItem] = []
        let local = model.engineChoice == .local
        let peer = local ? nil : model.peer(.local)
        let sections = local ? filteredSections : peer.map(peerSections) ?? []
        visible += sections.map { $0.name.map(SidebarItem.section) ?? .unassigned }
        if !(local ? filteredRooms : peer.map(peerRooms) ?? []).isEmpty { visible.append(.rooms) }
        visible += model.remoteEngines.filter { query.isEmpty || !remoteBots($0).isEmpty }.map { .engine($0.id) }
        return layout.blocks(visible)
    }

    @ViewBuilder
    private func block(_ item: SidebarItem, first: Bool, blocks: [SidebarItem]) -> some View {
        switch item {
        case .section, .unassigned:
            if model.engineChoice == .local {
                localSection(item.sectionName, first: first, blocks: blocks)
            } else if let peer = model.peer(.local) {
                peerSection(item.sectionName, of: peer, first: first, blocks: blocks)
            }
        case .rooms:
            roomsSection(first: first, blocks: blocks)
        case let .engine(id):
            if let engine = model.remoteEngines.first(where: { $0.id == id }) {
                remoteSection(engine, first: first, blocks: blocks)
            }
        }
    }

    /// A section of this Mac's bots while its chats are the ones open: it can
    /// be dragged, renamed and filled.
    @ViewBuilder
    private func localSection(_ name: String?, first: Bool, blocks: [SidebarItem]) -> some View {
        let sections = filteredSections
        let bots = sections.first { $0.name == name }?.bots ?? []
        let key = name ?? ""
        if name != nil || sections.count > 1 {
            sectionHeader(name, count: bots.count, first: first, blocks: blocks)
        }
        if bots.isEmpty, let name, !collapsed.contains(key) {
            let target = SidebarItem.section(name).stored
            Text(tr("Trascina qui un bot"))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                    .strokeBorder(dropTarget == target ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .dropDestination(for: String.self) { items, _ in
                    drop(items, on: .section(name), blocks: blocks, bots: true)
                } isTargeted: { dropTarget = $0 ? target : nil }
        }
        if !collapsed.contains(key) {
            ForEach(bots) { bot in
                row(for: bot, on: .local, list: bots).padding(.bottom, bot.chiefOfStaff == true ? 5 : 0)
            }
        }
    }

    /// A section of this Mac's bots while a server's chat is open, read from
    /// its peer; a click switches back to this Mac.
    @ViewBuilder
    private func peerSection(_ name: String?, of peer: EnginePeer, first: Bool, blocks: [SidebarItem]) -> some View {
        let sections = peerSections(peer)
        let bots = sections.first { $0.name == name }?.bots ?? []
        let key = name ?? ""
        let item = name.map(SidebarItem.section) ?? .unassigned
        if name != nil || sections.count > 1 {
            reorderable(SectionHeader(title: name ?? tr("Non assegnati"), count: bots.count, first: first,
                                      collapsed: collapsed.contains(key)) { flip(key) }, item, blocks: blocks)
                .contextMenu { moveButtons(item, blocks: blocks) }
        }
        if !collapsed.contains(key) {
            // ids of their own: the lazy stack keys its rows by id, and with the
            // shown engine's ids it reused those rows — their tap and menu
            // included — after a switch (a click then selected a chat the shown
            // engine does not have: "Nessuna chat selezionata")
            ForEach(bots, id: \.peerKey) { bot in
                peerRow(bot, of: peer, on: .local, list: bots)
                    .padding(.bottom, bot.chiefOfStaff == true ? 5 : 0)
            }
        }
    }

    /// This Mac's channels, from its peer while a server's chat is open.
    @ViewBuilder
    private func roomsSection(first: Bool, blocks: [SidebarItem]) -> some View {
        let local = model.engineChoice == .local
        let peer = local ? nil : model.peer(.local)
        let rooms = local ? filteredRooms : peer.map(peerRooms) ?? []
        reorderable(SectionHeader(title: tr("Canali"), count: rooms.count, first: first,
                                  collapsed: collapsed.contains("#rooms")) { flip("#rooms") }, .rooms, blocks: blocks)
            .contextMenu {
                if local {
                    Button(tr("Nuovo canale…")) { model.showNewRoom = true }
                    Divider()
                }
                moveButtons(.rooms, blocks: blocks)
            }
        if !collapsed.contains("#rooms") {
            if let peer {
                ForEach(rooms, id: \.peerKey) { room in
                    RoomRow(room: room, selected: false, peer: peer)
                        .onTapGesture { model.open(room: room.id, on: .local) }
                }
            } else {
                ForEach(rooms) { room in
                    RoomRow(room: room, selected: model.selection == .room(room.id))
                        .onTapGesture { model.selection = .room(room.id) }
                }
            }
        }
    }

    /// This Mac's hidden bots, at the bottom, while its chats are the ones open.
    @ViewBuilder
    private var hiddenBots: some View {
        let hidden = model.state.bots.filter { $0.hidden == true }
        if !hidden.isEmpty, query.isEmpty {
            SectionHeader(title: tr("Nascosti"), count: hidden.count, first: false,
                          collapsed: !collapsed.contains("#hidden-open")) { flip("#hidden-open") }
            if collapsed.contains("#hidden-open") {
                ForEach(hidden) { bot in
                    BotRow(bot: bot, selected: model.selection == .bot(bot.id))
                        .opacity(0.6)
                        .onTapGesture { model.selection = .bot(bot.id) }
                        .contextMenu {
                            Button(tr("Mostra")) { Task { await model.patch(bot, BotPatch(hidden: false)) } }
                        }
                }
            }
        }
    }

    /// A server: one section named after it, all its bots, no sections of its own.
    @ViewBuilder
    private func remoteSection(_ engine: RemoteEngine, first: Bool, blocks: [SidebarItem]) -> some View {
        let choice = EngineChoice.remote(engine.id)
        let shown = model.engineChoice == choice
        let peer = shown ? nil : model.peer(choice)
        let bots = remoteBots(engine)
        let key = "#engine:\(engine.id)"
        reorderable(SectionHeader(title: engine.name, count: bots.count, first: first, collapsed: collapsed.contains(key),
                                  icon: "server.rack", status: shown ? model.status == .live : peer?.reachable ?? false) { flip(key) },
                    .engine(engine.id), blocks: blocks)
            .contextMenu {
                Button(tr("Nuovo bot su %@", engine.name)) { Task { await model.createBot(on: choice) } }
                Divider()
                moveButtons(.engine(engine.id), blocks: blocks)
                Divider()
                Button(tr("Impostazioni dei server remoti…")) { openSettings() }
            }
        if !collapsed.contains(key) {
            if bots.isEmpty {
                Text(shown || peer?.reachable == true ? tr("Nessun bot") : tr("Collegamento in corso…"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            // two ForEach, not one with a branch inside: the same ids
            // would let the lazy stack reuse a row across a switch
            if shown {
                ForEach(bots) { bot in
                    row(for: bot, on: choice, list: bots, sections: false)
                }
            } else if let peer {
                ForEach(bots, id: \.peerKey) { bot in
                    peerRow(bot, of: peer, on: choice, list: bots)
                }
            }
        }
    }

    /// A server's bots that match the search, pinned first, then in the user's order.
    private func remoteBots(_ engine: RemoteEngine) -> [Bot] {
        let choice = EngineChoice.remote(engine.id)
        let all = botOrder.sorted(model.engineChoice == choice ? model.visibleBots : model.peer(choice)?.visibleBots ?? [])
        return query.isEmpty ? all : all.filter { matches($0.name) || matches($0.title) }
    }

    private func peerSections(_ peer: EnginePeer) -> [(name: String?, bots: [Bot])] {
        filter(arranged(AppModel.sections(of: peer.visibleBots))).filter { !$0.bots.isEmpty }
    }

    /// Sections in the user's order, and the bots of each in theirs.
    private func arranged(_ sections: [(name: String?, bots: [Bot])]) -> [(name: String?, bots: [Bot])] {
        layout.arrange(sections).map { ($0.name, botOrder.sorted($0.bots)) }
    }

    private func peerRooms(_ peer: EnginePeer) -> [Room] {
        filter(peer.state.rooms.filter { $0.dm != true && $0.guest == nil })
    }

    // MARK: Order

    /// A header that can be dragged onto another one, and takes one dropped on it.
    private func reorderable(_ header: some View, _ item: SidebarItem, blocks: [SidebarItem], bots: Bool = false) -> some View {
        header
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dropTarget == item.stored ? Theme.accent.opacity(0.18) : .clear))
            .draggable("item:" + item.stored) {
                Text(title(of: item)).font(.system(size: 12)).padding(6)
            }
            .dropDestination(for: String.self) { items, _ in
                drop(items, on: item, blocks: blocks, bots: bots)
            } isTargeted: { dropTarget = $0 ? item.stored : nil }
    }

    @ViewBuilder
    private func moveButtons(_ item: SidebarItem, blocks: [SidebarItem]) -> some View {
        Button(tr("Sposta su")) { layout.move(item, by: -1, among: blocks) }
            .disabled(!SectionLayout.canMove(item, by: -1, among: blocks))
        Button(tr("Sposta giù")) { layout.move(item, by: 1, among: blocks) }
            .disabled(!SectionLayout.canMove(item, by: 1, among: blocks))
    }

    private func title(of item: SidebarItem) -> String {
        switch item {
        case let .section(name): return name
        case .unassigned: return tr("Non assegnati")
        case .rooms: return tr("Canali")
        case let .engine(id): return model.remoteEngines.first { $0.id == id }?.name ?? id
        }
    }

    // MARK: Sections

    /// Header with its menu; a bot dropped on it moves in, a header dropped
    /// on it takes its place.
    private func sectionHeader(_ name: String?, count: Int, first: Bool, blocks: [SidebarItem]) -> some View {
        let key = name ?? ""
        let item = name.map(SidebarItem.section) ?? .unassigned
        return reorderable(SectionHeader(title: name ?? tr("Non assegnati"), count: count, first: first,
                                         collapsed: collapsed.contains(key)) { flip(key) }, item, blocks: blocks, bots: true)
            .contextMenu {
                if let name {
                    Button(tr("Rinomina sezione…")) { naming = .rename(name) }
                }
                moveButtons(item, blocks: blocks)
                Divider()
                Button(tr("Nuova sezione…")) { naming = .new }
                if let name {
                    Divider()
                    Button(tr("Elimina sezione"), role: .destructive) { deleteSection(name) }
                        .help(tr("I bot tornano tra i non assegnati"))
                }
            }
    }

    /// `bot:<id>` moves that bot into the section dropped on (when `bots`,
    /// on this Mac's own sections); `item:<item>` reorders.
    private func drop(_ items: [String], on target: SidebarItem, blocks: [SidebarItem], bots: Bool) -> Bool {
        var handled = false
        for payload in items {
            if payload.hasPrefix("bot:") {
                guard bots, target.isSection || target == .unassigned,
                      let bot = model.state.bot(String(payload.dropFirst(4))) else { continue }
                let section = target.sectionName ?? ""
                if (bot.section ?? "") != section { Task { await model.patch(bot, BotPatch(section: section)) } }
                handled = true
            } else if payload.hasPrefix("item:"), let moving = SidebarItem(stored: String(payload.dropFirst(5))) {
                layout.move(moving, to: target, among: blocks)
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
                TextField("", text: $query, prompt: Text(tr("Cerca")).foregroundStyle(Theme.secondary))
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
                Button(tr("Nuovo bot")) { Task { await model.createBot() } }
                if !model.remoteEngines.isEmpty {
                    // the submenu is the question: on which server
                    Menu(tr("Nuovo bot remoto")) {
                        ForEach(model.remoteEngines) { engine in
                            Button(engine.name) { Task { await model.createBot(on: .remote(engine.id)) } }
                        }
                    }
                }
                Button(tr("Nuovo canale…")) { model.showNewRoom = true }
                Button(tr("Nuova sezione…")) { naming = .new }
                Divider()
                Button(tr("Libreria team…")) { openWindow(id: "teams") }
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
            .help(tr("Nuovo bot su questo Mac (⌘N) o su un server, nuovo canale (⇧⌘N)"))
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            FooterRow(icon: "calendar", title: tr("Automazioni")) { openWindow(id: "automations") }
                .help(tr("Automazioni (⇧⌘R)"))
            HStack(spacing: 8) {
                InitialsAvatar(name: userName, size: 22)
                Text(userName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(IconButtonStyle(size: 27, iconSize: 15))
                    .help(tr("Impostazioni (⌘,)"))
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var userName: String { NSFullUserName().isEmpty ? NSUserName() : NSFullUserName() }

    /// A row of the engine shown. `sections` is false for a server's bots:
    /// they have none. The tap goes through `open`, which switches engine
    /// when needed, so even a row SwiftUI kept from before a switch opens
    /// the right chat. `list` is the block the row is in, for reordering.
    @ViewBuilder
    private func row(for bot: Bot, on engine: EngineChoice, list: [Bot], sections: Bool = true) -> some View {
        botReorder(BotRow(bot: bot, selected: model.selection == .bot(bot.id))
            .onTapGesture { model.open(bot: bot.id, on: engine) }, bot, list: list, sections: sections)
            .contextMenu {
                Button(bot.pinned == true ? tr("Rimuovi dai fissati") : tr("Fissa in alto")) {
                    Task { await model.patch(bot, BotPatch(pinned: !(bot.pinned ?? false))) }
                }
                botMoveButtons(bot, list: list)
                if sections {
                Menu(tr("Sposta in")) {
                    ForEach(layout.names, id: \.self) { name in
                        Button {
                            Task { await model.patch(bot, BotPatch(section: name)) }
                        } label: {
                            if bot.section == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                    if bot.section?.isEmpty == false {
                        Divider()
                        Button(tr("Nessuna sezione")) { Task { await model.patch(bot, BotPatch(section: "")) } }
                    }
                    Divider()
                    Button(tr("Nuova sezione…")) { naming = .move(bot.id) }
                }
                }
                Button(bot.unread ? tr("Segna come letto") : tr("Segna come non letto")) {
                    Task { await model.patch(bot, BotPatch(unread: !bot.unread)) }
                }
                Divider()
                Button(tr("Copia ID conversazione")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bot.threadId, forType: .string)
                }
                if !model.transferTargets.isEmpty {
                    Menu(tr("Trasferisci su")) {
                        ForEach(model.transferTargets, id: \.self) { target in
                            Button(model.engineName(target)) { moving = BotTransferRequest(bot: bot, target: target) }
                        }
                    }
                }
                Divider()
                Button(tr("Nascondi")) { Task { await model.patch(bot, BotPatch(hidden: true)) } }
                Button(tr("Elimina…"), role: .destructive) { confirmingDelete = bot }
            }
    }

    /// A bot of an engine the window is not showing: a click opens it there;
    /// it can be reordered among `list`, nothing else.
    private func peerRow(_ bot: Bot, of peer: EnginePeer, on engine: EngineChoice, list: [Bot]) -> some View {
        botReorder(BotRow(bot: bot, selected: false, peer: peer)
            .onTapGesture { model.open(bot: bot.id, on: engine) }, bot, list: list, sections: false)
            .contextMenu { botMoveButtons(bot, list: list) }
    }

    /// Drag a row onto another of its block to take its place; on this Mac's
    /// sections (`sections`) a bot from another section joins this one there.
    private func botReorder(_ row: some View, _ bot: Bot, list: [Bot], sections: Bool) -> some View {
        let key = "bot:" + bot.id
        return row
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .stroke(dropTarget == key ? Theme.accent : .clear, lineWidth: 1.5))
            .draggable(key) {
                HStack(spacing: 6) {
                    BotAvatar(bot: bot, size: 20, animated: false)
                    Text(bot.name).font(.system(size: 13, weight: .medium))
                }
                .padding(6)
            }
            .dropDestination(for: String.self) { items, _ in
                dropBots(items, onto: bot, list: list, sections: sections)
            } isTargeted: { dropTarget = $0 && query.isEmpty ? key : nil }
    }

    @ViewBuilder
    private func botMoveButtons(_ bot: Bot, list: [Bot]) -> some View {
        // a search shows part of the block: no reordering then
        Button(tr("Sposta su")) { botOrder.move(bot.id, by: -1, in: list) }
            .disabled(!query.isEmpty || !BotOrder.canMove(bot.id, by: -1, in: list))
        Button(tr("Sposta giù")) { botOrder.move(bot.id, by: 1, in: list) }
            .disabled(!query.isEmpty || !BotOrder.canMove(bot.id, by: 1, in: list))
        Divider()
    }

    private func dropBots(_ payloads: [String], onto target: Bot, list: [Bot], sections: Bool) -> Bool {
        defer { dropTarget = nil }
        guard query.isEmpty else { return false }
        for payload in payloads where payload.hasPrefix("bot:") {
            let id = String(payload.dropFirst(4))
            guard id != target.id else { return false }
            if let moved = list.first(where: { $0.id == id }) {
                // pinned bots stay above the others whatever the order says
                guard (moved.pinned == true) == (target.pinned == true) else { return false }
                botOrder.move(id, to: target.id, in: list.map(\.id))
                return true
            }
            if sections, let bot = model.state.bot(id) {
                botOrder.move(id, to: target.id, in: list.map(\.id))
                let section = target.section ?? ""
                if (bot.section ?? "") != section { Task { await model.patch(bot, BotPatch(section: section)) } }
                return true
            }
        }
        return false
    }

    private var filteredSections: [(name: String?, bots: [Bot])] { filter(arranged(model.sections)) }

    private func filter(_ sections: [(name: String?, bots: [Bot])]) -> [(name: String?, bots: [Bot])] {
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let bots = section.bots.filter { matches($0.name) || matches($0.title) }
            return bots.isEmpty ? nil : (section.name, bots)
        }
    }
    private var filteredRooms: [Room] {
        // not the mirrors of this Mac's own mixed channels on the server shown
        let me = model.activeRemoteEngine?.deviceId
        return filter(model.state.rooms.filter { $0.dm != true && ($0.guest == nil || $0.guest?.deviceId != me) })
    }
    private func filter(_ rooms: [Room]) -> [Room] {
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
    /// A server's section: its symbol, and a dot for its connection.
    var icon: String?
    var status: Bool?
    var toggle: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10)) }
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .fixedSize()
                if collapsed { Text(verbatim: "\(count)").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .opacity(hovering || collapsed ? 1 : 0)
                    .animation(Theme.quick, value: collapsed)
                Spacer(minLength: 0)
                if let status {
                    Circle().fill(status ? Theme.success : Theme.danger.opacity(0.8)).frame(width: 6, height: 6)
                        .help(status ? tr("Collegato") : tr("Non raggiungibile"))
                }
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
    /// Set for a bot of an engine the window is not showing: read from it,
    /// and no actions (they would go to the shown engine).
    var peer: EnginePeer?
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let busy = model.isBusy(bot)
        let last = transcript.last
        let chief = bot.chiefOfStaff == true
        HStack(spacing: 8) {
            BotAvatar(bot: bot, size: 32, state: SwarmeState.forBot(bot, last: last), priority: selected || busy)
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
                        Text(last.date.appFormatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .opacity(hovering ? 0 : 1)
                    }
                }
                .frame(height: 19.5)
                HStack(spacing: 6) {
                    if chief {
                        Text(tr("Chief of Staff")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
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
        .padding(.trailing, hovering && peer == nil ? 32 : 8)
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
            if hovering, bot.hidden != true, peer == nil {
                Button { Task { await model.patch(bot, BotPatch(hidden: true)) } } label: {
                    Image(systemName: "archivebox").font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card.opacity(0.9))
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1))
                }
                .buttonStyle(.plain)
                .help(tr("Nascondi"))
                .padding(.trailing, 4)
                .padding(.top, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
    }

    private var preview: String {
        if bot.activity == "waiting-on-you" { return tr("Ti sta aspettando") }
        if model.isBusy(bot) { return tr("Sta lavorando…") }
        guard let message = transcript.last(where: { $0.kind == .text && !($0.text ?? "").isEmpty }) else {
            return bot.description.isEmpty ? " " : bot.description
        }
        let text = (message.text ?? "").replacingOccurrences(of: "\n", with: " ")
        return (message.role == .user ? tr("Tu: ") : "") + text
    }

    private var transcript: [Message] {
        peer.map { $0.state.visibleTranscript(forThread: bot.threadId) } ?? model.visibleTranscript(bot.threadId)
    }
}

/// Rooms wear their members: one mascot at 32, or up to three at 18
/// overlapping by 8 plus a "+N" chip.
private struct RoomRow: View {
    let room: Room
    let selected: Bool
    /// Set for a channel of an engine the window is not showing: its members are read from it.
    var peer: EnginePeer?
    @Environment(AppModel.self) private var model

    var body: some View {
        let members = room.memberIds.compactMap { (peer?.state ?? model.state).bot($0) }
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
                            Text(verbatim: "+\(members.count - 3)")
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
                    Text(room.guest.map { tr("Specchio di %@", $0.hostName ?? tr("un altro dispositivo")) }
                         ?? (members.map(\.name) + (room.guests ?? []).map(\.name)).joined(separator: ", "))
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
            TextField(tr("Nome sezione"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button(tr("Annulla")) { dismiss() }
                Button(action: commit) { Text(isRename ? tr("Rinomina") : tr("Crea")) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || name.count > 60)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { if case let .rename(old) = naming { draft = old } }
    }

    private var isRename: Bool { if case .rename = naming { return true } else { return false } }
    private var title: String { isRename ? tr("Rinomina sezione") : tr("Nuova sezione") }
    private var name: String { draft.trimmingCharacters(in: .whitespaces) }

    private func commit() {
        guard !name.isEmpty, name.count <= 60 else { return }
        save(name)
        dismiss()
    }
}

/// Row ids for another engine's bots and sections, apart from the shown
/// engine's (see peerSections).
private extension Bot {
    var peerKey: String { "peer:" + id }
}

private extension Room {
    var peerKey: String { "peer-room:" + id }
}
