@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

final class JSONTests: XCTestCase {
    func testRoundTripKeepsOrderAndUnknownFields() throws {
        let text = #"{"zeta":1,"alpha":{"nested":[true,null,"x"]},"createdAt":1791901238120,"unknownFutureField":"keep me"}"#
        let json = try JSON.parse(text)
        XCTAssertEqual(json.serialized(), text, "order, integers and unknown keys survive")
    }

    func testPrettyMatchesJSONStringifyIndent() throws {
        XCTAssertEqual(try JSON.parse(#"{"a":[1,2],"b":{}}"#).pretty(), "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {}\n}")
    }

    func testEscapesAndSurrogates() throws {
        let json = try JSON.parse(#"{"s":"a\"b\\c\n😀è"}"#)
        XCTAssertEqual(json["s"]?.string, "a\"b\\c\n😀è")
        XCTAssertEqual(try JSON.parse(json.serialized()), json)
    }

    /// The trap that cost a parity diff: `nil` in a ternary is JSON null.
    func testNilLiteralIsJSONNullNotRemoval() {
        var object: JSONObject = ["a": 1]
        let removal: JSON? = Optional<JSON>.none
        object["a"] = removal
        XCTAssertNil(object["a"])
        XCTAssertTrue(JSON.null.isNull)
        XCTAssertFalse(JSON.number(0).isNull)
    }
}

final class RedactTests: XCTestCase {
    func testMasksCredentialShapes() {
        let out = Redact.text("key sk-ant-abcdefghijklmnopqrstu and Bearer abcdefghijklmnop and password=hunter2hunter2")
        XCTAssertFalse(out.contains("abcdefghijklmnopqrstu"))
        XCTAssertFalse(out.contains("hunter2hunter2"))
        XCTAssertTrue(out.contains("«redacted"))
    }

    func testMasksSecretNamedFieldsAndACPEnv() {
        let input: JSON = ["env": ["OMB_COMMS_TOKEN": "abc123456"], "list": [["name": "API_KEY", "value": "v-123456"]], "keyboard": "fine"]
        let out = Redact.json(input)
        XCTAssertEqual(out["env"]?["OMB_COMMS_TOKEN"]?.string, "«redacted 9 chars»")
        XCTAssertEqual(out["list"]?.array?.first?["value"]?.string, "«redacted 8 chars»")
        XCTAssertEqual(out["keyboard"]?.string, "fine")
    }
}

final class AutoApproveTests: XCTestCase {
    func testApprovalKeyNarrowsCommandsToTheProgram() {
        XCTAssertEqual(AutoApprove.approvalKey(tool: "Bash", summary: "FOO=1 sudo /usr/bin/git status"), "Bash:git")
        XCTAssertEqual(AutoApprove.approvalKey(tool: "Read", summary: "file"), "Read")
        XCTAssertEqual(AutoApprove.approvalKey(tool: "Bash", summary: "ls", scope: "local-computer"), "local-computer:Bash:ls")
    }

    func testGuardsBeatGrants() {
        let destructive = AutoApprove.verdict(autoApprove: true, alwaysAllow: [], tool: "Bash", summary: "rm -rf /tmp/x")
        XCTAssertNil(destructive.approve)
        XCTAssertEqual(destructive.source, "destructive-guard")
        let allowed = AutoApprove.verdict(autoApprove: false, alwaysAllow: ["Bash:git"], tool: "Bash", summary: "git status")
        XCTAssertEqual(allowed.source, "always-allow")
        XCTAssertEqual(AutoApprove.verdict(autoApprove: true, alwaysAllow: [], tool: "Read", summary: "~/.ssh/id_rsa").source, "sensitive-guard")
    }
}

final class LocalHostsTests: XCTestCase {
    func testGatewayNormalization() {
        XCTAssertEqual(LocalHosts.normalizeGatewayBaseUrl("https://litellm.example.com"), "https://litellm.example.com/v1")
        XCTAssertEqual(LocalHosts.normalizeGatewayBaseUrl(" http://h:4000/v1/ "), "http://h:4000/v1")
        XCTAssertNil(LocalHosts.normalizeGatewayBaseUrl("ftp://x"))
    }

    func testInjectIdsAndLabels() {
        XCTAssertEqual(LocalHosts.decode("local_endpoint::hermes/agent-1")?.model, "hermes/agent-1")
        XCTAssertNil(LocalHosts.decode("unknownhost::m"))
        let host = LocalHosts.all.first { $0.id == "local_endpoint" }!
        XCTAssertEqual(LocalHosts.label(host, model: "hermes/agent-1"), "hermes (agent-1)")
    }
}

@MainActor
final class StoreTests: XCTestCase {
    private func temporaryPaths() -> DataPaths {
        DataPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)"))
    }

    func testUnknownBotFieldsSurviveAWrite() throws {
        let paths = temporaryPaths()
        paths.ensure()
        let bots = #"[{"id":"b1","threadId":"t1","name":"X","title":"","description":"","notifications":true,"color":"blue","unread":false,"modelSelection":{"instanceId":"","model":""},"resumeCursors":{},"createdAt":1,"fromTheFuture":{"keep":true}}]"#
        try Data(bots.utf8).write(to: paths.bots)
        let store = try Store(paths: paths)
        store.patchBot("b1", ["pinned": true])
        let written = try JSON.parse(Data(contentsOf: paths.bots))
        XCTAssertEqual(written.array?.first?["fromTheFuture"]?["keep"]?.bool, true)
        XCTAssertEqual(written.array?.first?["pinned"]?.bool, true)
    }

    func testBranchingAndActiveLeaf() throws {
        let store = try Store(paths: temporaryPaths())
        let bot = store.createBot(seedMessages: false)
        let thread = bot["threadId"]!.string!
        let first = store.appendMessage(thread, ["role": "user", "kind": "text", "text": "uno"])
        store.appendMessage(thread, ["role": "bot", "kind": "text", "text": "risposta"])
        let edited = store.branchMessage(thread, sourceId: first["id"]!.string!, text: "due")!
        XCTAssertEqual(store.activePath(thread).compactMap { $0["text"]?.string }, ["due"])
        XCTAssertEqual(store.setActiveLeaf(thread, messageId: first["id"]!.string!), store.messages(thread)[1]["id"]?.string)
        XCTAssertEqual(store.activePath(thread).compactMap { $0["text"]?.string }, ["uno", "risposta"])
        XCTAssertNotNil(edited["parentId"])
    }

    func testMissingWorkingFolderFallsBackToTheWorkspace() throws {
        let store = try Store(paths: temporaryPaths())
        let bot = store.createBot(seedMessages: false)
        let id = bot["id"]!.string!, thread = bot["threadId"]!.string!
        let gone = "/nonexistent-\(UUID().uuidString)"
        store.patchBot(id, ["cwd": .string(gone)])
        XCTAssertEqual(store.pinTaskCwd(id, thread, fallback: "/tmp"), "/tmp")
        XCTAssertNil(store.bot(id)?["cwd"])
        XCTAssertEqual(store.pinTaskCwd(id, thread, fallback: "/elsewhere"), "/tmp")
    }

    func testPatchWithNullRemovesTheField() throws {
        let store = try Store(paths: temporaryPaths())
        let bot = store.createBot(seedMessages: false)
        let thread = bot["threadId"]!.string!
        let message = store.appendMessage(thread, ["role": "user", "kind": "text", "text": "x", "queued": true])
        let patched = store.patchMessage(thread, message["id"]!.string!, ["queued": .null])
        XCTAssertNil(patched?["queued"])
    }

    func testBotAuthoredTextIsRedactedButUserTextIsNot() throws {
        let store = try Store(paths: temporaryPaths())
        let thread = store.createBot(seedMessages: false)["threadId"]!.string!
        let bot = store.appendMessage(thread, ["role": "bot", "kind": "text", "text": "token sk-proj-abcdefghijklmnopqrst"])
        let user = store.appendMessage(thread, ["role": "user", "kind": "text", "text": "mio sk-proj-abcdefghijklmnopqrst"])
        XCTAssertFalse(bot["text"]!.string!.contains("abcdefghijklmnopqrst"))
        XCTAssertTrue(user["text"]!.string!.contains("abcdefghijklmnopqrst"))
    }
}
