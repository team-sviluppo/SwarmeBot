// Remote engines in the window — bot-remoto §7.
//
// One engine at a time in the window: the chat, inspector, automations and
// settings are those of the engine whose chat is open, this Mac's or a remote
// one. The sidebar lists every engine's bots (the others through an
// EnginePeer each); opening a chat of another engine switches to it, which
// re-points the client (chat URL, device token) and hydrates from scratch.
import CompanionCore
import Foundation

public enum EngineChoice: Hashable, Sendable {
    case local
    case remote(String)

    static let defaultsKey = "activeEngine"

    /// The choice of the last session, if that engine still exists.
    static func restored(from engines: [RemoteEngine]) -> EngineChoice {
        guard let saved = AppPaths.defaults.string(forKey: defaultsKey), saved != "local",
              engines.contains(where: { $0.id == saved }) else { return .local }
        return .remote(saved)
    }

    var saved: String {
        switch self {
        case .local: return "local"
        case let .remote(id): return id
        }
    }
}

extension AppModel {
    public var activeRemoteEngine: RemoteEngine? {
        guard case let .remote(id) = engineChoice else { return nil }
        return remoteEngines.first { $0.id == id }
    }

    public var engineName: String { activeRemoteEngine?.name ?? "Questo Mac" }

    /// The shown engine is on a server: its paths are the server's, not this Mac's.
    public var isRemote: Bool { activeRemoteEngine != nil }

    public func reloadRemoteEngines() {
        remoteEngines = remoteStore.all()
        if case let .remote(id) = engineChoice, !remoteEngines.contains(where: { $0.id == id }) { select(engine: .local) }
        syncPeers()
    }

    /// The engine a sidebar row belongs to, for the engines not shown.
    public func peer(_ choice: EngineChoice) -> EnginePeer? { peers[choice] }

    /// Open a bot's chat, switching the window to its engine first.
    public func open(bot id: String, on choice: EngineChoice) {
        if choice != engineChoice { select(engine: choice) }
        selection = .bot(id)
    }

    /// Show another engine: drop everything of the current one, then connect.
    /// The one left keeps streaming as a peer, so its sidebar rows stay live.
    public func select(engine choice: EngineChoice) {
        guard choice != engineChoice || client == nil else { return }
        if client != nil, peers[engineChoice] == nil {
            peers[engineChoice] = EnginePeer(choice: engineChoice, state: state, cursor: cursor)
        }
        let taken = peers.removeValue(forKey: choice)
        taken?.stop()
        engineChoice = choice
        AppPaths.defaults.set(choice.saved, forKey: EngineChoice.defaultsKey)
        streamTask?.cancel()
        streamTask = nil
        // the peer's bots keep the sidebar filled until the hydrate replaces them
        state = taken?.state ?? CompanionState()
        live.clearAll()
        cursor = nil
        visibleCache = [:]
        stateVersion &+= 1
        instances = []
        config = nil
        mcpConnectors = []
        webhookIngress = nil
        selection = nil
        client = nil
        connectToChoice()
        syncPeers()
    }

    /// A peer for every engine but the shown one; none for engines forgotten.
    func syncPeers() {
        var wanted: [EngineChoice] = remoteEngines.map { .remote($0.id) }
        if localPort != nil { wanted.append(.local) }
        wanted.removeAll { $0 == engineChoice }
        for (choice, peer) in peers where !wanted.contains(choice) {
            peer.stop()
            peers[choice] = nil
        }
        for choice in wanted {
            let peer = peers[choice] ?? EnginePeer(choice: choice)
            peers[choice] = peer
            if let client = peerClient(choice) { peer.start(client) }
        }
    }

    private func peerClient(_ choice: EngineChoice) -> CompanionClient? {
        switch choice {
        case .local:
            return localPort.map { CompanionClient(connection: Connection(name: "Questo Mac", host: "127.0.0.1", port: $0), token: nil) }
        case let .remote(id):
            return remoteEngines.first { $0.id == id }.flatMap { try? remoteClient($0) }
        }
    }

