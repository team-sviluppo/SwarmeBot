@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

@MainActor
final class ProjectScriptTests: XCTestCase {
    private func configure(_ repo: RepoFixture, command: String) async throws {
        let made = await repo.callRaw("POST", "/api/projects", body: ["name": "Scripts", "repos": [["role": "backend", "path": .string(repo.folder.path),
            "scripts": [["name": "Test", "command": .string(command)]]]]])
        let id = made.json?["project"]?["id"]?.string ?? ""
        let set = await repo.callRaw("PATCH", "/api/bots/\(repo.botId)", body: ["plugins": ["code": ["projectId": .string(id), "role": "backend"]]])
        XCTAssertEqual(set.status, 200)
    }

    private func settled(_ repo: RepoFixture) async throws -> JSON? {
        for _ in 0..<100 {
            let status = await repo.call("GET", "code/scripts").json
            if status?["run"]?["running"] == false { return status?["run"] }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("script did not settle")
        return nil
    }

    func testScriptUsesTheEnginesFolderAndCapturesFailureOutput() async throws {
        let repo = try await RepoFixture()
        try await configure(repo, command: "pwd; echo 'failed test' >&2; exit 7")
        let start = await repo.call("POST", "code/scripts", body: ["index": 0])
        XCTAssertEqual(start.status, 202)
        let run = try await settled(repo)
        XCTAssertEqual(run?["exitCode"], 7)
        XCTAssertTrue(run?["output"]?.string?.contains("failed test") == true)
        XCTAssertTrue(run?["output"]?.string?.contains("/project") == true)
        XCTAssertEqual(run?["folder"], .string(repo.folder.path))
    }

    func testOnlyConfiguredScriptsCanRunAndOnlyOneAtATime() async throws {
        let repo = try await RepoFixture()
        try await configure(repo, command: "echo ready; sleep 20")
        let bad = await repo.call("POST", "code/scripts", body: ["index": 10, "command": "echo unauthorized"])
        XCTAssertEqual(bad.status, 400)
        _ = await repo.call("POST", "code/scripts", body: ["index": 0])
        let again = await repo.call("POST", "code/scripts", body: ["index": 0])
        XCTAssertEqual(again.status, 409)
        let stop = await repo.call("POST", "code/scripts/stop", body: [:])
        XCTAssertEqual(stop.json?["run"]?["stopped"], true)
        let finished = try await settled(repo)
        XCTAssertEqual(finished?["running"], false)
    }

    func testChangingFolderHidesTheProjectsScripts() async throws {
        let repo = try await RepoFixture()
        try await configure(repo, command: "echo safe")
        _ = repo.harness.store.setTaskCwd(repo.botId, repo.threadId, cwd: repo.paths.root.path)
        let status = await repo.call("GET", "code/scripts")
        XCTAssertEqual(status.json?["scripts"]?.array?.count, 0)
        let refused = await repo.call("POST", "code/scripts", body: ["index": 0])
        XCTAssertEqual(refused.status, 400)
    }

    func testDisablingThePluginStopsItsProcesses() async throws {
        let repo = try await RepoFixture()
        try await configure(repo, command: "echo started; sleep 20")
        _ = await repo.call("POST", "code/scripts", body: ["index": 0])
        try repo.harness.plugins.setEnabled("code", false)
        try repo.harness.plugins.setEnabled("code", true)
        let run = try await settled(repo)
        XCTAssertEqual(run?["stopped"], true)
    }
}

@MainActor
final class CodeChatHistoryTests: XCTestCase {
    func testRecentChatsFollowActivityInsteadOfCreationTimeAndLeaveOutArchivedChats() async throws {
        let repo = try await RepoFixture()
        repo.harness.store.patchBot(repo.botId, ["codeMode": true])
        let newer = repo.harness.store.createTask(repo.botId, title: "Newer")!["threadId"]!.string!
        repo.harness.store.appendMessage(repo.threadId, ["role": "user", "kind": "text", "text": "Return to an older chat", "at": 9_999_999_999_999])
        let chats = CodeChats(harness: repo.harness)
        XCTAssertEqual(chats.recent()["chats"]?.array?.first?["threadId"], .string(repo.threadId))
        _ = try chats.patch(thread: repo.threadId, body: ["archived": true])
        XCTAssertEqual(chats.recent()["chats"]?.array?.first?["threadId"], .string(newer))
    }

