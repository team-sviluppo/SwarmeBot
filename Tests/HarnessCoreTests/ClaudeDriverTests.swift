@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

/// A blocking client for a broker socket, read off the main actor.
private final class BrokerClient: @unchecked Sendable {
    let fd: Int32

    init(_ path: String) throws {
        fd = PermissionProxy.connect(path)
        guard fd >= 0 else { throw XCTSkip("could not connect to \(path)") }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ message: JSON) {
        let bytes = Array((message.serialized() + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, bytes.count) }
    }

    private var buffer = Data()

    /// The next answer line, or nil after 5 s.
    func next() async -> JSON? {
        await Task.detached { [self] in
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return try? JSON.parse(Data(line))
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(fd, &chunk, chunk.count)
                if count <= 0 { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }.value
    }

    deinit { close(fd) }
}

@MainActor
final class PermissionBrokerTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("pb-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSocketPathsDifferForIdsWithACommonPrefix() {
        let a = PermissionBroker.socketPath(dataDir: dir, threadId: "t-perm-dup-1")
        let b = PermissionBroker.socketPath(dataDir: dir, threadId: "t-perm-dup-2")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix(dir.path + "/perm-t-pe"))
    }

    func testAskAnswerAndResolve() async throws {
        var asks: [BrokerAsk] = []
        var resolved: [(String, String)] = []
        let broker = PermissionBroker(socketPath: dir.appendingPathComponent("a.sock").path,
                                      onAsk: { asks.append($0) }, onResolve: { _, behavior, source in resolved.append((behavior, source)) })
        let client = try BrokerClient(broker.socketPath)
        client.send(["t": "ask", "id": "a1", "tool": "Bash", "input": ["command": "ls -la"]])
        for _ in 0..<50 where asks.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(asks.first?.tool, "Bash")
        XCTAssertEqual(asks.first.map(PermissionBroker.summary), "ls -la")
        // a question's answer does not fit a permission
        XCTAssertFalse(broker.answer("a1", behavior: "answer", message: "x"))
        XCTAssertTrue(broker.answer("a1", behavior: "allow", message: nil))
        XCTAssertFalse(broker.answer("a1", behavior: "allow", message: nil), "answered once only")
        let answer = await client.next()
        XCTAssertEqual(answer?["id"]?.string, "a1")
        XCTAssertEqual(answer?["behavior"]?.string, "allow")
        XCTAssertEqual(resolved.first?.0, "allow")
        XCTAssertEqual(resolved.first?.1, "user")
        broker.shutdown()
    }

    func testDuplicateIdIsDeniedAndNeverShown() async throws {
        var asks = 0
        let broker = PermissionBroker(socketPath: dir.appendingPathComponent("d.sock").path,
                                      onAsk: { _ in asks += 1 }, onResolve: { _, _, _ in })
        let client = try BrokerClient(broker.socketPath)
        client.send(["t": "ask", "id": "dup", "tool": "Bash", "input": [:]])
        client.send(["t": "ask", "id": "dup", "tool": "Bash", "input": [:]])
        let answer = await client.next()
        XCTAssertEqual(answer?["behavior"]?.string, "deny")
        XCTAssertEqual(answer?["message"]?.string, PermissionBroker.duplicateAskNote)
        XCTAssertEqual(asks, 1)
        broker.shutdown()
    }

    func testTimeoutDeniesPermissionsAndAnswersQuestions() async throws {
        var sources: [String] = []
        let broker = PermissionBroker(socketPath: dir.appendingPathComponent("t.sock").path, timeout: 0.2,
                                      onAsk: { _ in }, onResolve: { _, _, source in sources.append(source) })
        let client = try BrokerClient(broker.socketPath)
        client.send(["t": "ask", "id": "p", "tool": "Bash", "input": [:]])
        let denied = await client.next()
        XCTAssertEqual(denied?["behavior"]?.string, "deny")
        XCTAssertEqual(denied?["message"]?.string, PermissionBroker.denyTimeoutNote)
        client.send(["t": "ask", "id": "q", "kind": "question", "tool": "ask_user", "input": ["question": "?"]])
        let answered = await client.next()
        XCTAssertEqual(answered?["behavior"]?.string, "answer")
        XCTAssertEqual(sources, ["timeout", "timeout"])
        broker.shutdown()
    }

    /// The zombie card (#211): after close, an ask on a still-open
    /// connection is answered by the system and never becomes a card.
    func testClosedBrokerAnswersWithoutACard() async throws {
        var asks = 0
        var resolved: [String] = []
        let broker = PermissionBroker(socketPath: dir.appendingPathComponent("c.sock").path,
                                      onAsk: { _ in asks += 1 }, onResolve: { _, _, source in resolved.append(source) })
        let client = try BrokerClient(broker.socketPath)
        client.send(["t": "ask", "id": "open", "tool": "Bash", "input": [:]])
        for _ in 0..<50 where asks == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        broker.close()
        let drained = await client.next()
        XCTAssertEqual(drained?["message"]?.string, "SwarmeBot: the turn ended")
        XCTAssertEqual(resolved, ["system"])
        client.send(["t": "ask", "id": "late", "kind": "question", "tool": "ask_user", "input": [:]])
        let late = await client.next()
        XCTAssertEqual(late?["behavior"]?.string, "answer")
        XCTAssertEqual(asks, 1, "no card for the late ask")
        XCTAssertFalse(FileManager.default.fileExists(atPath: broker.socketPath))
        broker.shutdown()
    }
}

