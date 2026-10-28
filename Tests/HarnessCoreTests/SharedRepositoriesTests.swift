@testable import HarnessCore
import XCTest

@MainActor
final class SharedRepositoriesTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func harness(_ root: URL) throws -> Harness {
        try Harness(paths: DataPaths(root: root), environment: [:], drivers: [])
    }

    private func write(_ dir: URL, _ file: String, _ value: JSON) throws {
        try FileIO.writeAtomic(value.data, to: dir.appendingPathComponent(file))
    }

    private var bots: JSON { [["id": "writer", "name": "Writer", "title": "Editor", "description": "Write clearly"],
                               ["id": "researcher", "name": "Researcher", "description": "Cite sources"]] }
    private var connector: JSONObject { ["id": "example", "name": "Example", "transport": "http", "url": "https://example.com/mcp", "auth": "oauth",
                                        "oauth": ["clientId": "client", "clientSecret": ["secret": true, "value": "private-secret"]],
                                        "headers": ["X-API-Key": "private-header"], "env": ["NORMAL": "value", "API_TOKEN": ["secret": true, "value": "private-token"]]] }

    func testSelectiveImportSyncAndRestartKeepLocalState() throws {
        let dir = try root(), shared = try root()
        let engine = try harness(dir)
        try write(shared, "bots.json", bots)
        try engine.sharedRepositories.setFolder(.bots, shared.path)
        try engine.sharedRepositories.importSelected(.bots, ids: ["writer"])
        let bot = try XCTUnwrap(engine.store.bots.first), id = try XCTUnwrap(bot["id"]?.string)
        let thread = try XCTUnwrap(bot["threadId"]?.string)
        engine.store.patchBot(id, ["mascotAvatarImage": "local.png", "color": "purple", "modelSelection": ["instanceId": "mine", "model": "local"]])
        engine.store.appendMessage(thread, ["role": "user", "kind": "text", "text": "Keep this chat"])
        try write(shared, "bots.json", [["id": "writer", "name": "New name", "description": "Updated instructions", "color": "red", "modelSelection": ["model": "remote"], "mascotAvatarImage": "remote.png"]])
        let restarted = try harness(dir)
        XCTAssertTrue(restarted.sharedRepositories.sync().isEmpty)
        let updated = try XCTUnwrap(restarted.store.bot(id))
        XCTAssertEqual(restarted.store.bots.count, 1)
        XCTAssertEqual(updated["name"], "New name")
        XCTAssertEqual(updated["description"], "Updated instructions")
        XCTAssertEqual(updated["title"], "")
        XCTAssertEqual(updated["mascotAvatarImage"], "local.png")
        XCTAssertEqual(updated["color"], "purple")
        XCTAssertEqual(updated["modelSelection"]?["model"], "local")
        XCTAssertEqual(updated["threadId"]?.string, thread)
        XCTAssertTrue(restarted.store.messages(thread).contains { $0["text"] == "Keep this chat" })
        try restarted.sharedRepositories.importSelected(.bots, ids: ["writer"])
        XCTAssertEqual(restarted.store.bots.count, 1, "reimport is idempotent")
    }

    func testBotProfileWritesThroughAndAvatarDoesNot() async throws {
        let engine = try harness(root()), shared = try root()
        try write(shared, "bots.json", bots)
        try engine.sharedRepositories.setFolder(.bots, shared.path)
        try engine.sharedRepositories.importSelected(.bots, ids: ["writer"])
        let id = try XCTUnwrap(engine.store.bots.first?["id"]?.string)
        let routes = Routes(harness: engine)
        let response = await routes.handle(HTTPRequest(method: "PATCH", path: "/api/bots/\(id)", query: [:], headers: ["content-type": "application/json"], body: JSON.object(["name": "Shared rename", "description": "Shared edit", "color": "pink"]).data))
        guard case let .response(result) = response else { return XCTFail() }
        XCTAssertEqual(result.status, 200)
        let definitions = try engine.sharedRepositories.definitions(.bots)
        XCTAssertEqual(definitions.first?["name"], "Shared rename")
        XCTAssertEqual(definitions.first?["description"], "Shared edit")
        XCTAssertNil(definitions.first?["color"])
        XCTAssertEqual(engine.store.bot(id)?["color"], "pink")
    }

    func testConnectorSecretsNeverCrossMachinesAndLocalLoginSurvivesSync() throws {
        let publisher = try harness(root()), shared = try root()
        _ = try publisher.mcpConnectors.create(connector)
        publisher.mcpConnectors.setOAuthSecrets("example", ["access": "publisher-access", "refresh": "publisher-refresh"])
        publisher.mcpConnectors.setOAuthClient("example", ["clientId": "discovered-client"])
        try publisher.sharedRepositories.setFolder(.connectors, shared.path)
        try publisher.sharedRepositories.publish(.connectors, localId: "example")
        let text = try String(contentsOf: shared.appendingPathComponent("mcp-connectors.json"), encoding: .utf8)
        for secret in ["private-secret", "private-header", "private-token", "publisher-access", "publisher-refresh", "discovered-client"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        let reader = try harness(root())
        try reader.sharedRepositories.setFolder(.connectors, shared.path)
        try reader.sharedRepositories.importSelected(.connectors, ids: ["example"])
        XCTAssertNil(reader.mcpConnectors.oauthSecrets("example")["access"])
        XCTAssertEqual(reader.mcpConnectors.wire(reader.mcpConnectors.connector("example")!)["headers"]?["X-API-Key"]?["set"], false)
        var local = try XCTUnwrap(reader.mcpConnectors.connector("example"))
        local["env"] = ["NORMAL": "value", "API_TOKEN": ["secret": true, "value": "reader-token"]]
        local["enabled"] = false
        _ = try reader.mcpConnectors.update("example", local)
        reader.mcpConnectors.setOAuthSecrets("example", ["access": "reader-access", "refresh": "reader-refresh"])
        var changed = try XCTUnwrap(publisher.mcpConnectors.connector("example"))
        changed["name"] = "Updated connector"
        _ = try publisher.mcpConnectors.update("example", changed)
        try publisher.sharedRepositories.publish(.connectors, localId: "example")
        XCTAssertTrue(reader.sharedRepositories.sync().isEmpty)
        XCTAssertEqual(reader.mcpConnectors.connector("example")?["name"], "Updated connector")
        XCTAssertEqual(reader.mcpConnectors.connector("example")?["enabled"], false)
        XCTAssertEqual(reader.mcpConnectors.spec("example")?.env["API_TOKEN"], "reader-token")
        XCTAssertEqual(reader.mcpConnectors.oauthSecrets("example")["access"], "reader-access")
    }

    func testInvalidMissingAndSwitchedFoldersKeepCopies() throws {
        let engine = try harness(root()), first = try root(), second = try root()
        try write(first, "bots.json", bots)
        try engine.sharedRepositories.setFolder(.bots, first.path)
        try engine.sharedRepositories.importSelected(.bots, ids: ["writer"])
        let before = engine.store.bots
        try write(first, "bots.json", [["id": "writer", "name": "Wrong", "description": "Changed"], ["id": "invalid"]])
        XCTAssertFalse(engine.sharedRepositories.sync().isEmpty)
        XCTAssertEqual(engine.store.bots, before, "validate the whole catalog before mutating copies")
        try write(second, "bots.json", [["id": "writer", "name": "Other source", "description": "Other instructions"]])
        try engine.sharedRepositories.setFolder(.bots, second.path)
        XCTAssertTrue(engine.sharedRepositories.sync().isEmpty)
        XCTAssertEqual(engine.store.bots, before, "same id in another source must not replace a copy")
        try engine.sharedRepositories.setFolder(.bots, nil)
        XCTAssertTrue(engine.sharedRepositories.sync().isEmpty)
        XCTAssertEqual(engine.store.bots, before)
        try engine.sharedRepositories.setFolder(.bots, first.path)
        try FileManager.default.removeItem(at: first)
        XCTAssertFalse(engine.sharedRepositories.sync().isEmpty)
        XCTAssertEqual(engine.store.bots, before)
    }

    func testConnectorCollisionIsRejectedBeforeAnyImport() throws {
        let engine = try harness(root()), shared = try root()
        _ = try engine.mcpConnectors.create(connector)
        var other = connector; other["id"] = "other"
        try write(shared, "mcp-connectors.json", [.object(other), .object(connector)])
        try engine.sharedRepositories.setFolder(.connectors, shared.path)
        XCTAssertThrowsError(try engine.sharedRepositories.importSelected(.connectors, ids: ["other", "example"]))
        XCTAssertEqual(engine.mcpConnectors.connectors.count, 1)
        XCTAssertEqual(engine.sharedRepositories.snapshot(.connectors)["entries"]?.array?.last?["conflict"], true)
        for entry in engine.sharedRepositories.snapshot(.connectors)["entries"]?.array ?? [] {
            XCTAssertNotNil(entry["description"]?.string, "catalog entries must decode as text on the Mac")
        }
    }

    func testStdioCatalogAlwaysReturnsTextInsteadOfJSONNull() throws {
        let engine = try harness(root()), shared = try root()
        try write(shared, "mcp-connectors.json", [["id": "files", "name": "Files", "transport": "stdio", "command": "echo", "args": ["test"]]])
        try engine.sharedRepositories.setFolder(.connectors, shared.path)
        let entry = try XCTUnwrap(engine.sharedRepositories.snapshot(.connectors)["entries"]?.array?.first)
        XCTAssertEqual(entry["description"], "echo")
        XCTAssertEqual(entry["imported"], false)
    }

    func testRoutesAndFolderValidation() async throws {
        let engine = try harness(root()), shared = try root(), routes = Routes(harness: engine)
        func call(_ method: String, _ path: String, _ body: JSON = [:], json: Bool = true) async -> HTTPResponse {
            let result = await routes.handle(HTTPRequest(method: method, path: path, query: [:], headers: json ? ["content-type": "application/json"] : [:], body: body.data))
            guard case let .response(response) = result else { fatalError("not a response") }
            return response
        }
        let noJSON = await call("PUT", "/api/shared-repositories/bots", ["folder": .string(shared.path)], json: false)
        XCTAssertEqual(noJSON.status, 415)
        let relative = await call("PUT", "/api/shared-repositories/bots", ["folder": "relative"])
        XCTAssertEqual(relative.status, 400)
        let missing = await call("PUT", "/api/shared-repositories/bots", ["folder": "/no/such/shared-folder"])
        XCTAssertEqual(missing.status, 400)
        let localDir = await call("PUT", "/api/shared-repositories/bots", ["folder": .string(engine.paths.root.path)])
        XCTAssertEqual(localDir.status, 400)
        try write(shared, "bots.json", bots)
        let saved = await call("PUT", "/api/shared-repositories/bots", ["folder": .string(shared.path)])
        XCTAssertEqual(saved.status, 200)
        let catalog = try JSON.parse(saved.body)
        XCTAssertEqual(catalog["entries"]?.array?.count, 2)
        let imported = await call("POST", "/api/shared-repositories/bots/import", ["ids": ["writer"]])
        XCTAssertEqual(imported.status, 200)
        XCTAssertEqual(engine.store.bots.count, 1)
        let synced = await call("POST", "/api/shared-repositories/sync")
        XCTAssertEqual(synced.status, 200)
        let cleared = await call("PUT", "/api/shared-repositories/bots", ["folder": .null])
        XCTAssertEqual(cleared.status, 200)
        XCTAssertEqual(engine.store.bots.count, 1)
    }
}
