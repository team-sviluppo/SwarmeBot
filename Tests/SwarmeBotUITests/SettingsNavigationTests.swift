@testable import SwarmeBotUI
import XCTest

final class SettingsNavigationTests: XCTestCase {
    func testUpdatesIsAlwaysALocalDestinationRegardlessOfUpdaterAvailability() {
        XCTAssertTrue(SettingsSection.allCases.contains(.updates))
        XCTAssertEqual(SettingsSection.initial("updates", sections: SettingsSection.allCases), .updates)
    }

    func testRemoteSettingsDoNotOpenMacOnlySections() {
        for name in ["updates", "phone", "mac", "sharing", "remote"] {
            XCTAssertEqual(SettingsSection.initial(name, sections: SettingsSection.remoteSections), .general)
        }
        for section in SettingsSection.remoteSections {
            XCTAssertEqual(SettingsSection.initial(section.rawValue, sections: SettingsSection.remoteSections), section)
        }
    }

    func testInvalidOrMissingLaunchSelectionFallsBackToGeneral() {
        XCTAssertEqual(SettingsSection.initial(nil, sections: SettingsSection.allCases), .general)
        XCTAssertEqual(SettingsSection.initial("unknown", sections: SettingsSection.allCases), .general)
    }
}
