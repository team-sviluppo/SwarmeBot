@testable import SwarmeKit
import XCTest

final class AppearanceTests: XCTestCase {
    func testRawValuesAreWhatIsStored() {
        XCTAssertEqual(AppAppearance.allCases.map(\.rawValue), ["dark", "light", "system"])
    }

    func testUnknownStoredValueFallsBackToNothing() {
        // the settings fall back to dark when the stored string is not a case
        XCTAssertNil(AppAppearance(rawValue: "sepia"))
        XCTAssertEqual(AppAppearance(rawValue: "light"), .light)
    }
}
