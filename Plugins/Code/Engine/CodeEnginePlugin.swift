// The Code plugin, engine side: git state, branches and checkout of a chat's
// folder (docs/plans/2026-10-28-code-mode-t3.md §12). Everything here runs
// where the folder is, which on a remote engine is not the Mac showing the chat.
//
// `codeMode` on a bot is the plugin's switch for that bot; it stays a plain
// boolean on the wire because every client already reads and writes it.
import Foundation
import HarnessCore

@MainActor
public final class CodeEnginePlugin: EnginePlugin {
    private lazy var scripts = ProjectScripts()
    private let reviews = CodeReviews()
    private let pullRequests = CodePullRequests()
    public nonisolated init() {}

    public nonisolated var id: String { "code" }
    public nonisolated var name: String { "Code" }
    public nonisolated var version: String { "1.6.0" }
    public nonisolated var botFlags: [String] { ["codeMode"] }
    /// Code mode for a whole channel: one folder for every member, one of them working at a time.
    public nonisolated var groupFlags: [String] { ["codeMode"] }

    // MARK: projects on bots and channels

    /// `plugins.code` of a bot or a channel: `{projectId, role}`.
    private func data(of owner: PluginDataOwner, in harness: Harness) -> JSONObject? {
        let record: JSONObject?
        switch owner {
        case let .bot(id): record = harness.store.bot(id)
        case let .group(id): record = harness.store.group(id)
        }
        return record?["plugins"]?["code"]?.object
    }

    public func validateData(_ data: JSONObject, for owner: PluginDataOwner, harness: Harness) throws {
        let known: Set<String> = ["projectId", "role"]
        if let unknown = data.keys.first(where: { !known.contains($0) }) { throw HTTPError(400, "plugins.code has no field \(unknown)") }
        let existing = self.data(of: owner, in: harness)
        let store = ProjectStore(harness: harness)
        // the project the data will name: the one sent, else the one it already has
        let projectId: String? = data["projectId"] != nil ? data["projectId"]?.string : existing?["projectId"]?.string
        if let sent = data["projectId"], !sent.isNull {
            guard let id = sent.string, store.project(id) != nil else { throw HTTPError(400, "no such project") }
        }
        if let role = data["role"], !role.isNull {
            guard let name = role.string, ProjectRole.all.contains(name) else { throw HTTPError(400, "role must be one of \(ProjectRole.all.joined(separator: ", "))") }
            guard let projectId, let project = store.project(projectId) else { throw HTTPError(400, "role needs a project") }
            guard project["repos"]?.array?.contains(where: { $0["role"]?.string == name }) == true else {
                throw HTTPError(400, "the project has no \(name) folder")
            }
        }
    }

    /// A channel with members from other engines cannot be a Code channel, and a Code channel cannot take them:
    /// a guest works on its own engine, on its own folders, so there is no one folder for all.
    public func validatePatch(_ body: JSONObject, for owner: PluginDataOwner, existing: JSONObject, harness: Harness) throws {
        guard case .group = owner else { return }
        let wantsCode = body["codeMode"]?.bool ?? existing["codeMode"]?.bool ?? false
        let hasGuests = existing["guest"] != nil || !(existing["guests"]?.array?.isEmpty ?? true)
        let addsGuests = !(body["guests"]?.array?.isEmpty ?? true)
        if body["codeMode"]?.bool == true, hasGuests {
            throw HTTPError(400, "a channel with members from other engines cannot use Code mode")
        }
        if wantsCode, addsGuests { throw HTTPError(400, "a Code mode channel cannot take members from other engines") }
        if wantsCode {
            let folder: String?
            if let pinned = existing["pinnedCwd"] { folder = pinned.string }
            else if let sent = body["cwd"] { folder = sent.string }
            else { folder = existing["cwd"]?.string }
            guard folder?.isEmpty == false else { throw HTTPError(400, "choose a shared folder before enabling Code mode") }
        }
    }

