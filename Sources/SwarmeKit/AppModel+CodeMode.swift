// Code mode: the git branch of the chat's folder and the files a turn changed.
import CompanionCore
import Foundation

extension AppModel {
    /// What the agent is told when "Commit & push" is clicked. Engine-side
    /// text, so English like the rest of what the agent reads.
    static let commitAndPushPrompt = """
        Commit the changes in the working folder and push the branch to its remote. \
        Stage only what belongs to this work, write a clear commit message that describes what changed, \
        and tell me the branch and the commit when it is done.
        """

    /// Asks the engine for the folder's git state, asked again whenever it
    /// may have moved (a turn ended, another folder). An engine without the
    /// route, or a folder that went away, leaves nothing to show.
    public func refreshGit(threadId: String) async {
        guard let client else { return }
        let state = try? await client.threadGit(threadId: threadId)
        if gitStates[threadId] != state { gitStates[threadId] = state }
    }

    /// Hands the agent the commit and the push.
    public func commitAndPush() async {
        await send(Self.commitAndPushPrompt)
    }
}
