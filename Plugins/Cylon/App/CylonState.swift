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
    var projects: [CylonProject] = []
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

    // MARK: boards

    /// The boards of each project, by project id.
    var boards: [String: [CylonBoardWire]] = [:]
    /// What the person chose to look at, by project id.
    var chosenBoard: [String: String] = [:]
    var boardErrors: [String: String] = [:]

    func refreshBoards(model: AppModel, projectId: String) async {
        guard let client = model.client else { return }
        do {
            let list = try await client.cylonBoards(projectId: projectId)
            if boards[projectId] != list { boards[projectId] = list }
        } catch { if !Task.isCancelled { boardErrors[projectId] = error.localizedDescription } }
    }

    /// One call on a board; the board it answers with replaces the one shown, and a refusal is said under the list.
    func actOnBoard(model: AppModel, projectId: String, _ call: (CompanionClient) async throws -> CylonBoardWire) async {
        guard let client = model.client else { return }
        boardErrors[projectId] = nil
        do {
            let board = try await call(client)
            var list = boards[projectId] ?? []
            if let index = list.firstIndex(where: { $0.id == board.id }) { list[index] = board } else { list.append(board) }
            boards[projectId] = list
            chosenBoard[projectId] = board.id
        } catch {
            boardErrors[projectId] = error.localizedDescription
            await refreshBoards(model: model, projectId: projectId)
        }
    }

    func deleteBoard(model: AppModel, projectId: String, id: String) async {
        guard let client = model.client else { return }
        boardErrors[projectId] = nil
        do {
            try await client.deleteCylonBoard(id)
            boards[projectId]?.removeAll { $0.id == id }
            if chosenBoard[projectId] == id { chosenBoard[projectId] = nil }
        } catch { boardErrors[projectId] = error.localizedDescription }
    }

    /// How often to look again at a board: at once while a bot works on a ticket, soon while one is started, rarely otherwise.
    static func pollInterval(_ boards: [CylonBoardWire]) -> Duration {
        let states = boards.flatMap { $0.items.map(\.state) }
        if states.contains("running") { return .seconds(2) }
        return states.contains { $0 == "ready" || $0 == "waiting" } ? .seconds(5) : .seconds(12)
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

    /// Why a phase that could go cannot yet: its bot is busy in another conversation. Not a problem to fix, only to wait out.
    static func busyNote(_ phase: CylonStatus.Phase) -> String? {
        guard phase.state != "running", let bot = phase.bot, bot.busy == true else { return nil }
        return tr("%@ sta lavorando in un'altra conversazione: aspetta che finisca.", bot.name ?? "?")
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
