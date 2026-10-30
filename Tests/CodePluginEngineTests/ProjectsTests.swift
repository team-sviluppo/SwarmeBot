@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

/// Projects: folders with roles, which bot or channel belongs to which, and what a turn is told about them.
@MainActor
final class ProjectsTests: XCTestCase {
    private func folders(_ repo: RepoFixture, _ names: String...) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in names {
            let url = repo.paths.root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            out[name] = url.path
        }
        return out
    }

    private func create(_ repo: RepoFixture, _ body: JSON) async -> (status: Int, json: JSON?) {
        await repo.callRaw("POST", "/api/projects", body: body)
    }

    private func standard(_ repo: RepoFixture) async throws -> (id: String, paths: [String: String]) {
        let paths = try folders(repo, "api", "admin", "app")
        let made = await create(repo, ["name": "Gestionale Rossi", "clickupListId": "901512345678",
                                       "repos": [["role": "backend", "path": .string(paths["api"]!)], ["role": "backoffice", "path": .string(paths["admin"]!)],
                                                 ["role": "app", "path": .string(paths["app"]!)]]])
        XCTAssertEqual(made.status, 201, String(describing: made.json))
        return (made.json?["project"]?["id"]?.string ?? "", paths)
    }

    // MARK: the records

    func testAProjectIsCreatedListedChangedAndDeleted() async throws {
        let repo = try await RepoFixture()
        let (id, paths) = try await standard(repo)
        XCTAssertFalse(id.isEmpty)
        var list = await repo.callRaw("GET", "/api/projects").json?["projects"]?.array ?? []
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?["name"], "Gestionale Rossi")
        XCTAssertEqual(list.first?["repos"]?.array?.compactMap { $0["role"]?.string }, ["backend", "backoffice", "app"], "in the order roles are shown")

        let renamed = await repo.callRaw("PATCH", "/api/projects/\(id)", body: ["name": "Rossi", "clickupListId": .null])
        XCTAssertEqual(renamed.status, 200)
        XCTAssertEqual(renamed.json?["project"]?["name"], "Rossi")
        XCTAssertEqual(renamed.json?["project"]?["clickupListId"], .null)
        XCTAssertEqual(renamed.json?["project"]?["repos"]?.array?.count, 3, "what the request did not carry stays")

        // the folders: replaced as a whole, scripts kept
        let withBruno = await repo.callRaw("PATCH", "/api/projects/\(id)", body: ["repos": [
            ["role": "backend", "path": .string(paths["api"]!), "scripts": [["name": "Test", "command": "swift test"]]]]])
        XCTAssertEqual(withBruno.json?["project"]?["repos"]?.array?.first?["scripts"]?.array?.first?["command"], "swift test")

        let gone = await repo.callRaw("DELETE", "/api/projects/\(id)")
        XCTAssertEqual(gone.status, 200)
        list = await repo.callRaw("GET", "/api/projects").json?["projects"]?.array ?? []
        XCTAssertTrue(list.isEmpty)
        let again = await repo.callRaw("DELETE", "/api/projects/\(id)")
        XCTAssertEqual(again.status, 404)
        let missing = await repo.callRaw("PATCH", "/api/projects/nope", body: ["name": "x"])
        XCTAssertEqual(missing.status, 404)
    }

    func testBadProjectsAreRefused() async throws {
        let repo = try await RepoFixture()
        let paths = try folders(repo, "api")
        let api: JSON = ["role": "backend", "path": .string(paths["api"]!)]
        let refused: [(why: String, body: JSON)] = [
            ("no name", ["repos": []]), ("blank name", ["name": "  "]), ("name too long", ["name": .string(String(repeating: "x", count: 101))]),
            ("bad list id", ["name": "x", "clickupListId": "not a list!"]), ("repos not a list", ["name": "x", "repos": "api"]),
            ("unknown role", ["name": "x", "repos": [["role": "frontend", "path": .string(paths["api"]!)]]]),
            ("role twice", ["name": "x", "repos": [api, api]]),
            ("relative path", ["name": "x", "repos": [["role": "backend", "path": "api"]]]),
            ("folder that is not there", ["name": "x", "repos": [["role": "backend", "path": "/nope/not/here"]]]),
            ("bad scripts", ["name": "x", "repos": [["role": "backend", "path": .string(paths["api"]!), "scripts": [["name": "", "command": "x"]]]]]),
        ]
        for entry in refused {
            let answer = await create(repo, entry.body)
            XCTAssertEqual(answer.status, 400, entry.why)
        }
        let none = await repo.callRaw("GET", "/api/projects").json?["projects"]?.array ?? []
        XCTAssertTrue(none.isEmpty)
    }

    func testEachProjectHasAFileForTheAgents() async throws {
        let repo = try await RepoFixture()
        let (id, paths) = try await standard(repo)
        let file = repo.paths.root.appendingPathComponent("plugins/code/projects/\(id).json")
        let json = try JSON.parse(Data(contentsOf: file))
        XCTAssertEqual(json["name"], "Gestionale Rossi")
        XCTAssertEqual(json["clickupListId"], "901512345678")
        XCTAssertEqual(json["repos"]?.array?.first?["path"]?.string, paths["api"])
        XCTAssertNil(json["createdAt"], "only what an agent needs")
        _ = await repo.callRaw("DELETE", "/api/projects/\(id)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: bots and channels

    private func setData(_ repo: RepoFixture, bot: String? = nil, group: String? = nil, _ data: JSON) async -> (status: Int, json: JSON?) {
        let path = bot.map { "/api/bots/\($0)" } ?? "/api/groups/\(group!)"
        return await repo.callRaw("PATCH", path, body: ["plugins": ["code": data]])
    }

    func testABotChoosesAProjectAndAFolderToWorkOn() async throws {
        let repo = try await RepoFixture()
        let (id, paths) = try await standard(repo)
        let set = await setData(repo, bot: repo.botId, ["projectId": .string(id), "role": "backoffice"])
        XCTAssertEqual(set.status, 200, String(describing: set.json))
        XCTAssertEqual(set.json?["bot"]?["plugins"]?["code"]?["projectId"]?.string, id)
        XCTAssertEqual(repo.harness.store.bot(repo.botId)?["cwd"]?.string, paths["admin"], "the folder it works on is where it starts")
        // a field the plugin does not know survives, and so does another plugin's part
        repo.harness.store.patchBot(repo.botId, ["plugins": ["other": ["keep": true], "code": ["projectId": .string(id), "role": "backoffice", "future": 1]]])
        _ = await setData(repo, bot: repo.botId, ["role": "app"])
        let data = repo.harness.store.bot(repo.botId)?["plugins"]
        XCTAssertEqual(data?["other"]?["keep"], true)
        XCTAssertEqual(data?["code"]?["future"], 1)
        XCTAssertEqual(data?["code"]?["role"], "app")
        XCTAssertEqual(repo.harness.store.bot(repo.botId)?["cwd"]?.string, paths["app"])
    }

    func testNullTakesAFieldAway() async throws {
        let repo = try await RepoFixture()
        let (id, _) = try await standard(repo)
        _ = await setData(repo, bot: repo.botId, ["projectId": .string(id), "role": "backend"])
        let cleared = await setData(repo, bot: repo.botId, ["projectId": .null, "role": .null])
        XCTAssertEqual(cleared.status, 200)
        let data = repo.harness.store.bot(repo.botId)?["plugins"]?["code"]
        XCTAssertNil(data?["projectId"])
        XCTAssertNil(data?["role"])
    }

    func testTheDataIsChecked() async throws {
        let repo = try await RepoFixture()
        let (id, _) = try await standard(repo)
        let refused: [(why: String, data: JSON)] = [
            ("no such project", ["projectId": "nope"]), ("a role with no project", ["role": "backend"]),
            ("a role that is not one", ["projectId": .string(id), "role": "frontend"]),
            ("a field nobody knows", ["projectId": .string(id), "colour": "red"]), ("project not a string", ["projectId": 3]),
        ]
        for entry in refused {
            let answer = await setData(repo, bot: repo.botId, entry.data)
            XCTAssertEqual(answer.status, 400, entry.why)
        }
        // a role the project lacks
        let paths = try folders(repo, "solo")
        let small = await create(repo, ["name": "Small", "repos": [["role": "backend", "path": .string(paths["solo"]!)]]])
        let smallId = small.json?["project"]?["id"]?.string ?? ""
        let lacking = await setData(repo, bot: repo.botId, ["projectId": .string(smallId), "role": "app"])
        XCTAssertEqual(lacking.status, 400)
        XCTAssertNil(repo.harness.store.bot(repo.botId)?["plugins"], "nothing was written by a refused request")
        let notAnObject = await repo.callRaw("PATCH", "/api/bots/\(repo.botId)", body: ["plugins": ["code": "x"]])
        XCTAssertEqual(notAnObject.status, 400)
        let listed = await repo.callRaw("PATCH", "/api/bots/\(repo.botId)", body: ["plugins": 1])
        XCTAssertEqual(listed.status, 400)
    }

    func testAChannelHasAProjectToo() async throws {
        let repo = try await RepoFixture()
        let (id, paths) = try await standard(repo)
        let groupId = repo.harness.store.createGroup(name: "Backend Rossi", memberIds: [repo.botId])["id"]?.string ?? ""
        let set = await setData(repo, group: groupId, ["projectId": .string(id), "role": "backend"])
        XCTAssertEqual(set.status, 200, String(describing: set.json))
        XCTAssertEqual(repo.harness.store.group(groupId)?["cwd"]?.string, paths["api"])
        // once the channel's folder is fixed it does not move
        repo.harness.store.patchGroup(groupId, ["pinnedCwd": .string(paths["api"]!)])
        _ = await setData(repo, group: groupId, ["role": "app"])
        XCTAssertEqual(repo.harness.store.group(groupId)?["cwd"]?.string, paths["api"])
        XCTAssertEqual(repo.harness.store.group(groupId)?["plugins"]?["code"]?["role"], "app", "the choice is kept, the fixed folder is not touched")
    }

    func testDeletingAProjectFreesWhoBelongedToIt() async throws {
        let repo = try await RepoFixture()
        let (id, _) = try await standard(repo)
        let groupId = repo.harness.store.createGroup(name: "Room", memberIds: [repo.botId])["id"]?.string ?? ""
        _ = await setData(repo, bot: repo.botId, ["projectId": .string(id), "role": "backend"])
        _ = await setData(repo, group: groupId, ["projectId": .string(id)])
        _ = await repo.callRaw("DELETE", "/api/projects/\(id)")
        XCTAssertNil(repo.harness.store.bot(repo.botId)?["plugins"]?["code"]?["projectId"])
        XCTAssertNil(repo.harness.store.bot(repo.botId)?["plugins"]?["code"]?["role"])
        XCTAssertNil(repo.harness.store.group(groupId)?["plugins"]?["code"]?["projectId"])
    }

    func testAFolderThatMovesTakesItsWorkersWithIt() async throws {
        let repo = try await RepoFixture()
        let (id, paths) = try await standard(repo)
        _ = await setData(repo, bot: repo.botId, ["projectId": .string(id), "role": "backend"])
        let moved = try folders(repo, "api-moved")
        let answer = await repo.callRaw("PATCH", "/api/projects/\(id)", body: ["repos": [["role": "backend", "path": .string(moved["api-moved"]!)]]])
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(repo.harness.store.bot(repo.botId)?["cwd"]?.string, moved["api-moved"])
        // a chat that was working somewhere else is left where it was
        _ = await setData(repo, bot: repo.botId, ["projectId": .string(id), "role": "backend"])
        repo.harness.store.patchBot(repo.botId, ["cwd": .string(paths["app"]!)])
        let back = await repo.callRaw("PATCH", "/api/projects/\(id)", body: ["repos": [["role": "backend", "path": .string(paths["api"]!)]]])
        XCTAssertEqual(back.status, 200)
        XCTAssertEqual(repo.harness.store.bot(repo.botId)?["cwd"]?.string, paths["app"])
    }

    // MARK: what a turn is told

    private func context(_ project: JSON, role: String?, cwd: String?) -> ProjectContext? {
        ProjectContext.make(project: project.object!, role: role, cwd: cwd)
    }

    func testTheOtherFoldersAreLinkedReadOnly() async throws {
        let repo = try await RepoFixture()
        let (id, paths) = try await standard(repo)
        let project = ProjectStore(harness: repo.harness).project(id).map(JSON.object)!
        let working = context(project, role: "backend", cwd: nil)
        XCTAssertEqual(working?.workingRole, "backend")
        XCTAssertEqual(working?.workingPath, ReadOnlyGuard.canonical(paths["api"]!))
        XCTAssertEqual(working?.readOnly.map(\.role), ["backoffice", "app"])
        // no role said: the folder that holds the chat's own is the one it works on
        let byFolder = context(project, role: nil, cwd: paths["admin"]! + "/src")
        XCTAssertEqual(byFolder?.workingRole, "backoffice")
        XCTAssertEqual(byFolder?.readOnly.map(\.role), ["backend", "app"])
        // neither: it works elsewhere, and every folder of the project is context
        let elsewhere = context(project, role: nil, cwd: "/tmp")
        XCTAssertNil(elsewhere?.workingRole)
        XCTAssertEqual(elsewhere?.readOnly.count, 3)
    }

    func testAFolderInsideTheWorkingOneStaysReadOnlyButOneAroundItDoesNot() async throws {
        let repo = try await RepoFixture()
        let paths = try folders(repo, "rossi-api")
        let bruno = paths["rossi-api"]! + "/bruno"
        try FileManager.default.createDirectory(atPath: bruno, withIntermediateDirectories: true)
        let project: JSON = ["id": "p", "name": "P", "repos": [["role": "backend", "path": .string(paths["rossi-api"]!)], ["role": "bruno", "path": .string(bruno)]]]
        let onApi = context(project, role: "backend", cwd: nil)
        XCTAssertEqual(onApi?.readOnly.map(\.role), ["bruno"], "the collection in the API repo is linked read-only while working on the API")
        // working on the collection: the repo that holds it cannot be read-only, or it could not write anywhere
        let onBruno = context(project, role: "bruno", cwd: nil)
        XCTAssertEqual(onBruno?.readOnly.map(\.role), [])
    }

    func testAFolderThatIsGoneIsLeftOut() async throws {
        let repo = try await RepoFixture()
        let paths = try folders(repo, "here")
        let project: JSON = ["id": "p", "name": "P", "repos": [["role": "backend", "path": .string(paths["here"]!)], ["role": "app", "path": "/nope/gone"]]]
        XCTAssertEqual(context(project, role: "backend", cwd: nil)?.readOnly.count, 0)
    }

    func testThePromptNamesTheFoldersAndTheFile() async throws {
        let repo = try await RepoFixture()
        let (id, paths) = try await standard(repo)
        let store = ProjectStore(harness: repo.harness)
        let text = context(.object(store.project(id)!), role: "backend", cwd: nil)!.prompt(agentFile: store.agentFile(id).path)
        XCTAssertTrue(text.contains("project \"Gestionale Rossi\""))
        XCTAssertTrue(text.contains("You work on its Backend folder, \(ReadOnlyGuard.canonical(paths["api"]!))"))
        XCTAssertTrue(text.contains("linked read-only") && text.contains("never create, edit, delete or move"))
        XCTAssertTrue(text.contains("- Backoffice: \(ReadOnlyGuard.canonical(paths["admin"]!))"))
        XCTAssertTrue(text.contains("$SWARME_PROJECT_JSON"))
    }

    private func setup(_ repo: RepoFixture, bot: Bool = true, group: String? = nil) -> TurnSetup {
        let botRecord = repo.harness.store.bot(repo.botId) ?? JSONObject()
        let groupRecord = group.flatMap { repo.harness.store.group($0) }
        var turn = TurnSetup(botId: repo.botId, threadId: repo.threadId, groupId: group, driverKind: "claudeAgent", bot: botRecord, group: groupRecord,
                             cwd: botRecord["cwd"]?.string)
        repo.harness.plugins.beforeTurn(&turn)
        return turn
    }

    func testABotOfAProjectGetsTheFoldersTheFileAndTheTextBeforeATurn() async throws {
        let repo = try await RepoFixture()
        let (id, paths) = try await standard(repo)
        _ = await setData(repo, bot: repo.botId, ["projectId": .string(id), "role": "backend"])
        let turn = setup(repo)
        XCTAssertTrue(turn.system.contains("Gestionale Rossi"))
        XCTAssertEqual(turn.readOnlyFolders, [ReadOnlyGuard.canonical(paths["admin"]!), ReadOnlyGuard.canonical(paths["app"]!)])
        let file = try XCTUnwrap(turn.environment["SWARME_PROJECT_JSON"])
        XCTAssertEqual(try JSON.parse(Data(contentsOf: URL(fileURLWithPath: file)))["name"], "Gestionale Rossi")
    }

    func testAChatWithNoProjectIsLeftAlone() async throws {
        let repo = try await RepoFixture()
        let turn = setup(repo)
        XCTAssertEqual(turn.system, "")
        XCTAssertTrue(turn.environment.isEmpty)
        XCTAssertTrue(turn.readOnlyFolders.isEmpty)
    }

    func testInAChannelTheChannelsProjectWinsOverTheBots() async throws {
        let repo = try await RepoFixture()
        let (idA, _) = try await standard(repo)
        let pathsB = try folders(repo, "b-api")
        let projectB = await create(repo, ["name": "Beta", "repos": [["role": "backend", "path": .string(pathsB["b-api"]!)]]])
        let idB = projectB.json?["project"]?["id"]?.string ?? ""
        _ = await setData(repo, bot: repo.botId, ["projectId": .string(idA), "role": "backend"])
        let groupId = repo.harness.store.createGroup(name: "Beta room", memberIds: [repo.botId])["id"]?.string ?? ""
        _ = await setData(repo, group: groupId, ["projectId": .string(idB), "role": "backend"])
        let turn = setup(repo, group: groupId)
        XCTAssertTrue(turn.system.contains("Beta") && !turn.system.contains("Gestionale Rossi"), turn.system)
        // a channel with none: the bot's own project does not come along
        let bare = repo.harness.store.createGroup(name: "Bare", memberIds: [repo.botId])["id"]?.string ?? ""
        XCTAssertEqual(setup(repo, group: bare).system, "")
    }

    // MARK: all the way to the provider

    func testTheProviderReceivesTheProjectAndDeniesAWriteInALinkedFolder() async throws {
        let adapter = FakeAdapter(driverKind: "claudeAgent")
        let repo = try await RepoFixture(drivers: [FakeDriver(driverKind: "claudeAgent", adapter: adapter)], boot: true)
        let (id, paths) = try await standard(repo)
        let admin = ReadOnlyGuard.canonical(paths["admin"]!)
        adapter.script = { input, emit in
            emit(.turnStarted, nil)
            emit(.requestOpened(requestType: "permission", tool: "Edit", summary: #"{"file_path":"\#(admin)/src/app.ts"}"#, choices: nil, multiSelect: nil, approvalScope: nil), "req-ro")
            emit(.requestOpened(requestType: "permission", tool: "Read", summary: #"{"file_path":"\#(admin)/src/app.ts"}"#, choices: nil, multiSelect: nil, approvalScope: nil), "req-read")
            emit(.textCompleted(text: "done"), nil)
            emit(.turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil), nil)
        }
        let selection: JSON = ["instanceId": "claude", "model": "fake-1"]
        repo.harness.store.patchBot(repo.botId, ["modelSelection": selection])
        _ = await setData(repo, bot: repo.botId, ["projectId": .string(id), "role": "backend"])
        try repo.harness.startTurn(botId: repo.botId, text: "hello")
        for _ in 0..<100 where adapter.received.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        let input = try XCTUnwrap(adapter.received.first)
        XCTAssertTrue(input.system?.contains("Gestionale Rossi") == true)
        XCTAssertEqual(input.cwd, paths["api"], "the folder it works on")
        XCTAssertEqual(Set(input.readOnlyFolders), [admin, ReadOnlyGuard.canonical(paths["app"]!)])
        XCTAssertNotNil(input.pluginEnvironment["SWARME_PROJECT_JSON"])
        for _ in 0..<100 where adapter.denied.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(adapter.denied, ["req-ro"], "the edit in the linked folder is denied, the read is not")
        let chips = repo.harness.store.messages(repo.threadId).compactMap { $0["tool"]?["name"]?.string }
        XCTAssertTrue(chips.contains { $0.hasPrefix("denied, read-only folder") }, "\(chips)")
    }

    // MARK: folders of the machine

    func testTheFoldersOfTheMachineCanBeBrowsed() async throws {
        let repo = try await RepoFixture()
        let paths = try folders(repo, "one", "Two", "10", "2")
        try FileManager.default.createDirectory(atPath: paths["one"]! + "/.hidden", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: repo.paths.root.path + "/file.txt"))
        let relative = HTTPRequest(method: "GET", path: "/api/fs/dirs", query: ["path": "x"], headers: [:], body: Data())
        guard case let .response(refused) = await repo.routes.handle(relative) else { return XCTFail("not a response") }
        XCTAssertEqual(refused.status, 400, "a path that is not absolute")
        let request = HTTPRequest(method: "GET", path: "/api/fs/dirs", query: ["path": repo.paths.root.path], headers: [:], body: Data())
        guard case let .response(response) = await repo.routes.handle(request) else { return XCTFail("not a response") }
        let json = try JSON.parse(response.body)
        XCTAssertEqual(response.status, 200)
        let dirs = json["dirs"]?.array?.compactMap(\.string) ?? []
        XCTAssertFalse(dirs.contains("file.txt"), "folders only")
        XCTAssertEqual(dirs, dirs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "in the order Finder sorts them")
        let positions = ["2", "10", "one", "Two"].map { dirs.firstIndex(of: $0) }
        XCTAssertFalse(positions.contains { $0 == nil })
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(), "2 before 10, one before Two")
        XCTAssertEqual(json["path"]?.string, ReadOnlyGuard.canonical(repo.paths.root.path))
        XCTAssertEqual(json["parent"]?.string, (ReadOnlyGuard.canonical(repo.paths.root.path) as NSString).deletingLastPathComponent)
        let inner = HTTPRequest(method: "GET", path: "/api/fs/dirs", query: ["path": paths["one"]!, "hidden": "1"], headers: [:], body: Data())
        guard case let .response(innerResponse) = await repo.routes.handle(inner) else { return XCTFail("not a response") }
        XCTAssertEqual(try JSON.parse(innerResponse.body)["dirs"]?.array?.compactMap(\.string), [".hidden"])
        let file = HTTPRequest(method: "GET", path: "/api/fs/dirs", query: ["path": repo.paths.root.path + "/file.txt"], headers: [:], body: Data())
        guard case let .response(notFolder) = await repo.routes.handle(file) else { return XCTFail("not a response") }
        XCTAssertEqual(notFolder.status, 400)
        let root = HTTPRequest(method: "GET", path: "/api/fs/dirs", query: ["path": "/"], headers: [:], body: Data())
        guard case let .response(top) = await repo.routes.handle(root) else { return XCTFail("not a response") }
        XCTAssertEqual(try JSON.parse(top.body)["parent"], nil, "nothing above the root")
        let home = HTTPRequest(method: "GET", path: "/api/fs/dirs", query: [:], headers: [:], body: Data())
        guard case let .response(start) = await repo.routes.handle(home) else { return XCTFail("not a response") }
        XCTAssertEqual(try JSON.parse(start.body)["path"]?.string, ReadOnlyGuard.canonical(FileManager.default.homeDirectoryForCurrentUser.path))
    }
}