final class PermissionProxyTests: XCTestCase {
    func testAllowCarriesTheInputAndSuggestionsOnlyWhenAlways() {
        let args: JSON = ["tool_name": "Bash", "input": ["command": "ls"], "permission_suggestions": [["type": "addRules"]]]
        let once = try! JSON.parse(PermissionProxy.resultText(isQuestion: false, arguments: args, answer: ["behavior": "allow"]))
        XCTAssertEqual(once["behavior"]?.string, "allow")
        XCTAssertEqual(once["updatedInput"]?["command"]?.string, "ls")
        XCTAssertNil(once["updatedPermissions"])
        let always = try! JSON.parse(PermissionProxy.resultText(isQuestion: false, arguments: args, answer: ["behavior": "allow", "always": true]))
        XCTAssertEqual(always["updatedPermissions"]?.array?.count, 1)
    }

    func testDenyAndQuestionText() {
        let deny = try! JSON.parse(PermissionProxy.resultText(isQuestion: false, arguments: [:], answer: ["behavior": "deny"]))
        XCTAssertEqual(deny["message"]?.string, "Denied from SwarmeBot")
        XCTAssertEqual(PermissionProxy.resultText(isQuestion: true, arguments: [:], answer: ["behavior": "answer", "message": "Blu"]), "Blu")
        XCTAssertEqual(PermissionProxy.resultText(isQuestion: true, arguments: [:], answer: ["behavior": "answer"]),
                       "No answer was given — use your best judgment.")
    }
}

final class ClaudeCatalogTests: XCTestCase {
    func testNewestRowPerFamilyFromTheBinary() {
        let blob = #"xx FABLE_ID:"claude-fable-5",FABLE_NAME:"Claude Fable 5",OPUS_ID:"claude-opus-5",OPUS_NAME:"Claude Opus 5","#
            + #"OPUS_OLD_ID:"claude-opus-4-1",SONNET_ID:"claude-sonnet-5-5",SONNET_NAME:"Claude Sonnet 5.5",SONNET_PREV_ID:"claude-sonnet-5","#
            + #"MYTHOS_SONNET_ID:"claude-sonnet-9",HAIKU_ID:"claude-haiku-4-5" yy"#
        let options = ClaudeCatalog.fromBinary(Data(blob.utf8))
        XCTAssertEqual(options?.map(\.id), ["claude-fable-5", "claude-opus-5", "claude-sonnet-5-5", "claude-haiku-4-5"])
        XCTAssertEqual(options?[2].label, "Claude Sonnet 5.5")
        XCTAssertEqual(options?[3].label, "claude-haiku-4-5", "no _NAME: the id is the label")
        XCTAssertNil(ClaudeCatalog.fromBinary(Data("nothing here".utf8)))
    }

