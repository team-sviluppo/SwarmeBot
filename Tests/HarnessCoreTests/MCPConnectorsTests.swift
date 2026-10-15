@testable import HarnessCore
import XCTest

/// Connectors, phase 1 (docs/plans/2026-10-15-connettori-mcp.md): the
/// registry, the client on both transports, the pool and the settings API,
/// against `parity/fake_mcp.py`.
@MainActor
final class MCPConnectorsTests: XCTestCase {
    static let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../parity/fake_mcp.py").standardized.path

    private func temporaryPaths() throws -> DataPaths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DataPaths(root: dir)
    }

    private func stdioBody(_ id: String = "fake", secret: String = "s3cr3t-value") -> JSONObject {
        ["id": .string(id), "name": "Fake", "transport": "stdio", "command": "python3",
         "args": ["-I", .string(Self.fake), "stdio"],
         "env": ["FAKE_MCP_SECRET": ["secret": true, "value": .string(secret)], "PLAIN": "visible"]]
    }

    private func startHTTPFake() throws -> (Process, Int) {
        let port = Int.random(in: 41000...49000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", Self.fake, "http", String(port)]
        try process.run()
        return (process, port)
    }

    private func waitForHTTP(_ port: Int) async throws {
        for _ in 0..<50 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "DELETE"
            if (try? await URLSession.shared.data(for: request)) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("fake MCP server did not start")
    }

    // MARK: Registry

    func testValidationRules() throws {
        let registry = MCPConnectors(paths: try temporaryPaths())
        func rejects(_ body: JSONObject, _ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try registry.create(body), file: file, line: line) { error in
                XCTAssertTrue((error as? MCPConnectorInvalid)?.message.contains(fragment) == true, "\(error)", file: file, line: line)
            }
        }
        rejects(stdioBody("agents"), "reserved")
        rejects(stdioBody("import"), "reserved")
        rejects(stdioBody("Bad-Id"), "id must be")
        rejects(stdioBody("x"), "id must be")
        rejects(["id": "web", "transport": "http", "url": "http://example.com/mcp"], "https")
        rejects(["id": "web", "transport": "http", "url": "https://example.com/mcp", "headers": ["Accept": "x"]], "set by SwarmeBot")
        rejects(["id": "web", "transport": "http", "url": "https://example.com/mcp", "headers": ["X-Key": "a\nb"]], "line break")
        rejects(["id": "web", "transport": "stdio"], "command is required")
        rejects(["id": "web", "transport": "grpc"], "transport")

        XCTAssertNoThrow(try registry.create(["id": "lan", "transport": "http", "url": "http://192.168.1.20:3000/mcp"]))
        XCTAssertNoThrow(try registry.create(["id": "loop", "transport": "http", "url": "http://localhost:3000/mcp"]))
        XCTAssertNoThrow(try registry.create(stdioBody()))
        rejects(stdioBody(), "already exists")
    }

    func testSecretsStayOutOfTheDefinitionsAndTheAPI() throws {
        let paths = try temporaryPaths()
        let registry = MCPConnectors(paths: paths)
        try registry.create(stdioBody(secret: "s3cr3t-value"))

        let definitions = try String(contentsOf: registry.file, encoding: .utf8)
        XCTAssertFalse(definitions.contains("s3cr3t-value"))
        XCTAssertTrue(definitions.contains("visible"))
        let wire = registry.wireList.serialized()
        XCTAssertFalse(wire.contains("s3cr3t-value"))
        XCTAssertEqual(registry.wire(registry.connector("fake")!)["env"]?["FAKE_MCP_SECRET"], ["secret": true, "set": true])

        let mode = try FileManager.default.attributesOfItem(atPath: registry.secretsFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(try String(contentsOf: registry.secretsFile, encoding: .utf8).contains("s3cr3t-value"))

        // {secret: true} without a value keeps the stored one; a name left out is gone
        var edit = stdioBody()
        edit["env"] = ["FAKE_MCP_SECRET": ["secret": true]]
        try registry.update("fake", edit)
        XCTAssertEqual(registry.spec("fake")?.env, ["FAKE_MCP_SECRET": "s3cr3t-value"])
        XCTAssertEqual(registry.spec("fake")?.secretValues, ["s3cr3t-value"])

        // a fresh load sees the same thing; deleting takes the secret along
        XCTAssertEqual(MCPConnectors(paths: paths).spec("fake")?.env["FAKE_MCP_SECRET"], "s3cr3t-value")
        XCTAssertTrue(try registry.delete("fake"))
        XCTAssertFalse(try String(contentsOf: registry.secretsFile, encoding: .utf8).contains("s3cr3t-value"))
    }

    func testImportReadsClaudeDesktopConfig() throws {
        let config = try JSON.parse(#"""
        {"mcpServers": {
          "GitHub Tools": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                           "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_x", "LOG_LEVEL": "info"}},
          "remote": {"type": "http", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer abc", "X-Team": "ops"}},
          "old": {"type": "sse", "url": "https://mcp.example.com/sse"},
          "agents": {"command": "x"},
          "broken": {"foo": 1}
        }}
        """#)
        let (bodies, skipped) = MCPConnectors.importBodies(config, existingIds: ["remote"])
        XCTAssertEqual(bodies.map { $0["id"]?.string }, ["github_tools", "remote_2", "agents_2"])
        XCTAssertEqual(bodies[0]["env"]?["GITHUB_PERSONAL_ACCESS_TOKEN"], ["secret": true, "value": "ghp_x"])
        XCTAssertEqual(bodies[0]["env"]?["LOG_LEVEL"], "info")
        XCTAssertEqual(bodies[1]["transport"], "http")
        XCTAssertEqual(bodies[1]["headers"]?["Authorization"], ["secret": true, "value": "Bearer abc"])
        XCTAssertEqual(bodies[1]["headers"]?["X-Team"], "ops")
        XCTAssertEqual(skipped.compactMap { $0["name"]?.string }.sorted(), ["broken", "old"])
        let registry = MCPConnectors(paths: try temporaryPaths())
        for body in bodies { XCTAssertNoThrow(try registry.create(body)) }
    }

    // MARK: Client

    func testStdioClientListsPagesCallsAndReportsErrors() async throws {
        let client = MCPClient.stdio(command: "python3", args: ["-I", Self.fake, "stdio"], cwd: nil,
                                     environment: ["PATH": EnvPath.augmented(), "FAKE_MCP_SECRET": "abcd"])
        defer { client.close() }
        let server = try await client.connect(timeout: 20)
        XCTAssertEqual(server.name, "fake-mcp")
        XCTAssertEqual(server.instructions, "A fake server.")
        let tools = try await client.listTools(timeout: 10)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["echo", "slow", "fail", "big", "headers", "forget", "die"], "every page")

        let echo = try await client.callTool("echo", arguments: ["text": "ciao"], timeout: 10)
        XCTAssertEqual(echo["content"]?.array?.first?["text"]?.string, "ciao (secret len 4)")
        let failed = try await client.callTool("fail", arguments: .null, timeout: 10)
        XCTAssertEqual(failed["isError"]?.bool, true)
        do {
            _ = try await client.callTool("nope", arguments: [:], timeout: 10)
            XCTFail("unknown tool")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown tool nope"))
        }
        do {
            _ = try await client.callTool("slow", arguments: ["seconds": 5], timeout: 1)
            XCTFail("timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nessuna risposta"))
        }
        // a slow call does not hold the next one back
        let quick = try await client.callTool("echo", arguments: ["text": "dopo"], timeout: 10)
        XCTAssertEqual(quick["content"]?.array?.first?["text"]?.string, "dopo (secret len 4)")
    }

    func testStdioClientFailsCleanlyWhenTheCommandIsMissing() async {
        let client = MCPClient.stdio(command: "definitely-not-a-command-xyz", args: [], cwd: nil, environment: ["PATH": "/usr/bin"])
        do {
            try await client.connect(timeout: 5)
            XCTFail("no such command")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't installed"), error.localizedDescription)
        }
    }

    func testHTTPClientSessionsHeadersSSEAndAuth() async throws {
        let (fake, port) = try startHTTPFake()
        defer { fake.terminate() }
        try await waitForHTTP(port)
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!

        let client = MCPClient.http(url: url, headers: ["X-Team": "ops"])
        defer { client.close() }
        try await client.connect(timeout: 10)
        let listed = try await client.listTools(timeout: 10)
        XCTAssertEqual(listed.count, 7)
        // tools/call answers as an SSE stream
        let echo = try await client.callTool("echo", arguments: ["text": "via http"], timeout: 10)
        XCTAssertEqual(echo["content"]?.array?.first?["text"]?.string, "via http (secret len 0)")
        let seen = try await client.callTool("headers", arguments: [:], timeout: 10)
        let headers = try JSON.parse(seen["content"]?.array?.first?["text"]?.string ?? "{}")
        XCTAssertEqual(headers["X-Team"]?.string, "ops")
        XCTAssertNotNil(headers["Mcp-Session-Id"]?.string)
        XCTAssertNotNil(headers["Mcp-Protocol-Version"]?.string ?? headers["MCP-Protocol-Version"]?.string)

        // the server forgets the session: the client initializes again, once
        _ = try await client.callTool("forget", arguments: [:], timeout: 10)
        let again = try await client.callTool("echo", arguments: ["text": "di nuovo"], timeout: 10)
        XCTAssertEqual(again["content"]?.array?.first?["text"]?.string, "di nuovo (secret len 0)")

        let refused = MCPClient.http(url: url, headers: ["X-Fake-Auth": "wrong"])
        defer { refused.close() }
        do {
            try await refused.connect(timeout: 10)
            XCTFail("401")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("credenziali (HTTP 401)"), error.localizedDescription)
        }
    }

    // MARK: Pool

    func testPoolFiltersToolsAndRestartsADeadServer() async throws {
        let paths = try temporaryPaths()
        let registry = MCPConnectors(paths: paths)
        var body = stdioBody(secret: "pool-secret")
        body["tools"] = ["mode": "deny", "names": ["slow", "big", "headers", "forget"]]
        try registry.create(body)
        let pool = MCPConnectorPool(paths: paths, environment: ProcessInfo.processInfo.environment.merging(["XAI_API_KEY": "leak"]) { $1 })
        defer { pool.stopAll() }
        let spec = try XCTUnwrap(registry.spec("fake"))

        let tools = try await pool.tools(spec)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["echo", "fail", "die"])
        do {
            _ = try await pool.call(spec, tool: "slow", arguments: [:])
            XCTFail("filtered out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("escluso dal filtro"))
        }
        let echo = try await pool.call(spec, tool: "echo", arguments: ["text": "a"])
        XCTAssertEqual(echo["content"]?.array?.first?["text"]?.string, "a (secret len 11)")

        // the process dies mid-call: that call fails, the next one gets a fresh server
        do {
            _ = try await pool.call(spec, tool: "die", arguments: [:])
        } catch {}
        let after = try await pool.call(spec, tool: "echo", arguments: ["text": "b"])
        XCTAssertEqual(after["content"]?.array?.first?["text"]?.string, "b (secret len 11)")

        // the server's stderr is logged
        let log = try String(contentsOf: paths.root.appendingPathComponent("logs/mcp/fake.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("fake-mcp starting"))
    }

    func testPoolEnvironmentDropsWorkspaceKeys() throws {
        let pool = MCPConnectorPool(paths: try temporaryPaths(), environment: ["XAI_API_KEY": "x", "OMB_PORT": "1", "HOME": "/h", "PATH": "/usr/bin"])
        XCTAssertNil(pool.baseEnvironment["XAI_API_KEY"])
        XCTAssertNil(pool.baseEnvironment["OMB_PORT"])
        XCTAssertEqual(pool.baseEnvironment["HOME"], "/h")
        XCTAssertTrue(pool.baseEnvironment["PATH"]?.contains("/usr/bin") == true)
    }

    // MARK: API

    func testSettingsAPI() async throws {
        let paths = try temporaryPaths()
        let harness = try Harness(paths: paths, environment: ProcessInfo.processInfo.environment, drivers: [])
        let routes = Routes(harness: harness)
        func call(_ method: String, _ path: String, _ body: JSON? = nil, json: Bool = true) async throws -> (Int, JSON) {
            let request = HTTPRequest(method: method, path: path, query: [:],
                                      headers: json ? ["content-type": "application/json"] : [:], body: body?.data ?? Data())
            guard case let .response(response) = await routes.handle(request) else { XCTFail("not a response"); return (0, .null) }
            return (response.status, (try? JSON.parse(response.body)) ?? .null)
        }

        var (status, body) = try await call("POST", "/api/mcp-connectors", .object(stdioBody()), json: false)
        XCTAssertEqual(status, 415)
        (status, body) = try await call("POST", "/api/mcp-connectors", .object(stdioBody()))
        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["connector"]?["env"]?["FAKE_MCP_SECRET"], ["secret": true, "set": true])
        (status, body) = try await call("POST", "/api/mcp-connectors", ["id": "bad id", "transport": "stdio", "command": "x"])
        XCTAssertEqual(status, 400)

        (status, body) = try await call("POST", "/api/mcp-connectors/fake/test")
        XCTAssertEqual(status, 200)
        let check = try XCTUnwrap(body["connector"]?["lastCheck"])
        XCTAssertEqual(check["ok"], true, "\(check)")
        XCTAssertEqual(check["tools"]?.array?.count, 7)
        XCTAssertEqual(check["tools"]?.array?.first?["readOnly"], true)
        XCTAssertGreaterThan(check["schemaChars"]?.double ?? 0, 100)
        XCTAssertEqual(check["server"]?["name"], "fake-mcp")

        (status, body) = try await call("POST", "/api/mcp-connectors/import",
                                        ["mcpServers": ["Altro": ["command": "python3", "args": ["-I", .string(Self.fake), "stdio"]]]])
        XCTAssertEqual(body["created"]?.array?.first?["id"], "altro")
        (status, body) = try await call("GET", "/api/mcp-connectors")
        XCTAssertEqual(body["connectors"]?.array?.count, 2)
        XCTAssertFalse(body.serialized().contains("s3cr3t-value"))

        (status, _) = try await call("DELETE", "/api/mcp-connectors/altro", json: false)
        XCTAssertEqual(status, 200)
        (status, _) = try await call("GET", "/api/mcp-connectors/altro")
        XCTAssertEqual(status, 404)
        harness.mcpPool.stopAll()
    }
}
