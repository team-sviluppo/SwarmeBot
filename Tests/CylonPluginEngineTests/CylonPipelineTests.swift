@testable import CodePluginEngine
@testable import CylonPluginEngine
@testable import HarnessCore
import XCTest

// MARK: - a model that answers as the Cylon skills do

@MainActor
final class ScriptedAdapter: ProviderAdapter {
    let provider = "claudeAgent"
    var capabilities = AdapterCapabilities()
    private let emitter = EventEmitter()
    private(set) var received: [SendTurnInput] = []
    /// What the model does with a turn: the bot that speaks, and the events to emit.
    var script: (SendTurnInput, String, (RuntimeEvent.Body) -> Void) -> Void = { _, _, _ in }

    /// The member a room turn is for: the prompt ends with who is to reply.
    static func speaker(_ input: SendTurnInput) -> String {
        guard let range = input.text.range(of: "(Reply to the conversation above as ", options: .backwards) else { return "" }
        return String(input.text[range.upperBound...].prefix { $0 != "." })
    }

    func sendTurn(_ input: SendTurnInput) async throws -> String {
        received.append(input)
        script(input, Self.speaker(input)) { body in
            self.emitter.emit(RuntimeEvent(provider: self.provider, providerInstanceId: "claude", threadId: input.threadId, requestId: nil, body))
        }
        return "turn"
    }

    func interruptTurn(threadId: ThreadID) async {}
    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome { .rejected }
    func hasSession(threadId: ThreadID) -> Bool { false }
    func stopAll() async {}

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { emitter.add(listener) }
}

@MainActor
final class ScriptedInstance: ProviderInstance {
    let instanceId: InstanceID
    let driverKind = "claudeAgent"
    let displayName: String? = "Fake"
    let enabled = true
    let models = ModelCatalog(default: "fake-1", options: [ModelOption(id: "fake-1", label: "Fake 1")])
    let adapter: ProviderAdapter

    init(instanceId: InstanceID, adapter: ProviderAdapter) {
        self.instanceId = instanceId
        self.adapter = adapter
    }

    func refreshModels() async {}
    func snapshot() async -> ProviderSnapshot { .available(version: "0") }
    func dispose() async {}
}

@MainActor
struct ScriptedDriver: ProviderDriver {
    let adapter: ScriptedAdapter
    var driverKind: String { "claudeAgent" }
    var displayName: String { "Fake" }
    var access: String { "subscription" }

    func create(_ input: DriverCreateInput) async throws -> ProviderInstance { ScriptedInstance(instanceId: input.instanceId, adapter: adapter) }
}

// MARK: - a channel with its project, its bots and the skills