    /// A chat's default folder follows the folder it works on: what it picks in the project, it works in.
    public func dataChanged(for owner: PluginDataOwner, harness: Harness) {
        guard let data = self.data(of: owner, in: harness), let projectId = data["projectId"]?.string, let role = data["role"]?.string,
              let path = ProjectStore(harness: harness).project(projectId)?["repos"]?.array?.first(where: { $0["role"]?.string == role })?["path"]?.string else { return }
        switch owner {
        case let .bot(id):
            if harness.store.bot(id)?["cwd"]?.string != path { harness.store.patchBot(id, ["cwd": .string(path)]) }
        case let .group(id):
            // a channel's folder is fixed from the first turn on
            guard let group = harness.store.group(id), group["pinnedCwd"] == nil, group["cwd"]?.string != path else { return }
            harness.store.patchGroup(id, ["cwd": .string(path)])
        }
    }

    /// A channel's project, not its members': a bot of project A speaking in a channel of project B works with B.
    public func beforeTurn(_ turn: inout TurnSetup) {
        guard let harness = turn.harness else { return }
        // a bot reviewing another's changes reads the repository and changes nothing
        if let root = reviews.reading[turn.threadId] {
            turn.system += (turn.system.isEmpty ? "" : "\n\n") + CodeReviews.system
            turn.readOnlyFolders.append(ReadOnlyGuard.canonical(root))
        }
        // Plan mode: the chat's folder is read-only until the plan is approved
        if CodeModes(harness: harness).mode(of: turn.threadId) == .plan {
            turn.system += (turn.system.isEmpty ? "" : "\n\n") + CodeModes.prompt
            if let cwd = turn.cwd { turn.readOnlyFolders.append(ReadOnlyGuard.canonical(cwd)) }
        }
        let owner = turn.group ?? turn.bot
        guard let data = owner["plugins"]?["code"]?.object, let projectId = data["projectId"]?.string else { return }
        let store = ProjectStore(harness: harness)
        guard let project = store.project(projectId),
              let context = ProjectContext.make(project: project, role: data["role"]?.string, cwd: turn.cwd) else { return }
        let file = store.agentFile(projectId)
        turn.system += (turn.system.isEmpty ? "" : "\n\n") + context.prompt(agentFile: file.path)
        turn.environment["SWARME_PROJECT_JSON"] = file.path
        turn.readOnlyFolders += context.readOnly.map(\.path)
    }

