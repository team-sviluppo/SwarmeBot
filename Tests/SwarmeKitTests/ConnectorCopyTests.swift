@testable import CompanionCore
@testable import SwarmeKit
import XCTest

final class ConnectorCopyTests: XCTestCase {
    /// A connector as the local engine's API shows it: secrets only as `{secret, set}`.
    func connector(_ json: String) throws -> MCPConnector {
        try JSONDecoder().decode(MCPConnector.self, from: Data(json.utf8))
    }

    func testSecretsGoBackIntoTheForm() throws {
        let github = try connector(#"{"id":"github","name":"GitHub","transport":"stdio","command":"npx","args":["-y","x"],"env":{"TOKEN":{"secret":true,"set":true},"MODE":"ro"},"headers":{}}"#)
        let input = try ConnectorCopy.input(for: github, secrets: ["github": ["env": ["TOKEN": "ghp_123"]]])
        XCTAssertEqual(input.env.first { $0.name == "TOKEN" }?.value, "ghp_123")
        XCTAssertEqual(input.env.first { $0.name == "MODE" }?.value, "ro")
        let body = input.json
        let token = (body["env"] as? [String: Any])?["TOKEN"] as? [String: Any]
        XCTAssertEqual(token?["secret"] as? Bool, true)
        XCTAssertEqual(token?["value"] as? String, "ghp_123")
    }

    func testOAuthGoesWithItsClientSecretButNotItsTokens() throws {
        let notion = try connector(#"{"id":"notion","name":"Notion","transport":"http","url":"https://x","auth":"oauth","oauth":{"clientId":"cid","scope":"read","clientSecret":{"secret":true,"set":true}},"oauthState":{"status":"connected"}}"#)
        let input = try ConnectorCopy.input(for: notion, secrets: ["notion": ["oauth": ["clientSecret": "cs-1"]]])
        let oauth = input.json["oauth"] as? [String: Any]
        XCTAssertEqual(input.json["auth"] as? String, "oauth")
        XCTAssertEqual(oauth?["clientId"] as? String, "cid")
        XCTAssertEqual((oauth?["clientSecret"] as? [String: Any])?["value"] as? String, "cs-1")
        XCTAssertThrowsError(try ConnectorCopy.input(for: notion, secrets: [:])) { error in
            XCTAssertEqual(error as? ConnectorCopyError, .missingSecret(connector: "Notion", name: "client secret"))
        }
        // dynamic registration: no client secret of its own, nothing to fill
        let open = try connector(#"{"id":"linear","name":"Linear","transport":"http","url":"https://x","auth":"oauth"}"#)
        XCTAssertNil((try ConnectorCopy.input(for: open, secrets: [:]).json["oauth"] as? [String: Any])?["clientSecret"])
    }

    func testMissingSecretsAreRefused() throws {
        let api = try connector(#"{"id":"api","name":"API","transport":"http","url":"https://x","headers":{"Authorization":{"secret":true,"set":false}}}"#)
        XCTAssertThrowsError(try ConnectorCopy.input(for: api, secrets: [:])) { error in
            XCTAssertEqual(error as? ConnectorCopyError, .missingSecret(connector: "API", name: "Authorization"))
        }
    }

    func testTheSecretsFileIsReadAsTheEngineWritesIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sbcs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"github":{"env":{"TOKEN":"a"},"headers":{"X":"b"}},"notion":{"oauth":{"access":"t","refresh":"r","clientSecret":"cs"}},"bad":7}"#.utf8).write(to: file)
        let secrets = ConnectorCopy.readSecrets(file)
        XCTAssertEqual(secrets["github"]?["env"]?["TOKEN"], "a")
        XCTAssertEqual(secrets["github"]?["headers"]?["X"], "b")
        XCTAssertEqual(secrets["notion"]?["oauth"], ["clientSecret": "cs"], "the tokens stay on this Mac")
        XCTAssertNil(secrets["bad"])
    }
}

/// The copy against a real remote engine: a stdio connector with a secret, tried there.
final class ConnectorCopyIntegrationTests: XCTestCase {
    func testACopiedConnectorWorksOnTheServerAndHidesItsSecret() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["SWARMEBOT_VPS_TEST"], let http = env["SWARMEBOT_VPS_HTTP"], let fake = env["SWARMEBOT_VPS_FAKE_MCP"] else {
            throw XCTSkip("SWARMEBOT_VPS_TEST / _HTTP / _FAKE_MCP not set")
        }
        let parts = target.split(separator: ":")
        let root = URL(fileURLWithPath: "/tmp/sbc-\(UUID().uuidString.prefix(4))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SSHIdentityStore(root: root.appendingPathComponent("ssh"))
        var identity = try store.findOrCreate(host: String(parts[0]), port: Int(parts[1]) ?? 22, user: "deploy")
        identity = try await HostKeys.approve(try await HostKeys.scan(host: identity.host, port: identity.port)[0], for: identity, store: store)
        identity = try await RemoteAdmin(identity: identity, store: store).installKey(password: "s3cret-pw")
        let admin = RemoteAdmin(identity: identity, store: store)
        let ssh = SSHCommand(identity: identity, store: store)
        try await ssh.run("cat > ~/fake_mcp.py", stdin: try Data(contentsOf: URL(fileURLWithPath: fake)))
        let device = try await admin.addDevice(name: "connector-test")
        let remote = CompanionClient(connection: try XCTUnwrap(Connection.remote(chatURL: http + "/srv1/deploy")), token: device.token)

        // as this Mac's engine shows it, plus its secret from this Mac's secrets file
        let local = try JSONDecoder().decode(MCPConnector.self, from: Data(#"""
        {"id":"fakemcp","name":"Fake MCP","transport":"stdio","command":"python3","args":["-I","/home/deploy/fake_mcp.py","stdio"],
         "env":{"FAKE_MCP_SECRET":{"secret":true,"set":true}},"headers":{},"tools":{"mode":"all","names":[]},"toolTimeoutSeconds":30}
        """#.utf8))
        let secret = "copy-test-\(UUID().uuidString.prefix(8))"
        let copied = try await ConnectorCopy.copy(local, secrets: ["fakemcp": ["env": ["FAKE_MCP_SECRET": secret]]], to: remote)
        XCTAssertEqual(copied.lastCheck?.ok, true, copied.lastCheck?.error ?? "")
        XCTAssertGreaterThan(copied.lastCheck?.tools?.count ?? 0, 0)
        // the API shows that a secret is set, never its value
        guard case .secret(set: true)? = copied.env?["FAKE_MCP_SECRET"] else { return XCTFail("secret not set on the server") }
        let listed = try await remote.perform(remote.makeRequest("GET", "/api/mcp-connectors"))
        XCTAssertFalse(String(decoding: listed.0, as: UTF8.self).contains(secret))
        let stored = try await ssh.run("stat -c %a ~/.swarmebot/mcp-connector-secrets.json; grep -c '\(secret)' ~/.swarmebot/mcp-connector-secrets.json").text
        XCTAssertEqual(stored, "600\n1\n")

        // a second copy replaces it, it does not duplicate it
        _ = try await ConnectorCopy.copy(local, secrets: ["fakemcp": ["env": ["FAKE_MCP_SECRET": secret + "-2"]]], to: remote)
        let all = try await remote.mcpConnectors()
        XCTAssertEqual(all.filter { $0.id == "fakemcp" }.count, 1)
        try await remote.deleteMCPConnector("fakemcp")
    }
}
