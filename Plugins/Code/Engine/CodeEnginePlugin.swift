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
    public nonisolated init() {}

    public nonisolated var id: String { "code" }
    public nonisolated var name: String { "Code" }
    public nonisolated var version: String { "1.0.0" }
    public nonisolated var botFlags: [String] { ["codeMode"] }

    public func routes(_ router: PluginRouter) {
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
            guard let repo = await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard !ThreadGit.botWorking(in: repo.root, harness: harness, threadId: threadId) else {
                return .response(.error(409, "a bot is working — let it finish before switching branches"))
            }
            guard let name = try request.http.json()["name"]?.string else { return .response(.error(400, "name is required")) }
            try await ThreadGit.createBranch(folder: folder, name: name)
            return .response(.json(200, await ThreadGit.wire(folder: folder)))
        }
        router.get("/api/threads/:tid/git/diff") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else {
                return .response(.error(404, "no such thread"))
            }
            guard let repo = await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
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
            guard let repo = await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
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
            guard let repo = await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard !ThreadGit.botWorking(in: repo.root, harness: harness, threadId: threadId) else {
                return .response(.error(409, "a bot is working — let it finish before committing"))
            }
            return .response(.json(200, try await CodeCommit.run(folder: folder, request: parsed)))
        }
        router.get("/api/threads/:tid/files") { request in
            let harness = request.harness
            guard let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: request.params["tid"] ?? "")?.first else {
                return .response(.error(404, "no such thread"))
            }
            let repo = await ThreadGit.inspect(folder: folder)
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
            guard let repo = await ThreadGit.inspect(folder: folder) else { return .response(.error(400, "not a git repository")) }
            guard !ThreadGit.botWorking(in: repo.root, harness: harness, threadId: threadId) else {
                return .response(.error(409, "a bot is working — let it finish before switching branches"))
            }
            guard let ref = try request.http.json()["ref"]?.string else { return .response(.error(400, "ref is required")) }
            try await ThreadGit.checkout(folder: folder, ref: ref)
            return .response(.json(200, await ThreadGit.wire(folder: folder)))
        }
    }
}
