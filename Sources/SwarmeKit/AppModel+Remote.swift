// Remote engines in the window — bot-remoto §7.
//
// One engine at a time: the sidebar shows the bots of the engine picked at
// its top, this Mac's or a remote one. Switching re-points the client (chat
// URL, device token) and hydrates from scratch; everything else — chats,
// bots, automations, connectors — is the same API on either side. A sidebar
// mixing several engines at once is a later step.
import CompanionCore
import Foundation

public enum EngineChoice: Hashable, Sendable {
    case local
    case remote(String)

    static let defaultsKey = "activeEngine"

    /// The choice of the last session, if that engine still exists.
    static func restored(from engines: [RemoteEngine]) -> EngineChoice {
        guard let saved = UserDefaults.standard.string(forKey: defaultsKey), saved != "local",
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

    public func reloadRemoteEngines() {
        remoteEngines = remoteStore.all()
        if case let .remote(id) = engineChoice, !remoteEngines.contains(where: { $0.id == id }) { select(engine: .local) }
    }

    /// Show another engine: drop everything of the current one, then connect.
    public func select(engine choice: EngineChoice) {
        guard choice != engineChoice || client == nil else { return }
        engineChoice = choice
        UserDefaults.standard.set(choice.saved, forKey: EngineChoice.defaultsKey)
        streamTask?.cancel()
        streamTask = nil
        state = CompanionState()
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
            client = CompanionClient(connection: connection, token: token)
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
