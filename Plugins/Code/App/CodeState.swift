// Code mode's state: the git state of each chat's folder, and what the plugin
// asks the engine for it.
import CompanionCore
import Foundation
import Observation
import SwarmeBotUI
import SwarmeKit

/// The chat the plugin works in: a bot's, or a channel's. The views only need its thread and whether
/// someone is working in it.
struct CodeChat: Hashable {
    enum Kind: Hashable { case bot, room }

    let kind: Kind
    let id: String
    let threadId: String

    init(bot: Bot) {
        kind = .bot
        id = bot.id
        threadId = bot.threadId
    }

    init(room: Room) {
        kind = .room
        id = room.id
        threadId = room.threadId
    }

    /// The chat a plugin hook was asked about.
    init?(_ chat: ChatContext) {
        if let bot = chat.bot { self.init(bot: bot) }
        else if let room = chat.room { self.init(room: room) }
        else { return nil }
    }

    /// Read from the model each time, so a view that asks is redrawn when the work starts or ends.
    @MainActor
    func isBusy(_ model: AppModel) -> Bool {
        switch kind {
        case .bot: return model.state.bot(id).map(model.isBusy) ?? false
        case .room: return model.state.rooms.first { $0.id == id }?.busyBotId != nil
        }
    }
}

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
    /// The projects of the engine this window shows (Projects.swift on the engine).
    public internal(set) var projects: [Project] = []
    var scriptStatus: [String: ScriptStatus] = [:]
    var scriptErrors: [String: String] = [:]
    var scriptPanels: Set<String> = []
    var branchPickerRequest = 0
    /// Plan or Execute, by thread; absent is Execute.
    var modes: [String: CodeChatMode] = [:]
    /// The review of each chat's changes by another bot, by thread: the running one, or the last to end.
    var reviews: [String: CodeReviewRun] = [:]
    /// The pull request of each chat's branch, by thread.
    var pullRequests: [String: CodePullRequestStatus] = [:]
    var reviewErrors: [String: String] = [:]
    /// Threads with a fetch, pull or push running, and what the last one said.
    var syncing: Set<String> = []
    var syncErrors: [String: String] = [:]

    func engineHasPhase3(_ model: AppModel) -> Bool {
        guard let version = model.enginePlugins.first(where: { $0.id == "code" })?.version else { return false }
        return Self.version(version, atLeast: "1.4.0")
    }

    /// Whether the engine's plugin has Plan mode, reviews by another bot and the pull request's state.
    func engineHasPhase4(_ model: AppModel) -> Bool {
        guard let version = model.enginePlugins.first(where: { $0.id == "code" })?.version else { return false }
        return Self.version(version, atLeast: "1.5.0")
    }

    /// Whether the engine's plugin knows ahead/behind, fetch, pull and push.
    func engineHasGitSync(_ model: AppModel) -> Bool {
        guard let version = model.enginePlugins.first(where: { $0.id == "code" })?.version else { return false }
        return Self.version(version, atLeast: "1.6.0")
    }

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

    /// Whether the engine's plugin knows projects.
    func engineHasProjects(_ model: AppModel) -> Bool {
        guard let version = model.enginePlugins.first(where: { $0.id == "code" })?.version else { return false }
        return Self.version(version, atLeast: "1.2.0")
    }

    /// Whether the engine's plugin has Code mode for channels.
    func engineHasChannels(_ model: AppModel) -> Bool {
        guard let version = model.enginePlugins.first(where: { $0.id == "code" })?.version else { return false }
        return Self.version(version, atLeast: "1.3.0")
    }

    // MARK: projects

    func refreshProjects(model: AppModel) async {
        guard let client = model.client, engineHasProjects(model) else { projects = []; return }
        if let list = try? await client.projects() { projects = list }
    }

    /// Creates or changes a project; the engine's refusal (a folder that is not there…) comes back as the error.
    func saveProject(model: AppModel, id: String?, name: String, clickupListId: String?, repos: [ProjectRepo]) async throws {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        if let id { _ = try await client.updateProject(id, name: name, clickupListId: clickupListId, repos: repos) }
        else { _ = try await client.createProject(name: name, clickupListId: clickupListId, repos: repos) }
        await refreshProjects(model: model)
    }

    func deleteProject(model: AppModel, _ id: String) async throws {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        try await client.deleteProject(id)
        await refreshProjects(model: model)
    }

    func folders(model: AppModel, path: String?, hidden: Bool) async throws -> FolderListing {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        return try await client.folders(path: path, hidden: hidden)
    }

    /// The project a bot or channel belongs to, and the folder it works on, as the engine keeps them.
    func assignment(_ plugins: [String: JSONValue]?) -> (project: Project?, role: String?) {
        let data = (plugins ?? [:]).pluginData("code")
        let project = data["projectId"]?.string.flatMap { id in projects.first { $0.id == id } }
        return (project, data["role"]?.string)
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


// MARK: - Plan mode, review by another bot, pull request

extension CodeState {
    /// What the agent hears when the plan is approved. Engine-side text, so English.
    static let planApprovedPrompt = "The plan is approved. Go ahead and carry it out."

    func mode(of threadId: String) -> CodeChatMode { modes[threadId] ?? .execute }

    func refreshMode(model: AppModel, threadId: String) async {
        guard engineHasPhase4(model), let client = model.client else { return }
        let mode = (try? await client.codeMode(threadId: threadId)) ?? .execute
        if modes[threadId] != mode { modes[threadId] = mode }
    }

    func setMode(model: AppModel, threadId: String, _ mode: CodeChatMode) async {
        guard let client = model.client else { return }
        do {
            try await client.setCodeMode(threadId: threadId, mode)
            modes[threadId] = mode
        } catch { model.lastError = error.localizedDescription }
    }

    /// The plan is good: from now the agent may change things, and it is told to start.
    func approvePlan(model: AppModel, threadId: String) async {
        await setMode(model: model, threadId: threadId, .execute)
        guard mode(of: threadId) == .execute else { return }
        await model.send(Self.planApprovedPrompt)
    }

    // MARK: review

    /// The bots that can review this chat: every visible one but the chat's own.
    func reviewers(model: AppModel, chat: CodeChat) -> [Bot] {
        model.state.bots.filter { $0.hidden != true && !(chat.kind == .bot && $0.id == chat.id) }
    }

    func refreshReview(model: AppModel, threadId: String) async {
        guard engineHasPhase4(model), let client = model.client else { return }
        let run = try? await client.codeReview(threadId: threadId)
        if reviews[threadId] != run { reviews[threadId] = run }
    }

    func startReview(model: AppModel, threadId: String, botId: String) async {
        guard let client = model.client else { return }
        reviewErrors[threadId] = nil
        do { reviews[threadId] = try await client.startCodeReview(threadId: threadId, botId: botId) }
        catch { reviewErrors[threadId] = error.localizedDescription }
    }

    func cancelReview(model: AppModel, threadId: String) async {
        guard let client = model.client else { return }
        try? await client.cancelCodeReview(threadId: threadId)
        await refreshReview(model: model, threadId: threadId)
    }

    /// What the first bot is told about a review. Engine-side text, so English.
    static func reviewMessage(reviewer: String, review: String) -> String {
        "\(reviewer) reviewed your changes. Their review:\n\n\(review)\n\nGo through each point: fix what is right, and tell me briefly what you would not change and why."
    }

    /// *Apply*: the review goes to the bot that made the changes, and is marked so that it is offered once.
    func applyReview(model: AppModel, threadId: String, message: Message) async {
        let name = message.from.map { "@\($0.name)" } ?? "Another bot"
        if let client = model.client { try? await client.markCodeReviewApplied(threadId: threadId, messageId: message.id) }
        await model.send(Self.reviewMessage(reviewer: name, review: message.text ?? ""))
    }

    // MARK: pull request

    func refreshPullRequest(model: AppModel, threadId: String, refresh: Bool = false) async {
        guard engineHasPhase4(model), let client = model.client else { return }
        guard let status = try? await client.pullRequest(threadId: threadId, refresh: refresh) else { return }
        if pullRequests[threadId] != status { pullRequests[threadId] = status }
    }

    /// The CI failed: what failed goes to the bot, with the end of its logs.
    func sendCIFailures(model: AppModel, threadId: String) async throws {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        let message = try await client.ciFailureMessage(threadId: threadId)
        await model.send(message)
    }

    /// What the colleagues commented on the pull request goes to the bot.
    func sendPullRequestComments(model: AppModel, threadId: String) async throws {
        guard let client = model.client else { throw URLError(.notConnectedToInternet) }
        let message = try await client.pullRequestCommentsMessage(threadId: threadId)
        await model.send(message)
    }

    /// How often to ask GitHub again: soon while checks run, rarely when there is nothing to wait for.
    static func pollInterval(_ status: CodePullRequestStatus?) -> Duration {
        guard let status, status.available else { return .seconds(600) }
        guard let pr = status.pr else { return .seconds(180) }
        if !pr.isOpen { return .seconds(900) }
        return pr.checks.state == "pending" ? .seconds(30) : .seconds(120)
    }
}

// MARK: - Fetch, pull and push

/// What "Sincronizza" does: look at the remote, bring what it has, then send what is here.
enum GitSyncPlan {
    enum Step: String { case pull, push }

    /// After a fetch. A pull goes first because a push of a branch that is behind is refused; both when both.
    static func steps(ahead: Int, behind: Int) -> [Step] {
        (behind > 0 ? [.pull] : []) + (ahead > 0 ? [.push] : [])
    }
}

extension CodeState {
    /// One call to the engine for the thread's repository; its refusal (a pull that would need a merge, a push the
    /// remote rejects) is kept to be said as git said it.
    private func gitCall(model: AppModel, threadId: String, _ actions: [String]) async {
        guard let client = model.client, !syncing.contains(threadId) else { return }
        syncing.insert(threadId)
        syncErrors[threadId] = nil
        defer { syncing.remove(threadId) }
        do {
            for action in actions { gitStates[threadId] = try await client.gitSync(threadId: threadId, action: action) }
        } catch { syncErrors[threadId] = error.localizedDescription }
    }

    func fetchRemote(model: AppModel, threadId: String) async { await gitCall(model: model, threadId: threadId, ["fetch"]) }
    func pull(model: AppModel, threadId: String) async { await gitCall(model: model, threadId: threadId, ["pull"]) }
    func push(model: AppModel, threadId: String) async { await gitCall(model: model, threadId: threadId, ["push"]) }

    /// Fetch, then what that says is missing on either side; the first step that fails stops the rest.
    func sync(model: AppModel, threadId: String) async {
        guard let client = model.client, !syncing.contains(threadId) else { return }
        syncing.insert(threadId)
        syncErrors[threadId] = nil
        defer { syncing.remove(threadId) }
        do {
            var git = try await client.gitSync(threadId: threadId, action: "fetch")
            gitStates[threadId] = git
            for step in GitSyncPlan.steps(ahead: git.ahead ?? 0, behind: git.behind ?? 0) {
                git = try await client.gitSync(threadId: threadId, action: step.rawValue)
                gitStates[threadId] = git
            }
        } catch { syncErrors[threadId] = error.localizedDescription }
    }
}

