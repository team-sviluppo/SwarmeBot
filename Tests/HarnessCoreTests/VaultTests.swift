@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

/// The secrets vault (docs/plans/2026-10-25-vault.md): storage and
/// encryption, the API, a turn's grant and tool, masking, the environments.
@MainActor
final class VaultTests: XCTestCase {
    static let token = "ghp_TESTabcdefghijklmnopqrstuvwxyz0123"

    private func temporaryPaths() throws -> DataPaths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DataPaths(root: dir)
    }

    private func key() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    private func github(_ vault: Vault, name: String = "GITHUB_TOKEN") throws {
        try vault.create(["name": .string(name), "preset": "github", "description": "Org token", "hint": "push to origin",
                          "value": .string(Self.token)])
    }

    // MARK: Storage

    func testNamesAndFields() throws {
        let vault = Vault(paths: try temporaryPaths(), key: nil)
        for bad in ["lower", "A", "PATH", "OMB_X", "SWARMEBOT_KEY", "GIT_ASKPASS", "1ABC", "A-B"] {
            XCTAssertThrowsError(try vault.create(["name": .string(bad), "value": "123456"]), bad)
        }
        try github(vault)
        XCTAssertThrowsError(try github(vault), "a name is unique")
        XCTAssertThrowsError(try vault.create(["name": "OTHER", "value": "two\nlines"]))
        XCTAssertThrowsError(try vault.create(["name": "OTHER", "preset": "aws", "value": "123456"]))
        XCTAssertEqual(vault.secret("GITHUB_TOKEN")?.keys.joined(separator: ","), "name,preset,description,hint,createdAt,updatedAt")
        try vault.update("GITHUB_TOKEN", ["description": "Personal"])
        XCTAssertEqual(vault.secret("GITHUB_TOKEN")?["description"], "Personal")
        XCTAssertEqual(vault.value("GITHUB_TOKEN"), Self.token, "the value stays when not given")
    }

    func testFilesArePrivateAndTheMetadataHasNoValue() throws {
        let paths = try temporaryPaths()
        let vault = Vault(paths: paths, key: nil)
        try github(vault)
        for name in ["vault.json", "vault-secrets.json"] {
            let mode = try FileManager.default.attributesOfItem(atPath: paths.root.appendingPathComponent(name).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o600, name)
        }
        let meta = try String(contentsOf: paths.root.appendingPathComponent("vault.json"), encoding: .utf8)
        XCTAssertFalse(meta.contains(Self.token))
        XCTAssertFalse(vault.wire().serialized().contains(Self.token))
        XCTAssertEqual(vault.wire()["secrets"]?.array?.first?["set"], true)
    }

    func testEncryptionRoundTripWrongKeyAndMigration() throws {
        let paths = try temporaryPaths()
        let first = key()
        // written without a key, as on a remote engine
        try github(Vault(paths: paths, key: nil))
        var file = try String(contentsOf: paths.root.appendingPathComponent("vault-secrets.json"), encoding: .utf8)
        XCTAssertTrue(file.contains(Self.token))

        // the Mac's key arrives: the file is sealed at once
        let sealed = Vault(paths: paths, key: first)
        XCTAssertTrue(sealed.encrypted)
        file = try String(contentsOf: paths.root.appendingPathComponent("vault-secrets.json"), encoding: .utf8)
        XCTAssertFalse(file.contains(Self.token))
        XCTAssertTrue(file.contains("AES-GCM"))
        XCTAssertEqual(Vault(paths: paths, key: first).value("GITHUB_TOKEN"), Self.token)

        for other in [nil, key()] {
            let locked = Vault(paths: paths, key: other)
            XCTAssertTrue(locked.locked)
            XCTAssertNil(locked.value("GITHUB_TOKEN"))
            XCTAssertThrowsError(try locked.create(["name": "OTHER", "value": "123456"]), "a locked vault is never overwritten")
            XCTAssertEqual(locked.wire()["locked"], true)
        }
    }

    func testReloadSeesAnotherWriter() throws {
        let paths = try temporaryPaths()
        let engine = Vault(paths: paths, key: nil)
        XCTAssertNil(engine.secret("GITHUB_TOKEN"))
        // the ssh command is another process with its own Vault
        try github(Vault(paths: paths, key: nil))
        engine.reload()
        XCTAssertEqual(engine.value("GITHUB_TOKEN"), Self.token)
    }

    func testGrantsAndRemoval() throws {
        let vault = Vault(paths: try temporaryPaths(), key: nil)
        try github(vault)
        try vault.create(["name": "HF", "preset": "huggingface", "value": "hf_abcdefghij"])
        XCTAssertThrowsError(try vault.setGrants(botId: "b", ["secrets": [["name": "NOPE"]]]))
        XCTAssertThrowsError(try vault.setGrants(botId: "b", ["secrets": [["name": "HF", "mode": "always"]]]))
        try vault.setGrants(botId: "b", ["secrets": [["name": "GITHUB_TOKEN", "mode": "safe"], ["name": "HF", "mode": "env"],
                                                     ["name": "HF", "mode": "safe"]], "note": "only on main"])
        XCTAssertEqual(vault.grants(botId: "b").secrets, [.init(name: "GITHUB_TOKEN", mode: "safe"), .init(name: "HF", mode: "env")])
        XCTAssertEqual(vault.grants(botId: "b").note, "only on main")
        try vault.remove("HF")
        XCTAssertEqual(vault.grants(botId: "b").secrets.map(\.name), ["GITHUB_TOKEN"])
        XCTAssertNil(vault.value("HF"))
        vault.forgetBot("b")
        XCTAssertTrue(vault.grants(botId: "b").secrets.isEmpty)
    }

    // MARK: Environment and masking

    func testPresetsSetWhatTheToolsRead() throws {
        let vault = Vault(paths: try temporaryPaths(), key: nil)
        try github(vault, name: "ORG_TOKEN")
        try vault.create(["name": "HF", "preset": "huggingface", "value": "hf_abcdefghij"])
        try vault.create(["name": "PLAIN", "value": "plain-value"])
        let env = vault.environment(for: ["ORG_TOKEN", "HF", "PLAIN"])
        XCTAssertEqual(env["ORG_TOKEN"], Self.token)
        XCTAssertEqual(env["GH_TOKEN"], Self.token)
        XCTAssertEqual(env["GITHUB_TOKEN"], Self.token)
        XCTAssertEqual(env["GIT_CONFIG_COUNT"], "1")
        XCTAssertEqual(env["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraheader")
        XCTAssertEqual(env["GIT_CONFIG_VALUE_0"], "AUTHORIZATION: basic \(Data("x-access-token:\(Self.token)".utf8).base64EncodedString())")
        XCTAssertEqual(env["HF_TOKEN"], "hf_abcdefghij")
        XCTAssertEqual(env["PLAIN"], "plain-value")
        XCTAssertEqual(vault.environment(for: ["PLAIN"]).keys.sorted(), ["PLAIN"])
    }

    func testMaskingCoversTheEncodedForms() throws {
        let vault = Vault(paths: try temporaryPaths(), key: nil)
        try github(vault)
        try vault.create(["name": "SHORT", "value": "abc"])
        try vault.create(["name": "SPECIAL", "value": "p@ss/word+1"])
        let base64 = Data(Self.token.utf8).base64EncodedString()
        let header = Data("x-access-token:\(Self.token)".utf8).base64EncodedString()
        let text = "token=\(Self.token) b64=\(base64) hdr=\(header) url=p%40ss%2Fword%2B1 raw=p@ss/word+1 abc"
        XCTAssertEqual(vault.mask(text), "token=«secret GITHUB_TOKEN» b64=«secret GITHUB_TOKEN» hdr=«secret GITHUB_TOKEN» url=«secret SPECIAL» raw=«secret SPECIAL» abc",
                       "a value shorter than 6 characters is not masked")
        XCTAssertEqual(vault.mask(["a": ["b": .string(Self.token)]]), ["a": ["b": "«secret GITHUB_TOKEN»"]])
    }

    func testStoreStreamAndLogAreMasked() throws {
        let paths = try temporaryPaths()
        let harness = try Harness(paths: paths, environment: ProcessInfo.processInfo.environment, drivers: [])
        try github(harness.vault)
        let bot = harness.store.createBot()
        let threadId = bot["threadId"]?.string ?? ""
        let message = harness.store.appendMessage(threadId, ["role": "bot", "kind": "text", "text": .string("here: \(Self.token)")])
        XCTAssertEqual(message["text"], "here: «secret GITHUB_TOKEN»")
        let patched = harness.store.patchMessage(threadId, message["id"]?.string ?? "", ["text": .string("again \(Self.token)")])
        XCTAssertEqual(patched?["text"], "again «secret GITHUB_TOKEN»")
        harness.bus.publish(RuntimeEvent(provider: "claude", threadId: threadId, turnId: "t", .textCompleted(text: "x \(Self.token)")))
        let log = try String(contentsOf: paths.events.appendingPathComponent("\(threadId).ndjson"), encoding: .utf8)
        XCTAssertFalse(log.contains(Self.token))
        XCTAssertTrue(log.contains("«secret GITHUB_TOKEN»"))
    }

    // MARK: Turns

    func testTurnSecretsByModeAndDriver() throws {
        let harness = try Harness(paths: try temporaryPaths(), environment: ProcessInfo.processInfo.environment, drivers: [])
        try github(harness.vault)
        try harness.vault.create(["name": "HF", "preset": "huggingface", "value": "hf_abcdefghij"])
        XCTAssertTrue(harness.turnSecrets(botId: "b", threadId: "t", driverKind: "claude", canMount: true, cwd: nil, computerKind: nil).prompt.isEmpty,
                      "no grants, nothing changes")
        try harness.vault.setGrants(botId: "b", ["secrets": [["name": "GITHUB_TOKEN", "mode": "safe"], ["name": "HF", "mode": "env"]],
                                                 "note": "never force-push"])

        let claude = harness.turnSecrets(botId: "b", threadId: "t", driverKind: "claude", canMount: true, cwd: "/tmp", computerKind: nil)
        let server = try XCTUnwrap(claude.server)
        XCTAssertEqual(server.args, ["mcp-secrets"])
        XCTAssertEqual(Set(server.env.keys), ["OMB_HARNESS_URL", "OMB_COMMS_TOKEN", "OMB_SECRETS_GRANT", "OMB_SECRETS_NAMES"])
        XCTAssertEqual(server.env["OMB_SECRETS_NAMES"], "GITHUB_TOKEN")
        XCTAssertFalse(server.json.serialized().contains(Self.token), "the helper never holds a value")
        XCTAssertEqual(claude.environment["HF_TOKEN"], "hf_abcdefghij")
        XCTAssertNil(claude.environment["GITHUB_TOKEN"], "a safe secret stays out of the CLI's environment")
        XCTAssertTrue(claude.prompt.contains("GITHUB_TOKEN") && claude.prompt.contains("never force-push") && claude.prompt.contains("run_with_secrets"))
        XCTAssertFalse(claude.prompt.contains(Self.token) || claude.prompt.contains("hf_abcdefghij"))

        let pi = harness.turnSecrets(botId: "b", threadId: "t2", driverKind: "piAgent", canMount: false, cwd: nil, computerKind: nil)
        XCTAssertNil(pi.server)
        XCTAssertEqual(pi.environment["HF_TOKEN"], "hf_abcdefghij")
        XCTAssertTrue(pi.prompt.contains("cannot be used with this engine"))

        let grok = harness.turnSecrets(botId: "b", threadId: "t3", driverKind: "grok", canMount: false, cwd: nil, computerKind: nil)
        XCTAssertNil(grok.server)
        XCTAssertTrue(grok.environment.isEmpty && grok.prompt.isEmpty)

        let vm = harness.turnSecrets(botId: "b", threadId: "t4", driverKind: "claude", canMount: true, cwd: nil, computerKind: "vm")
        XCTAssertNil(vm.server)
        XCTAssertTrue(vm.environment.isEmpty)
        XCTAssertTrue(vm.prompt.contains("not available while you work on a computer"))
    }

    private func run(_ harness: Harness, grant: String, _ body: JSON) async -> (Int, JSON) {
        let request = HTTPRequest(method: "POST", path: "/api/internal/secrets/run", query: [:],
                                  headers: ["authorization": "Bearer \(harness.commsToken)", SecretsGrant.header: grant,
                                            "content-type": "application/json"], body: body.data)
        let response = await harness.internalRoute(request)!
        return (response.status, (try? JSON.parse(response.body)) ?? .null)
    }

    func testTheToolRunsWithTheSecretAndMasksTheOutput() async throws {
        let harness = try Harness(paths: try temporaryPaths(), environment: ProcessInfo.processInfo.environment.merging(["ANTHROPIC_API_KEY": "sk-ant-should-not-leak"]) { $1 },
                                  drivers: [])
        try github(harness.vault)
        try harness.vault.create(["name": "OTHER", "value": "other-value-123"])
        try harness.vault.setGrants(botId: "b", ["secrets": [["name": "GITHUB_TOKEN"]]])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-cwd-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let turn = harness.turnSecrets(botId: "b", threadId: "t", driverKind: "claude", canMount: true, cwd: folder.path, computerKind: nil)
        let grant = try XCTUnwrap(turn.server?.env["OMB_SECRETS_GRANT"]?.string)

        var (status, body) = await run(harness, grant: grant, [
            "command": "echo \"$GITHUB_TOKEN\"; echo \"$GH_TOKEN\" >&2; printf '%s' \"${ANTHROPIC_API_KEY:-none}\"; echo; basename \"$PWD\"; exit 3",
            "secrets": ["GITHUB_TOKEN"],
        ])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["exitCode"], 3)
        XCTAssertEqual(body["stdout"], .string("«secret GITHUB_TOKEN»\nnone\n\(folder.lastPathComponent)\n"),
                       "the value was set, came back masked; the engine's own keys did not ride along; it ran in the chat's folder")
        XCTAssertEqual(body["stderr"], "«secret GITHUB_TOKEN»\n")

        (status, _) = await run(harness, grant: grant, ["command": "true", "secrets": ["OTHER"]])
        XCTAssertEqual(status, 403, "a secret the bot was not given")
        (status, _) = await run(harness, grant: "guess", ["command": "true", "secrets": []])
        XCTAssertEqual(status, 403)
        (status, body) = await run(harness, grant: grant, ["command": "sleep 5", "secrets": [], "timeout_sec": 1])
        XCTAssertEqual(body["timedOut"], true)

        harness.revokeSecretsGrants(threadId: "t")
        (status, _) = await run(harness, grant: grant, ["command": "true", "secrets": []])
        XCTAssertEqual(status, 403, "a settled turn's grant is gone")
    }

    func testTheProxyFormatsTheResult() {
        let ok = SecretsProxy.text(["exitCode": 0, "stdout": "hi\n", "stderr": "", "timedOut": false, "truncated": false])
        XCTAssertEqual(ok.text, "exit code: 0\n--- stdout ---\nhi\n")
        XCTAssertFalse(ok.isError)
        let failed = SecretsProxy.text(["exitCode": .null, "stdout": "", "stderr": "boom", "timedOut": true, "truncated": true])
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("timed out") && failed.text.contains("truncated") && failed.text.contains("boom"))
        XCTAssertEqual(SecretsProxy.tool(["A", "B"])["inputSchema"]?["properties"]?["secrets"]?["items"]?["enum"], ["A", "B"])
    }

    func testTheEngineKeepsTheKeyToItself() throws {
        let key = key()
        let harness = try Harness(paths: try temporaryPaths(),
                                  environment: ["PATH": "/usr/bin:/bin", Vault.keyEnv: key.base64EncodedString()], drivers: [])
        XCTAssertTrue(harness.vault.encrypted)
        XCTAssertNil(harness.environment[Vault.keyEnv])
        XCTAssertNil(ProcessInfo.processInfo.environment[Vault.keyEnv])
        XCTAssertNil(Harness.commandEnvironment(["GH_TOKEN": "x", "OMB_PORT": "1", "LANG": "C", "PATH": "/bin"])["GH_TOKEN"])
        XCTAssertEqual(Harness.commandEnvironment(["LANG": "C", "PATH": "/bin"])["LANG"], "C")
    }

    // MARK: API

    func testAPIServesNoValueAndIsReadOnlyRemotely() async throws {
        let harness = try Harness(paths: try temporaryPaths(), environment: ProcessInfo.processInfo.environment, drivers: [])
        let routes = Routes(harness: harness)
        let bot = harness.store.createBot()
        let botId = bot["id"]?.string ?? ""
        func call(_ method: String, _ path: String, _ body: JSON? = nil, device: String? = nil) async -> (Int, JSON) {
            var request = HTTPRequest(method: method, path: path, query: [:],
                                      headers: body == nil ? [:] : ["content-type": "application/json"], body: body?.data ?? Data())
            request.deviceId = device
            guard case let .response(response) = await routes.handle(request) else { XCTFail("not a response"); return (0, .null) }
            return (response.status, (try? JSON.parse(response.body)) ?? .null)
        }
        var (status, body) = await call("POST", "/api/vault/secrets", ["name": "GITHUB_TOKEN", "preset": "github", "value": .string(Self.token)])
        XCTAssertEqual(status, 201)
        XCTAssertNil(body["secret"]?["value"])
        (status, body) = await call("PUT", "/api/vault/grants/\(botId)", ["secrets": [["name": "GITHUB_TOKEN", "mode": "env"]], "note": ""])
        XCTAssertEqual(status, 200)
        (status, _) = await call("PUT", "/api/vault/grants/nobody", ["secrets": []])
        XCTAssertEqual(status, 404)
        (status, body) = await call("GET", "/api/vault")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["secrets"]?.array?.first?["set"], true)
        XCTAssertEqual(body["grants"]?[botId]?["secrets"]?.array?.first?["mode"], "env")
        XCTAssertNotNil(body["support"]?["safe"])
        XCTAssertFalse(body.serialized().contains(Self.token))

        (status, _) = await call("GET", "/api/vault", device: "phone")
        XCTAssertEqual(status, 200, "a remote client may read the list")
        for (method, path, payload) in [("POST", "/api/vault/secrets", JSON.object(["name": "X_TOKEN", "value": "123456"])),
                                        ("PATCH", "/api/vault/secrets/GITHUB_TOKEN", ["value": "123456"]),
                                        ("DELETE", "/api/vault/secrets/GITHUB_TOKEN", nil),
                                        ("PUT", "/api/vault/grants/\(botId)", ["secrets": []])] as [(String, String, JSON?)] {
            (status, body) = await call(method, path, payload, device: "phone")
            XCTAssertEqual(status, 403, "\(method) \(path)")
            XCTAssertEqual(body["error"]?.string, VaultRoutes.remoteRefusal)
        }

        (status, _) = await call("DELETE", "/api/vault/secrets/GITHUB_TOKEN")
        XCTAssertEqual(status, 200)
        (status, body) = await call("GET", "/api/vault")
        XCTAssertEqual(body["secrets"]?.array?.count, 0)
        XCTAssertNil(body["grants"]?[botId]?["secrets"]?.array?.first)
    }
}