    func testSettingsExtrasAreCustomRows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"availableModels":["claude-opus-5","my-proxy/model","bad id!"],"customModels":[{"id":"x-1","name":"X One","effortLevels":["low","high"]}],"model":"y-2"}"#.utf8)
            .write(to: dir.appendingPathComponent("settings.json"))
        let catalog = ClaudeCatalog.fromSettings(["CLAUDE_CONFIG_DIR": dir.path])
        XCTAssertEqual(catalog.options.map(\.id), ["claude-fable-5", "claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "my-proxy/model", "x-1", "y-2"])
        XCTAssertEqual(catalog.options[5].label, "X One")
        XCTAssertEqual(catalog.options[5].effortLevels, ["low", "high"])
        XCTAssertEqual(catalog.options[5].custom, true)
        XCTAssertNil(catalog.options[1].custom, "official rows stay untagged")
    }

    func testCliRowsLeadAndTheDefaultFollowsThem() {
        let merged = ClaudeCatalog.withCliModels(
            ModelCatalog(default: "claude-sonnet-5", options: [ModelOption(id: "claude-sonnet-5", label: "S"), ModelOption(id: "mine", label: "m", custom: true)]),
            [ModelOption(id: "claude-sonnet-5-5", label: "S55")]
        )
        XCTAssertEqual(merged.options.map(\.id), ["claude-sonnet-5-5", "mine"])
        XCTAssertEqual(merged.default, "claude-sonnet-5-5")
    }

    func testConfigDecoding() throws {
        XCTAssertEqual(try ClaudeConfig(.null).cli, "claude")
        XCTAssertEqual(try ClaudeConfig(.null).permissionMode, .acceptEdits)
        XCTAssertEqual(try ClaudeConfig(["permissionMode": "bypassPermissions"]).permissionMode, .bypassPermissions)
        XCTAssertThrowsError(try ClaudeConfig(["permissionMode": "yolo"]))
    }

    func testEnvironmentStripsIdentityAndWorkspaceKeys() {
        let env = ClaudeInstance.environment(model: "claude-sonnet-5", source: [
            "ANTHROPIC_API_KEY": "sk-x", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "XAI_API_KEY": "x", "BOX_TOKEN": "b", "HOME": "/tmp",
        ])
        for key in ["ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "XAI_API_KEY", "BOX_TOKEN"] { XCTAssertNil(env[key], key) }
        XCTAssertEqual(env["NPM_CONFIG_LOGLEVEL"], "error")
        let local = ClaudeInstance.environment(model: "unsloth::local-model", source: ["UNSLOTH_STUDIO_AUTH_TOKEN": "u-secret"])
        XCTAssertEqual(local["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8888")
        XCTAssertEqual(local["ANTHROPIC_AUTH_TOKEN"], "u-secret")
        XCTAssertEqual(local["ANTHROPIC_MODEL"], "local-model")
    }
}

@MainActor
final class CLIProcessTests: XCTestCase {
    func testLinesInOrderThenClose() async throws {
        let process = try CLIProcess(cli: "/bin/sh", args: ["-c", "printf 'a\\nb\\nè'; echo err >&2; exit 3"], cwd: "/tmp", environment: ["PATH": "/bin:/usr/bin"])
        var lines: [String] = []
        var stderr = ""
        let code: Int32? = await withCheckedContinuation { continuation in
            process.onLine = { lines.append($0) }
            process.onStderr = { stderr += $0 }
            process.onClose = { continuation.resume(returning: $0) }
            process.start()
        }
        XCTAssertEqual(lines, ["a", "b", "è"])
        XCTAssertEqual(stderr, "err\n")
        XCTAssertEqual(code, 3)
    }

    /// The engine ignores SIGTERM for itself; a CLI must not inherit that.
    func testKillTreeStopsAChildEvenWhenWeIgnoreSIGTERM() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let process = try CLIProcess(cli: "/bin/sleep", args: ["30"], cwd: nil, environment: [:])
        let started = Date()
        let code: Int32? = await withCheckedContinuation { continuation in
            process.onClose = { continuation.resume(returning: $0) }
            process.start()
            process.killTree()
        }
        XCTAssertNil(code, "killed by a signal")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testMissingCliIsASetupFailure() {
        XCTAssertThrowsError(try CLIProcess(cli: "definitely-not-a-cli-xyz", args: [], cwd: nil, environment: [:])) { error in
            XCTAssertEqual((error as? SpawnFailure)?.setup, true)
        }
    }
}

final class ACPHarnessTests: XCTestCase {
    func testCursorTextCatalogWithMarkers() {
        let catalog = ACPHarnesses.cursorCatalog(text: "Available models\n\nauto - Auto (current)\nfake-fast - Fake Fast (default)\nsonnet-x  Sonnet X\n")
        XCTAssertEqual(catalog?.default, "fake-fast")
        XCTAssertEqual(catalog?.options.suffix(2).map(\.id), ["fake-fast", "sonnet-x"])
        XCTAssertEqual(catalog?.options.last?.label, "Sonnet X")
        XCTAssertEqual(catalog?.options.first?.id, "auto", "static rows lead")
    }

    func testCursorAuthFromBannerAndText() {
        XCTAssertEqual(ACPHarnesses.cursorAuth(json: ACPHarnesses.firstJSON("banner\n{\"auth\":{\"status\":\"logged_in\"}}")), true)
        XCTAssertEqual(ACPHarnesses.cursorAuth(text: "You are not logged in"), false)
        XCTAssertNil(ACPHarnesses.cursorAuth(text: "hello"))
    }

    func testGrokCatalogReadsSlugsAndDefault() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"""
        [models]
        default = "local-qwen"

        [model.local-qwen]
        model = "qwen3"
        name = "Qwen locale"

        [model."bad slug!"]
        model = "x"
        """#.write(to: home.appendingPathComponent(".grok/config.toml"), atomically: true, encoding: .utf8)
        let catalog = ACPHarnesses.grokCatalog(["HOME": home.path])
        XCTAssertEqual(catalog.options.map(\.id), ["grok-4.6", "grok-4.5", "local-qwen"])
        XCTAssertEqual(catalog.options.last?.label, "Qwen locale")
        XCTAssertEqual(catalog.default, "local-qwen")
    }

    func testHermesProviderBlockIsReplacedNotDuplicated() {
        let before = "model: x\nproviders:\n  local_endpoint:\n    base_url: http://old/v1\n    api_key: old\n  other:\n    base_url: http://o/v1\n"
        let after = ACPHarnesses.upsertHermesProvider(before, hostId: "local_endpoint", baseUrl: "http://new/v1", apiKey: "k")
        XCTAssertEqual(after, "model: x\nproviders:\n  local_endpoint:\n    base_url: http://new/v1\n    api_key: k\n  other:\n    base_url: http://o/v1\n")
        let fresh = ACPHarnesses.upsertHermesProvider("model: x", hostId: "omlx", baseUrl: "http://a b/v1", apiKey: "k")
        XCTAssertEqual(fresh, "model: x\n\nproviders:\n  omlx:\n    base_url: \"http://a b/v1\"\n    api_key: k\n")
    }

    func testDroidInjectIdAndCredentialStrip() {
        XCTAssertEqual(ACPHarnesses.droidInjectId(host: "local_endpoint", model: "fake/echo 1"), "custom:swarmebot-local_endpoint-fake-echo-1")
        XCTAssertEqual(ACPHarnesses.classifyOpencode(RPCError(message: "x", code: -32000)), "invalid_credentials")
        XCTAssertEqual(ACPHarnesses.classifyCursor(RPCError(message: "Your subscription has expired", code: nil)), "inactive_subscription")
    }
}
