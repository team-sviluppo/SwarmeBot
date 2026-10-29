// Code mode's state: the git state of each chat's folder, and what the plugin
// asks the engine for it.
import CompanionCore
import Foundation
import Observation
import SwarmeKit

struct CodeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
public final class CodeState {
    /// The git state of each chat's folder, by thread.
    public internal(set) var gitStates: [String: ThreadGitState] = [:]

    /// What the agent is told when "Commit & push" is clicked. Engine-side
    /// text, so English like the rest of what the agent reads.
    static let commitAndPushPrompt = """
        Commit the changes in the working folder and push the branch to its remote. \
        Stage only what belongs to this work, write a clear commit message that describes what changed, \
        and tell me the branch and the commit when it is done.
        """

    func gitBranches(model: AppModel, threadId: String) async throws -> [GitBranch] {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        return try await client.gitBranches(threadId: threadId)
    }

    func checkoutBranch(model: AppModel, threadId: String, ref: String) async throws {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        gitStates[threadId] = try await client.checkoutBranch(threadId: threadId, ref: ref)
    }

    /// Resolve the engine's actual folder, including a task's override and default workspace.
    func folder(model: AppModel, threadId: String) async throws -> String {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        let state = try await client.threadGit(threadId: threadId)
        guard let folder = state.folder else { throw CodeError(message: tr("Cartella di lavoro non disponibile")) }
        return folder
    }

    /// Asks the engine for the folder's git state, asked again whenever it
    /// may have moved (a turn ended, another folder). An engine without the
    /// route, or a folder that went away, leaves nothing to show.
    func refreshGit(model: AppModel, threadId: String) async {
        guard let client = model.client else { return }
        let state = try? await client.threadGit(threadId: threadId)
        if gitStates[threadId] != state { gitStates[threadId] = state }
    }

    /// Hands the agent the commit and the push.
    func commitAndPush(model: AppModel) async {
        await model.send(Self.commitAndPushPrompt)
    }
}