@MainActor
final class CylonFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cylon-plugin-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let adapter = ScriptedAdapter()
    let harness: Harness
    let routes: Routes
    let folder: URL
    let groupId: String
    let threadId: String
    /// Planner (spec and plan), runner, reviewer (review and pull request).
    let planner: String
    let runner: String
    let reviewer: String
    static let phases = ["spec", "plan", "run", "review", "pull"]

    init(withSkills: Bool = true, roles: Bool = true, follow: Bool = true) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let harness = try Harness(paths: DataPaths(root: root.appendingPathComponent("data", isDirectory: true)), environment: ProcessInfo.processInfo.environment,
                                  drivers: [ScriptedDriver(adapter: adapter)], plugins: [CodeEnginePlugin(), CylonEnginePlugin()])
        self.harness = harness
        await harness.boot()
        routes = Routes(harness: harness)
        folder = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let selection: JSON = ["instanceId": "claude", "model": "fake-1"]
        func bot(_ name: String) -> String {
            let id = harness.store.createBot(seedMessages: false)["id"]!.string!
            harness.store.patchBot(id, ["modelSelection": selection, "name": .string(name)])
            return id
        }
        planner = bot("Pianificatore")
        runner = bot("Esecutore")
        reviewer = bot("Revisore")
        let group = harness.store.createGroup(name: "Titiro API", memberIds: [planner, runner, reviewer])
        groupId = group["id"]!.string!
        threadId = group["threadId"]!.string!
        var data: JSONObject = ["code": ["projectId": "p1"]]
        if follow { data["cylon"] = ["follow": true] }
        harness.store.patchGroup(groupId, ["cwd": .string(folder.path), "plugins": .object(data)])
        if withSkills {
            for phase in Self.phases {
                let text = "---\nname: cylon-\(phase)\ndescription: Cylon \(phase)\n---\n\nDo the \(phase) phase.\n"
                try harness.skills.add([Skills.UploadFile(path: "SKILL.md", data: Data(text.utf8), executable: false)], replace: true)
            }
            for id in [planner, runner, reviewer] {
                harness.store.patchBot(id, ["skills": .array(Self.phases.map { ["id": .string("cylon-\($0)"), "defaultOn": true] })])
            }
        }
        if roles {
            _ = await call("PUT", "/api/cylon/roles/p1", ["spec": .string(planner), "plan": .string(planner), "run": .string(runner),
                                                            "review": .string(reviewer), "pull": .string(reviewer)])
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func call(_ method: String, _ path: String, _ body: JSON? = nil) async -> (status: Int, json: JSON?) {
        let request = HTTPRequest(method: method, path: path, query: [:], headers: ["content-type": "application/json"], body: body?.data ?? Data())
        guard case let .response(response) = await routes.handle(request) else { return (-1, nil) }
        return (response.status, try? JSON.parse(response.body))
    }

    func status() async -> JSON? { await call("GET", "/api/groups/\(groupId)/cylon").json }
    /// The channel's status, which a test reads before it asserts: XCTest's assertions cannot await.
    func requireStatus() async throws -> JSON {
        let current = await status()
        return try XCTUnwrap(current)
    }
    func start(_ ticket: String = "seed1", tag: String = "cylon-spec", replace: Bool = false) async -> (status: Int, json: JSON?) {
        await call("POST", "/api/groups/\(groupId)/cylon/start", ["ticket": .string(ticket), "tag": .string(tag), "replace": .bool(replace)])
    }
    func run(_ phase: String, _ body: JSON = [:]) async -> (status: Int, json: JSON?) { await call("POST", "/api/groups/\(groupId)/cylon/phases/\(phase)/run", body) }
    func state(_ phase: String) async -> String? {
        await status()?["phases"]?.array?.first { $0["key"]?.string == phase }?["state"]?.string
    }

    /// Waits until the channel is idle and the phase has the state: the plugin follows a turn after it ends.
    func settled(_ phase: String, _ expected: String) async throws {
        for _ in 0..<200 {
            if await state(phase) == expected, harness.store.group(groupId)?["busyBotId"]?.string == nil { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let now = await state(phase)
        XCTFail("\(phase) is \(String(describing: now)), not \(expected)")
    }

    /// Waits for the `turns`-th turn of the model to end, and for the plugin to have followed it.
    func turnEnded(_ turns: Int) async throws {
        for _ in 0..<200 {
            if adapter.received.count >= turns, harness.store.group(groupId)?["busyBotId"]?.string == nil, harness.groupQueues[groupId] == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(adapter.received.count, turns, "the model was not asked")
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    /// The skill a turn was called with: its text begins with the invocation.
    static func called(_ input: SendTurnInput) -> String? {
        guard input.text.hasPrefix("[The user called /") else { return nil }
        return String(input.text.dropFirst("[The user called /".count).prefix { $0 != " " })
    }

    func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func said(_ body: (RuntimeEvent.Body) -> Void, _ text: String, ok: Bool = true) {
        body(.turnStarted)
        body(.textCompleted(text: text))
        body(.turnCompleted(ok: ok, stopReason: nil, cost: nil, denials: nil, usage: nil))
    }
}

@MainActor
final class CylonPipelineTests: XCTestCase {
    // MARK: the whole flow

    func testATicketGoesThroughEveryPhaseWithTheBotOfEachRole() async throws {
        let fixture = try await CylonFixture()
        var interviewed = false
        fixture.adapter.script = { input, bot, emit in
            switch CylonFixture.called(input) {
            case "cylon-spec"?:
                fixture.said(emit, "Ho creato il ticket.\n\n```\n/cylon-plan new9\n```")
            case "cylon-plan"?:
                // the interview: a question first, the plan after the person answers
                fixture.said(emit, "Domanda 1 di 5: chi usa la pagina?")
            case "cylon-run"?:
                fixture.said(emit, "Implementato.\n\n/cylon-pull cylon-features/login-page")
            case "cylon-review"?:
                fixture.said(emit, "Report della review.\n\n✅ REVIEW PASSED")
            case "cylon-pull"?:
                fixture.said(emit, "PR aperta: https://github.com/team-sviluppo/titiro-api/pull/7")
            default:
                if input.text.contains("Ok, tutto chiaro") {
                    interviewed = true
                    try? fixture.write("cylon-features/login-page/.data.json", #"{"clickup_task_id":"new9","branch":"feature/login-page"}"#)
                    try? fixture.write("cylon-features/login-page/plan.md", "---\nstatus: approved\n---\n# Piano\n")
                    fixture.said(emit, "Piano approvato.\n\n/cylon-run cylon-features/login-page")
                } else {
                    fixture.said(emit, "non so cosa fare (\(bot))")
                }
            }
        }
        let started = await fixture.start()
        XCTAssertEqual(started.status, 200, String(describing: started.json))
        XCTAssertEqual(started.json?["pipeline"]?["ticketId"], "seed1")
        XCTAssertEqual(started.json?["phases"]?.array?.first?["current"], true)
        XCTAssertEqual(started.json?["phases"]?.array?.first?["command"], "/cylon-spec seed1")

        // Spec: the planner, with the skill's text; the ticket the spec made is the one that goes on
        var sent = await fixture.run("spec")
        XCTAssertEqual(sent.status, 202, String(describing: sent.json))
        try await fixture.settled("spec", "done")
        var current = try await fixture.requireStatus()
        XCTAssertEqual(current["pipeline"]?["ticketId"], "new9")
        XCTAssertEqual(current["pipeline"]?["specTicketId"], "seed1")
        let first = try XCTUnwrap(fixture.adapter.received.first)
        XCTAssertEqual(ScriptedAdapter.speaker(first), "Pianificatore")
        XCTAssertTrue(first.text.hasPrefix("[The user called /cylon-spec for this message."), String(first.text.prefix(100)))
        XCTAssertTrue(first.text.contains("Do the spec phase."), "the skill's whole text is in the turn")

        // Plan: an interview, so the turn ending is not the phase ending
        sent = await fixture.run("plan")
        XCTAssertEqual(sent.status, 202, String(describing: sent.json))
        try await fixture.turnEnded(2)
        let interviewing = await fixture.state("plan")
        XCTAssertEqual(interviewing, "running")
        XCTAssertFalse(interviewed)
        let blocked = await fixture.run("run")
        XCTAssertEqual(blocked.status, 409, "the next phase waits for the plan")
        XCTAssertTrue(blocked.json?["error"]?.string?.contains("not over yet") == true)
        let answer = await fixture.call("POST", "/api/groups/\(fixture.groupId)/messages", ["text": "@Pianificatore Ok, tutto chiaro"])
        XCTAssertEqual(answer.status, 202)
        try await fixture.settled("plan", "done")
        XCTAssertTrue(interviewed)
        current = try await fixture.requireStatus()
        XCTAssertEqual(current["pipeline"]?["slug"], "login-page", "found through the ticket named in .data.json")
        XCTAssertEqual(current["phases"]?.array?[2]["command"], "/cylon-run cylon-features/login-page")

        // Run, Review, Pull request: each to its own bot, with the task's folder
        sent = await fixture.run("run")
        XCTAssertEqual(sent.status, 202, String(describing: sent.json))
        try await fixture.settled("run", "done")
        XCTAssertEqual(ScriptedAdapter.speaker(try XCTUnwrap(fixture.adapter.received.last)), "Esecutore")
        sent = await fixture.run("review")
        try await fixture.settled("review", "done")
        XCTAssertEqual(ScriptedAdapter.speaker(try XCTUnwrap(fixture.adapter.received.last)), "Revisore")
        sent = await fixture.run("pull")
        try await fixture.settled("pull", "done")
        current = try await fixture.requireStatus()
        XCTAssertEqual(current["pipeline"]?["prUrl"], "https://github.com/team-sviluppo/titiro-api/pull/7")
        XCTAssertEqual(current["pipeline"]?["finished"], true)
        XCTAssertEqual(current["phases"]?.array?.compactMap { $0["state"]?.string }, ["done", "done", "done", "done", "done"])
    }

    func testATicketTaggedForPlanningStartsAtThePlan() async throws {
        let fixture = try await CylonFixture()
        let started = await fixture.start("86c2x9k", tag: "cylon-plan")
        XCTAssertEqual(started.status, 200, String(describing: started.json))
        let phases = started.json?["phases"]?.array ?? []
        XCTAssertEqual(phases.first?["state"], "skipped", "the spec is already there")
        XCTAssertEqual(phases[1]["current"], true)
        XCTAssertEqual(phases[1]["command"], "/cylon-plan 86c2x9k")
        let spec = await fixture.run("spec")
        XCTAssertEqual(spec.status, 202, "a skipped phase can still be sent, if the person changes their mind")
    }

    // MARK: starting

    func testATicketMustComeWithAFlowToFollowAndAKnownTag() async throws {
        let off = try await CylonFixture(follow: false)
        let notFollowing = await off.start()
        XCTAssertEqual(notFollowing.status, 409)
        XCTAssertTrue(notFollowing.json?["error"]?.string?.contains("does not follow the Cylon flow") == true)

        let fixture = try await CylonFixture()
        for (ticket, tag, why) in [("two words", "cylon-plan", "not an id"), ("", "cylon-plan", "empty"), ("t1", "cylon-nope", "unknown tag"),
                                   ("https://evil.example/t/abc", "cylon-plan", "another host")] {
            let refused = await fixture.start(ticket, tag: tag)
            XCTAssertEqual(refused.status, 400, why)
        }
        let investigate = await fixture.start("t1", tag: "cylon-investigate")
        XCTAssertEqual(investigate.status, 400)
        XCTAssertTrue(investigate.json?["error"]?.string?.contains("outside the flow") == true, "investigations are not part of the pipeline")
        let address = await fixture.start("https://app.clickup.com/t/86c2x9k", tag: "cylon-plan")
        XCTAssertEqual(address.json?["pipeline"]?["ticketId"], "86c2x9k")
        let unknown = await fixture.call("GET", "/api/groups/nope/cylon")
        XCTAssertEqual(unknown.status, 404)
    }

    func testAnotherTicketStartsOverWithAFreshSessionButNotInTheMiddleOfOne() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("one", tag: "cylon-plan")
        fixture.harness.store.appendMessage(fixture.threadId, ["role": "user", "kind": "text", "text": "old talk"])
        let middle = await fixture.start("two", tag: "cylon-plan")
        XCTAssertEqual(middle.status, 409, "ticket one is not finished")
        XCTAssertTrue(middle.json?["error"]?.string?.contains("in the middle of ticket one") == true)
        let replaced = await fixture.start("two", tag: "cylon-plan", replace: true)
        XCTAssertEqual(replaced.status, 200, String(describing: replaced.json))
        XCTAssertEqual(replaced.json?["pipeline"]?["ticketId"], "two")
        XCTAssertEqual(fixture.harness.store.messages(fixture.threadId).filter { $0["sessionDivider"]?.bool == true }.count, 1, "the history stays, the session is new")
        XCTAssertFalse(fixture.harness.roomContext(fixture.threadId).contains("old talk"), "and the bots do not see the old ticket")
        fixture.harness.store.patchGroup(fixture.groupId, ["busyBotId": .string(fixture.runner)])
        let busy = await fixture.start("three", tag: "cylon-plan", replace: true)
        XCTAssertEqual(busy.status, 409, "not while someone is working")
        fixture.harness.store.patchGroup(fixture.groupId, ["busyBotId": .null])
        let reset = await fixture.call("DELETE", "/api/groups/\(fixture.groupId)/cylon")
        XCTAssertEqual(reset.json?["pipeline"], .null)
    }

    // MARK: sending

    func testAPhaseIsRefusedWhenItsBotOrItsSkillIsNotThere() async throws {
        let noRoles = try await CylonFixture(roles: false)
        _ = await noRoles.start("t1", tag: "cylon-plan")
        let none = await noRoles.run("plan")
        XCTAssertEqual(none.status, 409)
        XCTAssertTrue(none.json?["error"]?.string?.contains("no bot for plan") == true, String(describing: none.json))

        let noSkills = try await CylonFixture(withSkills: false)
        _ = await noSkills.start("t1", tag: "cylon-plan")
        let missing = await noSkills.run("plan")
        XCTAssertEqual(missing.status, 409)
        XCTAssertTrue(missing.json?["error"]?.string?.contains("skill cylon-plan is not on this engine") == true)

        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        // the planner has the skills only when it is told, and a bot that left the channel cannot play
        fixture.harness.store.patchBot(fixture.planner, ["skills": []])
        let unassigned = await fixture.run("plan")
        XCTAssertEqual(unassigned.status, 409)
        XCTAssertTrue(unassigned.json?["error"]?.string?.contains("does not have the skill cylon-plan") == true)
        fixture.harness.store.patchBot(fixture.planner, ["skills": [["id": "cylon-plan", "defaultOn": false]]])
        let off = await fixture.run("plan")
        XCTAssertEqual(off.status, 409, "a skill the bot switched off is not there")
        fixture.harness.store.patchBot(fixture.planner, ["skills": [["id": "cylon-plan", "defaultOn": true]]])
        fixture.harness.store.patchGroup(fixture.groupId, ["memberIds": .array([.string(fixture.runner), .string(fixture.reviewer)])])
        let notMember = await fixture.run("plan")
        XCTAssertEqual(notMember.status, 409)
        XCTAssertTrue(notMember.json?["error"]?.string?.contains("not a member of this channel") == true)
        let nonsense = await fixture.run("dance")
        XCTAssertEqual(nonsense.status, 404)
        XCTAssertTrue(fixture.adapter.received.isEmpty, "nothing was sent for any of these")
    }

    func testAPhaseThatWritesDoesNotRunInPlanMode() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        _ = await fixture.call("PUT", "/api/threads/\(fixture.threadId)/code/mode", ["mode": "plan"])
        let refused = await fixture.run("plan")
        XCTAssertEqual(refused.status, 409)
        XCTAssertTrue(refused.json?["error"]?.string?.contains("Plan mode") == true)
        _ = await fixture.call("PUT", "/api/threads/\(fixture.threadId)/code/mode", ["mode": "execute"])
        fixture.adapter.script = { _, _, emit in fixture.said(emit, "ok") }
        let sent = await fixture.run("plan")
        XCTAssertEqual(sent.status, 202, String(describing: sent.json))
    }

    func testAPhaseNeedsTheTaskFolderTheEarlierOnesMade() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        let skipped = await fixture.call("POST", "/api/groups/\(fixture.groupId)/cylon/phases/plan/skip")
        XCTAssertEqual(skipped.status, 200)
        let unknown = await fixture.run("run")
        XCTAssertEqual(unknown.status, 409)
        XCTAssertTrue(unknown.json?["error"]?.string?.contains("not known yet") == true)
        let unsafe = await fixture.run("run", ["slug": "../../etc"])
        XCTAssertEqual(unsafe.status, 400)
        // the person names the folder, or it is on disk already
        fixture.adapter.script = { _, _, emit in fixture.said(emit, "ok") }
        let named = await fixture.run("run", ["slug": "by-hand"])
        XCTAssertEqual(named.status, 202, String(describing: named.json))
        XCTAssertEqual(named.json?["pipeline"]?["slug"], "by-hand")
        XCTAssertTrue(fixture.harness.store.messages(fixture.threadId).contains { $0["text"]?.string == "@Esecutore /cylon-run cylon-features/by-hand" })
    }

    func testABotBusyElsewhereIsNotSentAPhaseItWouldSkip() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        for phase in ["plan"] { _ = await fixture.call("POST", "/api/groups/\(fixture.groupId)/cylon/phases/\(phase)/done") }
        // the runner is working in another conversation: a channel turn for it would be skipped, and the
        // phase would be left "running" with no turn behind it, and no way to send it again
        fixture.harness.store.patchBot(fixture.runner, ["busy": true])
        let status = try await fixture.requireStatus()
        let phase = status["phases"]?.array?[2]
        XCTAssertEqual(phase?["bot"]?["busy"], true, "the app can say why")
        XCTAssertEqual(phase?["canRun"], false)
        let refused = await fixture.run("run", ["slug": "login"])
        XCTAssertEqual(refused.status, 409, String(describing: refused.json))
        XCTAssertTrue(refused.json?["error"]?.string?.contains("@Esecutore is working in another conversation") == true, String(describing: refused.json))
        let state = await fixture.state("run")
        XCTAssertEqual(state, "pending", "nothing was sent, so nothing is running")
        XCTAssertTrue(fixture.adapter.received.isEmpty)
        XCTAssertFalse(fixture.harness.store.messages(fixture.threadId).contains { $0["role"]?.string == "user" }, "and nothing was said in the channel")

        // once it is free the same phase goes out
        fixture.harness.store.patchBot(fixture.runner, ["busy": false])
        fixture.adapter.script = { _, _, emit in fixture.said(emit, "ok") }
        let sent = await fixture.run("run", ["slug": "login"])
        XCTAssertEqual(sent.status, 202, String(describing: sent.json))
        XCTAssertEqual(sent.json?["phases"]?.array?[2]["bot"]?["busy"], false)
    }

    func testAPhaseWhoseModelIsGoneIsNotSentEither() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        let gone: JSON = ["instanceId": "no-such-engine", "model": "x"]
        fixture.harness.store.patchBot(fixture.planner, ["modelSelection": gone])
        let refused = await fixture.run("plan")
        XCTAssertEqual(refused.status, 409, String(describing: refused.json))
        XCTAssertTrue(refused.json?["error"]?.string?.contains("model of @Pianificatore is not available") == true, String(describing: refused.json))
        let state = await fixture.state("plan")
        XCTAssertEqual(state, "pending")
    }

    func testABusyChannelTakesNoPhase() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        fixture.harness.store.patchGroup(fixture.groupId, ["busyBotId": .string(fixture.runner)])
        let busy = await fixture.run("plan")
        XCTAssertEqual(busy.status, 409)
        let status = try await fixture.requireStatus()
        XCTAssertEqual(status["phases"]?.array?[1]["canRun"], false)
        XCTAssertEqual(status["busy"], true)
    }

    // MARK: how a phase ends

    func testATurnThatFailsLeavesThePhaseToBeSentAgain() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        fixture.adapter.script = { _, _, emit in fixture.said(emit, "interrotto", ok: false) }
        _ = await fixture.run("plan")
        try await fixture.settled("plan", "failed")
        let status = try await fixture.requireStatus()
        XCTAssertEqual(status["phases"]?.array?[1]["note"], "the turn did not finish")
        XCTAssertEqual(status["phases"]?.array?[1]["canRun"], true)
        fixture.adapter.script = { _, _, emit in fixture.said(emit, "Domanda 1") }
        let again = await fixture.run("plan")
        XCTAssertEqual(again.status, 202)
        try await fixture.turnEnded(2)
        let afterAgain = await fixture.state("plan")
        XCTAssertEqual(afterAgain, "running", "the question is not the end of the phase")
    }

    func testAFailedReviewIsFailedAndItsFixCanBeReviewedAgain() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        for phase in ["plan", "run"] { _ = await fixture.call("POST", "/api/groups/\(fixture.groupId)/cylon/phases/\(phase)/done") }
        var verdict = "❌ REVIEW FAILED"
        fixture.adapter.script = { _, _, emit in fixture.said(emit, "Problemi:\n- manca un test\n\n\(verdict)") }
        let sent = await fixture.run("review", ["slug": "login"])
        XCTAssertEqual(sent.status, 202, String(describing: sent.json))
        try await fixture.settled("review", "failed")
        let failedReview = try await fixture.requireStatus()
        XCTAssertTrue(failedReview["phases"]?.array?[3]["note"]?.string?.contains("fix what it found") == true)
        let blocked = await fixture.run("pull")
        XCTAssertEqual(blocked.status, 409, "the pull request waits for a review that passes")
        verdict = "✅ REVIEW PASSED"
        _ = await fixture.run("review")
        try await fixture.settled("review", "done")
    }

    func testAPhaseCanBeSkippedOrMarkedDoneByHandWithinTheRules() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        func post(_ phase: String, _ action: String) async -> Int { await fixture.call("POST", "/api/groups/\(fixture.groupId)/cylon/phases/\(phase)/\(action)").status }
        let early = await post("run", "skip")
        XCTAssertEqual(early, 409, "the plan is not over")
        let doneByHand = await post("plan", "done")
        XCTAssertEqual(doneByHand, 200)
        let twice = await post("plan", "done")
        XCTAssertEqual(twice, 409)
        let skipOver = await post("plan", "skip")
        XCTAssertEqual(skipOver, 409, "a phase that is over is not skipped")
        let skipped = await post("run", "skip")
        XCTAssertEqual(skipped, 200)
        let afterwards = try await fixture.requireStatus()
        let phases = afterwards["phases"]?.array ?? []
        XCTAssertEqual(phases.compactMap { $0["state"]?.string }, ["skipped", "done", "skipped", "pending", "pending"])
        XCTAssertEqual(phases[2]["note"], "skipped", "what was not done stays marked")
        XCTAssertEqual(phases[3]["current"], true)
        XCTAssertEqual(phases[3]["canSkip"], true)
        let nothing = await fixture.call("POST", "/api/groups/\(fixture.groupId)/cylon/phases/spec/skip")
        XCTAssertEqual(nothing.status, 409, "already skipped")
        let none = try await CylonFixture()
        let noPipeline = await none.call("POST", "/api/groups/\(none.groupId)/cylon/phases/plan/skip")
        XCTAssertEqual(noPipeline.status, 409)
    }

    func testOnlyTheBotOfTheRunningPhaseMovesIt() async throws {
        let fixture = try await CylonFixture()
        _ = await fixture.start("t1", tag: "cylon-plan")
        fixture.adapter.script = { _, _, emit in fixture.said(emit, "Domanda 1") }
        _ = await fixture.run("plan")
        try await fixture.turnEnded(1)
        let before = await fixture.state("plan")
        XCTAssertEqual(before, "running")
        // someone else speaking in the channel, even saying the closing words, is not the planner
        fixture.adapter.script = { _, _, emit in fixture.said(emit, "/cylon-run cylon-features/x") }
        _ = await fixture.call("POST", "/api/groups/\(fixture.groupId)/messages", ["text": "@Esecutore dimmi qualcosa"])
        try await fixture.turnEnded(2)
        let after = await fixture.state("plan")
        XCTAssertEqual(after, "running")
        XCTAssertEqual(ScriptedAdapter.speaker(try XCTUnwrap(fixture.adapter.received.last)), "Esecutore")
    }

    // MARK: roles and the Cylon source

    func testRolesBelongToTheProjectAndTheirBotsMustExist() async throws {
        let fixture = try await CylonFixture(roles: false)
        let empty = await fixture.call("GET", "/api/cylon/roles")
        XCTAssertEqual(empty.json?["roles"]?.object?.count, 0)
        let bad = await fixture.call("PUT", "/api/cylon/roles/p1", ["plan": "ghost"])
        XCTAssertEqual(bad.status, 400)
        let unknownPhase = await fixture.call("PUT", "/api/cylon/roles/p1", ["dance": .string(fixture.planner)])
        XCTAssertEqual(unknownPhase.status, 400)
        let set = await fixture.call("PUT", "/api/cylon/roles/p1", ["plan": .string(fixture.planner), "run": .string(fixture.runner)])
        XCTAssertEqual(set.json?["roles"]?["plan"]?.string, fixture.planner)
        let cleared = await fixture.call("PUT", "/api/cylon/roles/p1", ["run": .null])
        XCTAssertNil(cleared.json?["roles"]?["run"], "null takes the bot away")
        XCTAssertEqual(cleared.json?["roles"]?["plan"]?.string, fixture.planner, "and leaves the others")
        let status = try await fixture.requireStatus()
        XCTAssertEqual(status["projectId"], "p1")
        XCTAssertEqual(status["phases"]?.array?[1]["bot"]?["name"], "Pianificatore")
        XCTAssertEqual(status["phases"]?.array?[1]["bot"]?["member"], true)
        XCTAssertEqual(status["phases"]?.array?[1]["bot"]?["skillOnBot"], true)
        XCTAssertEqual(status["phases"]?.array?[2]["bot"], .null, "no bot for run")
        // a bot that is deleted leaves its parts
        CylonStore(harness: fixture.harness).forgetBot(fixture.planner)
        XCTAssertNil(CylonStore(harness: fixture.harness).roles(of: "p1")[.plan])
    }

    func testTheCylonSourceHandsItsSkillsToTheBotsThatHaveAPart() async throws {
        let fixture = try await CylonFixture(withSkills: false, roles: false)
        let source = try XCTUnwrap(fixture.harness.skillSources.create(["repo": "acme/cylon-skills"])["id"]?.string)
        let refused = await fixture.call("PUT", "/api/cylon/settings", ["sourceId": "nope"])
        XCTAssertEqual(refused.status, 400)
        let missing = await fixture.call("PUT", "/api/cylon/settings", [:])
        XCTAssertEqual(missing.status, 400)
        let set = await fixture.call("PUT", "/api/cylon/settings", ["sourceId": .string(source)])
        XCTAssertEqual(set.json?["sourceId"]?.string, source)
        _ = await fixture.call("PUT", "/api/cylon/roles/p1", ["plan": .string(fixture.planner), "run": .string(fixture.runner)])
        XCTAssertEqual(Set(fixture.harness.skillSources.sources.first?.assignBots ?? []), [fixture.planner, fixture.runner], "the bots with a part get the source's skills")
        let cleared = await fixture.call("PUT", "/api/cylon/settings", ["sourceId": .null])
        XCTAssertEqual(cleared.json?["sourceId"], .null)
        let status = try await fixture.requireStatus()
        XCTAssertNil(status["source"])
    }

    // MARK: data on the channel

    func testTheSwitchIsDataOfAChannelAndOnlyThat() async throws {
        let fixture = try await CylonFixture(follow: false)
        let on = await fixture.call("PATCH", "/api/groups/\(fixture.groupId)", ["plugins": ["cylon": ["follow": true]]])
        XCTAssertEqual(on.status, 200, String(describing: on.json))
        XCTAssertEqual(fixture.harness.store.group(fixture.groupId)?["plugins"]?["cylon"]?["follow"], true)
        XCTAssertEqual(fixture.harness.store.group(fixture.groupId)?["plugins"]?["code"]?["projectId"], "p1", "the other plugin's data is kept")
        for bad: JSON in [["unknown": true], ["follow": "yes"]] {
            let refused = await fixture.call("PATCH", "/api/groups/\(fixture.groupId)", ["plugins": ["cylon": bad]])
            XCTAssertEqual(refused.status, 400, String(describing: bad))
        }
        let botData = await fixture.call("PATCH", "/api/bots/\(fixture.planner)", ["plugins": ["cylon": ["follow": true]]])
        XCTAssertEqual(botData.status, 400, "a single bot has no flow")
        let plugins = await fixture.call("GET", "/api/plugins")
        let cylon = plugins.json?["plugins"]?.array?.first { $0["id"] == "cylon" }
        XCTAssertEqual(cylon?["enabled"], true)
        XCTAssertEqual(cylon?["requires"], ["code"])
        // it goes with the Code plugin: without it the routes are gone
        _ = await fixture.call("PUT", "/api/plugins/code", ["enabled": false])
        let gone = await fixture.call("GET", "/api/groups/\(fixture.groupId)/cylon")
        XCTAssertNotEqual(gone.status, 200)
    }
}
