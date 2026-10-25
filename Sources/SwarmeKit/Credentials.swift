// Workspace secrets, in the Keychain.
//
// The harness reads credentials from its environment in preference to
// `config.json` (server/config.ts `loadConfig`), with the Keychain as the store:
//
// - at boot, `environment` becomes part of the harness's env;
// - on save, the Keychain is written first and then the harness is told
//   with `PUT /api/config?secretStorage=external`, which makes the value
//   live without writing it to config.json.
//
// One Keychain item holding a small JSON object, rather than one item per
// secret: one read at launch, one access prompt if ever there is one.
import Foundation
import Security

public enum WorkspaceCredential: String, CaseIterable, Sendable {
    case xaiApiKey, boxToken, opencodeGoApiKey, localEndpointApiKey

    /// The env var `server/config.ts` reads.
    public var environmentName: String {
        switch self {
        case .xaiApiKey: return "XAI_API_KEY"
        case .boxToken: return "BOX_TOKEN"
        case .opencodeGoApiKey: return "OPENCODE_API_KEY"
        case .localEndpointApiKey: return "LOCAL_ENDPOINT_AUTH_KEY"
        }
    }

    /// The `PUT /api/config` patch that makes a value live.
    public func configPatch(_ value: String) -> [String: Any] {
        switch self {
        case .xaiApiKey: return ["xai": ["key": value]]
        case .boxToken: return ["box": ["token": value]]
        case .opencodeGoApiKey: return ["opencodeGo": ["apiKey": value]]
        case .localEndpointApiKey: return ["localEndpoint": ["apiKey": value]]
        }
    }

    public var label: String {
        switch self {
        case .xaiApiKey: return tr("Chiave API xAI")
        case .boxToken: return tr("Token Box (computer cloud)")
        case .opencodeGoApiKey: return tr("Chiave OpenCode Go")
        case .localEndpointApiKey: return tr("Chiave del server compatibile OpenAI")
        }
    }
}

public enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return tr("Portachiavi: %@", SecCopyErrorMessageString(status, nil) as String? ?? tr("errore %@", String(status)))
        }
    }
}

public enum CredentialStore {
    static var service: String { "com.swarmebot.mac" + AppPaths.keychainSuffix }
    static let account = "workspace-credentials"

    // MARK: Reading and writing

    public static func load() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return values
    }

    public static func save(_ values: [String: String]) throws {
        let data = try JSONEncoder().encode(values)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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

    public static func set(_ credential: WorkspaceCredential, _ value: String?) throws {
        var values = load()
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            values.removeValue(forKey: credential.rawValue)
        } else {
            values[credential.rawValue] = trimmed
        }
        try save(values)
        try? writeSecretsFile(credential, trimmed)
    }

    /// One env var in `~/.swarmebot/secrets.json`. The harness reads this at
    /// boot, so the key is still there after a restart when the Keychain
    /// item is not visible to the new process.
    private static func writeSecretsFile(_ credential: WorkspaceCredential, _ value: String) throws {
        let dir = AppPaths.home.appendingPathComponent(".swarmebot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("secrets.json")
        var env = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        if value.isEmpty { env.removeValue(forKey: credential.environmentName) } else { env[credential.environmentName] = value }
        let data = try JSONSerialization.data(withJSONObject: env, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The env vars for a harness this app starts. The file fills anything
    /// the Keychain does not return.
    public static var environment: [String: String] {
        let url = AppPaths.home
            .appendingPathComponent(".swarmebot/secrets.json")
        var env = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        let values = load()
        for credential in WorkspaceCredential.allCases {
            if let value = values[credential.rawValue], !value.isEmpty {
                env[credential.environmentName] = value
            }
        }
        return env.filter { !$0.value.isEmpty }
    }

}

/// The key that seals this Mac's vault at rest (docs/plans/2026-10-25-vault.md
/// V6): 32 random bytes in their own Keychain item, handed to the engine at
/// launch in SWARMEBOT_VAULT_KEY. Created only when there is none: a Keychain
/// that refuses to answer must not get a new key, or the sealed file could
/// never be opened again — the engine then shows the vault as locked.
public enum VaultKey {
    static let account = "vault-key"
    public static let environmentName = "SWARMEBOT_VAULT_KEY"

    public static func loadOrCreate() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialStore.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let key = Data(bytes)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialStore.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}