    public func routes(_ router: PluginRouter) {
        router.get("/api/code/chats/recent") { request in
            .response(.json(200, CodeChats(harness: request.harness).recent()))
        }
        router.get("/api/bots/:bid/code/chats") { request in
            .response(.json(200, try await CodeChats(harness: request.harness).list(botId: request.params["bid"] ?? "")))
        }
        router.get("/api/bots/:bid/code/chats/search") { request in
            .response(.json(200, try CodeChats(harness: request.harness).search(botId: request.params["bid"] ?? "", query: request.http.query["q"] ?? "")))
        }
        router.patch("/api/threads/:tid/code/chat") { request in
            .response(.json(200, try CodeChats(harness: request.harness).patch(thread: request.params["tid"] ?? "", body: request.http.json())))
        }
        router.get("/api/threads/:tid/code/scripts") { request in
            .response(.json(200, try self.scripts.status(harness: request.harness, thread: request.params["tid"] ?? "")))
        }
        router.post("/api/threads/:tid/code/scripts") { request in
            guard let index = try request.http.json()["index"]?.double, index.isFinite, index.rounded() == index, (0..<20).contains(index) else {
                throw HTTPError(400, "index must name a project script")
            }
            return .response(.json(202, ["run": try self.scripts.start(harness: request.harness, thread: request.params["tid"] ?? "", index: Int(index))]))
        }
        router.post("/api/threads/:tid/code/scripts/stop") { request in
            let thread = request.params["tid"] ?? ""
            _ = try self.scripts.configuration(harness: request.harness, thread: thread)
            return .response(.json(200, ["run": self.scripts.stop(thread: thread)]))
        }
        router.get("/api/threads/:tid/code/mode") { request in
            let thread = request.params["tid"] ?? ""
            guard ThreadFiles.roots(request.harness.store, request.harness.paths, threadId: thread) != nil else { return .response(.error(404, "no such thread")) }
            return .response(.json(200, ["mode": .string(CodeModes(harness: request.harness).mode(of: thread).rawValue)]))
        }
        router.put("/api/threads/:tid/code/mode") { request in
            let thread = request.params["tid"] ?? ""
            guard ThreadFiles.roots(request.harness.store, request.harness.paths, threadId: thread) != nil else { return .response(.error(404, "no such thread")) }
            guard let mode = try request.http.json()["mode"]?.string.flatMap(CodeMode.init(rawValue:)) else { throw HTTPError(400, "mode must be plan or execute") }
            try CodeModes(harness: request.harness).set(mode, for: thread)
            return .response(.json(200, ["mode": .string(mode.rawValue)]))
        }
        router.get("/api/threads/:tid/code/review") { request in
            .response(.json(200, self.reviews.status(of: request.params["tid"] ?? "")))
        }
        router.post("/api/threads/:tid/code/review") { request in
            let harness = request.harness
            let threadId = request.params["tid"] ?? ""
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: threadId)?.first else { return .response(.error(404, "no such thread")) }
            guard let reviewer = try request.http.json()["botId"]?.string, !reviewer.isEmpty else { throw HTTPError(400, "botId is required") }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            let material = try await CodeReviews.material(root: repo.root, changes: repo.changes.map(\.path))
            let run = try self.reviews.start(harness: harness, originThread: threadId, reviewerId: reviewer, root: repo.root, branch: repo.detached ? nil : repo.branch,
                                             files: material.files, diff: material.diff, truncated: material.truncated)
            var answer = run.wire
            answer["scope"] = .string(material.scope)
            return .response(.json(202, ["review": answer]))
        }
        router.delete("/api/threads/:tid/code/review") { request in
            .response(.json(200, ["cancelled": .bool(self.reviews.cancel(threadId: request.params["tid"] ?? ""))]))
        }
        router.post("/api/threads/:tid/code/review/applied") { request in
            guard let id = try request.http.json()["messageId"]?.string else { throw HTTPError(400, "messageId is required") }
            try self.reviews.markApplied(harness: request.harness, threadId: request.params["tid"] ?? "", messageId: id)
            return .response(.json(200, ["ok": true]))
        }
        router.get("/api/threads/:tid/code/pr") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else { return .response(.error(404, "no such thread")) }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.json(200, ["available": true, "pr": .null])) }
            return .response(.json(200, try await self.pullRequests.status(root: repo.root, branch: repo.detached ? nil : repo.branch, refresh: request.http.query["refresh"] == "1")))
        }
        router.get("/api/threads/:tid/code/pr/ci-failures") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else { return .response(.error(404, "no such thread")) }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            return .response(.json(200, try await self.pullRequests.ciFailures(root: repo.root, branch: repo.detached ? nil : repo.branch)))
        }
        router.get("/api/threads/:tid/code/pr/comments") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else { return .response(.error(404, "no such thread")) }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            return .response(.json(200, try await self.pullRequests.comments(root: repo.root, branch: repo.detached ? nil : repo.branch)))
        }
        router.get("/api/projects") { request in
            .response(.json(200, ["projects": .array(ProjectStore(harness: request.harness).all.map(JSON.object))]))
        }
        router.post("/api/projects") { request in
            let project = try ProjectStore(harness: request.harness).create(try request.http.json())
            return .response(.json(201, ["project": .object(project)]))
        }
        router.patch("/api/projects/:id") { request in
            let project = try ProjectStore(harness: request.harness).update(request.params["id"] ?? "", try request.http.json())
            return .response(.json(200, ["project": .object(project)]))
        }
        router.delete("/api/projects/:id") { request in
            try ProjectStore(harness: request.harness).delete(request.params["id"] ?? "")
            return .response(.json(200, ["ok": true]))
        }
        router.get("/api/fs/dirs") { request in
            .response(try FolderBrowser.list(path: request.http.query["path"], hidden: request.http.query["hidden"] == "1"))
        }
        router.get("/api/threads/:tid/git") { request in
            guard let roots = ThreadFiles.roots(request.harness.store, request.harness.paths, threadId: request.params["tid"] ?? "") else {
                return .response(.error(404, "no such thread"))
            }
            return .response(.json(200, await ThreadGit.wire(folder: roots.first)))
        }
        router.get("/api/threads/:tid/git/branches") { request in
            guard let folder = ThreadFiles.roots(request.harness.store, request.harness.paths, threadId: request.params["tid"] ?? "")?.first else {
                return .response(.error(404, "no such thread"))
            }
            return .response(.json(200, ["branches": .array(try await ThreadGit.branches(folder: folder))]))
        }
        router.post("/api/threads/:tid/git/branch") { request in
            let harness = request.harness
            let threadId = request.params["tid"] ?? ""
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: threadId)?.first else {
                return .response(.error(404, "no such thread"))
            }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard !ThreadGit.botWorking(in: repo.root, harness: harness, threadId: threadId) else {
                return .response(.error(409, "a bot is working — let it finish before switching branches"))
            }
            guard let name = try request.http.json()["name"]?.string else { return .response(.error(400, "name is required")) }
            try await ThreadGit.createBranch(folder: folder, name: name)
            return .response(.json(200, await ThreadGit.wire(folder: folder)))
        }
        router.post("/api/threads/:tid/git/fetch") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else {
                return .response(.error(404, "no such thread"))
            }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard (await GitRun.text(["remote"], in: repo.root)).map({ !$0.isEmpty }) == true else { return .response(.error(409, "this repository has no remote")) }
            // only the remote-tracking refs move: the working tree and the branch are not touched, so a bot may be working
            guard let output = await GitRun.git(["fetch", "--prune"], in: repo.root, timeout: 120) else { return .response(.error(504, "git fetch did not complete")) }
            guard output.ok else { return .response(.error(409, GitRun.said(output))) }
            self.pullRequests.forget(root: repo.root)
            return .response(.json(200, await ThreadGit.wire(folder: folder)))
        }
        router.post("/api/threads/:tid/git/pull") { request in
            let harness = request.harness
            let threadId = request.params["tid"] ?? ""
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: threadId)?.first else {
                return .response(.error(404, "no such thread"))
            }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard !repo.detached else { return .response(.error(400, "a detached HEAD has nothing to pull")) }
            guard !ThreadGit.botWorking(in: repo.root, harness: harness, threadId: threadId) else {
                return .response(.error(409, "a bot is working — let it finish before pulling"))
            }
            guard (await GitRun.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo.root))?.ok == true else {
                return .response(.error(400, "this branch follows no remote branch: push it first"))
            }
            // fast-forward only: a pull that would merge or rebase is the person's to decide, in a terminal
            guard let output = await GitRun.git(["pull", "--ff-only"], in: repo.root, timeout: 180) else { return .response(.error(504, "git pull did not complete")) }
            guard output.ok else { return .response(.error(409, GitRun.said(output))) }
            self.pullRequests.forget(root: repo.root)
            return .response(.json(200, await ThreadGit.wire(folder: folder)))
        }
        router.post("/api/threads/:tid/git/push") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else {
                return .response(.error(404, "no such thread"))
            }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard !repo.detached else { return .response(.error(400, "a detached HEAD cannot be pushed")) }
            // the working tree is not touched, so a bot may be working; what is pushed is what is committed
            try await CodeCommit.push(root: repo.root, branch: repo.branch)
            self.pullRequests.forget(root: repo.root)
            return .response(.json(200, await ThreadGit.wire(folder: folder)))
        }
        router.get("/api/threads/:tid/git/diff") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else {
                return .response(.error(404, "no such thread"))
            }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            let result = try await GitDiff.diff(root: repo.root, path: request.http.query["path"])
            var answer: JSONObject = ["diff": .string(result.diff), "truncated": .bool(result.truncated), "binary": .bool(result.binary)]
            answer["path"] = result.path.map { .string($0) } ?? .null
            return .response(.json(200, .object(answer)))
        }
        router.post("/api/threads/:tid/git/commit-message") { request in
            let harness = request.harness
            let threadId = request.params["tid"] ?? ""
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: threadId)?.first else {
                return .response(.error(404, "no such thread"))
            }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            let message = try await CommitMessage.generate(harness: harness, threadId: threadId, root: repo.root)
            return .response(.json(200, ["message": .string(message)]))
        }
        router.post("/api/threads/:tid/git/commit") { request in
            let harness = request.harness
            let threadId = request.params["tid"] ?? ""
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: threadId)?.first else {
                return .response(.error(404, "no such thread"))
            }
            let parsed = try CodeCommit.parse(try request.http.json())
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard !ThreadGit.botWorking(in: repo.root, harness: harness, threadId: threadId) else {
                return .response(.error(409, "a bot is working — let it finish before committing"))
            }
            let result = try await CodeCommit.run(folder: folder, request: parsed)
            self.pullRequests.forget(root: repo.root)
            return .response(.json(200, result))
        }
        router.get("/api/threads/:tid/files") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else {
                return .response(.error(404, "no such thread"))
            }
            let repo = try await ThreadGit.inspect(folder: folder)
            let base = repo?.root ?? folder
            let listed = await CodeFiles.list(folder: base, root: repo?.root)
            let changed = (repo?.changes ?? []).map(\.path)
            let limit = min(max(Int(request.http.query["limit"] ?? "") ?? CodeFiles.limit, 1), 200)
            let ranked = CodeFiles.rank(listed, query: request.http.query["q"] ?? "", preferred: changed, limit: limit)
            let files: [JSON] = ranked.map { relative in
                ["path": .string((base as NSString).appendingPathComponent(relative)), "relative": .string(relative),
                 "name": .string((relative as NSString).lastPathComponent)]
            }
            return .response(.json(200, ["files": .array(files)]))
        }
        router.get("/api/code/settings") { request in
            .response(.json(200, CodeSettings(harness: request.harness).wire))
        }
        router.put("/api/code/settings") { request in
            try CodeSettings(harness: request.harness).update(try request.http.json(), harness: request.harness)
            return .response(.json(200, CodeSettings(harness: request.harness).wire))
        }
        router.get("/api/threads/:tid/resume-command") { request in
            .response(.json(200, ResumeCommand.wire(harness: request.harness, threadId: request.params["tid"] ?? "")))
        }
        router.post("/api/threads/:tid/git/checkout") { request in
            let harness = request.harness
            let threadId = request.params["tid"] ?? ""
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: threadId)?.first else {
                return .response(.error(404, "no such thread"))
            }
            guard let repo = try await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard !ThreadGit.botWorking(in: repo.root, harness: harness, threadId: threadId) else {
                return .response(.error(409, "a bot is working — let it finish before switching branches"))
            }
            guard let ref = try request.http.json()["ref"]?.string else { return .response(.error(400, "ref is required")) }
            try await ThreadGit.checkout(folder: folder, ref: ref)
            return .response(.json(200, await ThreadGit.wire(folder: folder)))
        }
    }

    public func stop(_ harness: Harness) {
        scripts.stopAll()
        reviews.stopAll()
    }
}
