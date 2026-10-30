@testable import CylonPluginEngine
import XCTest

/// How a phase of a Cylon task is told to be over, from what its skill prints and leaves on disk.
final class CylonDetectTests: XCTestCase {
    func testASeedBecomesTheTicketTheSpecNames() {
        let said = "Ho creato il ticket **Pagina di login** (https://app.clickup.com/t/86c2x9k).\n\nPer continuare incolla in una nuova sessione:\n\n```\n/cylon-plan 86c2x9k\n```"
        XCTAssertEqual(CylonDetect.outcome(.spec, text: said, onDisk: nil), .done(ticketId: "86c2x9k"))
        XCTAssertEqual(CylonDetect.nextTicket(in: "/cylon-plan https://app.clickup.com/t/9000/abc123"), "abc123", "the ticket's address will do in place of its id")
        XCTAssertEqual(CylonDetect.nextTicket(in: "prima /cylon-plan old1 poi /cylon-plan new2"), "new2", "the last one is the next step")
        XCTAssertNil(CylonDetect.nextTicket(in: "/cylon-plan <id>"), "a placeholder is no ticket")
        XCTAssertEqual(CylonDetect.outcome(.spec, text: "Quale utente deve vedere la pagina?", onDisk: nil), .waiting, "an interview ends turns with questions")
    }

    func testAPlanIsOverWhenItsFileSaysApproved() {
        XCTAssertEqual(CylonDetect.outcome(.plan, text: "Ti ho scritto il piano: va bene?", onDisk: ("login-page", false)), .waiting)
        XCTAssertEqual(CylonDetect.outcome(.plan, text: "ok", onDisk: ("login-page", true)), .done(slug: "login-page"), "the file is better evidence than the chat")
        XCTAssertEqual(CylonDetect.outcome(.plan, text: "Per eseguire:\n/cylon-run cylon-features/login-page", onDisk: nil), .done(slug: "login-page"), "or the command it ends with")
        XCTAssertEqual(CylonDetect.outcome(.plan, text: "Domanda 3 di 7", onDisk: nil), .waiting)
    }

    func testPlanApprovalIsReadFromTheFrontMatterOnly() {
        XCTAssertTrue(CylonDetect.planApproved(text: "---\nstatus: approved\n---\n# Piano\n"))
        XCTAssertTrue(CylonDetect.planApproved(text: "---\r\ntitle: x\r\nstatus: approved\r\n---\r\nbody"))
        XCTAssertFalse(CylonDetect.planApproved(text: "---\nstatus: draft\n---\n"))
        XCTAssertFalse(CylonDetect.planApproved(text: "# Piano\n\nstatus: approved\n"), "no front matter")
        XCTAssertFalse(CylonDetect.planApproved(text: "---\nstatus: draft\n---\nstatus: approved\n"), "only the front matter counts")
        XCTAssertFalse(CylonDetect.planApproved(text: ""))
    }

    func testARunIsOverWhenItNamesThePullCommand() {
        let said = "Ho implementato i passi 1-4. Il timer resta attivo.\n\n```\n/cylon-pull cylon-features/login-page\n```"
        XCTAssertEqual(CylonDetect.outcome(.run, text: said, onDisk: nil), .done(slug: "login-page"))
        XCTAssertEqual(CylonDetect.outcome(.run, text: "Il piano non si può seguire: manca src/login.ts", onDisk: nil), .waiting, "it stopped to say why")
    }

    func testAReviewIsJudgedOnItsLastLine() {
        XCTAssertEqual(CylonDetect.outcome(.review, text: "Report\n\nTutto ok.\n\n✅ REVIEW PASSED\n", onDisk: nil), .done())
        guard case .failed = CylonDetect.outcome(.review, text: "Problemi:\n- manca il test\n\n❌ REVIEW FAILED", onDisk: nil) else { return XCTFail("a failed review") }
        XCTAssertEqual(CylonDetect.outcome(.review, text: "Se fosse REVIEW FAILED lo direi qui\nMa non ho finito", onDisk: nil), .waiting, "the word in the middle of the text is no verdict")
        XCTAssertEqual(CylonDetect.outcome(.review, text: "", onDisk: nil), .waiting)
    }

    func testAPullIsOverWhenThePullRequestIsThere() {
        XCTAssertEqual(CylonDetect.outcome(.pull, text: "PR aperta: https://github.com/team-sviluppo/titiro-api/pull/42 — ticket aggiornato", onDisk: nil),
                       .done(prUrl: "https://github.com/team-sviluppo/titiro-api/pull/42"))
        XCTAssertEqual(CylonDetect.outcome(.pull, text: "Non sono riuscito ad aprirla: https://github.com/o/r/compare/main...feature", onDisk: nil), .waiting, "a compare link is no pull request")
    }

    func testTheTicketIsTheIdOrTheLastPartOfItsAddress() {
        XCTAssertEqual(CylonDetect.ticketId("86c2x9k"), "86c2x9k")
        XCTAssertEqual(CylonDetect.ticketId("  86c2x9k \n"), "86c2x9k")
        XCTAssertEqual(CylonDetect.ticketId("https://app.clickup.com/t/86c2x9k?foo=1#bar"), "86c2x9k")
        XCTAssertEqual(CylonDetect.ticketId("https://app.clickup.com/t/9000123/CU-abc"), "CU-abc")
        for bad in ["", "two words", "https://evil.example/t/abc", "a/b", "../x", String(repeating: "a", count: 65)] {
            XCTAssertNil(CylonDetect.ticketId(bad), bad)
        }
    }