    /// Point the client at the chosen engine and open its stream.
    func connectToChoice() {
        switch engineChoice {
        case .local:
            guard let localPort else {
                status = .starting("Avvio del motore di questo Mac…")
                return
            }
            client = CompanionClient(connection: Connection(name: "Questo Mac", host: "127.0.0.1", port: localPort), token: nil)
        case let .remote(id):
            guard let engine = remoteEngines.first(where: { $0.id == id }), let connection = engine.connection else {
                status = .failed("Server remoto non configurato correttamente")
                return
            }
            guard let token = RemoteEngineStore.token(engineId: id) else {
                status = .failed("Questo Mac non ha un token per \(engine.name): abbinalo di nuovo da Impostazioni › Server remoti")
                return
            }
            let remote = CompanionClient(connection: connection, token: token)
            client = remote
            checkRemoteContract(remote, engine: engine)
        }
        connect()
    }

    /// What the banner says when the stream fails, in terms of what to do.
    func offlineReason(_ error: Error) -> String {
        if case let APIError.status(code, _)? = error as? APIError, code == 401, let engine = activeRemoteEngine {
            return "\(engine.name) non riconosce più questo Mac (dispositivo revocato?): abbinalo di nuovo da Impostazioni › Server remoti"
        }
        if let engine = activeRemoteEngine {
            return "\(engine.name) non raggiungibile: \(error.localizedDescription). Il server continua a lavorare; mi ricollego da solo."
        }
        return error.localizedDescription
    }

    // MARK: Adding and removing

    /// Keep an engine and its device token; show it.
    public func addRemoteEngine(_ engine: RemoteEngine, token: String) throws {
        try RemoteEngineStore.setToken(token, engineId: engine.id)
        try remoteStore.save(engine)
        reloadRemoteEngines()
        select(engine: .remote(engine.id))
    }

    /// Forget an engine on this Mac (the server keeps running; its device stays until revoked).
    public func forgetRemoteEngine(_ id: String) throws {
        if engineChoice == .remote(id) { select(engine: .local) }
        try remoteStore.remove(id)
        reloadRemoteEngines()
    }

    /// Pair this Mac with an engine another device administers: chat URL + one-time code (§4.3).
    public func pairRemoteEngine(chatURL: String, code: String, name: String?) async throws -> RemoteEngine {
        guard let connection = Connection.remote(chatURL: chatURL) else { throw RemotePairingError.badURL }
        let claim = try await RemoteDevices.claim(connection: connection, code: code, deviceName: Host.current().localizedName ?? "Mac")
        let engine = RemoteEngine(id: "eng_" + UUID().uuidString.prefix(8).lowercased(), name: name?.isEmpty == false ? name! : connection.host,
                                  chatURL: chatURL, identityId: nil, deviceId: claim.deviceId, site: nil, prefix: nil, tls: nil, createdAt: Date())
        try addRemoteEngine(engine, token: claim.token)
        return engine
    }
}

public enum RemotePairingError: LocalizedError {
    case badURL

    public var errorDescription: String? {
        switch self {
        case .badURL: return "L'indirizzo deve essere l'URL https del server, per esempio https://bot.example.it/srv1/deploy"
        }
    }
}

extension AppModel {
    /// The ssh identity this Mac administers an engine with, if any.
    public func identity(for engine: RemoteEngine) -> SSHIdentity? {
        guard let id = engine.identityId else { return nil }
        return identityStore.all().first { $0.id == id }
    }

    public func makeSetupFlow() -> ServerSetupFlow {
        ServerSetupFlow(identities: identityStore, engines: remoteStore)
    }

    /// A client for any saved engine, shown or not (devices, pairing codes).
    public func remoteClient(_ engine: RemoteEngine) throws -> CompanionClient {
        guard let connection = engine.connection, let token = RemoteEngineStore.token(engineId: engine.id) else {
            throw RemotePairingError.badURL
        }
        return CompanionClient(connection: connection, token: token)
    }

    public func openTerminal(_ identity: SSHIdentity) throws {
        try ServerTerminal.open(identity, store: identityStore)
    }
}

extension AppModel {
    /// Claude's login on a server this Mac administers: the `claude setup-token` token (§4.2).
    public func setClaudeToken(_ token: String, for engine: RemoteEngine) async throws {
        guard let identity = identity(for: engine) else {
            throw ProcessRunner.Failure(message: "Questo Mac non amministra \(engine.name): il token si imposta dal Mac che lo ha configurato")
        }
        try await RemoteAdmin(identity: identity, store: identityStore).setClaudeToken(token)
        // the next servers get it in their setup
        try ServerClaudeToken.save(token)
        if engineChoice == .remote(engine.id) { await refreshInstances() }
    }

