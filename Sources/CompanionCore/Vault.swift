// The secrets vault (`/api/vault*`, docs/plans/2026-10-25-vault.md). Desktop
// only. The engine never returns a value: a secret says whether it has one.
// On a remote engine the API is read-only; the Mac that administers it
// writes over ssh (SwarmeKit).
import Foundation

public struct VaultSecret: Decodable, Hashable, Identifiable, Sendable {
    public var name: String
    /// generic · github · huggingface · npm
    public var preset: String
    public var description: String
    public var hint: String
    public var set: Bool
    public var createdAt: Double
    public var updatedAt: Double
    public var id: String { name }
}

/// One secret handed to a bot. `mode`: "safe" (only through the engine's
/// `run_with_secrets`) or "env" (in the CLI's environment).
public struct VaultGrant: Codable, Hashable, Sendable {
    public var name: String
    public var mode: String

    public init(name: String, mode: String) {
        self.name = name
        self.mode = mode
    }
}

public struct VaultBotGrants: Codable, Hashable, Sendable {
    public var secrets: [VaultGrant]
    public var note: String

    public init(secrets: [VaultGrant] = [], note: String = "") {
        self.secrets = secrets
        self.note = note
    }
}

public struct VaultState: Decodable, Hashable, Sendable {
    /// A sealed file this engine has no key for.
    public var locked: Bool
    /// Values sealed at rest (this Mac's engine).
    public var encrypted: Bool
    public var secrets: [VaultSecret]
    public var grants: [String: VaultBotGrants]
    /// Driver kinds that can use a secret in each mode.
    public var support: Support?

    public struct Support: Decodable, Hashable, Sendable {
        public var safe: [String]
        public var env: [String]
    }

    public func grants(botId: String) -> VaultBotGrants { grants[botId] ?? VaultBotGrants() }
}

/// What the app sends to create or change a secret. `value` nil keeps the stored one.
public struct VaultSecretInput: Sendable {
    public var name: String
    public var preset: String
    public var description: String
    public var hint: String
    public var value: String?

    public init(name: String, preset: String, description: String, hint: String, value: String?) {
        self.name = name
        self.preset = preset
        self.description = description
        self.hint = hint
        self.value = value
    }

    /// The JSON body; `name` only when creating.
    public func body(includingName: Bool) -> [String: Any] {
        var body: [String: Any] = ["preset": preset, "description": description, "hint": hint]
        if includingName { body["name"] = name }
        if let value { body["value"] = value }
        return body
    }
}

extension CompanionClient {
    public func vault() async throws -> VaultState {
        try await send(try makeRequest("GET", "/api/vault"), as: VaultState.self)
    }

    public func createVaultSecret(_ input: VaultSecretInput) async throws {
        try await send(try makeRequest("POST", "/api/vault/secrets", body: input.body(includingName: true)))
    }

    public func updateVaultSecret(_ input: VaultSecretInput) async throws {
        try await send(try makeRequest("PATCH", "/api/vault/secrets/\(input.name)", body: input.body(includingName: false)))
    }

    public func deleteVaultSecret(_ name: String) async throws {
        try await send(try makeRequest("DELETE", "/api/vault/secrets/\(name)"))
    }

    public func setVaultGrants(botId: String, _ grants: VaultBotGrants) async throws {
        let list = grants.secrets.map { ["name": $0.name, "mode": $0.mode] }
        try await send(try makeRequest("PUT", "/api/vault/grants/\(botId)", body: ["secrets": list, "note": grants.note]))
    }
}
