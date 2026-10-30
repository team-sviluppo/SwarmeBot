@testable import CylonPluginApp
import CompanionCore
import XCTest

/// The board as the engine answers it (`GET /api/cylon/boards`, Plugins/Cylon/Engine/CylonBoards.swift), its order and
/// the channels a ticket can go to.
@MainActor
final class CylonBoardWireTests: XCTestCase {
    /// A real answer, cut: one ticket started and waiting for the person, one not started, one on a channel that works
    /// on another ticket.
    private let live = """
    {"boards":[{"id":"b1","projectId":"p1","title":"Login con Google","createdAt":1793346917680,"parentUrl":"https://app.clickup.com/t/86c2x00","items":[
    {"id":"i1","role":"backend","groupId":"g1","ticketId":"86c2x9k","tag":"cylon-plan","title":"API login Google","state":"waiting","channel":{"name":"Backend Titiro","follows":true},
     "flow":{"follow":true,"phases":[{"key":"spec","skill":"cylon-spec","bot":null,"state":"skipped"},{"key":"plan","skill":"cylon-plan","bot":{"botId":"b1","name":"Pianificatore","member":true,"skillOnEngine":true,"skillOnBot":true,"busy":false},"state":"running","current":true,"canRun":false,"canSkip":false,"canMarkDone":true}],
     "busy":false,"projectId":"p1","pipeline":{"ticketId":"86c2x9k","tag":"cylon-plan","title":"API login Google","slug":"api-login-google","finished":false}}},
    {"id":"i2","role":"app","groupId":"g2","ticketId":"86c2xb4","tag":"cylon-plan","state":"not-started","channel":{"name":"App Titiro","follows":true},
     "flow":{"follow":true,"phases":[{"key":"spec","skill":"cylon-spec","bot":null},{"key":"plan","skill":"cylon-plan","bot":null}],"busy":false,"projectId":"p1","pipeline":null}},
    {"id":"i3","role":"backoffice","groupId":"g3","ticketId":"86c2xa1","tag":"cylon-spec","state":"other-ticket","channel":{"name":"Backoffice Titiro","follows":true},"prUrl":"https://github.com/o/r/pull/7",
     "flow":{"follow":true,"phases":[],"busy":false,"projectId":"p1","pipeline":{"ticketId":"86c2zzz","tag":"cylon-plan","title":"Altro","slug":"altro","finished":false}}}],
    "summary":{"total":3,"done":0,"prOpen":0,"running":1,"notStarted":1,"problems":1},
    "busyBots":[{"botId":"b1","name":"Pianificatore","channel":"Backend Titiro"},{"botId":"b2","name":"Revisore"}]}]}
    """

    private func boards() throws -> [CylonBoardWire] {
        struct Answer: Decodable { var boards: [CylonBoardWire] }
        return try JSONDecoder().decode(Answer.self, from: Data(live.utf8)).boards
    }