    /// Claude Code and omp on a server this Mac administers, as its setup does (ServerAgents).
    public func configureAgents(on engine: RemoteEngine) async throws -> [String] {
        guard let identity = identity(for: engine) else { throw EngineUpdateError.notAdministered(engine.name) }
        let admin = RemoteAdmin(identity: identity, store: identityStore)
        let report = try await ServerAgents.configure(admin: admin, client: try remoteClient(engine), probe: try await admin.probe())
        if engineChoice == .remote(engine.id) { await refreshInstances() }
        return report
    }
}

/// What the server's engine is, next to what this app would install (§5.5).
public struct RemoteEngineStatus: Equatable, Sendable {
    public var installed: String?
    public var expected: String?
    public var probe: RemoteProbe

    public var updateAvailable: Bool { expected != nil && installed != expected }
}

public enum EngineUpdateError: LocalizedError, Equatable {
    case busy([String])
    case notAdministered(String)
    case didNotComeBack

    public var errorDescription: String? {
        switch self {
        case let .busy(names):
            return "Stanno lavorando: \(names.joined(separator: ", ")). Aggiornare adesso interrompe i loro turni."
        case let .notAdministered(name):
            return "Questo Mac non amministra \(name): l'aggiornamento si fa dal Mac che lo ha configurato"
        case .didNotComeBack:
            return "Il motore aggiornato non risponde: controlla il server (Apri un terminale sul server)"
        }
    }
}

/// The update itself (§5.5), apart from AppModel so it can run against a test server.
public enum EngineUpdater {
    public static func update(admin: RemoteAdmin, client: CompanionClient, force: Bool, linux: LinuxEngines = .standard) async throws {
        if !force, let fleet = try? await client.fleet(messages: 0) {
            let working = fleet.bots.filter { $0.busy == true || ["working", "waiting-on-you"].contains($0.activity ?? "") }.map(\.name)
            if !working.isEmpty { throw EngineUpdateError.busy(working) }
        }
        try await admin.updateEngine(probe: try await admin.probe(), linux: linux)
        // back when the new engine answers on the chat URL, as every client sees it
        for _ in 0..<60 {
            if let health = try? await client.remoteHealth(), health.remote == true { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw EngineUpdateError.didNotComeBack
    }
}

extension AppModel {
    /// Installed vs expected engine, over ssh. Nil when this Mac does not administer it.
    public func engineStatus(_ engine: RemoteEngine) async throws -> RemoteEngineStatus? {
        guard let identity = identity(for: engine) else { return nil }
        let probe = try await RemoteAdmin(identity: identity, store: identityStore).probe()
        return RemoteEngineStatus(installed: probe.engineHash, expected: RemoteAdmin.expectedEngine(for: probe), probe: probe)
    }

    /// Replace the server's engine with this app's. Refuses while bots work unless `force`.
    public func updateEngine(_ engine: RemoteEngine, force: Bool = false) async throws {
        guard let identity = identity(for: engine) else { throw EngineUpdateError.notAdministered(engine.name) }
        try await EngineUpdater.update(admin: RemoteAdmin(identity: identity, store: identityStore),
                                       client: try remoteClient(engine), force: force)
    }

    /// A remote engine speaking another contract is named for what it is, not left to fail oddly.
    func checkRemoteContract(_ client: CompanionClient, engine: RemoteEngine) {
        Task { [weak self] in
            guard let health = try? await client.remoteHealth() else { return }
            guard let self, self.engineChoice == .remote(engine.id), !health.isCompatible else { return }
            self.streamTask?.cancel()
            self.status = .failed("Il motore su \(engine.name) è di un'altra versione (contratto \(health.contract.map(String.init) ?? "?"), questa app parla \(RemoteHealth.supportedContract)): aggiornalo da Impostazioni › Server remoti")
        }
    }
}

extension AppModel {
    /// Copy this Mac's pi config (keys, custom providers) to a server it administers.
    public func copyPiConfig(to engine: RemoteEngine) async throws -> [String] {
        guard let identity = identity(for: engine) else { throw EngineUpdateError.notAdministered(engine.name) }
        let copied = try await RemoteAdmin(identity: identity, store: identityStore).copyPiConfig()
        if engineChoice == .remote(engine.id) { await refreshInstances() }
        return copied
    }
}

