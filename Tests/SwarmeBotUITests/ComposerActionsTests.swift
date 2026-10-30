@testable import SwarmeBotUI
import XCTest

final class ComposerActionsTests: XCTestCase {
    func testAnExtraPRChipWrapsTheFollowingActionsWithoutOverlap() {
        let sizes = [160, 110, 180, 50, 90, 130, 100].map { CGSize(width: $0, height: 26) }
        let frames = ComposerActionsLayout.frames(sizes: sizes, width: 520)
        XCTAssertEqual(frames.count, sizes.count)
        XCTAssertEqual(frames[4].minY, 34, "the PR and remaining actions move onto another row")
        for (frame, size) in zip(frames, sizes) {
            XCTAssertEqual(frame.size, size)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, 520)
        }
        for index in frames.indices {
            for other in frames.indices where other > index {
                XCTAssertFalse(frames[index].intersects(frames[other]))
            }
        }
    }

    func testResizingBackToAWideColumnKeepsEverythingOnOneRow() {
        let sizes = [CGSize(width: 160, height: 26), CGSize(width: 110, height: 26), CGSize(width: 90, height: 26)]
        XCTAssertEqual(ComposerActionsLayout.frames(sizes: sizes, width: 200).last?.minY, 68)
        XCTAssertTrue(ComposerActionsLayout.frames(sizes: sizes, width: 400).allSatisfy { $0.minY == 0 })
    }

    func testHiddenChipsDoNotReserveSpaceAndRowsRespectTallControls() {
        let frames = ComposerActionsLayout.frames(sizes: [CGSize(width: 100, height: 40), .zero,
                                                        CGSize(width: 100, height: 26)], width: 200)
        XCTAssertEqual(frames[1].size, .zero)
        XCTAssertEqual(frames[2].origin, CGPoint(x: 0, y: 48))
    }

    func testAnOversizedControlRemainsPartOfTheScrollableContent() {
        let frames = ComposerActionsLayout.frames(sizes: [CGSize(width: 300, height: 26), CGSize(width: 90, height: 26)], width: 200)
        XCTAssertEqual(frames[0].width, 300)
        XCTAssertEqual(frames[1].origin, CGPoint(x: 0, y: 34))
    }
}
