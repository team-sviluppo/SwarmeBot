@testable import CylonPluginApp
import CompanionCore
import SwarmeKit
import XCTest

/// The flow as the engine answers it (`GET /api/groups/:gid/cylon`, Plugins/Cylon/Engine), and what the bar says of it.
@MainActor
final class CylonWireTests: XCTestCase {
    /// A real answer of the engine, cut to two phases: the plan done, the run being worked on.
    private let live = """
    {"follow": true, "phases": [{"key": "plan", "skill": "cylon-plan", "bot": {"botId": "b1", "name": "Pianificatore", "member": true, "skillOnEngine": true, "skillOnBot": true}, "state": "done", "current": false, "canRun": true, "canSkip": false, "canMarkDone": false, "command": "/cylon-plan cylon-features/pagina-di-login", "finishedAt": 1793303198822}, {"key": "run", "skill": "cylon-run", "bot": {"botId": "b1", "name": "Esecutore", "member": true, "skillOnEngine": true, "skillOnBot": true}, "state": "running", "current": true, "canRun": false, "canSkip": false, "canMarkDone": true, "command": "/cylon-run cylon-features/pagina-di-login"}], "busy": false, "projectId": "p1", "pipeline": {"ticketId": "86c2x9k", "tag": "cylon-plan", "title": "Pagina di login", "slug": "pagina-di-login", "finished": false}}
    """

    private func decode(_ json: String) throws -> CylonStatus {
        try JSONDecoder().decode(CylonStatus.self, from: Data(json.utf8))
    }

    func testTheEnginesAnswerIsRead() throws {
        let status = try decode(live)
        XCTAssertTrue(status.follow)
        XCTAssertEqual(status.pipeline?.ticketId, "86c2x9k")
        XCTAssertEqual(status.pipeline?.slug, "pagina-di-login")
        XCTAssertEqual(status.pipeline?.title, "Pagina di login")
        XCTAssertEqual(status.phases.map(\.key), ["plan", "run"])
        XCTAssertEqual(status.phases.map(\.state), ["done", "running"])
        XCTAssertTrue(status.phases[0].isDone)
        XCTAssertFalse(status.phases[1].isDone)
        XCTAssertEqual(status.phases[1].command, "/cylon-run cylon-features/pagina-di-login")
        XCTAssertEqual(status.phases[1].bot?.name, "Esecutore")
        XCTAssertTrue(status.running, "a phase is being worked on")
        XCTAssertEqual(status.current?.key, "run")
    }

    func testAChannelWithNoTicketHasNoPipelineAndNoStates() throws {
        let json = #"{"follow":true,"busy":false,"projectId":null,"pipeline":null,"phases":[{"key":"spec","skill":"cylon-spec","bot":null},{"key":"plan","skill":"cylon-plan","bot":null}]}"#
        let status = try decode(json)
        XCTAssertNil(status.pipeline)
        XCTAssertNil(status.projectId)
        XCTAssertNil(status.phases[0].state)
        XCTAssertNil(status.current)
        XCTAssertFalse(status.running)
    }

