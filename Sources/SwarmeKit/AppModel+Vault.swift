// The secrets vault (docs/plans/2026-10-25-vault.md): the engine's list and
// grants, and their changes. This Mac's engine is written through its API; a
// server only through ssh, by the Mac that administers it (V7), and the
// engine there re-reads the files at its next turn.
import CompanionCore
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

public enum VaultEditError: LocalizedError {
    case notAdministered(String)
    case missingLocalValue(String)

    public var errorDescription: String? {
        switch self {
        case let .notAdministered(name):
            return tr("Il vault di %@ si modifica solo dal Mac che amministra il server", name)
        case let .missingLocalValue(name):
            return tr("Il valore di %@ non si legge dal vault di questo Mac", name)
        }
    }
}

extension AppModel {
    public func refreshVault() async {
        guard let client else { return }
        if let state = try? await client.vault() { vault = state }
    }

    /// The server this model shows, when it is one.
    var vaultRemoteEngine: RemoteEngine? {
        guard case let .remote(id) = engineChoice else { return nil }
        return remoteEngines.first { $0.id == id }
    }

    /// Whether this Mac may change the vault of the engine shown.
    public var vaultEditable: Bool {
        guard let engine = vaultRemoteEngine else { return true }
        return identity(for: engine) != nil
    }

    private func vaultAdmin() throws -> RemoteAdmin? {
        guard let engine = vaultRemoteEngine else { return nil }
        guard let identity = identity(for: engine) else { throw VaultEditError.notAdministered(engine.name) }
        return RemoteAdmin(identity: identity, store: identityStore)
    }

    private static func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    /// Create (`existing` false) or change a secret.
    public func saveVaultSecret(_ input: VaultSecretInput, existing: Bool) async throws {
        if let admin = try vaultAdmin() {
            try await admin.ssh.run(RemoteScripts.command(RemoteScripts.vaultSet, [input.name]),
                                    stdin: try Self.jsonLine(input.body(includingName: false)), timeout: 60)
        } else {
            guard let client else { throw CancellationError() }
            if existing { try await client.updateVaultSecret(input) } else { try await client.createVaultSecret(input) }
        }
        await refreshVault()
    }

    public func deleteVaultSecret(_ name: String) async throws {
        if let admin = try vaultAdmin() {
            try await admin.ssh.run(RemoteScripts.command(RemoteScripts.vaultUnset, [name]), timeout: 60)
        } else {
            guard let client else { throw CancellationError() }
            try await client.deleteVaultSecret(name)
        }
        await refreshVault()
    }

    public func setVaultGrants(botId: String, _ grants: VaultBotGrants) async throws {
        if let admin = try vaultAdmin() {
            let list = grants.secrets.map { ["name": $0.name, "mode": $0.mode] }
            try await admin.ssh.run(RemoteScripts.command(RemoteScripts.vaultGrant, [botId]),
                                    stdin: try Self.jsonLine(["secrets": list, "note": grants.note]), timeout: 60)
        } else {
            guard let client else { throw CancellationError() }
            try await client.setVaultGrants(botId: botId, grants)
        }
        await refreshVault()
    }

    /// A secret of this Mac's vault, value included, onto a server this Mac
    /// administers. The value goes on the ssh's stdin, never on a command line.
    public func copyVaultSecret(_ secret: VaultSecret, to engine: RemoteEngine) async throws {
        guard let identity = identity(for: engine) else { throw VaultEditError.notAdministered(engine.name) }
        guard let value = LocalVault.value(secret.name) else { throw VaultEditError.missingLocalValue(secret.name) }
        let input = VaultSecretInput(name: secret.name, preset: secret.preset, description: secret.description, hint: secret.hint, value: value)
        try await RemoteAdmin(identity: identity, store: identityStore).ssh
            .run(RemoteScripts.command(RemoteScripts.vaultSet, [secret.name]), stdin: try Self.jsonLine(input.body(includingName: false)), timeout: 60)
    }
}

/// This Mac's vault file, read by the app itself to copy a value to a server:
/// the API never returns one. Same format as the engine's (HarnessCore/Vault.swift).
public enum LocalVault {
    public static var file: URL { HarnessEngine.realDataDir.appendingPathComponent("vault-secrets.json") }

    public static func value(_ name: String, key: Data? = VaultKey.loadOrCreate(), file: URL = LocalVault.file) -> String? {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = object["values"] as? [String: String], let stored = values[name] else { return nil }
        guard object["alg"] as? String == "AES-GCM" else { return stored }
        #if canImport(CryptoKit)
        guard let key, let sealed = Data(base64Encoded: stored), let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(name.utf8)) else { return nil }
        return String(decoding: plain, as: UTF8.self)
        #else
        return nil
        #endif
    }
}