    func testArchiveAndReadMarkersAreKeptOnTheEngine() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        repo.harness.store.appendMessage(repo.threadId, ["role": "bot", "kind": "text", "text": "done"])
        let listing = "/api/bots/\(repo.botId)/code/chats"
        let first = await repo.callRaw("GET", listing)
        XCTAssertEqual(first.json?["chats"]?.array?.first?["unread"], true)
        _ = await repo.call("PATCH", "code/chat", body: ["read": true, "archived": true])
        let second = await repo.callRaw("GET", listing)
        XCTAssertEqual(second.json?["chats"]?.array?.first?["unread"], false)
        XCTAssertEqual(second.json?["chats"]?.array?.first?["archived"], true)
        XCTAssertEqual(second.json?["chats"]?.array?.first?["git"]?["branch"], "main")
        repo.harness.store.appendMessage(repo.threadId, ["role": "bot", "kind": "text", "text": "another reply"])
        let third = await repo.callRaw("GET", listing)
        XCTAssertEqual(third.json?["chats"]?.array?.first?["unread"], true)
    }

    func testSearchIsScopedBeforeTheLimitAndEscapesWildcards() async throws {
        let repo = try await RepoFixture()
        let other = repo.harness.store.createBot(seedMessages: false)["threadId"]!.string!
        repo.harness.store.appendMessage(repo.threadId, ["role": "user", "kind": "text", "text": "100% own content"])
        for _ in 0..<60 { repo.harness.store.appendMessage(other, ["role": "user", "kind": "text", "text": "100% other content"]) }
        let store = CodeChats(harness: repo.harness)
        let hits = try store.search(botId: repo.botId, query: "100%")
        XCTAssertEqual(hits["hits"]?.array?.count, 1)
        XCTAssertEqual(hits["hits"]?.array?.first?["threadId"], .string(repo.threadId))
        XCTAssertTrue(hits["hits"]?.array?.first?["snippet"]?.string?.contains("own content") == true)
    }

    func testGitLineCountsIgnoreBinaryAndHandleRenameNames() {
        let counts = ThreadGit.lineCounts("18\t4\tsrc/a.swift\n-\t-\timage.png\n2\t1\t{old => new}/b.swift\n")
        XCTAssertEqual(counts.added, 20)
        XCTAssertEqual(counts.deleted, 5)
    }
}

