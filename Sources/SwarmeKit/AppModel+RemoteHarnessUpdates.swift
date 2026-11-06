import CompanionCore
import Foundation

extension AppModel {
    public func remoteHarnessStatus(for engine: RemoteEngine) -> RemoteHarnessUpdateStatus? {
        (owner ?? self).remoteHarnessUpdates.statuses[engine.id]
    }

    /// One automatic check per administered server per app launch. Newly added
    /// servers join the same sweep; settings-only models never start a second one.
    public func checkRemoteHarnessUpdates(_ only: RemoteEngine? = nil, force: Bool = false) {
        if settingsOnly { owner?.checkRemoteHarnessUpdates(only, force: force); return }
        if force { harnessReleaseSource.reset() }
        let administered = remoteEngines.filter { identity(for: $0) != nil }
        remoteHarnessUpdates.retain(Set(administered.map(\.id)))
        for engine in administered where only == nil || engine.id == only?.id {
            guard let identity = identity(for: engine), let client = try? remoteClient(engine) else { continue }
            let admin = RemoteAdmin(identity: identity, store: identityStore)
            let source = harnessReleaseSource
            let operations = RemoteHarnessUpdater.Operations(probe: { try await admin.probe() }, busy: {
                let fleet = try await client.fleet(messages: 0)
                return fleet.bots.filter { $0.busy == true || ["working", "waiting-on-you", "no-signal"].contains($0.activity ?? "") }.map(\.name)
            }, update: { kind, probe, idle in
                try await admin.updateHarness(kind, probe: probe, source: source, ensureIdle: idle)
            })
            remoteHarnessUpdates.check(engine.id, operations: operations, force: force)
        }
    }
}
