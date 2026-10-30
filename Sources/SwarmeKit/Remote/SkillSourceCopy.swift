// "Copia su server" for a GitHub skill source (docs/plans/2026-10-28-code-mode-t3.md §11): the source of this
// Mac's engine, created on a server with its token, so the server keeps its own skills up to date with the Mac off.
//
// The token is a secret of the vault, and a remote engine's vault is written over ssh by the Mac that
// administers it, so it goes the way `copyVaultSecret` sends one: on the ssh's stdin, never on a command line.
// The source itself goes over the engine's HTTPS API, and the server is asked to update right away, so the answer
// says whether it works there (a token that cannot see the repository, a skill that is not valid).
import CompanionCore
import Foundation

public enum SkillSourceCopy {
    /// A source's settings as another engine takes them. The bots it was handed to are this engine's, not the
    /// server's, so only "every bot" travels: who else gets the skills is chosen there.
    public static func fields(_ source: SkillSource) -> [String: Any] {
        var out: [String: Any] = [
            "repo": source.repo, "path": source.path, "ref": source.ref, "name": source.name, "enabled": source.enabled,
            "assign": ["all": source.assign.all, "botIds": [String]()] as [String: Any],
            "requires": ["commands": source.requires.commands, "connectors": source.requires.connectors] as [String: Any],
        ]
        out["secret"] = source.secret.map { $0 as Any } ?? NSNull()
        return out
    }

    /// The same folder of the same repository at the same ref: what a server already has is that source, whatever it is called.
    public static func same(_ a: SkillSource, _ b: SkillSource) -> Bool {
        a.repo == b.repo && a.path == b.path && a.ref == b.ref
    }

    /// The source on the server: made, or changed if the server already has that folder; then the server updates from it.
    /// The token, if the source names one, must already be in the server's vault (`AppModel.copySkillSource` puts it there).
    public static func copy(_ source: SkillSource, to remote: CompanionClient) async throws -> SkillSource {
        let existing = try await remote.skillSources().first { same($0, source) }
        let saved: SkillSource
        if let existing { saved = try await remote.updateSkillSource(existing.id, fields(source)) }
        else { saved = try await remote.addSkillSource(fields(source)) }
        return try await remote.syncSkillSource(saved.id, force: false)
    }
}

extension AppModel {
    /// Copy one of this Mac's skill sources to a server this Mac administers, and have the server update from it.
    /// With `withSecret` the token goes to the server's vault first (replacing one of the same name); without it the
    /// server must have the secret already, or it refuses the source. The answer is the server's source after its
    /// first update: its `last` says how that went.
    @discardableResult
    public func copySkillSource(_ source: SkillSource, to engine: RemoteEngine, withSecret: Bool = true) async throws -> SkillSource {
        let remote = try remoteClient(engine)
        if withSecret, let name = source.secret {
            if vault == nil { await refreshVault() }
            guard let secret = vault?.secrets.first(where: { $0.name == name }) else { throw VaultEditError.missingLocalValue(name) }
            try await copyVaultSecret(secret, to: engine)
        }
        return try await SkillSourceCopy.copy(source, to: remote)
    }

    /// What a server already has, to say which copies replace something.
    public func remoteSkillSources(_ engine: RemoteEngine) async throws -> [SkillSource] {
        try await remoteClient(engine).skillSources()
    }
}
