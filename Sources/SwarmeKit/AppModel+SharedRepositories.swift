import CompanionCore
import Foundation

extension AppModel {
    public func refreshSharedRepository(_ kind: SharedRepositoryKind) async -> SharedRepository? {
        guard let client else { return nil }
        do { return try await client.sharedRepository(kind) }
        catch { lastError = error.localizedDescription; return nil }
    }

    public func setSharedFolder(_ kind: SharedRepositoryKind, _ path: String?) async -> SharedRepository? {
        guard let client else { return nil }
        lastError = nil
        do { return try await client.setSharedFolder(kind, path) }
        catch { lastError = error.localizedDescription; return nil }
    }

    public func importShared(_ kind: SharedRepositoryKind, ids: [String]) async -> SharedRepository? {
        guard let client else { return nil }
        lastError = nil
        do {
            let result = try await client.importShared(kind, ids: ids)
            if kind == .connectors { await refreshMCPConnectors() }
            else if !settingsOnly { try await hydrate() }
            return result
        } catch { lastError = error.localizedDescription; return nil }
    }

    public func publishShared(_ kind: SharedRepositoryKind, id: String) async -> SharedRepository? {
        guard let client else { return nil }
        lastError = nil
        do { return try await client.publishShared(kind, id: id) }
        catch { lastError = error.localizedDescription; return nil }
    }

    public func syncSharedRepositories() async {
        guard let client else { return }
        lastError = nil
        do {
            let problems = try await client.syncSharedRepositories()
            if !problems.isEmpty { lastError = problems.joined(separator: "\n") }
            await refreshMCPConnectors()
        } catch { lastError = error.localizedDescription }
    }

    /// Settings-only models do not keep chats; get names for the publish menu.
    public func shareableBots() async -> [Bot] {
        guard let client else { return [] }
        do { return try await client.fleet(messages: 0).bots }
        catch { lastError = error.localizedDescription; return [] }
    }
}
