// Workspace secrets, in the Keychain.
//
// The harness reads credentials from its environment in preference to
// `config.json` (server/config.ts `loadConfig`). Electron kept them in
// `credentials.bin`, encrypted with safeStorage, and passed them as env vars
// at fork; this is the same contract with the Keychain as the store:
//
// - at boot, `environment` becomes part of the harness's env;
// - on save, the Keychain is written first and then the harness is told
//   with `PUT /api/config?secretStorage=external`, which makes the value
//   live without writing it to config.json.
//
// One Keychain item holding a small JSON object, rather than one item per
// secret: one read at launch, one access prompt if ever there is one.
import CommonCrypto
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
        case .xaiApiKey: return "Chiave API xAI"
        case .boxToken: return "Token Box (computer cloud)"
        case .opencodeGoApiKey: return "Chiave OpenCode Go"
        case .localEndpointApiKey: return "Chiave Local Endpoint"
        }
    }
}

public enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    case electronStoreMissing
    case electronKeyUnavailable(OSStatus)
    case electronFormat(String)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "Portachiavi: \(SecCopyErrorMessageString(status, nil) as String? ?? "errore \(status)")"
        case .electronStoreMissing:
            return "Nessun archivio credenziali dell'app Electron trovato."
        case let .electronKeyUnavailable(status):
            return "Chiave 'SwarmeBot Safe Storage' non leggibile dal Portachiavi (\(status))."
        case let .electronFormat(detail):
            return "Archivio Electron in un formato non riconosciuto: \(detail)"
        }
    }
}

public enum CredentialStore {
    static let service = "com.swarmebot.mac"
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
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swarmebot", isDirectory: true)
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
        let url = FileManager.default.homeDirectoryForCurrentUser
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

    // MARK: Importing from the Electron app

    /// Read the Electron app's `credentials.bin` and merge it into ours.
    ///
    /// Electron's safeStorage on macOS is Chromium's OSCrypt: a random
    /// password in the Keychain under "<App> Safe Storage", stretched with
    /// PBKDF2-SHA1 (salt "saltysalt", 1003 rounds) into an AES-128-CBC key,
    /// IV of 16 spaces, ciphertext prefixed "v10". Reading that Keychain item
    /// belongs to another app, so macOS asks the user — which is why this
    /// runs only from an explicit button, never at launch.
    @discardableResult
    public static func importFromElectron() throws -> [String] {
        let file = HarnessLocator.userData.appendingPathComponent("credentials.bin")
        guard let blob = try? Data(contentsOf: file), !blob.isEmpty else { throw CredentialStoreError.electronStoreMissing }
        let password = try electronPassword()
        let plaintext = try decryptOSCrypt(blob, password: password)
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw CredentialStoreError.electronFormat("JSON non valido")
        }
        var values = load()
        var imported: [String] = []
        for credential in WorkspaceCredential.allCases {
            if let value = object[credential.rawValue] as? String, !value.isEmpty {
                values[credential.rawValue] = value
                imported.append(credential.label)
            }
        }
        try save(values)
        return imported
    }

    static func electronPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SwarmeBot Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialStoreError.electronKeyUnavailable(status)
        }
        return data
    }

    /// Chromium OSCrypt "v10" on macOS. Pure, so it is testable with a
    /// known password and a blob encrypted the same way.
    public static func decryptOSCrypt(_ blob: Data, password: Data) throws -> Data {
        let prefix = Data("v10".utf8)
        guard blob.starts(with: prefix) else { throw CredentialStoreError.electronFormat("prefisso mancante") }
        let ciphertext = blob.dropFirst(prefix.count)
        let key = try deriveKey(password)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        return try crypt(CCOperation(kCCDecrypt), Data(ciphertext), key: key, iv: iv)
    }

    /// The inverse, for tests.
    public static func encryptOSCrypt(_ plaintext: Data, password: Data) throws -> Data {
        let key = try deriveKey(password)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        return Data("v10".utf8) + (try crypt(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv))
    }

    private static func deriveKey(_ password: Data) throws -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(repeating: 0, count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CredentialStoreError.electronFormat("PBKDF2 \(status)") }
        return key
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, input.count,
                            out.baseAddress, outputCount, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CredentialStoreError.electronFormat("AES \(status)") }
        return output.prefix(written)
    }
}
