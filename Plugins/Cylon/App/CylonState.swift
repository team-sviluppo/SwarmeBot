// The Cylon plugin's state: each channel's flow, who plays what in each project, and which skill source it uses.
import CompanionCore
import Foundation
import Observation
import SwarmeKit

@MainActor
@Observable
public final class CylonState {
    /// By channel id.
    var statuses: [String: CylonStatus] = [:]
    var errors: [String: String] = [:]
    /// Project id → phase → bot id.
    var roles: [String: [String: String]] = [:]
    var projects: [CylonProjectName] = []
    var sourceId: String?

    func refresh(model: AppModel, groupId: String) async {
        guard let client = model.client else { return }
        do {
            let status = try await client.cylonStatus(groupId: groupId)
            if statuses[groupId] != status { statuses[groupId] = status }
        } catch {
            if !Task.isCancelled { errors[groupId] = error.localizedDescription }
        }
    }

    /// One call to the engine, the answer kept; its refusal is said under the bar.
    func act(model: AppModel, groupId: String, _ call: (CompanionClient) async throws -> CylonStatus) async {
        guard let client = model.client else { return }
        errors[groupId] = nil
        do { statuses[groupId] = try await call(client) } catch {
            errors[groupId] = error.localizedDescription
            await refresh(model: model, groupId: groupId)
        }
    }

    func refreshSettings(model: AppModel) async {
        guard let client = model.client else { return }
        roles = (try? await client.cylonRoles()) ?? [:]
        projects = (try? await client.cylonProjects()) ?? []
        sourceId = try? await client.cylonSourceId()
    }

    func setRole(model: AppModel, project: String, phase: String, botId: String?) async {
        guard let client = model.client else { return }
        do {
            try await client.setCylonRole(project: project, phase: phase, botId: botId)
            await model.refreshSkillSources()
        } catch { model.lastError = error.localizedDescription }
        await refreshSettings(model: model)
    }

    func setSource(model: AppModel, _ id: String?) async {
        guard let client = model.client else { return }
        do {
            try await client.setCylonSource(id)
            await model.refreshSkillSources()
        } catch { model.lastError = error.localizedDescription }
        await refreshSettings(model: model)
    }

    /// How often to look again: soon while a phase runs, rarely otherwise.
    static func pollInterval(_ status: CylonStatus?) -> Duration {
        guard let status else { return .seconds(5) }
        return status.running || status.busy ? .seconds(2) : .seconds(15)
    }

    /// What is missing for the phase to go out, in words, or nil when nothing is.
    static func problem(_ phase: CylonStatus.Phase, status: CylonStatus) -> String? {
        let title = CylonPhaseKey.title(phase.key)
        guard let bot = phase.bot else {
            return status.projectId == nil ? tr("Il canale non ha un progetto: sceglilo nelle sue impostazioni.")
                : tr("Nessun bot per %@: scegli in Impostazioni › Plugin › Cylon.", title)
        }
        if !bot.member { return tr("%@ fa %@ ma non è un membro del canale.", bot.name ?? "?", title) }
        if !bot.skillOnEngine { return tr("La skill %@ non è su questo motore: aggiungi la sorgente in Impostazioni › Skill.", phase.skill) }
        // with a skill source set, the engine hands the skill over when the phase goes out
        if !bot.skillOnBot, status.source == nil { return tr("%@ non ha la skill %@.", bot.name ?? "?", phase.skill) }
        return nil
    }
}
