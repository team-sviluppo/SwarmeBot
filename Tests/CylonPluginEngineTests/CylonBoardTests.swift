@testable import CylonPluginEngine
@testable import HarnessCore
import XCTest

/// The board of a job that touches several repositories: tickets in the channels of their repositories, in the order of
/// priority, with their state read from the channels' pipelines.
@MainActor
final class CylonBoardTests: XCTestCase {
    // MARK: fixtures

    @MainActor
    private struct Boards {
        let fixture: CylonFixture
        let backend: String
        let app: String
        let backoffice: String

        var harness: Harness { fixture.harness }
        func call(_ method: String, _ path: String, _ body: JSON? = nil, query: [String: String] = [:]) async -> (status: Int, json: JSON?) { await fixture.call(method, path, body, query: query) }
        func wire(_ board: String) async -> JSON? { await call("GET", "/api/cylon/boards/\(board)").json?["board"] }
        func state(_ board: String, _ ticket: String) async -> String? {
            await wire(board)?["items"]?.array?.first { $0["ticketId"]?.string == ticket }?["state"]?.string
        }
        func pipeline(_ group: String, _ id: String? = nil) -> CylonPipeline? { CylonStore(harness: harness).pipeline(of: group) }
    }

    /// A project with a channel per repository (backend, app, backoffice), each following the flow.
    private func boards() async throws -> Boards {
        let fixture = try await CylonFixture()
        func channel(_ name: String, role: String, follow: Bool = true) -> String {
            let group = fixture.harness.store.createGroup(name: name, memberIds: [fixture.planner, fixture.runner, fixture.reviewer])
            var data: JSONObject = ["code": ["projectId": "p1", "role": .string(role)]]
            if follow { data["cylon"] = ["follow": true] }
            fixture.harness.store.patchGroup(group["id"]!.string!, ["cwd": .string(fixture.folder.path), "plugins": .object(data)])
            return group["id"]!.string!
        }
        return Boards(fixture: fixture, backend: channel("Backend Titiro", role: "backend"), app: channel("App Titiro", role: "app"),
                      backoffice: channel("Backoffice Titiro", role: "backoffice"))
    }

    private func newBoard(_ b: Boards, title: String = "Login con Google") async throws -> String {
        let made = await b.call("POST", "/api/cylon/boards", ["projectId": "p1", "title": .string(title)])
        XCTAssertEqual(made.status, 201, String(describing: made.json))
        return try XCTUnwrap(made.json?["board"]?["id"]?.string)
    }

    private func add(_ b: Boards, _ board: String, role: String, ticket: String, tag: String = "cylon-plan", group: String? = nil, title: String? = nil) async -> (status: Int, json: JSON?) {
        var body: JSONObject = ["role": .string(role), "ticket": .string(ticket), "tag": .string(tag)]
        if let group { body["groupId"] = .string(group) }
        if let title { body["title"] = .string(title) }
        return await b.call("POST", "/api/cylon/boards/\(board)/items", .object(body))
    }

    private func firstItem(_ b: Boards, _ board: String) async throws -> String {
        let wire = await b.wire(board)
        return try XCTUnwrap(wire?["items"]?.array?.first?["id"]?.string)
    }

    private func itemIds(_ b: Boards, _ board: String) async -> [String] {
        await b.wire(board)?["items"]?.array?.compactMap { $0["ticketId"]?.string } ?? []
    }

    // MARK: the board itself

