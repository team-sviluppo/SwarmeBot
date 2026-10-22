@testable import HarnessCore
import XCTest

// The channel's working folder: set at creation or by PATCH, fixed by the
// first turn, then every member works in it.
@MainActor
final class RoomFolderTests: XCTestCase {
    private var harness: Harness!
    private var routes: Routes!
    private var folder: URL!
    private var members: [JSON] = []

    private func prepare() throws {
        let paths = temporaryPaths()
        harness = try Harness(paths: paths, environment: ProcessInfo.processInfo.environment, drivers: [])
        routes = Routes(harness: harness)
        folder = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        members = (0..<2).map { _ in .string(harness.store.createBot(seedMessages: false)["id"]!.string!) }
    }

    private func call(_ method: String, _ path: String, body: JSON) async -> (Int, JSON?) {
        let request = HTTPRequest(method: method, path: path, query: [:], headers: ["content-type": "application/json"], body: body.data)
        guard case let .response(response) = await routes.handle(request) else { XCTFail("not a response"); return (0, nil) }
        return (response.status, try? JSON.parse(response.body))
    }

    func testCreatingARoomWithAFolder() async throws {
        try prepare()
        let (status, body) = await call("POST", "/api/groups", body: ["memberIds": .array(members), "cwd": .string(folder.path)])
        XCTAssertEqual(status, 201)
        XCTAssertEqual(body?["group"]?["cwd"]?.string, folder.path)
    }

    func testRefusesAFolderThatDoesNotExistOrIsRelative() async throws {
        try prepare()
        for bad in [folder.path + "/nope", "relative/dir"] {
            let (status, _) = await call("POST", "/api/groups", body: ["memberIds": .array(members), "cwd": .string(bad)])
            XCTAssertEqual(status, 400, bad)
        }
        XCTAssertTrue(harness.store.groups.isEmpty)
    }

    func testFolderCanChangeUntilTheFirstTurnPinsIt() async throws {
        try prepare()
        let (_, created) = await call("POST", "/api/groups", body: ["memberIds": .array(members)])
        let id = created!["group"]!["id"]!.string!
        XCTAssertNil(created?["group"]?["cwd"])

        var (status, body) = await call("PATCH", "/api/groups/\(id)", body: ["cwd": .string(folder.path)])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body?["group"]?["cwd"]?.string, folder.path)

        (status, body) = await call("PATCH", "/api/groups/\(id)", body: ["cwd": ""])
        XCTAssertEqual(status, 200)
        XCTAssertNil(body?["group"]?["cwd"])

        _ = await call("PATCH", "/api/groups/\(id)", body: ["cwd": .string(folder.path)])
        XCTAssertEqual(harness.store.pinGroupCwd(id), folder.path)
        (status, _) = await call("PATCH", "/api/groups/\(id)", body: ["cwd": ""])
        XCTAssertEqual(status, 409)
        XCTAssertEqual(harness.store.group(id)?["cwd"]?.string, folder.path)
    }

    func testAChannelBetweenTwoBotsHasNoFolder() async throws {
        try prepare()
        let dm = harness.store.createGroup(name: "dm", memberIds: members.compactMap(\.string), dm: true)
        let (status, _) = await call("PATCH", "/api/groups/\(dm["id"]!.string!)", body: ["cwd": .string(folder.path)])
        XCTAssertEqual(status, 400)
    }
}
