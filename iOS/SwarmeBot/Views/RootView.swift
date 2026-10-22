// The list of chats: one section per paired server with its bots and rooms
// (plan §1). The phone's own bots get their section in phase 3.
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

    var body: some View {
        NavigationStack(path: $path) {
            List {
                PhoneSection(newBot: $newBot)
                if model.sessions.isEmpty {
                    Section {
                        Button(tr("Abbina un server"), systemImage: "qrcode.viewfinder") { showPairing = true }
                    } header: {
                        Label(tr("Nessun server"), systemImage: "server.rack")
                    } footer: {
                        Text(tr("Abbina un server dal Mac: Impostazioni › server › Abbina telefono, poi inquadra il QR."))
                    }
                }
                ForEach(model.sessions) { session in
                    ServerSection(session: session)
                }
            }
            .navigationTitle(Text(verbatim: "SwarmeBot"))
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("Abbina un server"), systemImage: "qrcode.viewfinder") { showPairing = true }
                }
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
            // the Camera app read the Mac's QR and opened us
            guard let link = RemotePairingLink(url: url) else { return }
            pendingLink = link
            showPairing = true
        }
    }
}

/// The phone's own bots: private, never synced (D5).
private struct PhoneSection: View {
    @Environment(AppModel.self) private var model
    @Binding var newBot: Bool

    var body: some View {
        Section {
            ForEach(model.local.bots) { bot in
                NavigationLink(value: LocalRoute(botId: bot.id)) {
                    ChatRow(name: bot.name, color: bot.color, preview: preview(bot), unread: false,
                            busy: model.local.chat(bot.id).busy, symbol: symbol(bot.kind))
                }
            }
            Button(tr("Nuovo bot sul telefono"), systemImage: "plus") { newBot = true }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "iphone")
                Text(tr("Sul telefono"))
            }
        }
    }

    private func preview(_ bot: LocalBot) -> String {
        model.local.chat(bot.id).messages.last(where: { $0.role == .bot || $0.role == .user })?.text
            .replacingOccurrences(of: "\n", with: " ") ?? ""
    }

    private func symbol(_ kind: LocalBotKind) -> String {
        switch kind {
        case .endpoint: return "network"
        case .gemma: return "cpu"
        case .apple: return "apple.intelligence"
        }
    }
}

private struct ServerSection: View {
    let session: RemoteSession

    var body: some View {
        Section {
            ForEach(session.visibleBots) { bot in
                NavigationLink(value: Route(serverId: session.id, chat: .bot(bot.id))) {
                    ChatRow(name: bot.name, color: bot.color, preview: preview(bot.threadId), unread: bot.unread,
                            busy: session.isBusy(bot), symbol: "person.crop.circle.fill")
                }
            }
            ForEach(session.state.rooms) { room in
                NavigationLink(value: Route(serverId: session.id, chat: .room(room.id))) {
                    ChatRow(name: room.name, color: nil, preview: preview(room.threadId), unread: room.unread,
                            busy: room.busyBotId != nil, symbol: "number")
                }
            }
        } header: {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(verbatim: session.server.name)
                Spacer()
                Text(statusText).font(.caption2).textCase(nil)
            }
        } footer: {
            if case .unpaired = session.status {
                Text(tr("Questo telefono non è più abbinato: abbinalo di nuovo dal Mac."))
            }
        }
    }

    private func preview(_ threadId: String) -> String {
        guard let last = session.state.messages[threadId]?.last(where: { $0.kind == .text }) else { return "" }
        return MessageRow.visibleText(last.text ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    private var statusColor: Color {
        switch session.status {
        case .live: return .green
        case .connecting, .cached: return .orange
        case .offline, .unpaired: return .red
        }
    }

    private var statusText: String {
        switch session.status {
        case .live: return tr("Connesso")
        case .connecting: return tr("Connessione…")
        case .cached: return session.cachedAt.map { tr("Aggiornato %@", $0.appRelative()) } ?? tr("Connessione…")
        case let .offline(reason): return reason
        case .unpaired: return tr("Non abbinato")
        }
    }
}

private struct ChatRow: View {
    let name: String
    let color: String?
    let preview: String
    let unread: Bool
    let busy: Bool
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color.flatMap(Color.init(hex:)) ?? .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: name).font(.body.weight(unread ? .semibold : .regular))
                    if busy { ProgressView().controlSize(.mini) }
                }
                if !preview.isEmpty {
                    Text(verbatim: preview).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if unread { Circle().fill(Color.accentColor).frame(width: 8, height: 8) }
        }
    }
}
