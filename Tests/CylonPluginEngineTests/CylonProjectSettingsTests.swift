@testable import CylonPluginEngine
@testable import HarnessCore
import XCTest

@MainActor
final class CylonProjectSettingsTests: XCTestCase {
    private func project(_ f: CylonFixture) async throws -> String {
        let made = await f.call("POST", "/api/projects", ["name": "P", "clickupListId": "legacy-list",
            "repos": [["role": "default", "label": "Default", "path": .string(f.folder.path)]]])
        XCTAssertEqual(made.status, 201)
        return try XCTUnwrap(made.json?["project"]?["id"]?.string)
    }

    func testLegacyClickUpMovesToCylonAndClearingDoesNotResurrectTheOldValue() async throws {
        let f = try await CylonFixture()
        let id = try await project(f)
        let initial = await f.call("GET", "/api/cylon/projects/\(id)")
        XCTAssertEqual(initial.json?["clickupListId"], "legacy-list")
        let updated = await f.call("PUT", "/api/cylon/projects/\(id)", ["clickupListId": "new-list"])
        XCTAssertEqual(updated.json?["clickupListId"], "new-list")
        XCTAssertEqual(CylonStore(harness: f.harness).read("projects.json")[id]?["clickupListId"], "new-list")
        let cleared = await f.call("PUT", "/api/cylon/projects/\(id)", ["clickupListId": .null])
        XCTAssertEqual(cleared.json?["clickupListId"], .null)
        let reloaded = await f.call("GET", "/api/cylon/projects/\(id)")
        XCTAssertEqual(reloaded.json?["clickupListId"], .null)
        let bad = await f.call("PUT", "/api/cylon/projects/\(id)", ["clickupListId": "bad list!"])
        XCTAssertEqual(bad.status, 400)
        let unknown = await f.call("PUT", "/api/cylon/projects/no-such-project", ["clickupListId": "a"])
        XCTAssertEqual(unknown.status, 404)
    }

    func testClickUpContextAndRoutesDisappearWhenCylonIsDisabled() async throws {
        let f = try await CylonFixture()
        let id = try await project(f)
        f.harness.store.patchGroup(f.groupId, ["plugins": ["code": ["projectId": .string(id), "role": "default"]]])
        func setup() -> TurnSetup {
            var value = TurnSetup(botId: f.runner, threadId: f.threadId, groupId: f.groupId, driverKind: "claudeAgent",
                bot: f.harness.store.bot(f.runner)!, group: f.harness.store.group(f.groupId), cwd: f.folder.path)
            f.harness.plugins.beforeTurn(&value)
            return value
        }
        let enabled = setup()
        XCTAssertTrue(enabled.system.contains("legacy-list"))
        let enabledFile = try XCTUnwrap(enabled.environment["SWARME_PROJECT_JSON"])
        XCTAssertEqual(try JSON.parse(Data(contentsOf: URL(fileURLWithPath: enabledFile)))["clickupListId"], "legacy-list")
        let oldExport = f.harness.plugins.directory(for: "code").appendingPathComponent("projects/" + id + ".json")
        try FileIO.writeAtomic(JSON.object(["clickupListId": "legacy-list"]).data, to: oldExport)
        try f.harness.plugins.setEnabled("cylon", false)
        let disabled = setup()
        XCTAssertFalse(disabled.system.contains("ClickUp"))
        let disabledFile = try XCTUnwrap(disabled.environment["SWARME_PROJECT_JSON"])
        XCTAssertNil(try JSON.parse(Data(contentsOf: URL(fileURLWithPath: disabledFile)))["clickupListId"])
        let unavailable = await f.call("GET", "/api/cylon/projects/\(id)")
        XCTAssertEqual(unavailable.status, 404)
        try f.harness.plugins.setEnabled("cylon", true)
        let restored = await f.call("GET", "/api/cylon/projects/\(id)")
        XCTAssertEqual(restored.json?["clickupListId"], "legacy-list")
    }

    func testBoardsAcceptTheStableIdOfACustomRepository() async throws {
        let f = try await CylonFixture()
        let role = UUID().uuidString.lowercased()
        f.harness.store.patchGroup(f.groupId, ["plugins": ["code": ["projectId": "p1", "role": .string(role)], "cylon": ["follow": true]]])
        let made = await f.call("POST", "/api/cylon/boards", ["projectId": "p1", "title": "Job"])
        let id = try XCTUnwrap(made.json?["board"]?["id"]?.string)
        let added = await f.call("POST", "/api/cylon/boards/\(id)/items", ["role": .string(role), "ticket": "t1"])
        XCTAssertEqual(added.status, 201)
        XCTAssertEqual(added.json?["board"]?["items"]?.array?.first?["role"], .string(role))
    }
}
