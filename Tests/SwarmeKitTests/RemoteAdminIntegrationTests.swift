@testable import CompanionCore
@testable import SwarmeKit
import XCTest

// The whole server setup against a disposable Ubuntu 24.04 with systemd, sshd
// and sudo (docs/plans/2026-10-16-bot-remoto.md §12). Off unless asked:
//
//   SWARMEBOT_VPS_TEST=127.0.0.1:2222  SWARMEBOT_VPS_HTTP=http://127.0.0.1:18080 \
//   SWARMEBOT_VPS_ENGINE=build/linux/swarme-harness-aarch64  swift test --filter RemoteAdminIntegrationTests
//
// The server has `deploy` (password s3cret-pw, sudo with password) and
// `other` (password other-pw, no sudo).
final class RemoteAdminIntegrationTests: XCTestCase {
    var host = "", port = 22, http = "", engine = ""
    var store: SSHIdentityStore!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["SWARMEBOT_VPS_TEST"] else { throw XCTSkip("SWARMEBOT_VPS_TEST not set") }
        let parts = target.split(separator: ":")
        host = String(parts[0])
        port = parts.count > 1 ? Int(parts[1]) ?? 22 : 22
        http = env["SWARMEBOT_VPS_HTTP"] ?? ""
        engine = env["SWARMEBOT_VPS_ENGINE"] ?? ""
        // short: ssh's control socket path must fit in 104 bytes
        store = SSHIdentityStore(root: URL(fileURLWithPath: "/tmp/sbv-\(UUID().uuidString.prefix(4))", isDirectory: true))
    }

    override func tearDown() {
        if let store { try? FileManager.default.removeItem(at: store.root) }
    }

    func approved(_ user: String) async throws -> SSHIdentity {
        let identity = try store.findOrCreate(host: host, port: port, user: user)
        let keys = try await HostKeys.scan(host: host, port: port)
        XCTAssertEqual(keys.first?.type, "ssh-ed25519")
        XCTAssertTrue(keys.first?.fingerprint.hasPrefix("SHA256:") == true)
        return try await HostKeys.approve(keys[0], for: identity, store: store)
    }

    func testFullSetupFromPasswordToChatOverHTTP() async throws {
        var deploy = try await approved("deploy")
        let keyBefore = await RemoteAdmin(identity: deploy, store: store).keyWorks()
        XCTAssertFalse(keyBefore)

        // a wrong password is refused, nothing installed
        do {
            _ = try await RemoteAdmin(identity: deploy, store: store).installKey(password: "wrong")
            XCTFail("wrong password accepted")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .authentication)
        }

        deploy = try await RemoteAdmin(identity: deploy, store: store).installKey(password: "s3cret-pw")
        XCTAssertNotNil(deploy.keyInstalledAt)
        let keyFile = store.keyFile(deploy)
        let keyDate = try FileManager.default.attributesOfItem(atPath: keyFile.path)[.modificationDate] as? Date

        // R9: the same login again is the same identity and the same key — no password, no new key
        let again = try store.findOrCreate(host: host.uppercased(), port: port, user: "deploy")
        XCTAssertEqual(again.id, deploy.id)
        let keyAgain = await RemoteAdmin(identity: again, store: store).keyWorks()
        XCTAssertTrue(keyAgain)
        _ = try await RemoteAdmin(identity: again, store: store).installKey(password: "s3cret-pw")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: keyFile.path)[.modificationDate] as? Date, keyDate)
        let authorized = try await SSHCommand(identity: deploy, store: store).run("grep -c ' swarmebot:\(deploy.id)$' ~/.ssh/authorized_keys").text
        XCTAssertEqual(authorized.trimmingCharacters(in: .whitespacesAndNewlines), "1")

        let admin = RemoteAdmin(identity: deploy, store: store)
        let probe = try await admin.probe()
        XCTAssertEqual(probe.os, "ubuntu")
        XCTAssertTrue(probe.supported, probe.version)
        XCTAssertEqual(probe.sudo, "password")
        XCTAssertFalse(probe.isRoot)

        // sudo: a wrong password never runs the script; the right one runs it as root
        do {
            _ = try await admin.runAsRoot("id -un", [], probe: probe, sudoPassword: "nope")
            XCTFail("wrong sudo password accepted")
        } catch {}
        let whoami = try await admin.runAsRoot("id -un; echo \"arg=$1\"", ["it's here"], probe: probe, sudoPassword: "s3cret-pw")
        XCTAssertEqual(RemoteScripts.values(whoami.text)["arg"], "it's here")
        XCTAssertTrue(whoami.text.hasPrefix("root"), whoami.text)

        guard !engine.isEmpty, !http.isEmpty else { throw XCTSkip("SWARMEBOT_VPS_ENGINE / SWARMEBOT_VPS_HTTP not set: setup checked up to sudo") }
        let binary = URL(fileURLWithPath: engine)
        let sha = try String(contentsOfFile: engine + ".sha256", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try await admin.installEngine(binary: binary, sha256: sha, probe: probe)
        let afterUpload = try await admin.probe()
        XCTAssertEqual(afterUpload.engineHash, sha)

        let caddy = CaddySettings(site: ":8080", prefix: "srv1/deploy/", tls: .off)
        XCTAssertEqual(caddy.prefix, "/srv1/deploy")
        let chatURL = http + caddy.prefix
        let setup = try await admin.setupLinux(caddy: caddy, chatURL: chatURL, probe: probe, sudoPassword: "s3cret-pw")
        XCTAssertEqual(setup.socketDirectory, "/run/swarmebot/deploy")
        let afterSetup = try await admin.probe()
        XCTAssertTrue(afterSetup.serviceActive)

        let device = try await admin.addDevice(name: "Mac di prova")
        XCTAssertTrue(device.deviceId.hasPrefix("dev_"))

        // from here on only HTTP, like any client (R6)
        let connection = try XCTUnwrap(Connection.remote(chatURL: chatURL))
        let health = try await URLSession.shared.data(from: XCTUnwrap(connection.baseURL?.appendingPathComponent("api/health")))
        XCTAssertEqual((health.1 as? HTTPURLResponse)?.statusCode, 200)
        let client = CompanionClient(connection: connection, token: device.token)
        let bots = try await client.perform(client.makeRequest("GET", "/api/bots"))
        XCTAssertEqual((bots.1 as? HTTPURLResponse)?.statusCode, 200)
        var anonymous = try client.makeRequest("GET", "/api/bots")
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        let unauthorized = try await URLSession.shared.data(for: anonymous)
        XCTAssertEqual((unauthorized.1 as? HTTPURLResponse)?.statusCode, 401)

        // Claude's login: the setup-token token, into the engine's secrets, seen after the restart
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

        // the setup is idempotent: running it again changes nothing that works
        _ = try await admin.setupLinux(caddy: caddy, chatURL: chatURL, probe: probe, sudoPassword: "s3cret-pw")
        let healthAgain = try await client.perform(client.makeRequest("GET", "/api/health"))
        XCTAssertEqual((healthAgain.1 as? HTTPURLResponse)?.statusCode, 200)

        // a second login on the same server is a second identity with its own key
        var other = try await approved("other")
        XCTAssertNotEqual(other.id, deploy.id)
        other = try await RemoteAdmin(identity: other, store: store).installKey(password: "other-pw")
        XCTAssertNotEqual(try String(contentsOf: URL(fileURLWithPath: store.keyFile(other).path + ".pub"), encoding: .utf8),
                          try String(contentsOf: URL(fileURLWithPath: keyFile.path + ".pub"), encoding: .utf8))
        let otherProbe = try await RemoteAdmin(identity: other, store: store).probe()
        XCTAssertEqual(otherProbe.sudo, "password") // asks, and then is refused
        // and it cannot reach deploy's engine socket
        let peek = try await SSHCommand(identity: other, store: store).run("ls /run/swarmebot/deploy 2>&1 || true").text
        XCTAssertTrue(peek.contains("Permission denied"), peek)

        try await RemoteAdmin(identity: other, store: store).removeKey()
        let otherKey = await RemoteAdmin(identity: other, store: store).keyWorks()
        XCTAssertFalse(otherKey)
    }

    func testAChangedHostKeyStopsEveryCall() async throws {
        var deploy = try await approved("deploy")
        deploy = try await RemoteAdmin(identity: deploy, store: store).installKey(password: "s3cret-pw")
        // pretend the approved key was another one
        var forged = deploy
        let fake = "AAAAC3NzaC1lZDI1NTE5AAAAIJ8Yb3VuZ2x5LWZvcmdlZC1rZXktZm9yLXRoZS10ZXN0"
        forged.hostKey?.line = "\(HostKeys.knownHostsName(host, port)) ssh-ed25519 \(fake)"
        try store.update(forged)
        await SSHCommand(identity: forged, store: store).closeMaster()
        do {
            try await SSHCommand(identity: forged, store: store).run("true")
            XCTFail("a changed host key was accepted")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .hostKeyChanged)
        }
    }
}

