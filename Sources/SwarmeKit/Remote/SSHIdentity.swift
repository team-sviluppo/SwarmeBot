// ssh identities for administering remote engines — bot-remoto §5.1, §5.3.
//
// One identity per (host, port, user), whatever number of engines or
// settings use that login: the key is generated once, installed once and
// reused (R9). The private key is a file because ssh wants one (`-i`); it
// lives in a 0700 folder of its own, never in ~/.ssh, and only SwarmeBot's
// ssh calls use it (`IdentitiesOnly`).
import Foundation

public struct SSHIdentity: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var host: String
    public var port: Int
    public var user: String
    public var hostKey: HostKey?
    public var keyInstalledAt: Date?
    public var createdAt: Date

    public struct HostKey: Codable, Hashable, Sendable {
        public var type: String
        public var fingerprint: String
        /// The known_hosts line that was approved, verbatim.
        public var line: String
        public var approvedAt: Date
    }

    /// What two identities must share to be the same login.
    public struct Login: Hashable, Sendable {
        public var host: String
        public var port: Int
        public var user: String

        public init(host: String, port: Int, user: String) {
            self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.port = port
            self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public var login: Login { Login(host: host, port: port, user: user) }
    public var label: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
}

public enum SSHInputError: LocalizedError, Equatable {
    case host, port, user

    public var errorDescription: String? {
        switch self {
        case .host: return "Indirizzo del server non valido"
        case .port: return "La porta ssh deve essere tra 1 e 65535"
        case .user: return "Nome utente non valido"
        }
    }
}

/// `~/.swarmebot/ssh/`: identities.json, known_hosts, one folder per key, the control sockets.
public final class SSHIdentityStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL = AppPaths.home.appendingPathComponent(".swarmebot/ssh", isDirectory: true)) {
        self.root = root
    }

    public var file: URL { root.appendingPathComponent("identities.json") }
    public var knownHosts: URL { root.appendingPathComponent("known_hosts") }
    /// Short on purpose: unix socket paths stop at 104 bytes, and ssh adds the %C hash.
    public var controlDirectory: URL { root.appendingPathComponent("cm", isDirectory: true) }
    public func keyFile(_ identity: SSHIdentity) -> URL { root.appendingPathComponent(identity.id, isDirectory: true).appendingPathComponent("id_ed25519") }

    func ensure() throws {
        for dir in [root, controlDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    static func validate(_ login: SSHIdentity.Login) throws {
        // a hostname, an IPv4 or a bracket-free IPv6; never an ssh option
        guard !login.host.isEmpty, !login.host.hasPrefix("-"),
              login.host.range(of: #"^[a-z0-9.:\-]+$"#, options: .regularExpression) != nil else { throw SSHInputError.host }
        guard (1...65535).contains(login.port) else { throw SSHInputError.port }
        guard login.user.range(of: #"^[A-Za-z_][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil else { throw SSHInputError.user }
    }

    public func all() -> [SSHIdentity] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> [SSHIdentity] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SSHIdentity].self, from: data)) ?? []
    }

    private func write(_ identities: [SSHIdentity]) throws {
        try ensure()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(identities).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The identity for this login: the existing one if any (R9), else a new record.
    public func findOrCreate(host: String, port: Int, user: String) throws -> SSHIdentity {
        let login = SSHIdentity.Login(host: host, port: port, user: user)
        try Self.validate(login)
        lock.lock(); defer { lock.unlock() }
        var identities = read()
        if let existing = identities.first(where: { $0.login == login }) { return existing }
        let slug = "\(login.user)_\(login.host)".lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
        let identity = SSHIdentity(id: String(slug.prefix(40)) + "_" + String(UUID().uuidString.prefix(6)).lowercased(),
                                   host: login.host, port: login.port, user: login.user, hostKey: nil, keyInstalledAt: nil, createdAt: Date())
        identities.append(identity)
        try write(identities)
        return identity
    }

    public func update(_ identity: SSHIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        var identities = read()
        guard let index = identities.firstIndex(where: { $0.id == identity.id }) else { return }
        identities[index] = identity
        try write(identities)
        try writeKnownHosts(identities)
    }

    /// Forget an identity: its record, its known_hosts line, its key folder.
    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let identities = read().filter { $0.id != id }
        try write(identities)
        try writeKnownHosts(identities)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }

    /// known_hosts holds exactly the approved keys, nothing ssh learned on its own.
    private func writeKnownHosts(_ identities: [SSHIdentity]) throws {
        let lines = Set(identities.compactMap(\.hostKey?.line))
        try ensure()
        try (lines.sorted().joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: knownHosts, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
    }

    /// The key pair for an identity, generated the first time (never twice: R9).
    public func ensureKey(_ identity: SSHIdentity) async throws -> (privateKey: URL, publicKey: String) {
        let key = keyFile(identity)
        let pub = URL(fileURLWithPath: key.path + ".pub")
        if !FileManager.default.fileExists(atPath: key.path) {
            try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let result = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "swarmebot:\(identity.id)", "-f", key.path])
            guard result.status == 0 else { throw ProcessRunner.Failure(message: "ssh-keygen: \(result.stderr)") }
        }
        let publicKey = try String(contentsOf: pub, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, publicKey)
    }
}
