// The remote engines this Mac talks to — bot-remoto §7.
//
// `~/.swarmebot/remote-engines.json` holds what is not secret: the chat URL,
// the name, which ssh identity administers it (if this Mac does). The device
// token is in the Keychain, one item per engine, and is all a client needs
// to chat (R6): ssh is never involved in that.
import CompanionCore
import Foundation
import Security

public struct RemoteEngine: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// What every client uses, behind whatever proxy (R12): `https://…/<prefix>`.
    public var chatURL: String
    /// The ssh identity that administers it from this Mac; nil when paired by QR only.
    public var identityId: String?
    public var deviceId: String?
    /// How Caddy on the server is set up, for re-running the setup.
    public var site: String?
    public var prefix: String?
    public var tls: String?
    public var createdAt: Date

    public var connection: Connection? { Connection.remote(chatURL: chatURL, name: name) }
}

public final class RemoteEngineStore: @unchecked Sendable {
    public let file: URL
    static var keychainService: String { "com.swarmebot.mac.remote-engine" + AppPaths.keychainSuffix }
    private let lock = NSLock()

    public init(file: URL = AppPaths.home.appendingPathComponent(".swarmebot/remote-engines.json")) {
        self.file = file
    }

    public func all() -> [RemoteEngine] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> [RemoteEngine] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RemoteEngine].self, from: data)) ?? []
    }

    private func write(_ engines: [RemoteEngine]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(engines).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Insert or replace by id.
    public func save(_ engine: RemoteEngine) throws {
        lock.lock(); defer { lock.unlock() }
        var engines = read().filter { $0.id != engine.id }
        engines.append(engine)
        try write(engines.sorted { $0.createdAt < $1.createdAt })
    }

    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try write(read().filter { $0.id != id })
        Self.deleteToken(engineId: id)
    }

    // MARK: Device tokens, in the Keychain

    /// On test data (SWARMEBOT_HOME) a 0600 file instead: a development build is
    /// re-signed on every compile, and the Keychain would ask for the login
    /// password each time it reads an item another build wrote.
    static var isolatedTokens: URL { AppPaths.home.appendingPathComponent(".swarmebot/remote-tokens.json") }

    static func readIsolatedTokens() -> [String: String] {
        (try? Data(contentsOf: isolatedTokens)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
    }

    static func writeIsolatedTokens(_ tokens: [String: String]) throws {
        try FileManager.default.createDirectory(at: isolatedTokens.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: tokens, options: [.sortedKeys]).write(to: isolatedTokens, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: isolatedTokens.path)
    }

    public static func token(engineId: String) -> String? {
        if AppPaths.isIsolated { return readIsolatedTokens()[engineId] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: engineId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setToken(_ token: String, engineId: String) throws {
        if AppPaths.isIsolated {
            var tokens = readIsolatedTokens()
            tokens[engineId] = token
            try writeIsolatedTokens(tokens)
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: engineId,
        ]
        let data = Data(token.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychain(status)
        }
    }

    public static func deleteToken(engineId: String) {
        if AppPaths.isIsolated {
            var tokens = readIsolatedTokens()
            tokens[engineId] = nil
            try? writeIsolatedTokens(tokens)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: engineId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
