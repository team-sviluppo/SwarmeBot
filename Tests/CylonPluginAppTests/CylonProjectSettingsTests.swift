@testable import CylonPluginApp
import CompanionCore
@testable import SwarmeBotUI
@testable import SwarmeKit
import XCTest

@MainActor
final class CylonProjectSettingsAppTests: XCTestCase {
    func testClickUpSettingsAreContributedOnlyByAnEnabledCylonPlugin() {
        let model = AppModel()
        let host = PluginHost()
        host.install([CylonAppPlugin()])
        model.enginePlugins = [EnginePluginInfo(id: "cylon", name: "Cylon", version: "1.2.0", enabled: true)]
        XCTAssertEqual(host.settingsSections(.global, on: model).count, 1)
        model.enginePlugins[0].enabled = false
        XCTAssertTrue(host.settingsSections(.global, on: model).isEmpty)
    }

    func testBoardNamesComeFromRepositoryLabelsWithALegacyFallback() throws {
        let value = #"{"id":"p","name":"P","repos":[{"role":"repo-uuid","label":"Warehouse"},{"role":"backend"},{"role":"default","label":"Default"}]}"#
        let project = try JSONDecoder().decode(CylonProject.self, from: Data(value.utf8))
        XCTAssertEqual(project.repositoryLabel("repo-uuid"), "Warehouse")
        XCTAssertEqual(project.repositoryLabel("backend"), "Backend")
        XCTAssertEqual(project.repositoryLabel("default"), "Default")
    }
}
