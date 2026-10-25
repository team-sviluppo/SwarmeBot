// "Copia su server…" for many at once: this Mac's connectors and skills sent
// to a server in one go, so they are not made again by hand there
// (docs/plans/2026-10-25-copia-su-server.md). Each item goes the way the
// single copy already does (ConnectorCopy, copySkill); one that fails does
// not stop the others.
import CompanionCore
import Foundation

public struct ServerCopyOutcome: Identifiable, Sendable {
    public enum Kind: Sendable { case connector, skill }
    public var kind: Kind
    public var id: String
    public var name: String
    /// nil when it was copied; otherwise why not.
    public var error: String?
    /// Connectors only: how the server's own try went.
    public var note: String?
}

extension AppModel {
    /// What the server already has, to say which copies replace something.
    public func serverInventory(_ engine: RemoteEngine) async throws -> (connectors: Set<String>, skills: Set<String>) {
        let remote = try remoteClient(engine)
        async let connectors = remote.mcpConnectors()
        async let skills = remote.skills()
        return try await (Set(connectors.map(\.id)), Set(skills.map(\.id)))
    }

    /// Copy these connectors and skills of this Mac's engine to `engine`;
    /// a skill of the same name there is replaced, as a connector of the same id is.
    public func copyToServer(connectors: [MCPConnector], skills: [Skill], engine: RemoteEngine) async -> [ServerCopyOutcome] {
        var outcomes: [ServerCopyOutcome] = []
        let secrets = ConnectorCopy.readSecrets()
        let remote: CompanionClient
        do { remote = try remoteClient(engine) } catch {
            return connectors.map { ServerCopyOutcome(kind: .connector, id: $0.id, name: $0.name, error: error.localizedDescription) }
                + skills.map { ServerCopyOutcome(kind: .skill, id: $0.id, name: $0.name, error: error.localizedDescription) }
        }
        for connector in connectors {
            do {
                let copied = try await ConnectorCopy.copy(connector, secrets: secrets, to: remote)
                let check = copied.lastCheck
                let note = connector.usesOAuth
                    ? tr("copiato: rifai il login OAuth sul server")
                    : check?.ok == true
                    ? tr("provato sul server: %@ strumenti", String(check?.tools?.count ?? 0))
                    : tr("copiato, ma la prova sul server non è riuscita: %@", check?.error ?? tr("errore sconosciuto"))
                outcomes.append(ServerCopyOutcome(kind: .connector, id: connector.id, name: connector.name, note: note))
            } catch {
                outcomes.append(ServerCopyOutcome(kind: .connector, id: connector.id, name: connector.name, error: error.localizedDescription))
            }
        }
        for skill in skills {
            do {
                _ = try await copySkill(skill, to: engine, replace: true)
                outcomes.append(ServerCopyOutcome(kind: .skill, id: skill.id, name: skill.name))
            } catch {
                outcomes.append(ServerCopyOutcome(kind: .skill, id: skill.id, name: skill.name, error: error.localizedDescription))
            }
        }
        return outcomes
    }
}
