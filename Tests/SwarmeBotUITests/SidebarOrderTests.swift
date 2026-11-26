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

    func testMenuMovesAmongTheBlocksShown() {
        let shown: [SidebarItem] = [.section("A"), .rooms, .engine("e1")]
        XCTAssertFalse(SectionLayout.canMove(.section("A"), by: -1, among: shown))
        XCTAssertTrue(SectionLayout.canMove(.rooms, by: -1, among: shown))
        XCTAssertFalse(SectionLayout.canMove(.engine("e1"), by: 1, among: shown))
        XCTAssertFalse(SectionLayout.canMove(.unassigned, by: 1, among: shown), "not shown")
    }
}
