// Code mode's state: the git state of each chat's folder, and what the plugin
// asks the engine for it.
import CompanionCore
import Foundation
import Observation
import SwarmeKit

/// A file a message points the agent at.
public struct FileReference: Hashable, Sendable, Identifiable {
    /// The engine's path: on a server, a path on the server.
    public var path: String
    public var name: String
    public var id: String { path }

    public init(path: String) {
        self.path = path
        name = (path as NSString).lastPathComponent
    }
}

struct CodeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
public final class CodeState {
    /// The git state of each chat's folder, by thread.
    public internal(set) var gitStates: [String: ThreadGitState] = [:]
    /// Whether and how each chat can be continued in the agent's CLI, by thread.
    public internal(set) var resumeCommands: [String: ResumeCommand] = [:]
    /// The files each chat's next message refers to, by thread: a path goes to the agent, not the file.
    public internal(set) var references: [String: [FileReference]] = [:]
    /// The comments on the diff not yet sent as a review, by thread.
    var comments: [String: [DiffComment]] = [:]
    /// The model that writes commit messages on the engine this window shows (nil: the bot's own).
    var commitModel: CodeSettingsWire.Pick?

    /// What the agent is told when "Commit & push" is clicked. Engine-side
    /// text, so English like the rest of what the agent reads.
    static let commitAndPushPrompt = """
        Commit the changes in the working folder and push the branch to its remote. \
        Stage only what belongs to this work, write a clear commit message that describes what changed, \
        and tell me the branch and the commit when it is done.
        """

    /// Whether the engine's plugin is new enough for the diff, the file search and the commit window.
    func engineHasWorkflow(_ model: AppModel) -> Bool {
        guard let version = model.enginePlugins.first(where: { $0.id == "code" })?.version else { return false }
        return Self.version(version, atLeast: "1.1.0")
    }

    /// `1.10.0` is newer than `1.9.0`: numbers, not text.
    static func version(_ version: String, atLeast minimum: String) -> Bool {
        func parts(_ text: String) -> [Int] { text.split(separator: ".").map { Int($0) ?? 0 } }
        let have = parts(version), need = parts(minimum)
        for index in 0..<max(have.count, need.count) {
            let a = index < have.count ? have[index] : 0, b = index < need.count ? need[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    // MARK: file references

    func addReference(_ reference: FileReference, threadId: String) {
        guard !(references[threadId] ?? []).contains(where: { $0.path == reference.path }) else { return }
        references[threadId, default: []].append(reference)
    }

    func removeReference(_ path: String, threadId: String) {
        references[threadId]?.removeAll { $0.path == path }
    }

    /// What the next message refers to, and lets go of it: it goes with that message.
    func takeReferences(threadId: String) -> [FileReference] {
        defer { references[threadId] = nil }
        return references[threadId] ?? []
    }

    /// The text that follows a message to point the agent at its files. Engine-side text, so English.
    static func referencesBlock(_ files: [FileReference]) -> String {
        "Files I am referring to (read them as you need):\n" + files.map { "- \($0.path)" }.joined(separator: "\n")
    }

    // MARK: engine calls

    func diff(model: AppModel, threadId: String, path: String?) async throws -> FileDiff {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        return try await client.gitDiff(threadId: threadId, path: path)
    }

    func searchFiles(model: AppModel, threadId: String, query: String) async -> [CodeFile] {
        guard let client = model.client else { return [] }
        return (try? await client.searchFiles(threadId: threadId, query: query)) ?? []
    }

    func commitMessage(model: AppModel, threadId: String) async throws -> String {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        return try await client.commitMessage(threadId: threadId)
    }

    func commit(model: AppModel, threadId: String, message: String, files: [String]?, mode: CommitMode, branch: String?) async throws -> CommitResult {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        let result = try await client.commit(threadId: threadId, message: message, files: files, mode: mode, branch: branch)
        if let git = result.git { gitStates[threadId] = git } else { await refreshGit(model: model, threadId: threadId) }
        return result
    }

    func refreshSettings(model: AppModel) async {
        guard let client = model.client else { return }
        commitModel = (try? await client.codeSettings())?.commitModel
    }

    func setCommitModel(model: AppModel, _ pick: CodeSettingsWire.Pick?) async {
        guard let client = model.client else { return }
        do { commitModel = try await client.setCommitModel(pick).commitModel } catch { model.lastError = error.localizedDescription }
    }

    // MARK: review

    func addComment(_ comment: DiffComment, threadId: String) { comments[threadId, default: []].append(comment) }

    func removeComment(_ id: UUID, threadId: String) { comments[threadId]?.removeAll { $0.id == id } }

    /// Every comment as one message to the agent, and the comments let go.
    func sendReview(model: AppModel, threadId: String) async {
        let pending = comments[threadId] ?? []
        guard !pending.isEmpty else { return }
        comments[threadId] = nil
        await model.send(Review.message(pending))
    }

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

    func createBranch(model: AppModel, threadId: String, name: String) async throws {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        gitStates[threadId] = try await client.createBranch(threadId: threadId, name: name)
    }

    /// Asks the engine whether the chat can be continued in a terminal; an engine
    /// without the route, or a chat with no session, says no.
    func refreshResume(model: AppModel, threadId: String) async {
        guard let client = model.client else { return }
        let command = try? await client.resumeCommand(threadId: threadId)
        if resumeCommands[threadId] != command { resumeCommands[threadId] = command }
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
