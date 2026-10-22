// The list of chats: one section per paired server with its bots and rooms
// (plan §1). The phone's own bots get their section in phase 3.
import CompanionCore
import SwiftUI

struct Route: Hashable {
    let serverId: String
    let chat: ChatRef
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route] = []
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var pendingLink: RemotePairingLink?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.sessions.isEmpty {
                    ContentUnavailableView {
                        Label(tr("Nessun server"), systemImage: "server.rack")
                    } description: {
                        Text(tr("Abbina un server dal Mac: Impostazioni › server › Abbina telefono, poi inquadra il QR."))
                    } actions: {
                        Button(tr("Abbina un server")) { showPairing = true }.buttonStyle(.borderedProminent)
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
        #if DEBUG
        .task {
            // UI checks on the simulator: `-pairLink swarmebot://pair?…` pairs without the camera
            guard let raw = UserDefaults.standard.string(forKey: "pairLink"), let url = URL(string: raw),
                  let link = RemotePairingLink(url: url), !model.sessions.contains(where: { $0.server.chatURL == link.chatURL }) else { return }
            try? await model.pair(link)
        }
        .task {
            // `-openFirstChat YES`: land in the first bot's chat
            guard UserDefaults.standard.bool(forKey: "openFirstChat") else { return }
            for _ in 0..<40 {
                if let session = model.sessions.first, let bot = session.visibleBots.first {
                    path = [Route(serverId: session.id, chat: .bot(bot.id))]
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