    private func room(_ plugins: String?) throws -> Room {
        let extra = plugins.map { #","plugins":\#($0)"# } ?? ""
        return try JSONDecoder().decode(Room.self, from: Data(#"{"id":"g\#(plugins?.count ?? 0)","threadId":"t","name":"x","memberIds":[],"defaultResponder":{"kind":"everyone"},"bulletin":"","unread":false,"createdAt":1\#(extra)}"#.utf8))
    }

    func testTheBoardIsReadWithItsTicketsInOrder() throws {
        let board = try XCTUnwrap(boards().first)
        XCTAssertEqual(board.title, "Login con Google")
        XCTAssertEqual(board.parentUrl, "https://app.clickup.com/t/86c2x00")
        XCTAssertEqual(board.items.map(\.ticketId), ["86c2x9k", "86c2xb4", "86c2xa1"], "the order of the array is the priority")
        XCTAssertEqual(board.items.map(\.state), ["waiting", "not-started", "other-ticket"])
        XCTAssertEqual(board.items[0].channel?.name, "Backend Titiro")
        XCTAssertEqual(board.items[0].flow?.phases.map(\.key), ["spec", "plan"])
        XCTAssertEqual(board.items[0].flow?.current?.key, "plan")
        XCTAssertEqual(board.items[0].url?.absoluteString, "https://app.clickup.com/t/86c2x9k")
        XCTAssertNil(board.items[1].title, "a ticket may have no name")
        XCTAssertEqual(board.summary.notStarted, 1)
        XCTAssertEqual(board.busyBots.map(\.name), ["Pianificatore", "Revisore"])
        XCTAssertEqual(board.busyBots[0].channel, "Backend Titiro")
        XCTAssertNil(board.busyBots[1].channel, "a bot may be busy in a chat of its own")
    }

    func testTheOtherTicketIsTheOneTheChannelWorksOn() throws {
        let items = try XCTUnwrap(boards().first).items
        XCTAssertEqual(items[2].otherTicket, "86c2zzz")
        XCTAssertNil(items[0].otherTicket, "only a channel working on another ticket has one to name")
    }

    func testABoardIsLookedAtAgainSoonWhileATicketMoves() throws {
        let board = try XCTUnwrap(boards().first)
        XCTAssertEqual(CylonState.pollInterval([board]), .seconds(5), "one is waiting for the person, none is being worked on")
        var running = board
        running.items[0].state = "running"
        XCTAssertEqual(CylonState.pollInterval([running]), .seconds(2))
        var idle = board
        idle.items = [idle.items[1]]
        XCTAssertEqual(CylonState.pollInterval([idle]), .seconds(12), "nothing is started")
        XCTAssertEqual(CylonState.pollInterval([]), .seconds(12))
    }

    func testDraggingATicketGivesTheNewOrder() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(CylonBoardOrder.moved(ids, from: IndexSet(integer: 2), to: 0), ["c", "a", "b", "d"], "to the top")
        XCTAssertEqual(CylonBoardOrder.moved(ids, from: IndexSet(integer: 0), to: 4), ["b", "c", "d", "a"], "to the bottom")
        XCTAssertEqual(CylonBoardOrder.moved(ids, from: IndexSet(integer: 0), to: 2), ["b", "a", "c", "d"], "SwiftUI's destination counts the list before the move")
        XCTAssertEqual(CylonBoardOrder.moved(ids, from: IndexSet(integer: 3), to: 1), ["a", "d", "b", "c"])
        XCTAssertEqual(CylonBoardOrder.moved(ids, from: IndexSet(integer: 1), to: 1), ids, "dropped where it was")
        XCTAssertEqual(CylonBoardOrder.moved(ids, from: IndexSet(integer: 1), to: 2), ids, "one place down from itself is the same place")
        XCTAssertEqual(CylonBoardOrder.moved(ids, from: IndexSet([0, 1]), to: 4), ["c", "d", "a", "b"], "several at once keep their order")
        XCTAssertEqual(CylonBoardOrder.moved(["a"], from: IndexSet(integer: 0), to: 1), ["a"])
        XCTAssertEqual(Set(CylonBoardOrder.moved(ids, from: IndexSet(integer: 1), to: 3)), Set(ids), "nothing is lost or doubled")
    }

    func testATicketGoesToTheChannelsThatWorkOnItsRepoAndFollowTheFlow() throws {
        let backend = try room(#"{"code":{"projectId":"p1","role":"backend"},"cylon":{"follow":true}}"#)
        let sameWithoutFlow = try room(#"{"code":{"projectId":"p1","role":"backend"}}"#)
        let otherProject = try room(#"{"code":{"projectId":"p2","role":"backend"},"cylon":{"follow":true}}"#)
        let otherRole = try room(#"{"code":{"projectId":"p1","role":"app"},"cylon":{"follow":true}}"#)
        let noRole = try room(#"{"code":{"projectId":"p1"},"cylon":{"follow":true}}"#)
        let rooms = [sameWithoutFlow, otherProject, otherRole, noRole, backend]
        XCTAssertEqual(CylonBoardChannels.candidates(rooms: rooms, projectId: "p1", role: "backend").map(\.id), [backend.id])
        XCTAssertEqual(CylonBoardChannels.candidates(rooms: rooms, projectId: "p1", role: "app").map(\.id), [otherRole.id])
        XCTAssertTrue(CylonBoardChannels.candidates(rooms: rooms, projectId: "p1", role: "bruno").isEmpty, "no channel works on it: the sheet says to make one")
    }

    func testAProjectKnowsTheRolesItsTicketsCanBelongTo() throws {
        let project = try JSONDecoder().decode(CylonProject.self, from: Data(#"{"id":"p1","name":"Titiro","repos":[{"role":"backend","path":"/a"},{"role":"app","path":"/b","scripts":[]}],"createdAt":1}"#.utf8))
        XCTAssertEqual(project.repos?.map(\.role), ["backend", "app"])
        let bare = try JSONDecoder().decode(CylonProject.self, from: Data(#"{"id":"p2","name":"Vuoto"}"#.utf8))
        XCTAssertNil(bare.repos)
    }

    func testEachRoleHasATitle() {
        for role in ["backend", "backoffice", "app", "bruno"] { XCTAssertFalse(CylonRoleTitle.title(role).isEmpty, role) }
        XCTAssertEqual(CylonRoleTitle.title("unknown"), "unknown", "an unknown role is shown as it is")
    }
}