    func testABoardIsMadeRenamedAndDeleted() async throws {
        let b = try await boards()
        for bad: JSON in [["title": "No project"], ["projectId": "p1"], ["projectId": "p1", "title": "  "], ["projectId": "p1", "title": .string(String(repeating: "x", count: 121))],
                          ["projectId": "p1", "title": "T", "parentUrl": "ftp://nope"], ["projectId": "p1", "title": "T", "parentUrl": "javascript:alert(1)"], ["projectId": "no spaces allowed", "title": "T"]] {
            let refused = await b.call("POST", "/api/cylon/boards", bad)
            XCTAssertEqual(refused.status, 400, String(describing: bad))
        }
        let made = await b.call("POST", "/api/cylon/boards", ["projectId": "p1", "title": " Login con Google ", "parentUrl": "https://app.clickup.com/t/86c2x9k"])
        XCTAssertEqual(made.status, 201, String(describing: made.json))
        let id = try XCTUnwrap(made.json?["board"]?["id"]?.string)
        XCTAssertEqual(made.json?["board"]?["title"], "Login con Google", "trimmed")
        XCTAssertEqual(made.json?["board"]?["summary"]?["total"], 0)
        _ = try await newBoard(b, title: "Fatturazione")
        let other = await b.call("POST", "/api/cylon/boards", ["projectId": "p2", "title": "Another project"])
        XCTAssertEqual(other.status, 201)
        let mine = await b.call("GET", "/api/cylon/boards", query: ["projectId": "p1"])
        XCTAssertEqual(mine.json?["boards"]?.array?.compactMap { $0["title"]?.string }, ["Login con Google", "Fatturazione"], "a project's boards, in the order they were made")
        let all = await b.call("GET", "/api/cylon/boards")
        XCTAssertEqual(all.json?["boards"]?.array?.count, 3)

        let renamed = await b.call("PATCH", "/api/cylon/boards/\(id)", ["title": "Accesso con Google", "parentUrl": .null])
        XCTAssertEqual(renamed.json?["board"]?["title"], "Accesso con Google")
        XCTAssertNil(renamed.json?["board"]?["parentUrl"], "null takes the link away")
        let kept = await b.call("PATCH", "/api/cylon/boards/\(id)", ["title": "  "])
        XCTAssertEqual(kept.status, 400)
        // kept on disk, not only in memory
        XCTAssertEqual(CylonStore(harness: b.harness).board(id)?.title, "Accesso con Google")

        let gone = await b.call("DELETE", "/api/cylon/boards/\(id)")
        XCTAssertEqual(gone.status, 200)
        let after = await b.call("GET", "/api/cylon/boards/\(id)")
        XCTAssertEqual(after.status, 404)
        for (method, path) in [("PATCH", "/api/cylon/boards/nope"), ("DELETE", "/api/cylon/boards/nope"), ("POST", "/api/cylon/boards/nope/items"),
                               ("POST", "/api/cylon/boards/nope/start-next"), ("DELETE", "/api/cylon/boards/nope/items/x")] {
            let answer = await b.call(method, path, [:])
            XCTAssertEqual(answer.status, 404, "\(method) \(path)")
        }
    }

    // MARK: tickets on it

