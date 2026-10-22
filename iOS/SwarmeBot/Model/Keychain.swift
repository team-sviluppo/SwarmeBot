// Secrets on this phone: device tokens of remote engines, API keys and OAuth
// tokens of the phone's own bots (plan §4.1, §8). Readable after the first
// unlock (a push action can answer a permission with the phone locked) and
// never synchronized: a secret leaves this phone only by being typed again.
import Foundation
import Security

enum Keychain {
    static let service = "com.swarmebot.ios"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { tr("Portachiavi non disponibile (errore %@).", String(status)) }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func set(_ value: String, for account: String) throws {
        var item = query(account)
        SecItemDelete(item as CFDictionary)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func get(_ account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
