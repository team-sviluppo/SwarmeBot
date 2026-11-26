import CompanionCore
@testable import SwarmeBotUI
import XCTest

@MainActor
final class SidebarOrderTests: XCTestCase {
    func testStoredFormRoundTrips() {
        for item in [SidebarItem.section("Hextra"), .section(""), .unassigned, .rooms, .engine("e1")] {
            XCTAssertEqual(SidebarItem(stored: item.stored), item)
        }
        XCTAssertNil(SidebarItem(stored: "nonsense"))
    }

    func testNewItemsGoWhereTheSidebarHadThem() {
        // an order saved before channels and servers could move
        let saved: [SidebarItem] = [.section("Hextra"), .section("Utility")]
        let order = SectionLayout.completed(saved, with: [.section("Harness"), .rooms, .engine("e1")])
        XCTAssertEqual(order, [.section("Hextra"), .section("Utility"), .section("Harness"), .unassigned, .rooms, .engine("e1")])
    }

    func testANewSectionStaysAmongTheSections() {
        let saved: [SidebarItem] = [.rooms, .section("Hextra"), .engine("e1"), .unassigned]
        let order = SectionLayout.completed(saved, with: [.section("Utility"), .engine("e2")])
        XCTAssertEqual(order, [.rooms, .section("Hextra"), .section("Utility"), .engine("e1"), .unassigned, .engine("e2")])
    }

    func testDraggedItemTakesTheTargetsPlace() {
        let order: [SidebarItem] = [.section("A"), .section("B"), .unassigned, .rooms, .engine("e1")]
        // up: above the target
        XCTAssertEqual(SectionLayout.moving(.rooms, to: .section("A"), in: order),
                       [.rooms, .section("A"), .section("B"), .unassigned, .engine("e1")])
        // down: below it, so the last place can be reached
        XCTAssertEqual(SectionLayout.moving(.section("A"), to: .engine("e1"), in: order),
                       [.section("B"), .unassigned, .rooms, .engine("e1"), .section("A")])
        XCTAssertEqual(SectionLayout.moving(.rooms, to: .rooms, in: order), order)
    }

    private func bot(_ id: String, pinned: Bool = false) throws -> Bot {
        let json = #"{"id":"\#(id)","threadId":"t\#(id)","name":"\#(id)","title":"","description":"","notifications":true,"color":"blue","unread":false,"modelSelection":{"instanceId":"i","model":"m"},"createdAt":1,"pinned":\#(pinned)}"#
        return try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
    }

    func testBotsFollowTheSavedOrderPinnedFirstUnknownLast() throws {
        let bots = try [bot("a"), bot("b"), bot("c", pinned: true), bot("d"), bot("e")]
        let sorted = BotOrder.sorted(bots, by: ["d", "x", "b", "a"])
        XCTAssertEqual(sorted.map(\.id), ["c", "d", "b", "a", "e"])
    }

    func testDraggedBotTakesTheTargetsPlace() {
        let list = ["a", "b", "c", "d"]
        // the other blocks' ids keep their relative order, this block goes after them
        XCTAssertEqual(BotOrder.reordered(["z", "b", "y"], list: list, moving: "d", to: "b"), ["z", "y", "a", "d", "b", "c"])
        XCTAssertEqual(BotOrder.reordered([], list: list, moving: "a", to: "c"), ["b", "c", "a", "d"])
        // from another section: just above the target
        XCTAssertEqual(BotOrder.reordered([], list: list, moving: "x", to: "c"), ["a", "b", "x", "c", "d"])
        XCTAssertEqual(BotOrder.reordered(["q"], list: list, moving: "a", to: "a"), ["q"])
    }

    func testPinnedBotsMoveOnlyAmongThemselves() throws {
        let list = try [bot("p", pinned: true), bot("a"), bot("b")]
        XCTAssertFalse(BotOrder.canMove("a", by: -1, in: list))
        XCTAssertTrue(BotOrder.canMove("a", by: 1, in: list))
        XCTAssertFalse(BotOrder.canMove("p", by: 1, in: list))
        XCTAssertFalse(BotOrder.canMove("b", by: 1, in: list))
    }

    func testMenuMovesAmongTheBlocksShown() {
        let shown: [SidebarItem] = [.section("A"), .rooms, .engine("e1")]
        XCTAssertFalse(SectionLayout.canMove(.section("A"), by: -1, among: shown))
        XCTAssertTrue(SectionLayout.canMove(.rooms, by: -1, among: shown))
        XCTAssertFalse(SectionLayout.canMove(.engine("e1"), by: 1, among: shown))
        XCTAssertFalse(SectionLayout.canMove(.unassigned, by: 1, among: shown), "not shown")
    }
}
