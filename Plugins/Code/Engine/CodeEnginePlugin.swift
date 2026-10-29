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
