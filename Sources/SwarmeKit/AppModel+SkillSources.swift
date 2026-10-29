// Skill sources: GitHub folders of skills that the engine keeps installed
// (docs/contract/http-sse.md). The app lists them and asks for an update; the engine does the work.
import CompanionCore
import Foundation

extension AppModel {
    public func refreshSkillSources() async {
        guard let client else { return }
        if let list = try? await client.skillSources() { skillSources = list }
    }

    private func store(_ source: SkillSource) {
        if let index = skillSources.firstIndex(where: { $0.id == source.id }) { skillSources[index] = source } else { skillSources.append(source) }
    }

    /// The engine's refusal (a bad repository, a secret that is not there) comes back as the error.
    public func addSkillSource(_ fields: [String: Any]) async -> Result<SkillSource, Error> {
        guard let client else { return .failure(CancellationError()) }
        do {
            let source = try await client.addSkillSource(fields)
            store(source)
            return .success(source)
        } catch { return .failure(error) }
    }

    public func updateSkillSource(_ id: String, _ fields: [String: Any]) async -> Result<SkillSource, Error> {
        guard let client else { return .failure(CancellationError()) }
        do {
            let source = try await client.updateSkillSource(id, fields)
            store(source)
            return .success(source)
        } catch { return .failure(error) }
    }

    public func deleteSkillSource(_ source: SkillSource) async {
        await perform { client in
            try await client.deleteSkillSource(source.id)
            self.skillSources.removeAll { $0.id == source.id }
            self.skills = try await client.skills()
        }
    }

    /// Looks for a newer commit now. What goes wrong is in the source's `last`, not thrown.
    public func syncSkillSource(_ source: SkillSource, force: Bool = false) async {
        await perform { client in
            self.store(try await client.syncSkillSource(source.id, force: force))
            self.skills = try await client.skills()
        }
    }

    public func rollbackSkillSource(_ source: SkillSource) async {
        await perform { client in
            self.store(try await client.rollbackSkillSource(source.id))
            self.skills = try await client.skills()
        }
    }
}
