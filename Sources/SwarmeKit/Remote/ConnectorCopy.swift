// "Copia su server" — bot-remoto §8 (R14): a connector of this Mac, created
// on a remote engine with its secrets, so bots there have it with the Mac off.
//
// The local engine never hands secrets out over its API, by design; they are
// in its `mcp-connector-secrets.json` (0600, this user's). The copy reads that
// file, puts each value back into the connector's form and sends it to the
// remote engine over HTTPS, in the `{secret: true, value}` shape the API takes.
// OAuth connectors are not copied: their tokens rotate and belong to one engine.
import CompanionCore
import Foundation

public enum ConnectorCopyError: LocalizedError, Equatable {
    case oauth(String)
    case missingSecret(connector: String, name: String)

    public var errorDescription: String? {
        switch self {
        case let .oauth(name):
            return tr("%@ usa OAuth: sui server remoti si configura a parte (i token OAuth non si copiano)", name)
        case let .missingSecret(connector, name):
            return tr("%@: il segreto %@ non è salvato su questo Mac, quindi non si può copiare", connector, name)
        }
    }
}

public enum ConnectorCopy {
    /// `{id: {env: {NAME: value}, headers: {Name: value}}}`
    public typealias Secrets = [String: [String: [String: String]]]

    public static var localSecretsFile: URL {
        AppPaths.home.appendingPathComponent(".swarmebot/mcp-connector-secrets.json")
    }

    public static func readSecrets(_ file: URL = localSecretsFile) -> Secrets {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: Secrets = [:]
        for (id, value) in object {
            guard let kinds = value as? [String: Any] else { continue }
            for kind in ["env", "headers"] {
                guard let entries = kinds[kind] as? [String: Any] else { continue }
                for (name, secret) in entries {
                    if let text = secret as? String { out[id, default: [:]][kind, default: [:]][name] = text }
                }
            }
        }
        return out
    }

    /// The connector's form with every secret filled in from this Mac.
    public static func input(for connector: MCPConnector, secrets: Secrets) throws -> MCPConnectorInput {
        guard !connector.usesOAuth else { throw ConnectorCopyError.oauth(connector.name) }
        var input = MCPConnectorInput(connector)
        func fill(_ entries: inout [MCPConnectorInput.Entry], kind: String) throws {
            for index in entries.indices where entries[index].secret {
                guard let value = secrets[connector.id]?[kind]?[entries[index].name], !value.isEmpty else {
                    throw ConnectorCopyError.missingSecret(connector: connector.name, name: entries[index].name)
                }
                entries[index].value = value
                entries[index].keepStored = false
            }
        }
        try fill(&input.env, kind: "env")
        try fill(&input.headers, kind: "headers")
        return input
    }

    /// Create it on the remote engine, or replace the one of the same id; then
    /// have that engine try it, since a command found on this Mac may be missing there.
    @discardableResult
    public static func copy(_ connector: MCPConnector, secrets: Secrets, to remote: CompanionClient) async throws -> MCPConnector {
        let input = try input(for: connector, secrets: secrets)
        let existing = try await remote.mcpConnectors().contains { $0.id == connector.id }
        if existing {
            try await remote.updateMCPConnector(connector.id, input)
        } else {
            try await remote.createMCPConnector(input)
        }
        return try await remote.testMCPConnector(connector.id)
    }
}

extension AppModel {
    /// Copy one of this Mac's connectors to a remote engine (with its secrets).
    public func copyConnector(_ connector: MCPConnector, to engine: RemoteEngine) async throws -> MCPConnector {
        try await ConnectorCopy.copy(connector, secrets: ConnectorCopy.readSecrets(), to: try remoteClient(engine))
    }
}