    func testATicketGoesInTheChannelOfItsRepository() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        let first = await add(b, board, role: "backend", ticket: "https://app.clickup.com/t/86c2x9k?foo=1", title: "API di login")
        XCTAssertEqual(first.status, 201, String(describing: first.json))
        let item = try XCTUnwrap(first.json?["board"]?["items"]?.array?.first)
        XCTAssertEqual(item["ticketId"], "86c2x9k", "the id out of its address")
        XCTAssertEqual(item["groupId"]?.string, b.backend)
        XCTAssertEqual(item["channel"]?["name"], "Backend Titiro")
        XCTAssertEqual(item["channel"]?["follows"], true)
        XCTAssertEqual(item["state"], "not-started")
        XCTAssertEqual(item["title"], "API di login")
        XCTAssertEqual(item["tag"], "cylon-plan", "the usual start")
        let appTicket = await add(b, board, role: "app", ticket: "86c2xb4", tag: "cylon-spec")
        XCTAssertEqual(appTicket.json?["board"]?["items"]?.array?.last?["groupId"]?.string, b.app)
        XCTAssertEqual(appTicket.json?["board"]?["items"]?.array?.last?["tag"], "cylon-spec")
    }

    func testWhatCannotBePutOnTheBoardIsRefusedWithAReason() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        _ = await add(b, board, role: "backend", ticket: "t1")
        let again = await add(b, board, role: "app", ticket: "t1")
        XCTAssertEqual(again.status, 409, "one ticket once")
        let none = await add(b, board, role: "bruno", ticket: "t2")
        XCTAssertEqual(none.status, 409)
        XCTAssertTrue(none.json?["error"]?.string?.contains("no channel works on bruno") == true, String(describing: none.json))
        for (ticket, tag, why) in [("two words", "cylon-plan", "not an id"), ("t3", "cylon-nope", "unknown tag"), ("https://evil.example/t/abc", "cylon-plan", "another host")] {
            let refused = await add(b, board, role: "app", ticket: ticket, tag: tag)
            XCTAssertEqual(refused.status, 400, why)
        }
        let investigate = await add(b, board, role: "app", ticket: "t4", tag: "cylon-investigate")
        XCTAssertEqual(investigate.status, 400, "outside the flow, so not on a board of it")
        let noRole = await b.call("POST", "/api/cylon/boards/\(board)/items", ["ticket": "t5"])
        XCTAssertEqual(noRole.status, 400)
        let weird = await b.call("POST", "/api/cylon/boards/\(board)/items", ["role": "../x", "ticket": "t5"])
        XCTAssertEqual(weird.status, 400)
        let ids = await itemIds(b, board)
        XCTAssertEqual(ids, ["t1"], "nothing of that was added")
    }

    func testSeveralChannelsOfARoleNeedOneToBeChosenAndAChannelMustFollowTheFlow() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        // a second channel for the app, and a third that does not follow the flow
        let second = b.harness.store.createGroup(name: "App Titiro 2", memberIds: [b.fixture.planner])["id"]!.string!
        b.harness.store.patchGroup(second, ["plugins": ["code": ["projectId": "p1", "role": "app"], "cylon": ["follow": true]]])
        let quiet = b.harness.store.createGroup(name: "Bruno Titiro", memberIds: [b.fixture.planner])["id"]!.string!
        b.harness.store.patchGroup(quiet, ["plugins": ["code": ["projectId": "p1", "role": "bruno"]]])

        let ambiguous = await add(b, board, role: "app", ticket: "t1")
        XCTAssertEqual(ambiguous.status, 400)
        XCTAssertTrue(ambiguous.json?["error"]?.string?.contains("App Titiro") == true && ambiguous.json?["error"]?.string?.contains("App Titiro 2") == true, "it names them: \(String(describing: ambiguous.json))")
        let chosen = await add(b, board, role: "app", ticket: "t1", group: second)
        XCTAssertEqual(chosen.status, 201, String(describing: chosen.json))
        XCTAssertEqual(chosen.json?["board"]?["items"]?.array?.first?["groupId"]?.string, second)
        let wrongRole = await add(b, board, role: "app", ticket: "t2", group: b.backend)
        XCTAssertEqual(wrongRole.status, 400, "that channel works on another repository")
        let notFollowing = await add(b, board, role: "bruno", ticket: "t3")
        XCTAssertEqual(notFollowing.status, 409)
        XCTAssertTrue(notFollowing.json?["error"]?.string?.contains("does not follow the Cylon flow") == true)
        // a project of another board does not lend its channels
        let other = await b.call("POST", "/api/cylon/boards", ["projectId": "p2", "title": "Elsewhere"])
        let elsewhere = await add(b, try XCTUnwrap(other.json?["board"]?["id"]?.string), role: "backend", ticket: "t9")
        XCTAssertEqual(elsewhere.status, 409, "the channels of p1 are not the channels of p2")
    }

    // MARK: priority

    func testThePriorityIsTheOrderOfTheListAndNothingElse() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        for (role, ticket) in [("backend", "t1"), ("backoffice", "t2"), ("app", "t3")] { _ = await add(b, board, role: role, ticket: ticket) }
        var ids = await itemIds(b, board)
        XCTAssertEqual(ids, ["t1", "t2", "t3"], "in the order they were added")
        let items = await b.wire(board)?["items"]?.array?.compactMap { $0["id"]?.string } ?? []

        let reversed = await b.call("PATCH", "/api/cylon/boards/\(board)", ["order": .array(items.reversed().map { .string($0) })])
        XCTAssertEqual(reversed.status, 200, String(describing: reversed.json))
        ids = await itemIds(b, board)
        XCTAssertEqual(ids, ["t3", "t2", "t1"])
        XCTAssertEqual(CylonStore(harness: b.harness).board(board)?.items.map(\.ticketId), ["t3", "t2", "t1"], "kept")

        for bad: JSON in [.array([.string(items[0])]), .array([.string(items[0]), .string(items[0]), .string(items[1])]),
                          .array([.string(items[0]), .string(items[1]), "ghost"]), "t1", .array([1, 2, 3])] {
            let refused = await b.call("PATCH", "/api/cylon/boards/\(board)", ["order": bad])
            XCTAssertEqual(refused.status, 400, String(describing: bad))
        }
        ids = await itemIds(b, board)
        XCTAssertEqual(ids, ["t3", "t2", "t1"], "a refused order changes nothing")
        // it blocks nothing: the last ticket can be started first
        let last = items[0]   // t1, last in the order now
        let started = await b.call("POST", "/api/cylon/boards/\(board)/items/\(last)/start", [:])
        XCTAssertEqual(started.status, 200, String(describing: started.json))
    }

    // MARK: starting

    func testStartingATicketDoesWhatTheChannelsOwnStartDoes() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        _ = await add(b, board, role: "backend", ticket: "86c2x9k", title: "API di login")
        let itemId = try await firstItem(b, board)
        b.harness.store.appendMessage(b.harness.store.group(b.backend)?["threadId"]?.string ?? "", ["role": "user", "kind": "text", "text": "old talk"])

        let started = await b.call("POST", "/api/cylon/boards/\(board)/items/\(itemId)/start", [:])
        XCTAssertEqual(started.status, 200, String(describing: started.json))
        XCTAssertEqual(started.json?["started"]?.string, itemId)
        let pipeline = try XCTUnwrap(b.pipeline(b.backend))
        XCTAssertEqual(pipeline.ticketId, "86c2x9k")
        XCTAssertEqual(pipeline.tag, "cylon-plan")
        XCTAssertEqual(pipeline.title, "API di login")
        XCTAssertEqual(pipeline.state(.spec), .skipped, "a ticket tagged for planning starts at the plan")
        XCTAssertEqual(started.json?["board"]?["items"]?.array?.first?["state"], "ready")
        let thread = b.harness.store.group(b.backend)?["threadId"]?.string ?? ""
        XCTAssertEqual(b.harness.store.messages(thread).filter { $0["sessionDivider"]?.bool == true }.count, 1, "a clean session, like the channel's own start")
        XCTAssertNil(b.pipeline(b.app), "only its own channel")

        let again = await b.call("POST", "/api/cylon/boards/\(board)/items/\(itemId)/start", [:])
        XCTAssertEqual(again.status, 409)
        XCTAssertTrue(again.json?["error"]?.string?.contains("already being followed") == true)
        let nothing = await b.call("POST", "/api/cylon/boards/\(board)/items/nope/start", [:])
        XCTAssertEqual(nothing.status, 404)
    }

    func testAChannelThatWorksOnAnotherTicketIsSaidAndStartingNeedsTheSameConfirmation() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        _ = await add(b, board, role: "backend", ticket: "mine")
        let itemId = try await firstItem(b, board)
        // the channel is in the middle of someone else's ticket
        _ = await b.call("POST", "/api/groups/\(b.backend)/cylon/start", ["ticket": "theirs", "tag": "cylon-plan"])
        let before = await b.state(board, "mine")
        XCTAssertEqual(before, "other-ticket")

        let refused = await b.call("POST", "/api/cylon/boards/\(board)/items/\(itemId)/start", [:])
        XCTAssertEqual(refused.status, 409)
        XCTAssertTrue(refused.json?["error"]?.string?.contains("in the middle of ticket theirs") == true, String(describing: refused.json))
        XCTAssertEqual(b.pipeline(b.backend)?.ticketId, "theirs", "nothing was replaced")

        let replaced = await b.call("POST", "/api/cylon/boards/\(board)/items/\(itemId)/start", ["replace": true])
        XCTAssertEqual(replaced.status, 200, String(describing: replaced.json))
        XCTAssertEqual(b.pipeline(b.backend)?.ticketId, "mine")
        let after = await b.state(board, "mine")
        XCTAssertEqual(after, "ready")
    }

    func testStartNextTakesTheFirstTicketNobodyStartedInTheOrderOfPriority() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        for (role, ticket) in [("backend", "t1"), ("app", "t2"), ("backoffice", "t3")] { _ = await add(b, board, role: role, ticket: ticket) }
        let items = await b.wire(board)?["items"]?.array?.compactMap { $0["id"]?.string } ?? []
        // the app first, then the backend, then the backoffice
        _ = await b.call("PATCH", "/api/cylon/boards/\(board)", ["order": [.string(items[1]), .string(items[0]), .string(items[2])]])

        var started: [String] = []
        for _ in 0..<3 {
            let next = await b.call("POST", "/api/cylon/boards/\(board)/start-next", [:])
            XCTAssertEqual(next.status, 200, String(describing: next.json))
            let id = try XCTUnwrap(next.json?["started"]?.string)
            started.append(try XCTUnwrap(next.json?["board"]?["items"]?.array?.first { $0["id"]?.string == id }?["ticketId"]?.string))
        }
        XCTAssertEqual(started, ["t2", "t1", "t3"])
        let none = await b.call("POST", "/api/cylon/boards/\(board)/start-next", [:])
        XCTAssertEqual(none.status, 409)
        XCTAssertTrue(none.json?["error"]?.string?.contains("nothing left to start") == true)
    }

    func testStartNextLeavesATicketWhoseChannelWorksOnAnotherAndStopsAtOneItCannotStart() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        _ = await add(b, board, role: "backend", ticket: "first")
        _ = await add(b, board, role: "app", ticket: "second")
        _ = await b.call("POST", "/api/groups/\(b.backend)/cylon/start", ["ticket": "someone-else", "tag": "cylon-plan"])
        // the first ticket's channel has another ticket in the middle: its state is not "not started", so the next one is the app's
        let next = await b.call("POST", "/api/cylon/boards/\(board)/start-next", [:])
        XCTAssertEqual(next.status, 200, String(describing: next.json))
        XCTAssertEqual(b.pipeline(b.backend)?.ticketId, "someone-else", "the first was not started over the other ticket")
        XCTAssertEqual(b.pipeline(b.app)?.ticketId, "second")
        // a busy channel is said, not walked around
        let busy = try await boards()
        let busyBoard = try await newBoard(busy)
        _ = await add(busy, busyBoard, role: "backend", ticket: "t1")
        _ = await add(busy, busyBoard, role: "app", ticket: "t2")
        busy.harness.store.patchGroup(busy.backend, ["busyBotId": .string(busy.fixture.runner)])
        let refused = await busy.call("POST", "/api/cylon/boards/\(busyBoard)/start-next", [:])
        XCTAssertEqual(refused.status, 409, "the channel is working: wait for it")
        XCTAssertNil(busy.pipeline(busy.app), "and the second was not started in its place")
    }

    // MARK: what the board says

    func testAStateIsReadFromTheChannelsPipeline() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        _ = await add(b, board, role: "backend", ticket: "t-backend")
        _ = await add(b, board, role: "app", ticket: "t-app")
        _ = await add(b, board, role: "backoffice", ticket: "t-back-office", tag: "cylon-spec")
        let store = CylonStore(harness: b.harness)
        let initial = await b.wire(board)
        XCTAssertEqual(initial?["summary"]?["notStarted"], 3)

        // backend: a phase being worked on while the channel works, and waiting for the person when it is idle
        var backend = CylonPipeline(ticketId: "t-backend", tag: "cylon-plan", title: nil)
        backend.phases[.plan]?.state = .running
        backend.phases[.plan]?.botId = b.fixture.planner
        try store.save(backend, of: b.backend)
        var state = await b.state(board, "t-backend")
        XCTAssertEqual(state, "waiting", "the turn ended and the phase did not: the bot asked something")
        b.harness.store.patchGroup(b.backend, ["busyBotId": .string(b.fixture.planner)])
        state = await b.state(board, "t-backend")
        XCTAssertEqual(state, "running")
        b.harness.store.patchGroup(b.backend, ["busyBotId": .null])
        backend.phases[.plan]?.state = .done
        try store.save(backend, of: b.backend)
        state = await b.state(board, "t-backend")
        XCTAssertEqual(state, "ready", "between two phases")
        backend.phases[.run]?.state = .failed
        try store.save(backend, of: b.backend)
        state = await b.state(board, "t-backend")
        XCTAssertEqual(state, "failed")

        // the app: all over, with its pull request
        var app = CylonPipeline(ticketId: "t-app", tag: "cylon-plan", title: nil)
        for phase in CylonPhase.allCases { app.phases[phase]?.state = .done }
        app.prUrl = "https://github.com/team-sviluppo/titiro-app/pull/9"
        try store.save(app, of: b.app)
        let done = await b.wire(board)
        let appItem = done?["items"]?.array?.first { $0["ticketId"] == "t-app" }
        XCTAssertEqual(appItem?["state"], "done")
        XCTAssertEqual(appItem?["prUrl"], "https://github.com/team-sviluppo/titiro-app/pull/9")

        // the backoffice: the spec made a new ticket, and the seed is still the one the board knows
        var spec = CylonPipeline(ticketId: "t-new-from-spec", tag: "cylon-spec", title: nil)
        spec.specTicketId = "t-back-office"
        spec.phases[.spec]?.state = .done
        try store.save(spec, of: b.backoffice)
        state = await b.state(board, "t-back-office")
        XCTAssertEqual(state, "ready", "followed through the ticket the spec made")

        let summary = try XCTUnwrap(done?["summary"])
        XCTAssertEqual(summary["total"], 3)
        XCTAssertEqual(summary["done"], 1)
        XCTAssertEqual(summary["prOpen"], 1)
        XCTAssertEqual(summary["problems"], 1, "the failed backend ticket")
        // the channel's own status, as its bar reads it, comes with the item
        XCTAssertEqual(appItem?["flow"]?["pipeline"]?["finished"], true)
        XCTAssertEqual(appItem?["flow"]?["phases"]?.array?.count, 5)

        // a channel that is gone
        _ = b.harness.store.deleteGroup(b.app)
        state = await b.state(board, "t-app")
        XCTAssertEqual(state, "channel-missing")
        let gone = await b.wire(board)?["items"]?.array?.first { $0["ticketId"] == "t-app" }
        XCTAssertEqual(gone?["channel"], .null)
        let restart = await b.call("POST", "/api/cylon/boards/\(board)/items/\(gone?["id"]?.string ?? "")/start", [:])
        XCTAssertEqual(restart.status, 409)
    }

    func testTheStateFunctionOnItsOwn() {
        func pipeline(_ ticket: String = "t", _ change: (inout CylonPipeline) -> Void = { _ in }) -> CylonPipeline {
            var p = CylonPipeline(ticketId: ticket, tag: "cylon-plan", title: nil)
            change(&p)
            return p
        }
        XCTAssertEqual(CylonBoards.state(ticketId: "t", pipeline: nil, channelExists: false, channelBusy: false), "channel-missing")
        XCTAssertEqual(CylonBoards.state(ticketId: "t", pipeline: nil, channelExists: true, channelBusy: false), "not-started")
        XCTAssertEqual(CylonBoards.state(ticketId: "t", pipeline: pipeline("other"), channelExists: true, channelBusy: false), "other-ticket")
        XCTAssertEqual(CylonBoards.state(ticketId: "t", pipeline: pipeline(), channelExists: true, channelBusy: false), "ready")
        XCTAssertEqual(CylonBoards.state(ticketId: "t", pipeline: pipeline { $0.phases[.plan]?.state = .running }, channelExists: true, channelBusy: true), "running")
        XCTAssertEqual(CylonBoards.state(ticketId: "t", pipeline: pipeline { $0.phases[.plan]?.state = .running }, channelExists: true, channelBusy: false), "waiting")
        XCTAssertEqual(CylonBoards.state(ticketId: "t", pipeline: pipeline { $0.phases[.plan]?.state = .failed }, channelExists: true, channelBusy: false), "failed")
        XCTAssertEqual(CylonBoards.state(ticketId: "t", pipeline: pipeline { for phase in CylonPhase.allCases { $0.phases[phase]?.state = .done } }, channelExists: true, channelBusy: false), "done")
        XCTAssertEqual(CylonBoards.state(ticketId: "seed", pipeline: pipeline("made-by-spec") { $0.specTicketId = "seed" }, channelExists: true, channelBusy: false), "ready")
    }

    func testABotThatIsBusyHoldsBackEveryChannelOfTheProjectAndTheBoardSaysWho() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        _ = await add(b, board, role: "backend", ticket: "t1")
        let quiet = await b.wire(board)
        XCTAssertEqual(quiet?["busyBots"]?.array?.count, 0)
        // the planner is working in the app's channel
        b.harness.store.patchBot(b.fixture.planner, ["busy": true])
        b.harness.store.patchGroup(b.app, ["busyBotId": .string(b.fixture.planner)])
        let busy = await b.wire(board)?["busyBots"]?.array ?? []
        XCTAssertEqual(busy.count, 1, "once, though the planner plays two phases")
        XCTAssertEqual(busy.first?["name"], "Pianificatore")
        XCTAssertEqual(busy.first?["channel"], "App Titiro")
        // working in a chat of its own, not in a channel
        b.harness.store.patchGroup(b.app, ["busyBotId": .null])
        let elsewhere = await b.wire(board)?["busyBots"]?.array ?? []
        XCTAssertEqual(elsewhere.first?["channel"], .null)
    }

    // MARK: what the board does not own

    func testTakingATicketOrTheBoardAwayStopsNothingInTheChannel() async throws {
        let b = try await boards()
        let board = try await newBoard(b)
        _ = await add(b, board, role: "backend", ticket: "t1")
        let itemId = try await firstItem(b, board)
        _ = await b.call("POST", "/api/cylon/boards/\(board)/items/\(itemId)/start", [:])
        XCTAssertNotNil(b.pipeline(b.backend))

        let removed = await b.call("DELETE", "/api/cylon/boards/\(board)/items/\(itemId)")
        XCTAssertEqual(removed.status, 200)
        XCTAssertEqual(removed.json?["board"]?["items"]?.array?.count, 0)
        XCTAssertNotNil(b.pipeline(b.backend), "the channel still follows its ticket")
        let missing = await b.call("DELETE", "/api/cylon/boards/\(board)/items/\(itemId)")
        XCTAssertEqual(missing.status, 404)

        _ = await add(b, board, role: "backend", ticket: "t1")
        _ = await b.call("DELETE", "/api/cylon/boards/\(board)")
        XCTAssertEqual(b.pipeline(b.backend)?.ticketId, "t1", "nor does deleting the board")
    }

    func testBoardsNeedTheJsonContentTypeLikeEveryMutation() async throws {
        let b = try await boards()
        let request = HTTPRequest(method: "POST", path: "/api/cylon/boards", query: [:], headers: [:], body: Data(#"{"projectId":"p1","title":"x"}"#.utf8))
        guard case let .response(response) = await b.fixture.routes.handle(request) else { return XCTFail("not a response") }
        XCTAssertEqual(response.status, 415)
        let plugins = await b.call("GET", "/api/plugins")
        XCTAssertEqual(plugins.json?["plugins"]?.array?.first { $0["id"] == "cylon" }?["version"], "1.1.0")
    }
}
