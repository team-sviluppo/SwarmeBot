@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

/// Commit, push and the commit message: run by the engine, no agent involved.
@MainActor
final class CodeCommitTests: XCTestCase {
    private func commit(_ repo: RepoFixture, _ body: JSON) async -> (status: Int, json: JSON?) {
        await repo.call("POST", "git/commit", body: body)
    }

    // MARK: commit

    func testCommitsEveryChangeWithTheMessage() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        try repo.write("new.txt", "fresh\n")
        let answer = await commit(repo, ["message": "Change a\n\nAnd add new.", "mode": "commit"])
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        XCTAssertEqual(answer.json?["branch"], "main")
        XCTAssertEqual(answer.json?["pushed"], false)
        XCTAssertEqual(answer.json?["git"]?["changes"]?.array?.count, 0, "the working tree is clean")
        XCTAssertFalse((answer.json?["commit"]?.string ?? "").isEmpty)
        let log = try repo.git("log", "-1", "--format=%B")
        XCTAssertTrue(log.hasPrefix("Change a\n\nAnd add new."), log)
    }

    func testCommitsOnlyTheFilesChosen() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        try repo.write("keep.txt", "later\n")
        try repo.write("other.txt", "also later\n")
        let chosen = repo.folder.appendingPathComponent("a.txt").path
        let answer = await commit(repo, ["message": "Only a", "files": .array([.string(chosen)])])
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        XCTAssertEqual(try repo.git("show", "--name-only", "--format=", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), "a.txt")
        let left = (answer.json?["git"]?["changes"]?.array ?? []).compactMap { $0["name"]?.string }.sorted()
        XCTAssertEqual(left, ["keep.txt", "other.txt"], "what was not chosen stays changed")
    }

    func testADeletionCanBeCommitted() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try FileManager.default.removeItem(at: repo.folder.appendingPathComponent("a.txt"))
        let answer = await commit(repo, ["message": "Drop a", "files": ["a.txt"]])
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        XCTAssertEqual(try repo.git("show", "--name-status", "--format=", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), "D\ta.txt")
    }

    func testRefusesWhatCannotBeCommitted() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        let clean = await commit(repo, ["message": "x"])
        XCTAssertEqual(clean.status, 400, "nothing to commit")
        try repo.write("a.txt", "two\n")
        let refused: [(why: String, body: JSON)] = [
            ("empty message", ["message": "  "]), ("unknown mode", ["message": "x", "mode": "bogus"]),
            ("no file chosen", ["message": "x", "files": []]), ("outside the repository", ["message": "x", "files": ["/etc/passwd"]]),
            ("paths that are not strings", ["message": "x", "files": [1]]), ("no branch name", ["message": "x", "mode": "push-new-branch"]),
            ("no message", ["mode": "commit"]),
        ]
        for entry in refused {
            let answer = await commit(repo, entry.body)
            XCTAssertEqual(answer.status, 400, entry.why)
        }
        XCTAssertEqual(try repo.git("log", "--oneline").split(separator: "\n").count, 1, "nothing was committed by a refused request")
    }

    func testAFailingHookSaysWhyAndCommitsNothing() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        let hook = repo.folder.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho 'lint: trailing whitespace in a.txt' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try repo.write("a.txt", "two \n")
        let answer = await commit(repo, ["message": "Try"])
        XCTAssertEqual(answer.status, 409)
        XCTAssertTrue(answer.json?["error"]?.string?.contains("lint: trailing whitespace in a.txt") == true, String(describing: answer.json))
        XCTAssertEqual(try repo.git("log", "--oneline").split(separator: "\n").count, 1)
    }

    func testAWorkingBotBlocksTheCommit() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        repo.harness.store.patchBot(repo.botId, ["busy": true])
        let answer = await commit(repo, ["message": "x"])
        XCTAssertEqual(answer.status, 409)
        XCTAssertTrue(answer.json?["error"]?.string?.contains("a bot is working") == true)
        XCTAssertEqual(try repo.git("log", "--oneline").split(separator: "\n").count, 1)
    }

    func testAFolderThatIsNotARepoCannotCommit() async throws {
        let repo = try await RepoFixture()
        let answer = await commit(repo, ["message": "x"])
        XCTAssertEqual(answer.status, 400)
    }

    // MARK: push

    /// A bare repository standing in for the remote, and a clone of it as the chat's folder.
    private func repoWithRemote() async throws -> (RepoFixture, bare: URL) {
        let repo = try await RepoFixture()
        let bare = repo.paths.root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try repo.git("init", "-q", "--bare", "-b", "main", in: bare)
        try repo.initRepo()
        try repo.git("remote", "add", "origin", bare.path)
        return (repo, bare)
    }

    func testPushesAndSetsTheUpstreamTheFirstTime() async throws {
        let (repo, bare) = try await repoWithRemote()
        try repo.write("a.txt", "two\n")
        let first = await commit(repo, ["message": "One", "mode": "push"])
        XCTAssertEqual(first.status, 200, String(describing: first.json))
        XCTAssertEqual(first.json?["pushed"], true)
        XCTAssertEqual(try repo.git("rev-parse", "main", in: bare).trimmingCharacters(in: .whitespacesAndNewlines),
                       try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(try repo.git("rev-parse", "--abbrev-ref", "@{u}").trimmingCharacters(in: .whitespacesAndNewlines), "origin/main")
        // the second one has an upstream already: a plain push
        try repo.write("a.txt", "three\n")
        let second = await commit(repo, ["message": "Two", "mode": "push"])
        XCTAssertEqual(second.status, 200, String(describing: second.json))
        XCTAssertEqual(try repo.git("rev-parse", "main", in: bare).trimmingCharacters(in: .whitespacesAndNewlines),
                       try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testPushesToANewBranchAndLeavesMainAlone() async throws {
        let (repo, bare) = try await repoWithRemote()
        try repo.git("push", "-q", "-u", "origin", "main")
        let before = try repo.git("rev-parse", "main").trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.write("a.txt", "two\n")
        let answer = await commit(repo, ["message": "Feature", "mode": "push-new-branch", "branch": "feature/x"])
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        XCTAssertEqual(answer.json?["branch"], "feature/x")
        XCTAssertEqual(try repo.git("rev-parse", "main").trimmingCharacters(in: .whitespacesAndNewlines), before, "main did not move")
        XCTAssertEqual(try repo.git("rev-parse", "feature/x", in: bare).trimmingCharacters(in: .whitespacesAndNewlines),
                       try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testAPushThatFailsKeepsTheCommitAndSaysSo() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        let answer = await commit(repo, ["message": "No remote", "mode": "push"])
        XCTAssertEqual(answer.status, 409)
        let message = answer.json?["error"]?.string ?? ""
        XCTAssertTrue(message.contains("committed") && message.contains("push failed") && message.contains("no remote"), message)
        XCTAssertEqual(try repo.git("log", "--oneline").split(separator: "\n").count, 2, "the commit is there")
    }

    func testANewBranchNameThatExistsStopsBeforeCommitting() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        let answer = await commit(repo, ["message": "x", "mode": "push-new-branch", "branch": "main"])
        XCTAssertEqual(answer.status, 409)
        XCTAssertEqual(try repo.git("log", "--oneline").split(separator: "\n").count, 1)
    }

    func testAPullRequestTakesItsTextFromTheCommitMessage() {
        let request = CodeCommit.Request(message: "Add login\n\nUsers can sign in.\nSessions last a day.", files: nil, mode: .pullRequest)
        let text = CodeCommit.pullRequestText(request)
        XCTAssertEqual(text.title, "Add login")
        XCTAssertEqual(text.body, "Users can sign in.\nSessions last a day.")
        var custom = request
        custom.prTitle = "  Login  "
        custom.prBody = "Body"
        XCTAssertEqual(CodeCommit.pullRequestText(custom).title, "Login")
        XCTAssertEqual(CodeCommit.pullRequestText(custom).body, "Body")
        XCTAssertEqual(CodeCommit.pullRequestText(.init(message: "Only a subject", files: nil, mode: .pullRequest)).body, "")
    }

    // MARK: commit message

    private func repoWithModel(reply: @escaping (SendTurnInput, (RuntimeEvent.Body, String?) -> Void) -> Void) async throws -> (RepoFixture, FakeAdapter) {
        let adapter = FakeAdapter(driverKind: "claudeAgent")
        adapter.script = reply
        let repo = try await RepoFixture(drivers: [FakeDriver(driverKind: "claudeAgent", adapter: adapter)], boot: true)
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        let selection: JSON = ["instanceId": "claude", "model": "fake-1"]
        repo.harness.store.patchBot(repo.botId, ["modelSelection": selection])
        return (repo, adapter)
    }

    func testTheMessageIsWrittenByTheModelFromTheDiff() async throws {
        let (repo, adapter) = try await repoWithModel { _, emit in
            emit(.turnStarted, nil)
            emit(.textCompleted(text: "```\nUpdate a to two\n\nThe file said one.\n```"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        let answer = await repo.call("POST", "git/commit-message", body: [:])
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        XCTAssertEqual(answer.json?["message"], "Update a to two\n\nThe file said one.", "the code fence around it is gone")
        let input = try XCTUnwrap(adapter.received.first)
        XCTAssertTrue(input.text.contains("+two") && input.text.contains("-one") && input.text.contains("- a.txt"), "the diff and the files are in the prompt")
        XCTAssertTrue(input.text.contains("- first"), "the recent subjects are there to match their style")
        XCTAssertNotEqual(input.cwd, repo.folder.path, "the model does not run in the repository")
        XCTAssertTrue(input.system?.contains("Never use a tool") == true)
        XCTAssertNotEqual(input.threadId, repo.threadId, "not a turn of the chat")
        XCTAssertTrue(repo.harness.store.messages(repo.threadId).isEmpty, "and nothing lands in the chat")
        XCTAssertEqual(input.model, "fake-1")
    }

    func testAToolRequestIsDeniedWhileWritingTheMessage() async throws {
        let (repo, adapter) = try await repoWithModel { _, emit in
            emit(.requestOpened(requestType: "permission", tool: "Edit", summary: "edit a.txt", choices: nil, multiSelect: nil, approvalScope: nil), "req-1")
            emit(.textCompleted(text: "Message"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        let answer = await repo.call("POST", "git/commit-message", body: [:])
        XCTAssertEqual(answer.status, 200)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(adapter.denied, ["req-1"])
    }

    func testMessageFailuresAreSaid() async throws {
        let (failing, _) = try await repoWithModel { _, emit in emit(.runtimeError(message: "model is down", setup: nil), nil) }
        let down = await failing.call("POST", "git/commit-message", body: [:])
        XCTAssertEqual(down.status, 502)
        XCTAssertTrue(down.json?["error"]?.string?.contains("model is down") == true)

        let (empty, _) = try await repoWithModel { _, emit in emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil) }
        let nothing = await empty.call("POST", "git/commit-message", body: [:])
        XCTAssertEqual(nothing.status, 502, "a turn with no text is no message")

        let clean = try await RepoFixture()
        try clean.initRepo()
        let noChanges = await clean.call("POST", "git/commit-message", body: [:])
        XCTAssertEqual(noChanges.status, 400, "no changes, no message")

        let noModel = try await RepoFixture()
        try noModel.initRepo()
        try noModel.write("a.txt", "two\n")
        let noAsk = await noModel.call("POST", "git/commit-message", body: [:])
        XCTAssertEqual(noAsk.status, 409, "no model to ask")
    }

    func testTheModelSetForCommitsWinsOverTheBotsOwn() async throws {
        let (repo, adapter) = try await repoWithModel { _, emit in
            emit(.textCompleted(text: "Message"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        let empty = await repo.callRaw("GET", "/api/code/settings")
        XCTAssertEqual(empty.status, 200)
        XCTAssertEqual(empty.json?["commitModel"], .null)
        let set = await repo.callRaw("PUT", "/api/code/settings", body: ["commitModel": ["instanceId": "claude", "model": "fake-2"]])
        XCTAssertEqual(set.status, 200, String(describing: set.json))
        XCTAssertEqual(set.json?["commitModel"]?["model"], "fake-2")
        _ = await repo.call("POST", "git/commit-message", body: [:])
        XCTAssertEqual(adapter.received.last?.model, "fake-2")
        // cleared, the bot's own model is back
        _ = await repo.callRaw("PUT", "/api/code/settings", body: ["commitModel": .null])
        _ = await repo.call("POST", "git/commit-message", body: [:])
        XCTAssertEqual(adapter.received.last?.model, "fake-1")
    }

    func testTheSettingsRefuseAModelThatIsNotThere() async throws {
        let repo = try await RepoFixture()
        let unknown = await repo.callRaw("PUT", "/api/code/settings", body: ["commitModel": ["instanceId": "nope", "model": "x"]])
        XCTAssertEqual(unknown.status, 400)
        let form = HTTPRequest(method: "PUT", path: "/api/code/settings", query: [:], headers: [:], body: Data())
        guard case let .response(refused) = await repo.routes.handle(form) else { return XCTFail("not a response") }
        XCTAssertEqual(refused.status, 415)
    }

    func testMessagesAreCleanedOfWhatModelsWrapAroundThem() {
        XCTAssertEqual(CommitMessage.clean("\"Fix it\""), "Fix it")
        XCTAssertEqual(CommitMessage.clean("`Fix it`"), "Fix it")
        XCTAssertEqual(CommitMessage.clean("```text\nFix it\n\nBody\n```"), "Fix it\n\nBody")
        XCTAssertEqual(CommitMessage.clean("  Fix it  \n"), "Fix it")
        XCTAssertEqual(CommitMessage.clean("Fix \"it\" now"), "Fix \"it\" now", "quotes inside are the message's own")
    }

    func testThePromptCutsAHugeDiff() {
        let prompt = CommitMessage.prompt(diff: String(repeating: "+x\n", count: CommitMessage.promptLimit), files: ["a"], recent: [])
        XCTAssertTrue(prompt.contains("[diff cut here"))
        XCTAssertLessThan(prompt.count, CommitMessage.promptLimit + 500)
    }

    // MARK: resume command, positive path

    func testAClaudeChatWithASessionCanBeContinuedInTheTerminal() async throws {
        let (repo, _) = try await repoWithModel { _, _ in }
        let task = try XCTUnwrap(repo.harness.store.taskByThread(repo.botId, repo.threadId))
        XCTAssertNotNil(task["threadId"])
        repo.harness.store.setResumeCursor(repo.botId, instanceId: "claude", cursor: .string("sess-42"), threadId: repo.threadId)
        let answer = await repo.call("GET", "resume-command")
        XCTAssertEqual(answer.json?["supported"], true, String(describing: answer.json))
        XCTAssertEqual(answer.json?["tool"], "claude")
        let command = answer.json?["command"]?.string ?? ""
        XCTAssertTrue(command.hasSuffix("exec claude '--resume' 'sess-42'"), command)
        XCTAssertTrue(command.contains("cd -- '\(repo.folder.path)'"), command)
    }
}
