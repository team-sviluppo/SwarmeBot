// The list of chats, in the Mac app's look (Grok style): the chief of staff
// large on top, then collapsible sections — the phone's own bots, then each
// server's bots by their sidebar section, and its channels — with mascots,
// times, previews and unread dots; search floats at the bottom.
import AgentCore
import CompanionCore
import SwiftUI

struct Route: Hashable {
    let serverId: String
    let chat: ChatRef
}

/// A chat with one of the phone's own bots.
struct LocalRoute: Hashable {
    let botId: String
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var pendingLink: RemotePairingLink?
    @State private var newBot = false
    @State private var search = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.isEmpty, let hero { HeroBot(session: hero.session, bot: hero.bot) }
                    PhoneSection(search: search)
                    ForEach(model.sessions) { session in
                        ServerSections(session: session, search: search)
                    }
                    if model.sessions.isEmpty, search.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(tr("Abbina un server"), systemImage: "qrcode.viewfinder") { showPairing = true }
                                .foregroundStyle(Theme.accent)
                            Text(tr("Abbina un server dal Mac: Impostazioni › server › Abbina telefono, poi inquadra il QR."))
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Theme.app)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationDestination(for: Route.self) { route in
                if let session = model.session(route.serverId) {
                    ChatView(session: session, chat: route.chat)
                }
            }
            .navigationDestination(for: LocalRoute.self) { route in
                LocalChatView(botId: route.botId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("Impostazioni"), systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) { addMenu }
            }
            .refreshable {
                for session in model.sessions {
                    session.pause()
                    session.resume()
                }
            }
        }
        .sheet(isPresented: $showPairing) {
            PairingView(initialLink: pendingLink).onDisappear { pendingLink = nil }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $newBot) { LocalBotEditor(existing: nil) }
        .onChange(of: model.open) { _, route in
            // a tapped notification: its chat on top
            guard let route else { return }
            path.append(route)
            model.open = nil
        }
        #if DEBUG
        .task {
            // UI checks on the simulator: `-pairLink swarmebot://pair?…` pairs without the camera
            guard let raw = UserDefaults.standard.string(forKey: "pairLink"), let url = URL(string: raw),
                  let link = RemotePairingLink(url: url), !model.sessions.contains(where: { $0.server.chatURL == link.chatURL }) else { return }
            try? await model.pair(link)
        }
        .task {
            // `-seedEndpoint <url> [-seedConnector <url>] [-sendText <text>]`: a phone bot on a test
            // endpoint, its chat open, a message sent; `-seedKind apple|gemma` for the on-device ones
            let defaults = UserDefaults.standard
            let kind = defaults.string(forKey: "seedKind").flatMap(LocalBotKind.init(rawValue:)) ?? .endpoint
            guard kind != .endpoint || defaults.string(forKey: "seedEndpoint") != nil else { return }
            if !model.local.bots.contains(where: { $0.kind == kind }) {
                var bot = LocalBot(id: newId(), name: "Bot di prova (\(kind.rawValue))", kind: kind, createdAt: Date())
                if let base = defaults.string(forKey: "seedEndpoint"), kind == .endpoint {
                    bot.endpoint = EndpointConfig(baseUrl: base, model: "fake/echo-1")
                }
                if let url = UserDefaults.standard.string(forKey: "seedConnector") {
                    let connector = LocalConnector(id: newId(), name: "Fake MCP", url: url, auth: .none, createdAt: Date())
                    model.local.save(connector, headers: [:])
                    bot.connectorIds = [connector.id]
                }
                model.local.save(bot, apiKey: "test-key")
            }
            guard let bot = model.local.bots.last(where: { $0.kind == kind }) else { return }
            path.append(LocalRoute(botId: bot.id))
            if let text = UserDefaults.standard.string(forKey: "sendText") { model.local.chat(bot.id).send(text) }
        }
        .task {
            // `-importLink swarmebot://import?…`: the Mac's settings QR, without the system's "Open in" prompt
            if let raw = UserDefaults.standard.string(forKey: "importLink"), let url = URL(string: raw), let link = PhoneConfigLink(url: url) {
                model.pendingImport = .link(link)
            }
        }
        .task {
            // `-openFirstChat YES`: land in the first bot's chat
            guard UserDefaults.standard.bool(forKey: "openFirstChat") else { return }
            for _ in 0..<40 {
                if let session = model.sessions.first, let bot = session.visibleBots.first {
                    path.append(Route(serverId: session.id, chat: .bot(bot.id)))
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        #endif
        .onOpenURL { url in
            // the Camera app read one of the Mac's QRs, or a `.swarmeconfig` was opened
            if let link = RemotePairingLink(url: url) {
                pendingLink = link
                showPairing = true
            } else if let link = PhoneConfigLink(url: url) {
                model.pendingImport = .link(link)
            } else if url.isFileURL, url.pathExtension == "swarmeconfig" {
                model.pendingImport = .file(url)
            }
        }
        .sheet(item: Binding(get: { model.pendingImport }, set: { model.pendingImport = $0 })) { ImportView(source: $0) }
    }

    /// The chief of staff of the first server, as Grok Bot shows its own.
    private var hero: (session: RemoteSession, bot: Bot)? {
        for session in model.sessions {
            if let bot = session.visibleBots.first(where: { $0.chiefOfStaff == true }) { return (session, bot) }
        }
        return nil
    }

    private var addMenu: some View {
        Menu {
            Button(tr("Nuovo bot sul telefono"), systemImage: "iphone") { newBot = true }
            Button(tr("Abbina un server"), systemImage: "qrcode.viewfinder") { showPairing = true }
        } label: {
            Image(systemName: "plus")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button(tr("Nuovo bot sul telefono"), systemImage: "iphone") { newBot = true }
                Button(tr("Abbina un server"), systemImage: "qrcode.viewfinder") { showPairing = true }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
                    .foregroundStyle(Theme.ink)
                    .frame(width: 52, height: 52)
                    .background(Theme.pill, in: Circle())
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField(tr("Cerca"), text: $search).foregroundStyle(Theme.ink).submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .background(Theme.pill, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

/// The chief of staff, large, at the top of the list.
private struct HeroBot: View {
    let session: RemoteSession
    let bot: Bot

    var body: some View {
        NavigationLink(value: Route(serverId: session.id, chat: .bot(bot.id))) {
            VStack(spacing: 10) {
                RemoteBotAvatar(bot: bot, size: 112)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "star.fill").font(.caption.bold()).foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(Theme.warning, in: Circle())
                    }
                Text(verbatim: bot.name).font(.subheadline).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .buttonStyle(.plain)
    }
}

/// A section's title; a tap folds it.
private struct SectionHeader: View {
    let title: String
    var detail: String? = nil
    var dot: Color? = nil
    @Binding var collapsed: Bool

    var body: some View {
        Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(verbatim: title).font(.body).foregroundStyle(Theme.secondary)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Spacer()
                if let detail { Text(verbatim: detail).font(.caption).foregroundStyle(Theme.tertiary).lineLimit(1) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One chat in the list: mascot, name (and a badge), time, preview, unread dot.
private struct ChatRow<Avatar: View>: View {
    let name: String
    var badge: String? = nil
    let preview: String
    let date: Date?
    let unread: Bool
    let busy: Bool
    @ViewBuilder let avatar: () -> Avatar

    var body: some View {
        HStack(spacing: 14) {
            avatar().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: name).font(.title3.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let badge {
                        Text(verbatim: badge).font(.footnote).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Spacer(minLength: 4)
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else if let date {
                        Text(verbatim: date.listStamp()).font(.subheadline).foregroundStyle(Theme.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    Text(verbatim: preview.isEmpty ? " " : preview).font(.body).foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if unread { Circle().fill(Theme.accent).frame(width: 10, height: 10) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private func matches(_ search: String, _ fields: String...) -> Bool {
    search.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(search) }
}

/// The phone's own bots: private, never synced (D5).
private struct PhoneSection: View {
    @Environment(AppModel.self) private var model
    let search: String
    @State private var collapsed = false

    var body: some View {
        let bots = model.local.bots.filter { matches(search, $0.name, last($0)?.text ?? "") }
        if !bots.isEmpty {
            SectionHeader(title: tr("Sul telefono"), collapsed: $collapsed)
            if !collapsed {
                ForEach(bots) { bot in
                    NavigationLink(value: LocalRoute(botId: bot.id)) {
                        ChatRow(name: bot.name, badge: badge(bot.kind), preview: last(bot)?.text.replacingOccurrences(of: "\n", with: " ") ?? "",
                                date: last(bot)?.at, unread: false, busy: model.local.chat(bot.id).busy) {
                            LocalBotAvatar(bot: bot, size: 56, busy: model.local.chat(bot.id).busy)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func last(_ bot: LocalBot) -> LocalMessage? {
        model.local.chat(bot.id).messages.last { $0.role == .bot || $0.role == .user }
    }

    private func badge(_ kind: LocalBotKind) -> String? {
        switch kind {
        case .gemma: return "Local AI"
        case .apple: return "Apple"
        case .endpoint: return nil
        }
    }
}

/// A server's bots by their sidebar section, then its channels.
private struct ServerSections: View {
    let session: RemoteSession
    let search: String
    @State private var collapsed: Set<String> = []

    var body: some View {
        let groups = sections
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            let key = group.name ?? "-"
            SectionHeader(title: group.name ?? session.server.name, detail: index == 0 ? statusText : nil, dot: index == 0 ? statusColor : nil,
                          collapsed: Binding(get: { collapsed.contains(key) }, set: { if $0 { collapsed.insert(key) } else { collapsed.remove(key) } }))
            if !collapsed.contains(key) {
                ForEach(group.bots) { bot in
                    NavigationLink(value: Route(serverId: session.id, chat: .bot(bot.id))) {
                        ChatRow(name: bot.name, preview: preview(bot.threadId), date: last(bot.threadId)?.date, unread: bot.unread,
                                busy: session.isBusy(bot)) {
                            RemoteBotAvatar(bot: bot, size: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if case .unpaired = session.status {
            Text(tr("Questo telefono non è più abbinato: abbinalo di nuovo dal Mac."))
                .font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal, 20)
        }
        let rooms = session.state.rooms.filter { matches(search, $0.name, preview($0.threadId)) }
        if !rooms.isEmpty {
            let key = "rooms"
            SectionHeader(title: tr("Canali"), collapsed: Binding(get: { collapsed.contains(key) }, set: { if $0 { collapsed.insert(key) } else { collapsed.remove(key) } }))
            if !collapsed.contains(key) {
                ForEach(rooms) { room in
                    NavigationLink(value: Route(serverId: session.id, chat: .room(room.id))) {
                        ChatRow(name: room.name, preview: preview(room.threadId), date: last(room.threadId)?.date, unread: room.unread,
                                busy: room.busyBotId != nil) {
                            RoomAvatar(members: room.memberIds.compactMap { session.state.bot($0) }, size: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// As the Mac's sidebar: labeled sections in first-seen order, unlabeled bots last; pinned first.
    private var sections: [(name: String?, bots: [Bot])] {
        let bots = session.visibleBots.filter { $0.chiefOfStaff != true || !search.isEmpty }
            .filter { matches(search, $0.name, preview($0.threadId)) }
        var order: [String?] = []
        var grouped: [String?: [Bot]] = [:]
        for bot in bots {
            let key = bot.section?.isEmpty == false ? bot.section : nil
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(bot)
        }
        order.sort { a, b in a != nil && b == nil }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    private func last(_ threadId: String) -> Message? {
        session.state.messages[threadId]?.last { $0.kind == .text }
    }

    private func preview(_ threadId: String) -> String {
        MessageRow.visibleText(last(threadId)?.text ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    private var statusColor: Color {
        switch session.status {
        case .live: return Theme.success
        case .connecting, .cached: return Theme.warning
        case .offline, .unpaired: return Theme.danger
        }
    }

    private var statusText: String {
        switch session.status {
        case .live: return session.server.name
        case .connecting: return tr("Connessione…")
        case .cached: return session.cachedAt.map { tr("Aggiornato %@", $0.appRelative()) } ?? tr("Connessione…")
        case let .offline(reason): return reason
        case .unpaired: return tr("Non abbinato")
        }
    }
}