    func testEachPhaseSendsItsSkillWithTheRightArgument() {
        XCTAssertEqual(CylonDetect.command(.spec, ticketId: "t1", slug: nil), "/cylon-spec t1")
        XCTAssertEqual(CylonDetect.command(.plan, ticketId: "t1", slug: nil), "/cylon-plan t1", "the first time: the ticket")
        XCTAssertEqual(CylonDetect.command(.plan, ticketId: "t1", slug: "login"), "/cylon-plan cylon-features/login", "later: the folder, to pick it up")
        XCTAssertEqual(CylonDetect.command(.run, ticketId: "t1", slug: "login"), "/cylon-run cylon-features/login")
        XCTAssertEqual(CylonDetect.command(.review, ticketId: "t1", slug: "login"), "/cylon-review cylon-features/login")
        XCTAssertEqual(CylonDetect.command(.pull, ticketId: "t1", slug: "login"), "/cylon-pull cylon-features/login")
        XCTAssertNil(CylonDetect.command(.run, ticketId: "t1", slug: nil), "nothing to run until the plan has made its folder")
    }

    func testTheTaskFolderIsFoundByItsTicket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cylon-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ slug: String, ticket: String, plan: String?) throws {
            let directory = root.appendingPathComponent("cylon-features/\(slug)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"clickup_task_id":"\#(ticket)","branch":"feature/\#(slug)"}"#.utf8).write(to: directory.appendingPathComponent(".data.json"))
            if let plan { try Data(plan.utf8).write(to: directory.appendingPathComponent("plan.md")) }
        }
        try make("other-task", ticket: "zzz", plan: "---\nstatus: approved\n---\n")
        try make("login-page", ticket: "t1", plan: "---\nstatus: draft\n---\n")
        let found = CylonDetect.onDisk(folder: root.path, ticketId: "t1", slug: nil)
        XCTAssertEqual(found?.slug, "login-page")
        XCTAssertEqual(found?.approved, false)
        try Data("---\nstatus: approved\n---\n".utf8).write(to: root.appendingPathComponent("cylon-features/login-page/plan.md"))
        XCTAssertEqual(CylonDetect.onDisk(folder: root.path, ticketId: "t1", slug: "login-page")?.approved, true, "a folder already known is not searched for")
        XCTAssertNil(CylonDetect.onDisk(folder: root.path, ticketId: "nobody", slug: nil))
        XCTAssertEqual(CylonDetect.onDisk(folder: root.path, ticketId: "t1", slug: "gone")?.slug, "login-page", "a known folder that is gone falls back to searching for the ticket's")
        XCTAssertNil(CylonDetect.onDisk(folder: nil, ticketId: "t1", slug: nil))
        XCTAssertNil(CylonDetect.onDisk(folder: "/definitely/not/a/folder", ticketId: "t1", slug: nil))
    }

    func testTheOrderOfTheFlowAndWhatBlocksWhat() {
        var pipeline = CylonPipeline(ticketId: "t1", tag: "cylon-plan", title: nil)
        XCTAssertEqual(pipeline.state(.spec), .skipped, "a ticket tagged for planning is already a specification")
        XCTAssertEqual(pipeline.next, .plan)
        XCTAssertTrue(pipeline.earlierResolved(.plan))
        XCTAssertFalse(pipeline.earlierResolved(.run), "the plan is not over")
        pipeline.phases[.plan]?.state = .done
        XCTAssertTrue(pipeline.earlierResolved(.run))
        XCTAssertFalse(pipeline.earlierResolved(.review))
        pipeline.phases[.run]?.state = .running
        XCTAssertEqual(pipeline.running, .run)
        XCTAssertEqual(pipeline.next, .run)
        let seeded = CylonPipeline(ticketId: "t2", tag: "cylon-spec", title: "Login")
        XCTAssertEqual(seeded.next, .spec)
        XCTAssertEqual(seeded.title, "Login")
    }

    func testAPipelineSurvivesTheFile() throws {
        var pipeline = CylonPipeline(ticketId: "t1", tag: "cylon-spec", title: "Login")
        pipeline.specTicketId = "seed"
        pipeline.slug = "login-page"
        pipeline.prUrl = "https://github.com/o/r/pull/1"
        pipeline.phases[.spec] = CylonPipeline.Entry(state: .done, botId: "b1", startedAt: 1, finishedAt: 2, fromCount: 3, note: "marked as done")
        pipeline.phases[.plan]?.state = .failed
        let again = try XCTUnwrap(CylonPipeline(json: pipeline.json))
        XCTAssertEqual(again.ticketId, "t1")
        XCTAssertEqual(again.specTicketId, "seed")
        XCTAssertEqual(again.slug, "login-page")
        XCTAssertEqual(again.state(.spec), .done)
        XCTAssertEqual(again.phases[.spec]?.fromCount, 3)
        XCTAssertEqual(again.phases[.spec]?.note, "marked as done")
        XCTAssertEqual(again.state(.plan), .failed)
        XCTAssertEqual(again.state(.pull), .pending)
        XCTAssertNil(CylonPipeline(json: ["nothing": true]))
    }
}
