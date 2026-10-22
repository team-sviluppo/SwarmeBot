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
    let local = LocalBots()
    var lastError: String?
    /// A chat to show, asked by a tapped notification.
    var open: Route?
    /// Settings from the Mac waiting to be looked at (a QR or a file).
    var pendingImport: ImportSource?

    init() {
        sessions = ServerStore.load().map { RemoteSession(server: $0) }
    }

    func session(_ id: String) -> RemoteSession? { sessions.first { $0.id == id } }

    // MARK: - Lifecycle

    func becameActive() {
        for session in sessions { session.resume() }
    }

    func wentToBackground() {
        for session in sessions { session.pause() }
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
        sessions.append(session)
        ServerStore.save(sessions.map(\.server))
        session.resume()
        PushManager.shared.requestPermission()
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
