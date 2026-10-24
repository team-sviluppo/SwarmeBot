// The iOS app's state: the paired remote engines, each a `RemoteSession`,
// and pairing a new one; the phone's own bots are `local` (plan §4).
import CompanionCore
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [RemoteSession] = []
    let local: LocalBots
    var lastError: String?
    /// A chat to show, asked by a tapped notification.
    var open: Route?
    /// The same for one of the phone's bots.
    var openPhoneBot: String?
    var openPhoneRoom: String?
    /// Settings from the Mac waiting to be looked at (a QR or a file).
    var pendingImport: ImportSource?

    /// While the app is off screen: the streams kept open, a turn on the phone finishing.
    @ObservationIgnored private var grace: (id: UIBackgroundTaskIdentifier, task: Task<Void, Never>)?

    init(local: LocalBots? = nil) {
        self.local = local ?? LocalBots()
        sessions = ServerStore.load().map { RemoteSession(server: $0) }
        for session in sessions { listen(session) }
        // guests of mixed channels speak through their server's session
        self.local.remoteSession = { [weak self] id in self?.session(id) }
    }

    func session(_ id: String) -> RemoteSession? { sessions.first { $0.id == id } }

    /// The unread chats, everywhere: the app icon's badge.
    var unreadCount: Int {
        sessions.reduce(local.unreadCount) { $0 + $1.state.unreadCount }
    }

    private func listen(_ session: RemoteSession) {
        session.onNotify = { [weak session] frame in
            guard let session else { return }
            Notifier.shared.deliver(frame, from: session)
        }
    }

    /// The guests a selection of `RoomGuest.memberId`s names, from the paired servers' bots.
    func roomGuests(_ ids: [String]) -> [RoomGuest] {
        let all = sessions.flatMap { session in
            session.visibleBots.map { RoomGuest(peerId: session.id, botId: $0.id, name: $0.name, color: $0.color,
                                                title: $0.title.isEmpty ? nil : $0.title) }
        }
        return ids.compactMap { id in all.first { $0.memberId == id } }
    }

    // MARK: - Lifecycle

    func becameActive() {
        endGrace()
        for session in sessions { session.resume() }
    }

    /// The streams stay open as long as iOS lets the app run (about half a
    /// minute), so a turn ending soon after still tells; a turn on the phone
    /// carries on as long as that. Then the background refreshes take over.
    func wentToBackground() {
        guard grace == nil else { return }
        let id = UIApplication.shared.beginBackgroundTask(withName: "finish turns") { [weak self] in
            // iOS calls it on the main thread, just before suspending the app
            MainActor.assumeIsolated { self?.settleInBackground() }
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled, self?.local.isBusy == true { try? await Task.sleep(for: .seconds(1)) }
            if !Task.isCancelled { self?.settleInBackground() }
        }
        grace = (id, task)
        if !sessions.isEmpty { Notifier.scheduleRefresh() }
    }

    private func settleInBackground() {
        for session in sessions {
            session.pause()
            Notifier.shared.remember(session)
        }
        Notifier.shared.setBadge(unreadCount)
        endGrace()
    }

    private func endGrace() {
        guard let grace else { return }
        self.grace = nil
        grace.task.cancel()
        UIApplication.shared.endBackgroundTask(grace.id)
    }

    /// An app refresh iOS granted: each server's bots, a notification for
    /// every chat that turned unread since, and the badge.
    func refreshInBackground() async {
        if !sessions.isEmpty { Notifier.scheduleRefresh() }
        var unread = local.unreadCount
        for session in sessions {
            guard let fleet = await session.fetchFleet() else {
                unread += session.state.unreadCount
                continue
            }
            Notifier.shared.reconcile(session, bots: fleet.bots)
            var state = CompanionState()
            state.hydrate(fleet)
            unread += state.unreadCount
        }
        Notifier.shared.setBadge(unread)
    }

    // MARK: - Pairing

    struct PairingFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Pair with the engine a `swarmebot://pair?…` link names (the Mac's QR,
    /// §5.1): trade the one-time code for this phone's token.
    @discardableResult
    func pair(_ link: RemotePairingLink, session: URLSession = .shared) async throws -> RemoteSession {
        guard let connection = Connection.remote(chatURL: link.chatURL, name: link.name) else {
            throw PairingFailure(message: tr("Indirizzo del server non valido."))
        }
        let health = try? await CompanionClient(connection: connection, token: nil, session: session).remoteHealth()
        if let health, !health.isCompatible {
            throw PairingFailure(message: tr("Questo server parla una versione diversa di SwarmeBot: aggiorna il motore o l'app."))
        }
        let claimed = try await RemoteDevices.claim(connection: connection, code: link.code, deviceName: UIDevice.current.name,
                                                    kind: "ios", session: session)
        let server = PairedServer(id: claimed.deviceId, name: link.name ?? connection.host, chatURL: link.chatURL, pairedAt: Date())
        try Keychain.set(claimed.token, for: server.tokenAccount)
        // pairing again with the same engine replaces the old entry
        let replaced = sessions.filter { $0.server.chatURL == server.chatURL }
        for old in replaced { remove(old) }
        let session = RemoteSession(server: server)
        listen(session)
        sessions.append(session)
        ServerStore.save(sessions.map(\.server))
        session.resume()
        Notifier.shared.requestPermission()
        Task { await PushManager.shared.register(session) }
        return session
    }

    /// Forget a server on this phone. The engine keeps the device until it
    /// is revoked from the Mac (Impostazioni › server › dispositivi).
    func remove(_ session: RemoteSession) {
        session.stop()
        Keychain.remove(session.server.tokenAccount)
        FleetCache.remove(session.server.id)
        sessions.removeAll { $0.id == session.id }
        ServerStore.save(sessions.map(\.server))
    }
}
