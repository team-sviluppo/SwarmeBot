// Skill sources: GitHub folders of skills that the engine keeps installed
// (docs/contract/http-sse.md). The app lists them and asks for an update; the engine does the work.
import CompanionCore
import Foundation

extension AppModel {
    public func refreshSkillSources() async {
        guard let client else { return }
        guard let list = try? await client.skillSources() else { return }
        skillSources = list
        announceSkillUpdates(list)
    }

    /// An update that changed skills is worth telling, since they can run scripts: whoever can write to the
    /// repository changes what the bots do. What was already there when the app first saw a source is not news.
    private func announceSkillUpdates(_ list: [SkillSource]) {
        let defaults = UserDefaults.standard
        let before = defaults.dictionary(forKey: SkillUpdates.key) as? [String: Double] ?? [:]
        let (news, seen) = SkillUpdates.news(in: list, seen: before)
        if seen != before { defaults.set(seen, forKey: SkillUpdates.key) }
        for item in news { onSkillsUpdated?(item.source, item.updated) }
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

/// Which update of which source was already told, so that a notification comes once.
public enum SkillUpdates {
    static let key = "skillSourceSeen"

    /// The sources whose newest update changed skills and was not seen yet, and what is seen now. A source seen for
    /// the first time (or with no run yet) only has its time recorded.
    public static func news(in sources: [SkillSource], seen: [String: Double]) -> (news: [(source: SkillSource, updated: SkillSource.Updated)], seen: [String: Double]) {
        var seen = seen
        var news: [(source: SkillSource, updated: SkillSource.Updated)] = []
        for source in sources {
            guard let last = source.last else { continue }
            defer { seen[source.id] = max(seen[source.id] ?? 0, last.checkedAt) }
            guard let known = seen[source.id] else { continue }
            if last.checkedAt > known, last.ok, let updated = last.updated, !updated.isEmpty { news.append((source, updated)) }
        }
        return (news, seen)
    }
}