/// The walk-through the settings sheet drives, on a fresh server.
@MainActor
final class ServerSetupFlowIntegrationTests: XCTestCase {
    func testTheSheetFlowFromFormToChat() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["SWARMEBOT_VPS_TEST"], let http = env["SWARMEBOT_VPS_HTTP"], let engine = env["SWARMEBOT_VPS_ENGINE"] else {
            throw XCTSkip("SWARMEBOT_VPS_TEST / _HTTP / _ENGINE not set")
        }
        let parts = target.split(separator: ":")
        // SWARMEBOT_VPS_KEEP=1 (with SWARMEBOT_HOME) leaves the result in the app's own stores:
        // a development app started on that home then shows the server
        let keep = env["SWARMEBOT_VPS_KEEP"] == "1" && AppPaths.isIsolated
        let root = URL(fileURLWithPath: "/tmp/sbf-\(UUID().uuidString.prefix(4))", isDirectory: true)
        defer { if !keep { try? FileManager.default.removeItem(at: root) } }
        let identities = keep ? SSHIdentityStore() : SSHIdentityStore(root: root.appendingPathComponent("ssh"))
        let engines = keep ? RemoteEngineStore() : RemoteEngineStore(file: root.appendingPathComponent("remote-engines.json"))
        let sha = try String(contentsOfFile: engine + ".sha256", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let flow = ServerSetupFlow(identities: identities, engines: engines) { _ in (URL(fileURLWithPath: engine), sha) }
        flow.name = "Prova"
        flow.host = String(parts[0])
        flow.port = Int(parts[1]) ?? 22
        flow.user = "deploy"
        flow.site = ":8080"
        flow.tls = .off
        flow.suggestPrefix()
        XCTAssertEqual(flow.prefix, "/127/deploy")
        flow.prefix = "/srv1/deploy"
        flow.chatURLOverride = http + "/srv1/deploy"
        XCTAssertNil(flow.formError)

        await flow.run()
        XCTAssertNil(flow.error)
        XCTAssertEqual(flow.step, .hostKey)
        let key = try XCTUnwrap(flow.scannedKeys.first)
        await flow.approve(key)
        // the key does not get in yet: the sheet asks for the password
        XCTAssertEqual(flow.step, .key)
        XCTAssertTrue(flow.needsPassword)
        flow.sshPassword = "s3cret-pw"
        await flow.run()
        XCTAssertNil(flow.error, flow.error ?? "")
        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.needsSudoPassword)
        XCTAssertEqual(flow.sshPassword, "", "the password must not outlive the setup")
        let saved = try XCTUnwrap(engines.all().first)
        XCTAssertEqual(saved.chatURL, http + "/srv1/deploy")
        let token = try XCTUnwrap(RemoteEngineStore.token(engineId: saved.id))
        defer { if !keep { RemoteEngineStore.deleteToken(engineId: saved.id) } }
        let health = try await CompanionClient(connection: XCTUnwrap(saved.connection), token: token).remoteHealth()
        XCTAssertEqual(health.remote, true)
        let fleet = try await CompanionClient(connection: XCTUnwrap(saved.connection), token: token).fleet(messages: 1)
        XCTAssertFalse(fleet.bots.isEmpty)
    }
}