@MainActor
final class SessionSummaryTests: XCTestCase {
    func testSteeringAChannelStopsTheOldRoundAndDrainsTheNewDirection() async throws {
        let adapter = FakeAdapter(driverKind: "claudeAgent")
        adapter.script = { input, emit in
            emit(.turnStarted, nil)
            if input.text.contains("new direction") { emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil) }
        }
        let repo = try await RepoFixture(drivers: [FakeDriver(driverKind: "claudeAgent", adapter: adapter)], boot: true)
        let second = repo.harness.store.createBot(seedMessages: false)["id"]!.string!
        for bot in [repo.botId, second] { repo.harness.store.patchBot(bot, ["modelSelection": ["instanceId": "claude", "model": "fake-1"]]) }
        let group = repo.harness.store.createGroup(name: "Queue", memberIds: [repo.botId, second])
        let id = group["id"]!.string!, thread = group["threadId"]!.string!
        repo.harness.store.patchGroup(id, ["defaultResponder": ["kind": "everyone"]])
        adapter.onInterrupt = { thread in
            repo.harness.bus.publish(RuntimeEvent(provider: "claudeAgent", providerInstanceId: "claude", threadId: thread,
                .turnCompleted(ok: false, stopReason: "interrupted", cost: nil, denials: nil, usage: nil)))
        }
        try repo.harness.startGroupTurn(groupId: id, text: "old round")
        for _ in 0..<100 where adapter.received.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try repo.harness.startGroupTurn(groupId: id, text: "queued detail")
        XCTAssertEqual(repo.harness.store.messages(thread).last?["queued"], true)
        XCTAssertFalse(repo.harness.roomContext(thread).contains("queued detail"))
        _ = await repo.harness.interruptGroup(id)
        try repo.harness.startGroupTurn(groupId: id, text: "new direction")
        for _ in 0..<100 where repo.harness.roomIsBusy(id) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(adapter.received.count, 3, "one old speaker, then both members in the new round")
        XCTAssertTrue(adapter.received.dropFirst().allSatisfy { $0.text.contains("new direction") })
        XCTAssertFalse(repo.harness.roomIsBusy(id))
        XCTAssertFalse(repo.harness.store.messages(thread).contains { $0["queued"] == true })
        await repo.harness.shutdown()
    }

    func testCodeChannelRequiresASharedFolder() async throws {
        let repo = try await RepoFixture()
        let group = repo.harness.store.createGroup(name: "Shared", memberIds: [repo.botId])
        let id = group["id"]!.string!
        let refused = await repo.callRaw("PATCH", "/api/groups/\(id)", body: ["codeMode": true])
        XCTAssertEqual(refused.status, 400)
        let accepted = await repo.callRaw("PATCH", "/api/groups/\(id)", body: ["codeMode": true, "cwd": .string(repo.folder.path)])
        XCTAssertEqual(accepted.status, 200)
        let cleared = await repo.callRaw("PATCH", "/api/groups/\(id)", body: ["cwd": .null])
        XCTAssertEqual(cleared.status, 400)
    }

    func testChannelCanGenerateACommitMessageWithItsDefaultMember() async throws {
        let adapter = FakeAdapter(driverKind: "claudeAgent")
        adapter.script = { _, emit in emit(.textCompleted(text: "Update the API"), nil); emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil) }
        let repo = try await RepoFixture(drivers: [FakeDriver(driverKind: "claudeAgent", adapter: adapter)], boot: true)
        try repo.initRepo()
        try repo.write("a.txt", "updated\n")
        repo.harness.store.patchBot(repo.botId, ["modelSelection": ["instanceId": "claude", "model": "fake-2"]])
        let group = repo.harness.store.createGroup(name: "Commit", memberIds: [repo.botId])
        repo.harness.store.patchGroup(group["id"]!.string!, ["cwd": .string(repo.folder.path)])
        let response = await repo.callRaw("POST", "/api/threads/\(group["threadId"]!.string!)/git/commit-message", body: [:])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["message"], "Update the API")
        XCTAssertEqual(adapter.received.last?.model, "fake-2")
        await repo.harness.shutdown()
    }

    func testRoomSummaryComesFromItsDefaultMemberInAFreshCall() async throws {
        let adapter = FakeAdapter(driverKind: "claudeAgent")
        adapter.script = { _, emit in emit(.textCompleted(text: "Keep the shared API decision"), nil); emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil) }
        let repo = try await RepoFixture(drivers: [FakeDriver(driverKind: "claudeAgent", adapter: adapter)], boot: true)
        repo.harness.store.patchBot(repo.botId, ["modelSelection": ["instanceId": "claude", "model": "fake-2"]])
        let group = repo.harness.store.createGroup(name: "Summary", memberIds: [repo.botId])
        let id = group["id"]!.string!, thread = group["threadId"]!.string!
        repo.harness.store.appendMessage(thread, ["role": "user", "kind": "text", "text": "Choose the API contract"])
        _ = try await repo.harness.newRoomSession(id, summarize: true)
        XCTAssertEqual(adapter.received.last?.model, "fake-2")
        XCTAssertNil(adapter.received.last?.resumeCursor)
        XCTAssertNotEqual(adapter.received.last?.threadId, thread)
        XCTAssertTrue(repo.harness.roomContext(thread).contains("Keep the shared API decision"))
        XCTAssertFalse(repo.harness.roomContext(thread).contains("Choose the API contract"))
        await repo.harness.shutdown()
    }

    func testAGuestCanSummarizeWithoutAdvancingItsMirrorSession() async throws {
        let adapter = FakeAdapter(driverKind: "claudeAgent")
        adapter.script = { _, emit in emit(.textCompleted(text: "Guest summary"), nil); emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil) }
        let repo = try await RepoFixture(drivers: [FakeDriver(driverKind: "claudeAgent", adapter: adapter)], boot: true)
        repo.harness.store.patchBot(repo.botId, ["modelSelection": ["instanceId": "claude", "model": "fake-1"]])
        let response = await repo.callRaw("POST", "/api/guest-turns/summary", body: ["conversationId": "host-channel", "botId": .string(repo.botId),
            "messages": [["id": "host-message", "role": "user", "name": "User", "text": "Summarize the current API work"]]])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["text"], "Guest summary")
        XCTAssertTrue(repo.harness.store.groups.isEmpty)
        XCTAssertTrue(adapter.received.last?.text.contains("API work") == true)
        XCTAssertNil(adapter.received.last?.resumeCursor)
        await repo.harness.shutdown()
    }

    func testContextIsStoredSeparatelyFromCumulativeUsage() async throws {
        let repo = try await RepoFixture()
        var event = RuntimeEvent(provider: "codex", threadId: repo.threadId, .tokenUsage(input: 500_000, output: 30_000))
        event.context = .init(used: 62_000, window: 200_000)
        repo.harness.fold(event)
        XCTAssertEqual(repo.harness.store.taskByThread(repo.botId, repo.threadId)?["context"]?["used"], 62_000)
        XCTAssertEqual(repo.harness.store.taskByThread(repo.botId, repo.threadId)?["context"]?["window"], 200_000)
        XCTAssertNil(event.json["context"], "the frozen runtime envelope is unchanged")
    }

    func testCompactionResumesFromTheSummaryWithoutTheOldCursor() async throws {
        let adapter = FakeAdapter(driverKind: "claudeAgent")
        adapter.script = { _, emit in emit(.textCompleted(text: "Keep the chosen API contract"), nil); emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil) }
        let repo = try await RepoFixture(drivers: [FakeDriver(driverKind: "claudeAgent", adapter: adapter)], boot: true)
        repo.harness.store.patchBot(repo.botId, ["modelSelection": ["instanceId": "claude", "model": "fake-1"]])
        repo.harness.store.appendMessage(repo.threadId, ["role": "user", "kind": "text", "text": "old details"])
        repo.harness.store.setResumeCursor(repo.botId, instanceId: "claude", cursor: "old", threadId: repo.threadId)
        try await repo.harness.compactTask(botId: repo.botId, thread: repo.threadId)
        XCTAssertNil(repo.harness.store.taskByThread(repo.botId, repo.threadId)?["resumeCursors"]?["claude"])
        let history = Harness.afterSessionDivider(repo.harness.store.activePath(repo.threadId))
        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history.first?["text"]?.string?.contains("API contract") == true)
        XCTAssertTrue(repo.harness.store.messages(repo.threadId).contains { $0["text"] == "old details" })
        try repo.harness.startTurn(botId: repo.botId, text: "continue")
        for _ in 0..<100 where adapter.received.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        let next = adapter.received.last
        XCTAssertNil(next?.resumeCursor)
        XCTAssertTrue(next?.text.contains("API contract") == true)
        XCTAssertFalse(next?.text.contains("old details") == true)
        XCTAssertTrue(next?.sessionKey?.contains(":") == true)
        await repo.harness.shutdown()
    }
}
