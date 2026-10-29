@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

// Code mode's view of a chat's folder: `GET /api/threads/:tid/git`, as the Code plugin serves it.
@MainActor
final class ThreadGitTests: XCTestCase {
    private var paths: DataPaths!
    private var harness: Harness!
    private var routes: Routes!
    private var threadId = ""
    private var botId = ""
    private var folder: URL!

    private func temporaryPaths() -> DataPaths {
        DataPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("code-plugin-\(UUID().uuidString)", isDirectory: true))
    }

    private func prepare() throws {
        paths = temporaryPaths()
        harness = try Harness(paths: paths, environment: ProcessInfo.processInfo.environment, drivers: [], plugins: [CodeEnginePlugin()])
        routes = Routes(harness: harness)
        let bot = harness.store.createBot(seedMessages: false)
        threadId = bot["threadId"]!.string!
        botId = bot["id"]!.string!
        folder = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        harness.store.patchBot(botId, ["cwd": .string(folder.path)])
    }

    @discardableResult
    private func git(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = folder
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func state() async -> JSON? {
        let request = HTTPRequest(method: "GET", path: "/api/threads/\(threadId)/git", query: [:], headers: [:], body: Data())
        guard case let .response(response) = await routes.handle(request), response.status == 200 else { return nil }
        return try? JSON.parse(response.body)
    }

    func testParsesPorcelainStatus() {
        let output = "?? new file.txt\0 M src/a.swift\0A  b.swift\0 D gone.txt\0R  moved.txt\0was.txt\0"
        XCTAssertEqual(ThreadGit.parseStatus(output), [
            .init(path: "new file.txt", status: "?"), .init(path: "src/a.swift", status: "M"), .init(path: "b.swift", status: "A"),
            .init(path: "gone.txt", status: "D"), .init(path: "moved.txt", status: "R"),
        ])
        XCTAssertEqual(ThreadGit.parseStatus(""), [])
    }

    func testAFolderThatIsNotARepoSaysSo() async throws {
        try prepare()
        let answer = await state()
        XCTAssertEqual(answer?["repo"], false)
        XCTAssertNil(answer?["branch"])
    }

    func testReportsTheBranchAndTheUncommittedFiles() async throws {
        try prepare()
        try git("init", "-q", "-b", "feature/x")
        try Data("one".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "first")
        var answer = await state()
        XCTAssertEqual(answer?["repo"], true)
        XCTAssertEqual(answer?["branch"], "feature/x")
        XCTAssertEqual(answer?["detached"], false)
        XCTAssertEqual(answer?["changes"]?.array?.count, 0)

        try Data("two".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("new".utf8).write(to: folder.appendingPathComponent("b.txt"))
        answer = await state()
        let changes = answer?["changes"]?.array ?? []
        XCTAssertEqual(changes.compactMap { $0["name"]?.string }.sorted(), ["a.txt", "b.txt"])
        XCTAssertEqual(changes.first { $0["name"] == "a.txt" }?["status"], "M")
        XCTAssertEqual(changes.first { $0["name"] == "b.txt" }?["status"], "?")
        XCTAssertEqual(changes.first { $0["name"] == "b.txt" }?["bytes"], 3)
        XCTAssertTrue(changes.first?["path"]?.string?.hasPrefix("/") == true)
    }

    func testADetachedHeadReportsTheShortSha() async throws {
        try prepare()
        try git("init", "-q", "-b", "main")
        try Data("one".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "first")
        try git("checkout", "-q", "--detach")
        let answer = await state()
        XCTAssertEqual(answer?["detached"], true)
        XCTAssertNotEqual(answer?["branch"]?.string, "main")
        XCTAssertFalse((answer?["branch"]?.string ?? "").isEmpty)
    }

    private func request(_ method: String, _ suffix: String, body: JSON = [:]) async throws -> HTTPResponse {
        let request = HTTPRequest(method: method, path: "/api/threads/\(threadId)/git/\(suffix)", query: [:],
                                  headers: ["content-type": "application/json"], body: body.data)
        guard case let .response(response) = await routes.handle(request) else { throw HTTPError(500, "no response") }
        return response
    }

    func testListsAndChecksOutLocalAndRemoteBranches() async throws {
        try prepare()
        try git("init", "-q", "-b", "main")
        try Data("one".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try git("add", ".")
        try git("commit", "-qm", "first")
        try git("branch", "feature/local")
        try git("config", "remote.origin.url", "https://example.invalid/repo.git")
        try git("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        try git("update-ref", "refs/remotes/origin/remote-feature", "HEAD")
        try git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/remote-feature")
        let listed = try await request("GET", "branches")
        let branches = try JSON.parse(listed.body)["branches"]?.array ?? []
        XCTAssertEqual(branches.compactMap { $0["name"]?.string }.sorted(), ["feature/local", "main", "origin/remote-feature"])
        for ref in ["refs/heads/feature/local", "refs/remotes/origin/remote-feature", "refs/heads/main", "refs/remotes/origin/remote-feature"] {
            let response = try await request("POST", "checkout", body: ["ref": .string(ref)])
            XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
            let state = try JSON.parse(response.body)
            XCTAssertEqual(state["detached"], false)
            XCTAssertEqual(state["folder"]?.string, folder.path)
        }
        let invalid = try await request("POST", "checkout", body: ["ref": "--force"])
        XCTAssertEqual(invalid.status, 400)
    }

    func testCheckoutPreservesConflictingEditsAndRejectsBusyBot() async throws {
        try prepare()
        try git("init", "-q", "-b", "main")
        let file = folder.appendingPathComponent("a.txt")
        try Data("one".utf8).write(to: file)
        try git("add", ".")
        try git("commit", "-qm", "first")
        try git("checkout", "-qb", "other")
        try Data("other".utf8).write(to: file)
        try git("commit", "-qam", "second")
        try git("checkout", "-q", "main")
        try Data("local edit".utf8).write(to: file)
        let conflict = try await request("POST", "checkout", body: ["ref": "refs/heads/other"])
        XCTAssertEqual(conflict.status, 409)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "local edit")
        let current = await state()
        XCTAssertEqual(current?["branch"], "main")
        harness.store.patchBot(botId, ["busy": true])
        let busy = try await request("POST", "checkout", body: ["ref": "refs/heads/other"])
        XCTAssertEqual(busy.status, 409)
    }

    func testCodeModeIsAPatchableFlag() async throws {
        try prepare()
        var request = HTTPRequest(method: "PATCH", path: "/api/bots/\(botId)", query: [:],
                                  headers: ["content-type": "application/json"], body: JSON.object(["codeMode": true]).data)
        guard case let .response(on) = await routes.handle(request) else { return XCTFail("not a response") }
        XCTAssertEqual(on.status, 200)
        XCTAssertEqual(harness.store.bot(botId)?["codeMode"], true)
        request.body = JSON.object(["codeMode": "yes"]).data
        guard case let .response(bad) = await routes.handle(request) else { return XCTFail("not a response") }
        XCTAssertEqual(bad.status, 400)
    }
}
