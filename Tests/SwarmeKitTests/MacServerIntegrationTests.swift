@testable import CompanionCore
@testable import SwarmeKit
import XCTest

// A Mac as server, for real: sshd, a throwaway admin user, LaunchDaemons
// (docs/plans/2026-10-16-bot-remoto.md §3.5). Off unless asked:
//
//   SWARMEBOT_MAC_SERVER_TEST=sbtest:<password>  SWARMEBOT_MAC_SERVER_PORT=18445 \
//   swift test --filter MacServerIntegrationTests
@MainActor
final class MacServerIntegrationTests: XCTestCase {
    func testSetupOnThisMacAsServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let login = env["SWARMEBOT_MAC_SERVER_TEST"], let colon = login.firstIndex(of: ":") else {
            throw XCTSkip("SWARMEBOT_MAC_SERVER_TEST not set")
        }
        let user = String(login[..<colon]), password = String(login[login.index(after: colon)...])
        let port = env["SWARMEBOT_MAC_SERVER_PORT"] ?? "18445"
        let root = URL(fileURLWithPath: "/tmp/sbm-\(UUID().uuidString.prefix(4))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identities = SSHIdentityStore(root: root.appendingPathComponent("ssh"))
        let engines = RemoteEngineStore(file: root.appendingPathComponent("remote-engines.json"))
        // the engine this test target was built with, next to the test bundle
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let engine = products.appendingPathComponent("swarme-harness")
        XCTAssertTrue(FileManager.default.fileExists(atPath: engine.path), engine.path)
        let flow = ServerSetupFlow(identities: identities, engines: engines, binaries: { _ in nil }) { arch in
            guard let archs = try? ServerSetupFlow.machOArchitectures(engine), archs.contains(arch == "aarch64" ? "arm64" : arch),
                  let data = try? Data(contentsOf: engine) else { return nil }
            return (engine, SHA256Digest.of(data).map { String(format: "%02x", $0) }.joined())
        }
        flow.name = "Questo Mac come server"
        flow.host = "127.0.0.1"
        flow.port = 22
        flow.user = user
        flow.site = ":\(port)"
        flow.tls = .off
        flow.prefix = "/mac/\(user)"
        flow.chatURLOverride = "http://127.0.0.1:\(port)/mac/\(user)"

        await flow.run()
        XCTAssertNil(flow.error, flow.error ?? "")
        await flow.approve(try XCTUnwrap(flow.scannedKeys.first))
        XCTAssertTrue(flow.needsPassword)
        flow.sshPassword = password
        await flow.run()
        XCTAssertNil(flow.error, flow.error ?? "")
        XCTAssertEqual(flow.probe?.os, "macos")
        XCTAssertEqual(flow.step, .done)

        let saved = try XCTUnwrap(engines.all().first)
        let token = try XCTUnwrap(RemoteEngineStore.token(engineId: saved.id))
        defer { RemoteEngineStore.deleteToken(engineId: saved.id) }
        let client = CompanionClient(connection: try XCTUnwrap(saved.connection), token: token)
        let health = try await client.remoteHealth()
        XCTAssertEqual(health.remote, true)
        let fleet = try await client.fleet(messages: 1)
        XCTAssertFalse(fleet.bots.isEmpty)
        let admin = RemoteAdmin(identity: try XCTUnwrap(flow.identity), store: identities)
        let probe = try await admin.probe()
        XCTAssertTrue(probe.serviceActive)

        // Claude's login on a server: no login Keychain for a user that never logged in at the
        // console, so the token from `claude setup-token` goes to the engine's secrets
        do {
            try await admin.setClaudeToken("not a token")
            XCTFail("a malformed token was accepted")
        } catch {}
        try await admin.setClaudeToken("sk-ant-oat01-integration-test-not-real")
        var authenticated = false
        for _ in 0..<40 where !authenticated {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let instances = try? await client.instances(),
               let claude = instances.first(where: { $0.driverKind == "claudeAgent" }) {
                authenticated = claude.snapshot.authenticated == true
            }
        }
        XCTAssertTrue(authenticated, "the engine's claude does not see the token")
    }
}
