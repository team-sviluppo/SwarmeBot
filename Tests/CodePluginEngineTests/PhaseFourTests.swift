@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

/// Plan / Execute, a review by another bot, and the pull request with its CI.
@MainActor
final class PhaseFourTests: XCTestCase {
    private let done: RuntimeEvent.Body = .turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil)

    override func tearDown() async throws {
        CodePullRequests.executable = "gh"
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertTrue(condition(), what)
    }

    private func repoWithModel(_ script: @escaping (SendTurnInput, (RuntimeEvent.Body, String?) -> Void) -> Void) async throws -> (RepoFixture, FakeAdapter) {
        let adapter = FakeAdapter(driverKind: "claudeAgent")
        adapter.script = script
        let repo = try await RepoFixture(drivers: [FakeDriver(driverKind: "claudeAgent", adapter: adapter)], boot: true)
        try repo.initRepo()
        let selection: JSON = ["instanceId": "claude", "model": "fake-1"]
        repo.harness.store.patchBot(repo.botId, ["modelSelection": selection])
        return (repo, adapter)
    }

    /// A second bot on the same fake model, which is the reviewer.
    private func reviewer(_ repo: RepoFixture, name: String = "Revisore") -> String {
        let bot = repo.harness.store.createBot(seedMessages: false)
        let id = bot["id"]!.string!
        let selection: JSON = ["instanceId": "claude", "model": "fake-2"]
        repo.harness.store.patchBot(id, ["modelSelection": selection, "name": .string(name)])
        return id
    }

    // MARK: plan mode

    func testAChatStartsInExecuteModeAndKeepsTheModeItIsGiven() async throws {
        let repo = try await RepoFixture()
        let start = await repo.call("GET", "code/mode")
        XCTAssertEqual(start.json?["mode"], "execute")
        let plan = await repo.call("PUT", "code/mode", body: ["mode": "plan"])
        XCTAssertEqual(plan.status, 200)
        XCTAssertEqual(plan.json?["mode"], "plan")
        let again = await repo.call("GET", "code/mode")
        XCTAssertEqual(again.json?["mode"], "plan")
        let stored = try Data(contentsOf: repo.paths.root.appendingPathComponent("plugins/code/modes.json"))
        XCTAssertEqual(try JSON.parse(stored)[repo.threadId], "plan")
        _ = await repo.call("PUT", "code/mode", body: ["mode": "execute"])
        let cleared = try Data(contentsOf: repo.paths.root.appendingPathComponent("plugins/code/modes.json"))
        XCTAssertNil(try JSON.parse(cleared)[repo.threadId], "execute is the absence of an entry")
        for body: JSON in [["mode": "dream"], ["mode": 1], [:]] {
            let refused = await repo.call("PUT", "code/mode", body: body)
            XCTAssertEqual(refused.status, 400, String(describing: body))
        }
        let unknown = await repo.callRaw("GET", "/api/threads/nope/code/mode")
        XCTAssertEqual(unknown.status, 404)
        let unknownPut = await repo.callRaw("PUT", "/api/threads/nope/code/mode", body: ["mode": "plan"])
        XCTAssertEqual(unknownPut.status, 404)
    }

    func testPlanModeTellsTheAgentAndLocksTheFolderForTheTurnAfterIt() async throws {
        let (repo, adapter) = try await repoWithModel { input, emit in
            emit(.turnStarted, nil)
            emit(.requestOpened(requestType: "permission", tool: "Edit", summary: #"{"file_path":"\#(ReadOnlyGuard.canonical(input.cwd ?? ""))/a.txt"}"#, choices: nil, multiSelect: nil, approvalScope: nil), "req-plan")
            emit(.textCompleted(text: "the plan"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        _ = await repo.call("PUT", "code/mode", body: ["mode": "plan"])
        try repo.harness.startTurn(botId: repo.botId, text: "add a login")
        try await eventually("the turn reaches the provider") { !adapter.received.isEmpty }
        let planned = try XCTUnwrap(adapter.received.first)
        XCTAssertTrue(planned.system?.contains("PLAN MODE") == true)
        XCTAssertEqual(planned.readOnlyFolders, [ReadOnlyGuard.canonical(repo.folder.path)], "the chat's own folder is linked read-only")
        try await eventually("the write is refused") { !adapter.denied.isEmpty }
        XCTAssertEqual(adapter.denied, ["req-plan"])
        try await eventually("the turn settles") { !Store.isBusy(repo.harness.store.bot(repo.botId)) }

        // back to Execute, the next turn is the usual one
        _ = await repo.call("PUT", "code/mode", body: ["mode": "execute"])
        adapter.script = { _, emit in
            emit(.turnStarted, nil)
            emit(.textCompleted(text: "done"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        try repo.harness.startTurn(botId: repo.botId, text: "go ahead")
        try await eventually("the second turn reaches the provider") { adapter.received.count == 2 }
        XCTAssertFalse(adapter.received[1].system?.contains("PLAN MODE") == true)
        XCTAssertTrue(adapter.received[1].readOnlyFolders.isEmpty)
    }

    func testAChannelFollowsItsOwnMode() async throws {
        let (repo, adapter) = try await repoWithModel { _, emit in
            emit(.turnStarted, nil)
            emit(.textCompleted(text: "ok"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        let group = repo.harness.store.createGroup(name: "Team", memberIds: [repo.botId])
        let groupThread = group["threadId"]!.string!
        _ = await repo.callRaw("PUT", "/api/threads/\(groupThread)/code/mode", body: ["mode": "plan"])
        let own = await repo.call("GET", "code/mode")
        XCTAssertEqual(own.json?["mode"], "execute", "the bot's own chat is not the channel's")
        var setup = TurnSetup(botId: repo.botId, threadId: groupThread, groupId: group["id"]?.string, driverKind: "claudeAgent",
                              bot: repo.harness.store.bot(repo.botId)!, group: group, cwd: repo.folder.path)
        setup.harness = repo.harness
        repo.harness.plugins.beforeTurn(&setup)
        XCTAssertTrue(setup.system.contains("PLAN MODE"))
        XCTAssertEqual(setup.readOnlyFolders, [ReadOnlyGuard.canonical(repo.folder.path)])
        XCTAssertTrue(adapter.received.isEmpty)
    }

    // MARK: review by another bot

    func testAnotherBotReviewsTheDiffAndTheReviewLandsInTheChat() async throws {
        let (repo, adapter) = try await repoWithModel { _, emit in
            emit(.turnStarted, nil)
            emit(.textCompleted(text: "Verdict: needs work\n\n`a.txt:1` — the value is hard-coded — read it from config"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        try repo.write("a.txt", "two\n")
        let reviewerId = reviewer(repo)
        let reviewerMain = repo.harness.store.bot(reviewerId)!["threadId"]!.string!

        let started = await repo.call("POST", "code/review", body: ["botId": .string(reviewerId)])
        XCTAssertEqual(started.status, 202, String(describing: started.json))
        XCTAssertEqual(started.json?["review"]?["status"], "running")
        XCTAssertEqual(started.json?["review"]?["scope"], "changes")
        XCTAssertEqual(started.json?["review"]?["reviewerName"], "Revisore")

        try await eventually("the review lands in the chat") {
            repo.harness.store.messages(repo.threadId).contains { $0["review"] != nil }
        }
        let message = try XCTUnwrap(repo.harness.store.messages(repo.threadId).first { $0["review"] != nil })
        XCTAssertEqual(message["role"], "bot")
        XCTAssertEqual(message["kind"], "text")
        XCTAssertEqual(message["from"]?["name"], "Revisore")
        XCTAssertEqual(message["from"]?["botId"]?.string, reviewerId)
        XCTAssertEqual(message["review"]?["applied"], false)
        XCTAssertTrue(message["text"]?.string?.contains("Verdict: needs work") == true)

        let input = try XCTUnwrap(adapter.received.first)
        XCTAssertTrue(input.text.contains("+two") && input.text.contains("-one") && input.text.contains("- a.txt"), "the diff and the files are in the request")
        XCTAssertTrue(input.text.contains("code review"))
        XCTAssertEqual(input.readOnlyFolders, [ReadOnlyGuard.canonical(repo.folder.path)], "the repository is the reviewer's to read, not to change")
        XCTAssertTrue(input.system?.contains("Do not change anything") == true)
        XCTAssertNotEqual(input.threadId, reviewerMain, "a task of its own: the reviewer's main chat stays as it was")
        XCTAssertEqual(repo.harness.store.bot(reviewerId)?["threadId"]?.string, reviewerMain)
        XCTAssertEqual(repo.harness.store.bot(reviewerId)?["tasks"]?.array?.first?["title"]?.string?.hasPrefix("Review: "), true)
        XCTAssertNil(input.agents, "a peer's turn gets no tool to contact other bots")

        let status = await repo.call("GET", "code/review")
        XCTAssertEqual(status.json?["review"]?["status"], "done")
        XCTAssertEqual(status.json?["review"]?["messageId"], message["id"])
        XCTAssertEqual(adapter.received.count, 1)
        // the reviewer's role in the turn is gone once it ends
        var later = TurnSetup(botId: reviewerId, threadId: input.threadId, groupId: nil, driverKind: "claudeAgent", bot: repo.harness.store.bot(reviewerId)!, group: nil, cwd: nil)
        later.harness = repo.harness
        repo.harness.plugins.beforeTurn(&later)
        XCTAssertTrue(later.readOnlyFolders.isEmpty)
    }

    func testApplyIsOfferedOnce() async throws {
        let (repo, _) = try await repoWithModel { _, emit in
            emit(.textCompleted(text: "Looks fine"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        try repo.write("a.txt", "two\n")
        let reviewerId = reviewer(repo)
        _ = await repo.call("POST", "code/review", body: ["botId": .string(reviewerId)])
        try await eventually("the review lands") { repo.harness.store.messages(repo.threadId).contains { $0["review"] != nil } }
        let id = try XCTUnwrap(repo.harness.store.messages(repo.threadId).first { $0["review"] != nil }?["id"]?.string)
        let applied = await repo.call("POST", "code/review/applied", body: ["messageId": .string(id)])
        XCTAssertEqual(applied.status, 200)
        let now = try XCTUnwrap(repo.harness.store.messages(repo.threadId).first { $0["id"]?.string == id })
        XCTAssertEqual(now["review"]?["applied"], true)
        XCTAssertEqual(now["from"]?["name"], "Revisore", "the rest of the message is kept")
        let unknown = await repo.call("POST", "code/review/applied", body: ["messageId": "nope"])
        XCTAssertEqual(unknown.status, 404)
        let plain = repo.harness.store.appendMessage(repo.threadId, ["role": "bot", "kind": "text", "text": "no review"])
        let notAReview = await repo.call("POST", "code/review/applied", body: ["messageId": .string(plain["id"]!.string!)])
        XCTAssertEqual(notAReview.status, 404, "only a review can be marked")
        let missing = await repo.call("POST", "code/review/applied", body: [:])
        XCTAssertEqual(missing.status, 400)
    }

    func testAReviewIsRefusedWhenItCannotWork() async throws {
        let (repo, _) = try await repoWithModel { _, emit in emit(.turnStarted, nil) }
        let reviewerId = reviewer(repo)
        let clean = await repo.call("POST", "code/review", body: ["botId": .string(reviewerId)])
        XCTAssertEqual(clean.status, 400, "nothing to review: \(String(describing: clean.json))")
        try repo.write("a.txt", "two\n")
        let own = await repo.call("POST", "code/review", body: ["botId": .string(repo.botId)])
        XCTAssertEqual(own.status, 400, "a bot does not review its own chat")
        let nobody = await repo.call("POST", "code/review", body: ["botId": "ghost"])
        XCTAssertEqual(nobody.status, 404)
        let blank = await repo.call("POST", "code/review", body: [:])
        XCTAssertEqual(blank.status, 400)
        repo.harness.store.patchBot(reviewerId, ["busy": true])
        let busy = await repo.call("POST", "code/review", body: ["botId": .string(reviewerId)])
        XCTAssertEqual(busy.status, 409)
        XCTAssertTrue(busy.json?["error"]?.string?.contains("working") == true)
        let folder = try await RepoFixture()
        let notRepo = await folder.call("POST", "code/review", body: ["botId": .string(reviewer(folder))])
        XCTAssertEqual(notRepo.status, 400)
        let unknown = await repo.callRaw("POST", "/api/threads/nope/code/review", body: ["botId": .string(reviewerId)])
        XCTAssertEqual(unknown.status, 404)
    }

    func testOnlyOneReviewRunsAtATimeAndItCanBeStopped() async throws {
        let (repo, adapter) = try await repoWithModel { _, emit in emit(.turnStarted, nil) }   // never answers
        try repo.write("a.txt", "two\n")
        let first = reviewer(repo, name: "Uno")
        let second = reviewer(repo, name: "Due")
        var interrupted: [String] = []
        adapter.onInterrupt = { interrupted.append($0) }
        let started = await repo.call("POST", "code/review", body: ["botId": .string(first)])
        XCTAssertEqual(started.status, 202)
        let again = await repo.call("POST", "code/review", body: ["botId": .string(second)])
        XCTAssertEqual(again.status, 409, "one review at a time for a chat")

        let cancelled = await repo.call("DELETE", "code/review")
        XCTAssertEqual(cancelled.json?["cancelled"], true)
        let status = await repo.call("GET", "code/review")
        XCTAssertEqual(status.json?["review"]?["status"], "cancelled")
        try await eventually("the reviewer's turn was interrupted") { !interrupted.isEmpty }
        XCTAssertEqual(interrupted.first, started.json?["review"]?["reviewerThread"]?.string)
        XCTAssertFalse(repo.harness.store.messages(repo.threadId).contains { $0["review"] != nil }, "nothing lands for a review that was stopped")
        let nothing = await repo.call("DELETE", "code/review")
        XCTAssertEqual(nothing.json?["cancelled"], false)
    }

    func testAFailedReviewSaysSoInTheChat() async throws {
        let (repo, _) = try await repoWithModel { _, emit in emit(.runtimeError(message: "model is down", setup: nil), nil) }
        try repo.write("a.txt", "two\n")
        let reviewerId = reviewer(repo)
        _ = await repo.call("POST", "code/review", body: ["botId": .string(reviewerId)])
        try await eventually("the failure is reported") {
            repo.harness.store.messages(repo.threadId).contains { $0["tool"]?["name"]?.string?.contains("the review by @Revisore failed") == true }
        }
        let status = await repo.call("GET", "code/review")
        XCTAssertEqual(status.json?["review"]?["status"], "failed")
        XCTAssertTrue(status.json?["review"]?["error"]?.string?.contains("model is down") == true)
        XCTAssertFalse(repo.harness.store.messages(repo.threadId).contains { $0["review"] != nil })
        // and a turn with no text is no review
        let (empty, _) = try await repoWithModel { _, emit in emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil) }
        try empty.write("a.txt", "two\n")
        _ = await empty.call("POST", "code/review", body: ["botId": .string(reviewer(empty))])
        try await eventually("an empty reply fails") {
            let state = empty.harness.store.messages(empty.threadId)
            return state.contains { $0["tool"]?["name"]?.string?.contains("failed") == true }
        }
    }

    func testAfterAPushTheReviewReadsTheBranchAgainstItsBase() async throws {
        let (repo, adapter) = try await repoWithModel { _, emit in
            emit(.textCompleted(text: "fine"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        try repo.git("checkout", "-q", "-b", "feature")
        try repo.write("b.txt", "new file\n")
        try repo.git("add", ".")
        try repo.git("commit", "-qm", "Add b")
        let answer = await repo.call("POST", "code/review", body: ["botId": .string(reviewer(repo))])
        XCTAssertEqual(answer.status, 202, String(describing: answer.json))
        XCTAssertEqual(answer.json?["review"]?["scope"], "branch")
        XCTAssertEqual(answer.json?["review"]?["branch"], "feature")
        try await eventually("the reviewer is asked") { !adapter.received.isEmpty }
        let text = try XCTUnwrap(adapter.received.first?.text)
        XCTAssertTrue(text.contains("+new file") && text.contains("- b.txt") && text.contains("branch feature"), text)
    }

    func testThePromptCutsAHugeDiff() {
        let prompt = CodeReviews.prompt(root: "/r", branch: nil, files: ["a"], diff: String(repeating: "x", count: CodeReviews.promptLimit + 500), truncated: false)
        XCTAssertTrue(prompt.contains("the diff is cut here"))
        XCTAssertLessThan(prompt.count, CodeReviews.promptLimit + 2_000)
        XCTAssertFalse(CodeReviews.prompt(root: "/r", branch: "b", files: ["a"], diff: "small", truncated: false).contains("cut here"))
    }

    // MARK: pull request and CI

    /// A `gh` that answers from canned files next to it, and writes down what it was asked.
    private func fakeGh(_ repo: RepoFixture, pr: String? = nil, discussion: String = #"{"comments":[],"reviews":[]}"#, threads: String = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}"#,
                        logs: [String: String] = [:], noPR: Bool = false, signedOut: Bool = false) throws -> (calls: URL, run: () -> [String]) {
        let dir = repo.paths.root.appendingPathComponent("fake-gh", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((pr ?? "{}").utf8).write(to: dir.appendingPathComponent("pr.json"))
        try Data(discussion.utf8).write(to: dir.appendingPathComponent("discussion.json"))
        try Data(threads.utf8).write(to: dir.appendingPathComponent("threads.json"))
        for (run, log) in logs { try Data(log.utf8).write(to: dir.appendingPathComponent("log-\(run).txt")) }
        let script = """
            #!/bin/sh
            d=$(dirname "$0")
            echo "$*" >> "$d/calls.log"
            case "$1 $2" in
              "--version "*) echo "gh version test"; exit 0;;
            esac
            \(signedOut ? #"echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4"# : "")
            case "$1 $2 $3" in
              "pr view --json") \(noPR ? #"echo 'no pull requests found for branch "main"' >&2; exit 1"# : #"cat "$d/pr.json"; exit 0"#);;
              "pr view 7") cat "$d/discussion.json"; exit 0;;
              "api graphql -F") cat "$d/threads.json"; exit 0;;
              "run view "*) cat "$d/log-$3.txt"; exit 0;;
            esac
            case "$1 $2" in
              "run view") cat "$d/log-$3.txt" 2>/dev/null; exit 0;;
            esac
            echo "unexpected: $*" >&2
            exit 2
            """
        let path = dir.appendingPathComponent("gh")
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        CodePullRequests.executable = path.path
        let calls = dir.appendingPathComponent("calls.log")
        return (calls, { ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) })
    }

    private static let failingPR = """
        {"number":7,"url":"https://github.com/o/r/pull/7","title":"Add login","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED",\
        "reviewDecision":"CHANGES_REQUESTED","headRefName":"feature","baseRefName":"main","author":{"login":"me"},\
        "comments":[{"author":{"login":"bob"},"body":"nice"}],"reviews":[{"author":{"login":"amy"},"body":"please add tests","state":"CHANGES_REQUESTED"},{"author":{"login":"zed"},"body":"","state":"APPROVED"}],\
        "statusCheckRollup":[\
        {"__typename":"CheckRun","name":"build","workflowName":"CI","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/111/job/1"},\
        {"__typename":"CheckRun","name":"test","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/111/job/2"},\
        {"__typename":"CheckRun","name":"lint","workflowName":"CI","status":"COMPLETED","conclusion":"TIMED_OUT","detailsUrl":"https://github.com/o/r/actions/runs/111/job/3"},\
        {"__typename":"CheckRun","name":"e2e","workflowName":"Nightly","status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://github.com/o/r/actions/runs/222/job/4"},\
        {"__typename":"CheckRun","name":"docs","workflowName":"Docs","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":"https://github.com/o/r/actions/runs/333/job/5"},\
        {"__typename":"StatusContext","context":"deploy/preview","state":"FAILURE","targetUrl":"https://preview.example/1"}]}
        """

    func testThePullRequestAndItsChecksAreFoldedForTheApp() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        _ = try fakeGh(repo, pr: Self.failingPR)
        let answer = await repo.call("GET", "code/pr")
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        XCTAssertEqual(answer.json?["available"], true)
        let pr = try XCTUnwrap(answer.json?["pr"])
        XCTAssertEqual(pr["number"], 7)
        XCTAssertEqual(pr["state"], "open")
        XCTAssertEqual(pr["draft"], false)
        XCTAssertEqual(pr["head"], "feature")
        XCTAssertEqual(pr["base"], "main")
        XCTAssertEqual(pr["merge"], "blocked")
        XCTAssertEqual(pr["reviewDecision"], "changes_requested")
        XCTAssertEqual(pr["author"], "me")
        XCTAssertEqual(pr["comments"], 2, "a discussion comment and a review that says something; an empty approval is not a comment")
        let checks = try XCTUnwrap(pr["checks"])
        XCTAssertEqual(checks["state"], "failure")
        XCTAssertEqual(checks["total"], 6)
        XCTAssertEqual(checks["passed"], 1)
        XCTAssertEqual(checks["failed"], 3, "a failure, a timeout and a failed status")
        XCTAssertEqual(checks["pending"], 1)
        let items = checks["items"]?.array ?? []
        XCTAssertEqual(items.map { $0["state"]?.string }, ["success", "failure", "failure", "pending", "skipped", "failure"])
        XCTAssertEqual(items[1]["workflow"], "CI")
        XCTAssertEqual(items[5]["name"], "deploy/preview")
        XCTAssertEqual(items[5]["url"], "https://preview.example/1")
    }

    func testChecksFoldIntoOneState() {
        func overall(_ items: [JSON]) -> String? {
            CodePullRequests.pullRequest(from: ["number": 1, "statusCheckRollup": .array(items)])["checks"]?["state"]?.string
        }
        let ok: JSON = ["__typename": "CheckRun", "name": "a", "status": "COMPLETED", "conclusion": "SUCCESS"]
        let running: JSON = ["__typename": "CheckRun", "name": "b", "status": "QUEUED", "conclusion": ""]
        let bad: JSON = ["__typename": "CheckRun", "name": "c", "status": "COMPLETED", "conclusion": "CANCELLED"]
        XCTAssertEqual(overall([]), "none")
        XCTAssertEqual(overall([ok]), "success")
        XCTAssertEqual(overall([ok, running]), "pending")
        XCTAssertEqual(overall([ok, running, bad]), "failure", "a failure outweighs one still running")
        XCTAssertEqual(overall([["__typename": "StatusContext", "context": "x", "state": "PENDING"]]), "pending")
        XCTAssertEqual(overall([["__typename": "StatusContext", "context": "x", "state": "ERROR"]]), "failure")
        XCTAssertEqual(overall([["__typename": "CheckRun", "name": "s", "status": "COMPLETED", "conclusion": "NEUTRAL"]]), "success", "skipped checks do not stop a pass")
    }

    func testABranchWithoutAPullRequestHasNone() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        _ = try fakeGh(repo, noPR: true)
        let answer = await repo.call("GET", "code/pr")
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        XCTAssertEqual(answer.json?["available"], true)
        XCTAssertEqual(answer.json?["pr"], .null)
        let ci = await repo.call("GET", "code/pr/ci-failures")
        XCTAssertEqual(ci.status, 404)
        let comments = await repo.call("GET", "code/pr/comments")
        XCTAssertEqual(comments.status, 404)
    }

    func testWithoutGhOrNotSignedInTheStateSaysWhy() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        CodePullRequests.executable = "/nonexistent/gh"
        let missing = await repo.call("GET", "code/pr")
        XCTAssertEqual(missing.status, 200)
        XCTAssertEqual(missing.json?["available"], false)
        XCTAssertTrue(missing.json?["reason"]?.string?.contains("not installed") == true)
        let ci = await repo.call("GET", "code/pr/ci-failures")
        XCTAssertEqual(ci.status, 400)

        _ = try fakeGh(repo, signedOut: true)
        let out = await repo.call("GET", "code/pr", query: ["refresh": "1"])
        XCTAssertEqual(out.json?["available"], false)
        XCTAssertTrue(out.json?["reason"]?.string?.contains("gh auth login") == true)
    }

    func testAnUnderstandableAnswerIsKeptForAFewSecondsAndRefreshedOnRequest() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        let gh = try fakeGh(repo, pr: Self.failingPR)
        _ = await repo.call("GET", "code/pr")
        _ = await repo.call("GET", "code/pr")
        XCTAssertEqual(gh.run().filter { $0.hasPrefix("pr view --json") }.count, 1, "the second window reads what the first asked")
        _ = await repo.call("GET", "code/pr", query: ["refresh": "1"])
        XCTAssertEqual(gh.run().filter { $0.hasPrefix("pr view --json") }.count, 2)
    }

    func testTheFailedChecksComeWithTheEndOfTheirLogsOncePerRun() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        let log = (1...300).map { "line \($0)" }.joined(separator: "\n") + "\nerror: expected 2 got 3"
        let gh = try fakeGh(repo, pr: Self.failingPR, logs: ["111": log])
        let answer = await repo.call("GET", "code/pr/ci-failures")
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        let message = try XCTUnwrap(answer.json?["message"]?.string)
        XCTAssertTrue(message.contains("pull request #7 (Add login) failed"), message)
        XCTAssertTrue(message.contains("### CI / test") && message.contains("### CI / lint") && message.contains("### deploy/preview"))
        XCTAssertTrue(message.contains("error: expected 2 got 3"), "the end of the log is there")
        XCTAssertFalse(message.contains("line 1\n"), "the start of a long log is not")
        XCTAssertTrue(message.contains("earlier lines left out"))
        XCTAssertTrue(message.contains("https://preview.example/1"), "a status with no log gives the link")
        XCTAssertTrue(message.contains("no log available for this check"))
        XCTAssertFalse(message.contains("### CI / build"), "what passed is not there")
        XCTAssertEqual(answer.json?["checks"], 3)
        XCTAssertEqual(gh.run().filter { $0.hasPrefix("run view") }, ["run view 111 --log-failed"], "two jobs of one run, one fetch")
    }

    func testNothingFailedMeansNothingToFix() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        let passing = #"{"number":8,"title":"x","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}"#
        _ = try fakeGh(repo, pr: passing)
        let answer = await repo.call("GET", "code/pr/ci-failures")
        XCTAssertEqual(answer.status, 404)
    }

    func testCommentsComeFromReviewsOpenThreadsAndTheDiscussion() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        let discussion = #"{"comments":[{"author":{"login":"bob"},"body":"nice work"}],"reviews":[{"author":{"login":"amy"},"body":"please add tests","state":"CHANGES_REQUESTED"},{"author":{"login":"zed"},"body":"","state":"APPROVED"}]}"#
        let threads = """
            {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[\
            {"isResolved":false,"isOutdated":false,"path":"src/a.swift","line":42,"comments":{"nodes":[{"author":{"login":"amy"},"body":"this can be nil"},{"author":{"login":"me"},"body":"why?"}]}},\
            {"isResolved":true,"isOutdated":false,"path":"src/b.swift","line":3,"comments":{"nodes":[{"author":{"login":"amy"},"body":"already fixed"}]}},\
            {"isResolved":false,"isOutdated":true,"path":"src/c.swift","line":null,"comments":{"nodes":[{"author":{"login":"cat"},"body":"rename this"}]}}]}}}}}
            """
        _ = try fakeGh(repo, pr: Self.failingPR, discussion: discussion, threads: threads)
        let answer = await repo.call("GET", "code/pr/comments")
        XCTAssertEqual(answer.status, 200, String(describing: answer.json))
        let message = try XCTUnwrap(answer.json?["message"]?.string)
        XCTAssertTrue(message.contains("pull request #7 (Add login)"))
        XCTAssertTrue(message.contains("- @amy (review, changes requested): please add tests"))
        XCTAssertTrue(message.contains("- on src/a.swift:42: @amy: this can be nil → @me: why?"))
        XCTAssertTrue(message.contains("- on src/c.swift (the code has changed since): @cat: rename this"))
        XCTAssertTrue(message.contains("- @bob (comment): nice work"))
        XCTAssertFalse(message.contains("already fixed"), "a conversation that is resolved is not brought back")
        XCTAssertFalse(message.contains("@zed"), "an approval with nothing to say")
        XCTAssertEqual(answer.json?["count"], 4)
    }

    func testNoCommentsIsNotAMessage() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        _ = try fakeGh(repo, pr: Self.failingPR)
        let answer = await repo.call("GET", "code/pr/comments")
        XCTAssertEqual(answer.status, 404)
    }

    func testRunIdsAndLogTailsAndABudget() {
        XCTAssertEqual(CodePullRequests.runId(from: "https://github.com/o/r/actions/runs/9876/job/5"), "9876")
        XCTAssertNil(CodePullRequests.runId(from: "https://preview.example/1"))
        XCTAssertEqual(CodePullRequests.tail("a\nb\nc", lines: 2), "[… 1 earlier lines left out]\nb\nc")
        XCTAssertEqual(CodePullRequests.tail("a\nb", lines: 5), "a\nb")
        let failures = (1...40).map { (name: "job \($0)", url: Optional("https://x/\($0)"), log: Optional(String(repeating: "e", count: 2_000))) }
        let message = CodePullRequests.ciMessage(number: 1, title: nil, failures: failures)
        XCTAssertLessThan(message.count, CodePullRequests.logBudget + 4_000, "a pile of failures stays a message a model can read")
        XCTAssertTrue(message.contains("more failed checks left out"))
        XCTAssertTrue(message.hasSuffix("tell me what you changed."))
    }
}
