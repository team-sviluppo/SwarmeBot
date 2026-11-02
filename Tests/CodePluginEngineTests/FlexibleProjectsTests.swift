@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

@MainActor
final class FlexibleProjectsTests: XCTestCase {
    private func entry(_ role: String, _ label: String, _ path: String) -> JSON {
        ["role": .string(role), "label": .string(label), "path": .string(path)]
    }

    func testMoreThanFourRepositoriesKeepTheirLabelsAndOrderAfterReload() async throws {
        let f = try await RepoFixture()
        let repos = (0..<24).reversed().map { entry("repo-\($0)", "Servizio \($0)", f.folder.path) }
        let made = await f.callRaw("POST", "/api/projects", body: ["name": "Many repos", "repos": .array(repos)])
        XCTAssertEqual(made.status, 201)
        let id = try XCTUnwrap(made.json?["project"]?["id"]?.string)
        let reloaded = try XCTUnwrap(ProjectStore(harness: f.harness).project(id)?["repos"]?.array)
        XCTAssertEqual(reloaded.count, 24)
        XCTAssertEqual(reloaded.map { $0["label"] }, repos.map { $0["label"] })
        XCTAssertEqual(reloaded.map { $0["role"] }, repos.map { $0["role"] })
    }

    func testRenamingAndReorderingKeepsAssignmentsScriptsAndUnknownFields() async throws {
        let f = try await RepoFixture()
        let store = ProjectStore(harness: f.harness)
        var api = entry("api-id", "API", f.folder.path).object!
        api["scripts"] = [["name": "Test", "command": "swift test"]]
        api["future"] = ["keep": true]
        var project = try store.create(["name": "P", "repos": [.object(api), entry("web-id", "Web", f.folder.path)]])
        let id = project["id"]!.string!
        project["repos"] = [.object(api), entry("web-id", "Web", f.folder.path)]
        project["future"] = "kept"
        try store.save([project])
        let assigned = await f.callRaw("PATCH", "/api/bots/\(f.botId)", body: ["plugins": ["code": ["projectId": .string(id), "role": "api-id"]]])
        XCTAssertEqual(assigned.status, 200)
        let group = f.harness.store.createGroup(name: "Web", memberIds: [f.botId])["id"]!.string!
        let channel = await f.callRaw("PATCH", "/api/groups/\(group)", body: ["plugins": ["code": ["projectId": .string(id), "role": "web-id"]]])
        XCTAssertEqual(channel.status, 200)
        let changed = await f.callRaw("PATCH", "/api/projects/\(id)", body: ["repos": [entry("web-id", "Backoffice nuovo", f.folder.path),
                                                                                   entry("api-id", "Servizi", f.folder.path)]])
        XCTAssertEqual(changed.status, 200)
        let saved = try XCTUnwrap(store.project(id))
        XCTAssertEqual(saved["repos"]?.array?.last?["scripts"]?.array?.first?["command"], "swift test")
        XCTAssertEqual(saved["repos"]?.array?.last?["future"]?["keep"], true)
        XCTAssertEqual(saved["future"], "kept")
        XCTAssertEqual(f.harness.store.bot(f.botId)?["plugins"]?["code"]?["role"], "api-id")
        XCTAssertEqual(f.harness.store.group(group)?["plugins"]?["code"]?["role"], "web-id")
        let context = try XCTUnwrap(ProjectContext.make(project: saved, role: "api-id", cwd: f.folder.path))
        XCTAssertTrue(context.prompt(agentFile: "/project.json").contains("Servizi folder"))
    }

    func testRemovingAnAssignedRepositoryRequiresChangingTheAssignmentFirst() async throws {
        let f = try await RepoFixture()
        let p = try ProjectStore(harness: f.harness).create(["name": "P", "repos": [entry("default", "Default", f.folder.path)]])
        let id = p["id"]!.string!
        _ = await f.callRaw("PATCH", "/api/bots/\(f.botId)", body: ["plugins": ["code": ["projectId": .string(id), "role": "default"]]])
        let blocked = await f.callRaw("PATCH", "/api/projects/\(id)", body: ["repos": []])
        XCTAssertEqual(blocked.status, 409)
        _ = await f.callRaw("PATCH", "/api/bots/\(f.botId)", body: ["plugins": ["code": ["role": .null]]])
        let removed = await f.callRaw("PATCH", "/api/projects/\(id)", body: ["repos": []])
        XCTAssertEqual(removed.status, 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.folder.path))
    }

    func testInvalidOrAmbiguousLabelsAndIdsAreRefused() async throws {
        let f = try await RepoFixture()
        let invalid: [[JSON]] = [
            [entry("repo/a", "API", f.folder.path)], [entry("a", "   ", f.folder.path)],
            [entry("a", String(repeating: "x", count: 101), f.folder.path)],
            [entry("a", "API", f.folder.path), entry("b", " api ", f.folder.path)],
            [entry("a", "API", f.folder.path), entry("a", "Web", f.folder.path)],
            [["role": "custom", "path": .string(f.folder.path)]],
        ]
        for repos in invalid {
            let result = await f.callRaw("POST", "/api/projects", body: ["name": "P", "repos": .array(repos)])
            XCTAssertEqual(result.status, 400)
        }
    }

    func testDefaultParentDoesNotHideTheMoreSpecificWorkingRepository() async throws {
        let f = try await RepoFixture()
        let child = f.folder.appendingPathComponent("api")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let p: JSONObject = ["id": "p", "name": "P", "repos": [entry("default", "Default", f.folder.path), entry("api", "Services", child.path)]]
        let context = try XCTUnwrap(ProjectContext.make(project: p, role: nil, cwd: child.path))
        XCTAssertEqual(context.workingRole, "api")
        XCTAssertTrue(context.readOnly.isEmpty, "an ancestor cannot be linked read-only over the working repository")
        let fromDefault = try XCTUnwrap(ProjectContext.make(project: p, role: "default", cwd: f.folder.path))
        XCTAssertEqual(fromDefault.readOnly.map(\.role), ["api"])
    }

    func testRootDefaultIsNeverLinkedReadOnlyOverAWorkingChildRepository() async throws {
        let f = try await RepoFixture()
        let project: JSONObject = ["id": "p", "name": "P", "repos": [entry("default", "Default", "/"), entry("api", "API", f.folder.path)]]
        let context = try XCTUnwrap(ProjectContext.make(project: project, role: "api", cwd: f.folder.path))
        XCTAssertTrue(context.readOnly.isEmpty)
        XCTAssertEqual(ProjectContext.make(project: project, role: nil, cwd: f.folder.path)?.workingRole, "api")
    }
}