    func testWhatIsMissingForAPhaseIsSaidInTheOrderItMatters() throws {
        func status(project: String?, bot: String, source: String = "null") throws -> CylonStatus {
            let projectJSON = project.map { "\"\($0)\"" } ?? "null"
            return try decode(#"{"follow":true,"busy":false,"projectId":\#(projectJSON),"pipeline":null,"phases":[{"key":"run","skill":"cylon-run","bot":\#(bot)}],"source":\#(source)}"#)
        }
        func problem(_ status: CylonStatus) -> String? { CylonState.problem(status.phases[0], status: status) }

        XCTAssertEqual(try problem(status(project: nil, bot: "null")), tr("Il canale non ha un progetto: sceglilo nelle sue impostazioni."), "no project: that comes first")
        XCTAssertEqual(try problem(status(project: "p1", bot: "null")), tr("Nessun bot per %@: scegli in Impostazioni › Plugin › Cylon.", CylonPhaseKey.title("run")))
        let notMember = #"{"botId":"b","name":"Esecutore","member":false,"skillOnEngine":true,"skillOnBot":true}"#
        XCTAssertEqual(try problem(status(project: "p1", bot: notMember)), tr("%@ fa %@ ma non è un membro del canale.", "Esecutore", CylonPhaseKey.title("run")))
        let noSkill = #"{"botId":"b","name":"Esecutore","member":true,"skillOnEngine":false,"skillOnBot":false}"#
        XCTAssertEqual(try problem(status(project: "p1", bot: noSkill)), tr("La skill %@ non è su questo motore: aggiungi la sorgente in Impostazioni › Skill.", "cylon-run"))
        let botLacks = #"{"botId":"b","name":"Esecutore","member":true,"skillOnEngine":true,"skillOnBot":false}"#
        XCTAssertEqual(try problem(status(project: "p1", bot: botLacks)), tr("%@ non ha la skill %@.", "Esecutore", "cylon-run"))
        let source = #"{"id":"s","name":"Cylon","ok":true,"installed":true,"missing":[]}"#
        XCTAssertNil(try problem(status(project: "p1", bot: botLacks, source: source)), "with a source set the engine hands the skill over when the phase goes out")
        let fine = #"{"botId":"b","name":"Esecutore","member":true,"skillOnEngine":true,"skillOnBot":true}"#
        XCTAssertNil(try problem(status(project: "p1", bot: fine)))
    }

    func testTheEngineIsAskedSoonWhileSomethingRunsAndRarelyWhenNothingDoes() throws {
        XCTAssertEqual(CylonState.pollInterval(try decode(live)), .seconds(2))
        let idle = try decode(#"{"follow":true,"busy":false,"projectId":null,"pipeline":null,"phases":[]}"#)
        XCTAssertEqual(CylonState.pollInterval(idle), .seconds(15))
        let busy = try decode(#"{"follow":true,"busy":true,"projectId":null,"pipeline":null,"phases":[]}"#)
        XCTAssertEqual(CylonState.pollInterval(busy), .seconds(2), "a working channel may finish a phase any moment")
        XCTAssertEqual(CylonState.pollInterval(nil), .seconds(5))
    }

    func testAChannelFollowsTheFlowOnlyWithItsSwitch() throws {
        func room(_ plugins: String?) throws -> Room {
            let extra = plugins.map { #","plugins":\#($0)"# } ?? ""
            return try JSONDecoder().decode(Room.self, from: Data(#"{"id":"g","threadId":"t","name":"x","memberIds":[],"defaultResponder":{"kind":"everyone"},"bulletin":"","unread":false,"createdAt":1\#(extra)}"#.utf8))
        }
        XCTAssertTrue(CylonAppPlugin.follows(try room(#"{"cylon":{"follow":true}}"#)))
        XCTAssertFalse(CylonAppPlugin.follows(try room(#"{"cylon":{"follow":false}}"#)))
        XCTAssertFalse(CylonAppPlugin.follows(try room(#"{"code":{"projectId":"p1"}}"#)), "another plugin's data is not the switch")
        XCTAssertFalse(CylonAppPlugin.follows(try room(nil)))
        XCTAssertFalse(CylonAppPlugin.follows(try room(#"{"cylon":{"follow":"yes"}}"#)))
    }

    func testPhasesHaveTheirOwnWords() {
        XCTAssertEqual(CylonPhaseKey.all, ["spec", "plan", "run", "review", "pull"], "the order the engine imposes")
        for key in CylonPhaseKey.all {
            XCTAssertNotEqual(CylonPhaseKey.title(key), key)
            XCTAssertNotEqual(CylonPhaseKey.verb(key), key)
        }
        XCTAssertEqual(CylonPhaseKey.title("other"), "other")
    }
}
