@testable import HarnessCore
import XCTest

/// Skills (docs/plans/2026-10-21-skill.md): the folder as the repository,
/// the settings API, and what a turn gets from them.
@MainActor
final class SkillsTests: XCTestCase {
    private func temporaryPaths() throws -> DataPaths {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DataPaths(root: dir)
    }

    private func manifest(_ name: String, _ description: String = "Builds the weekly Meta ads report.", body: String = "Read the campaigns, then fill the table.") -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)\n"
    }

    private func file(_ path: String, _ text: String, executable: Bool = false) -> Skills.UploadFile {
        Skills.UploadFile(path: path, data: Data(text.utf8), executable: executable)
    }

    // MARK: Front matter

    func testFrontMatterScalars() throws {
        let plain = try Skills.parse(manifest("meta-report"))
        XCTAssertEqual(plain.name, "meta-report")
        XCTAssertEqual(plain.description, "Builds the weekly Meta ads report.")
        XCTAssertEqual(plain.body, "Read the campaigns, then fill the table.")

        let quoted = try Skills.parse("---\nname: \"pdf\"\ndescription: 'Fill PDF forms: it''s quick'\nlicense: MIT\nmetadata:\n  author: x\n---\nbody")
        XCTAssertEqual(quoted.name, "pdf")
        XCTAssertEqual(quoted.description, "Fill PDF forms: it's quick")

        let folded = try Skills.parse("---\r\nname: docs\r\ndescription: >\r\n  Writes docs\r\n  for the team.\r\n---\r\nbody")
        XCTAssertEqual(folded.description, "Writes docs for the team.")
        let literal = try Skills.parse("---\nname: docs\ndescription: |\n  line one\n  line two\n---\n")
        XCTAssertEqual(literal.description, "line one\nline two")
    }

    func testFrontMatterIsRequired() {
        for bad in [
            "no front matter",
            "---\nname: x\n",
            "---\ndescription: missing name\n---\n",
            "---\nname: Meta Report\ndescription: d\n---\n",
            "---\nname: double--hyphen\ndescription: d\n---\n",
            "---\nname: ok\n---\n",
            "---\nname: ok\ndescription: \(String(repeating: "a", count: 1025))\n---\n",
        ] {
            XCTAssertThrowsError(try Skills.parse(bad), bad.debugDescription)
        }
    }

    func testPathsStayInsideTheSkill() {
        XCTAssertEqual(Skills.cleanPath("scripts/run.py"), "scripts/run.py")
        XCTAssertEqual(Skills.cleanPath("references//api.md"), "references/api.md")
        for bad in ["/etc/passwd", "../x", "scripts/../../x", ".git/config", "scripts/.env", "a\\b", ""] {
            XCTAssertNil(Skills.cleanPath(bad), bad)
        }
    }

    // MARK: The repository

    func testAddKeepsSubfoldersAndTheExecutableBit() throws {
        let skills = Skills(paths: try temporaryPaths())
        var changes = 0
        skills.onChange = { changes += 1 }
        let added = try skills.add([
            file("SKILL.md", manifest("meta-report")),
            file("scripts/fetch.py", "print('hi')", executable: true),
            file("references/fields.md", "# Fields"),
            file("assets/logo.png", "png"),
        ], replace: false)
        XCTAssertEqual(added.id, "meta-report")
        XCTAssertEqual(added.files, ["SKILL.md", "assets/logo.png", "references/fields.md", "scripts/fetch.py"])
        XCTAssertTrue(added.hasScripts)
        XCTAssertEqual(changes, 1)
        let script = skills.directory("meta-report").appendingPathComponent("scripts/fetch.py").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script))
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: skills.manifest("meta-report").path))

        XCTAssertThrowsError(try skills.add([file("SKILL.md", manifest("meta-report"))], replace: false)) {
            XCTAssertEqual(($0 as? SkillInvalid)?.status, 409)
        }
        // a replace swaps the folder whole: the old script is gone
        let replaced = try skills.add([file("SKILL.md", manifest("meta-report", "Second version."))], replace: true)
        XCTAssertEqual(replaced.files, ["SKILL.md"])
        XCTAssertFalse(replaced.hasScripts)
        XCTAssertEqual(skills.list().map(\.description), ["Second version."])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: skills.folder.path), ["meta-report"], "no staging folder left")
    }

    func testAddRefusesBadUploads() throws {
        let skills = Skills(paths: try temporaryPaths())
        let cases: [[Skills.UploadFile]] = [
            [file("README.md", "no manifest")],
            [file("SKILL.md", manifest("x-y")), file("../escape.sh", "x")],
            [file("SKILL.md", manifest("x-y")), file("a.md", "1"), file("A.md", "2")],
            [file("SKILL.md", "---\nname: x\n---\n")],
        ]
        for upload in cases { XCTAssertThrowsError(try skills.add(upload, replace: false)) }
        let big = Skills.UploadFile(path: "assets/big.bin", data: Data(count: Skills.maxBytes), executable: false)
        XCTAssertThrowsError(try skills.add([file("SKILL.md", manifest("big")), big], replace: false)) {
            XCTAssertEqual(($0 as? SkillInvalid)?.status, 413)
        }
        XCTAssertEqual(skills.list(), [])
    }

    func testUpdateRewritesOnlyTheManifestAndKeepsTheName() throws {
        let skills = Skills(paths: try temporaryPaths())
        try skills.add([file("SKILL.md", manifest("meta-report")), file("scripts/a.sh", "echo")], replace: false)
        let updated = try skills.update("meta-report", content: manifest("meta-report", "New description."))
        XCTAssertEqual(updated.description, "New description.")
        XCTAssertEqual(updated.files, ["SKILL.md", "scripts/a.sh"])
        XCTAssertThrowsError(try skills.update("meta-report", content: manifest("other-name")))
        XCTAssertThrowsError(try skills.update("missing", content: manifest("missing"))) { XCTAssertEqual(($0 as? SkillInvalid)?.status, 404) }
    }

    /// The folder is the truth: a skill copied in by hand, or by a sync
    /// client from another Mac, is there without any import; a broken one
    /// is simply not offered.
    func testTheFolderIsTheRepository() throws {
        let skills = Skills(paths: try temporaryPaths())
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString.prefix(8))")
        skills.chosenFolder = { shared.path }
        for (name, text) in [("synced", manifest("synced")), ("wrong-name", manifest("other")), ("Bad Name", manifest("bad"))] {
            let dir = shared.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        }
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertEqual(skills.list().map(\.id), ["synced"])
        XCTAssertTrue(skills.remove("synced"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("synced").path))
    }

    // MARK: Turns

    func testActiveSkillsMatrix() {
        let bot: JSONObject = ["id": "b", "skills": [
            ["id": "uno", "defaultOn": true], ["id": "due", "defaultOn": false], ["id": "sparita", "defaultOn": true],
            ["id": "uno", "defaultOn": false],
        ]]
        func ids(_ task: JSONObject?) -> [String] { Skills.active(bot: bot, task: task) { $0 != "sparita" } }
        XCTAssertEqual(ids(nil), ["uno"], "defaults; missing and duplicate entries drop out")
        XCTAssertEqual(ids(["skills": ["due": true]]), ["uno", "due"])
        XCTAssertEqual(ids(["skills": ["uno": false, "due": true]]), ["due"])
        XCTAssertEqual(Skills.active(bot: ["id": "b"], task: nil) { _ in true }, [])
    }

    func testSlashNamesAnAssignedSkill() {
        let bot: JSONObject = ["id": "b", "skills": [["id": "meta-report", "defaultOn": false], ["id": "pdf", "defaultOn": true]]]
        XCTAssertEqual(Skills.invoked("/meta-report per ottobre", bot: bot), ["meta-report"])
        XCTAssertEqual(Skills.invoked("usa /pdf e poi /meta-report, grazie /pdf", bot: bot), ["pdf", "meta-report"])
        XCTAssertEqual(Skills.invoked("(/pdf)", bot: bot), ["pdf"])
        XCTAssertEqual(Skills.invoked("apri /pdf/file.txt e /tmp/pdf", bot: bot), [], "a path is not a call")
        XCTAssertEqual(Skills.invoked("http://x.it/pdf e a/pdf", bot: bot), [])
        XCTAssertEqual(Skills.invoked("/altro", bot: bot), [], "only the bot's own skills")
        XCTAssertEqual(Skills.invoked("/pdf", bot: ["id": "b"]), [])
    }

    func testPromptIndexInlineTextAndInvocation() throws {
        let skills = Skills(paths: try temporaryPaths())
        try skills.add([file("SKILL.md", manifest("meta-report", "Builds the\n  weekly report."))], replace: false)
        try skills.add([file("SKILL.md", manifest("pdf", "Fills PDF forms.", body: "Use scripts/fill.py."))], replace: false)

        XCTAssertEqual(skills.prompt([], mode: .paths), "")
        XCTAssertEqual(skills.prompt(["gone"], mode: .paths), "")
        let index = skills.prompt(["meta-report", "pdf", "gone"], mode: .paths)
        XCTAssertTrue(index.contains("- meta-report: Builds the weekly report. — \"\(skills.manifest("meta-report").path)\""), index)
        XCTAssertTrue(index.contains("- pdf: Fills PDF forms."))
        XCTAssertFalse(index.contains("Use scripts/fill.py."), "the index carries no instructions")

        let inline = skills.prompt(["pdf"], mode: .inline)
        XCTAssertTrue(inline.contains("<skill name=\"pdf\">\n---\nname: pdf"), inline)
        XCTAssertTrue(inline.contains("Use scripts/fill.py."))
        XCTAssertFalse(inline.contains(skills.folder.path), "no paths for an engine that cannot open them")

        let called = skills.invocation(["pdf"], mode: .paths)
        XCTAssertTrue(called.hasPrefix("[The user called /pdf for this message."))
        XCTAssertTrue(called.contains("folder=\"\(skills.directory("pdf").path)\""))
        XCTAssertTrue(called.contains("Use scripts/fill.py."))
        XCTAssertTrue(called.hasSuffix("[The user's message:]\n\n"))
        XCTAssertEqual(skills.invocation([], mode: .paths), "")
        XCTAssertFalse(skills.invocation(["pdf"], mode: .inline).contains("folder="))
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
        func upload(_ files: [(String, String, Bool)], replace: Bool? = nil) -> JSON {
            var body: JSONObject = ["files": .array(files.map {
                ["path": .string($0.0), "content": .string(Data($0.1.utf8).base64EncodedString()), "executable": .bool($0.2)]
            })]
            if let replace { body["replace"] = .bool(replace) }
            return .object(body)
        }

        let skill = upload([("SKILL.md", manifest("meta-report"), false), ("scripts/run.sh", "echo hi", true)])
        var (status, body) = try await call("POST", "/api/skills", skill, json: false)
        XCTAssertEqual(status, 415)
        (status, body) = try await call("POST", "/api/skills", skill)
        XCTAssertEqual(status, 201)
        XCTAssertEqual(body["skill"]?["id"], "meta-report")
        XCTAssertEqual(body["skill"]?["files"], ["SKILL.md", "scripts/run.sh"])
        XCTAssertEqual(body["skill"]?["hasScripts"], true)
        (status, body) = try await call("POST", "/api/skills", skill)
        XCTAssertEqual(status, 409)
        (status, body) = try await call("POST", "/api/skills", ["files": [["path": "SKILL.md", "content": "not base64!"]]])
        XCTAssertEqual(status, 400)

        (status, body) = try await call("GET", "/api/skills")
        XCTAssertEqual(body["skills"]?.array?.map { $0["id"] }, ["meta-report"])
        (status, body) = try await call("GET", "/api/skills/meta-report")
        XCTAssertEqual(body["content"]?.string, manifest("meta-report"))
        (status, body) = try await call("PUT", "/api/skills/meta-report", ["content": .string(manifest("meta-report", "Edited."))])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["skill"]?["description"], "Edited.")
        (status, _) = try await call("GET", "/api/skills/nope")
        XCTAssertEqual(status, 404)

        // on a bot, and switched in a chat, like the connectors
        let bot = harness.store.createBot(seedMessages: false)
        let botId = try XCTUnwrap(bot["id"]?.string), threadId = try XCTUnwrap(bot["threadId"]?.string)
        (status, body) = try await call("PATCH", "/api/bots/\(botId)", ["skills": [["id": "unknown"]]])
        XCTAssertEqual(status, 400)
        (status, body) = try await call("PATCH", "/api/bots/\(botId)", ["skills": [["id": "meta-report", "defaultOn": false]]])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(harness.store.bot(botId)?["skills"], [["id": "meta-report", "defaultOn": false]])
        (status, body) = try await call("PATCH", "/api/bots/\(botId)/tasks/\(threadId)", ["skills": ["meta-report": true, "Bad Id": true]])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(harness.store.taskByThread(botId, threadId)?["skills"], ["meta-report": true])

        (status, _) = try await call("DELETE", "/api/skills/meta-report", json: false)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(harness.store.bot(botId)?["skills"], [], "a deleted skill leaves the bot")
        XCTAssertNil(harness.store.taskByThread(botId, threadId)?["skills"], "and its chats")
        (status, _) = try await call("DELETE", "/api/skills/meta-report", json: false)
        XCTAssertEqual(status, 404)
    }

    func testFolderSetting() async throws {
        let paths = try temporaryPaths()
        let harness = try Harness(paths: paths, environment: ProcessInfo.processInfo.environment, drivers: [])
        let routes = Routes(harness: harness)
        func call(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> (Int, JSON) {
            let request = HTTPRequest(method: method, path: path, query: [:], headers: ["content-type": "application/json"], body: body?.data ?? Data())
            guard case let .response(response) = await routes.handle(request) else { XCTFail("not a response"); return (0, .null) }
            return (response.status, (try? JSON.parse(response.body)) ?? .null)
        }
        var (status, body) = try await call("GET", "/api/skills-folder")
        XCTAssertEqual(body["folder"]?.string, paths.root.appendingPathComponent("skills").path)
        XCTAssertEqual(body["custom"], false)

        let shared = paths.root.appendingPathComponent("OneDrive-skills")
        (status, body) = try await call("PUT", "/api/skills-folder", ["folder": .string(shared.path)])
        XCTAssertEqual(status, 200, "\(body)")
        XCTAssertEqual(body["custom"], true)
        XCTAssertEqual(harness.skills.folder.path, shared.path)
        XCTAssertEqual(harness.config.json["skills"], ["folder": .string(shared.path)], "kept in config.json")

        (status, _) = try await call("PUT", "/api/skills-folder", ["folder": "relative/path"])
        XCTAssertEqual(status, 400)
        (status, _) = try await call("PUT", "/api/skills-folder", ["folder": "/no/such/parent/skills"])
        XCTAssertEqual(status, 400)
        (status, body) = try await call("PUT", "/api/skills-folder", ["folder": .null])
        XCTAssertEqual(body["custom"], false)
        XCTAssertNil(harness.config.json["skills"])
    }
}
