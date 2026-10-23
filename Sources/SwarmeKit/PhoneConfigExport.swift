// "Invia al telefono" (docs/plans/2026-10-22-app-ios.md §7, D11): this Mac's
// OpenAI-compatible server and HTTP connectors, with their secrets, for the iOS app's
// own bots. Secrets come from where "Copia su server" reads them (the engine
// never hands them out over its API); OAuth connectors go without tokens.
//
// Two ways across, both sealed (CompanionCore/PhoneConfig.swift):
// - `PhoneConfigServer`: a one-shot listener on the local network for two
//   minutes, no Bonjour, no other route; the QR carries its address, a
//   one-time code and the key;
// - a `.swarmeconfig` file sealed with a passphrase.
import CompanionCore
import CryptoKit
import Foundation
import Network

public enum PhoneConfigExport {
    public struct Item: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case endpoint, connector(String) }
        public var id: String
        public var kind: Kind
        public var name: String
        public var detail: String
        /// Why it travels without something (an OAuth login, a missing secret).
        public var note: String?
    }

    /// What can be sent: the OpenAI-compatible server when it has an address, and every HTTP connector.
    @MainActor
    public static func items(_ model: AppModel) -> [Item] {
        var out: [Item] = []
        if let base = model.config?.localEndpoint?.baseUrl, !base.isEmpty {
            out.append(Item(id: "endpoint", kind: .endpoint, name: tr("Server compatibile OpenAI"), detail: base,
                            note: CredentialStore.load()[WorkspaceCredential.localEndpointApiKey.environmentName] == nil
                                ? tr("senza chiave: non è salvata su questo Mac") : nil))
        }
        for connector in model.mcpConnectors where connector.transport == "http" {
            out.append(Item(id: "connector:\(connector.id)", kind: .connector(connector.id), name: connector.name, detail: connector.url ?? "",
                            note: connector.usesOAuth ? tr("OAuth: sul telefono si rifà l'accesso") : nil))
        }
        return out
    }

    /// The chosen items with their secrets.
    @MainActor
    public static func build(_ model: AppModel, chosen: Set<String>) -> PhoneConfig {
        var config = PhoneConfig()
        let secrets = ConnectorCopy.readSecrets()
        for item in items(model) where chosen.contains(item.id) {
            switch item.kind {
            case .endpoint:
                let key = CredentialStore.load()[WorkspaceCredential.localEndpointApiKey.environmentName]
                config.endpoints.append(PhoneConfig.Endpoint(name: tr("Server compatibile OpenAI"), baseUrl: item.detail, apiKey: key))
            case let .connector(id):
                guard let connector = model.mcpConnectors.first(where: { $0.id == id }), let url = connector.url else { continue }
                if connector.usesOAuth {
                    config.connectors.append(PhoneConfig.Connector(name: connector.name, url: url, auth: "oauth",
                                                                   oauthClientId: connector.oauth?.clientId.flatMap { $0.isEmpty ? nil : $0 }))
                    continue
                }
                var headers: [String: String] = [:]
                for (name, value) in connector.headers ?? [:] {
                    switch value {
                    case let .plain(text): headers[name] = text
                    case .secret: if let text = secrets[id]?["headers"]?[name] { headers[name] = text }
                    }
                }
                config.connectors.append(PhoneConfig.Connector(name: connector.name, url: url, auth: headers.isEmpty ? "none" : "headers",
                                                               headers: headers.isEmpty ? nil : headers))
            }
        }
        return config
    }
}

/// Serves one sealed configuration, once, on the local network.
public final class PhoneConfigServer: @unchecked Sendable {
    public static let lifetime: TimeInterval = 120

    private let queue = DispatchQueue(label: "swarme.phone-config")
    private var listener: NWListener?
    private var sealed = Data()
    private var code = ""
    private var served = false
    /// Called on the main queue when the phone took it, or time ran out.
    public var onFinish: ((_ delivered: Bool) -> Void)?

    public init() {}

    /// Start serving; the link is what the QR shows.
    public func start(_ config: PhoneConfig) async throws -> PhoneConfigLink {
        guard let host = Self.localAddress() else {
            throw PhoneConfig.Failure(message: tr("Questo Mac non è in una rete locale: usa il file."))
        }
        let key = SymmetricKey(size: .bits256)
        sealed = try config.sealed(with: key)
        code = Self.randomCode()
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // the handler runs on `queue`, one call at a time
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error):
                    once.done = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.asyncAfter(deadline: .now() + Self.lifetime) { [weak self] in self?.finish(delivered: false) }
        return PhoneConfigLink(host: host, port: Int(port), code: code, key: key.withUnsafeBytes { Data($0) })
    }

    public func stop() {
        queue.async { [weak self] in self?.finish(delivered: false) }
    }

    private func finish(delivered: Bool) {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        sealed = Data()
        let done = onFinish
        DispatchQueue.main.async { done?(delivered) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let ok = !self.served && self.listener != nil && line == "GET /\(self.code) HTTP/1.1"
            let body = ok ? self.sealed : Data()
            let head = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
                if ok {
                    self.served = true
                    self.finish(delivered: true)
                }
            })
        }
    }

    private final class Once: @unchecked Sendable {
        var done = false
    }

    static func randomCode() -> String {
        Data((0..<18).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// This Mac's IPv4 address on Wi-Fi or Ethernet.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: entry.ifa_name), String(cString: host)))
        }
        // en0/en1 first: Wi-Fi and Ethernet, not VPN tunnels
        return (found.first { $0.name.hasPrefix("en") } ?? found.first)?.address
    }
}
