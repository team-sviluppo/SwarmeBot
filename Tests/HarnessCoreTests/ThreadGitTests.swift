@testable import HarnessCore
import XCTest

// Code mode's view of a chat's folder: `GET /api/threads/:tid/git`.
@MainActor
final class ThreadGitTests: XCTestCase {
    private var paths: DataPaths!
    private var harness: Harness!
    private var routes: Routes!
    private var threadId = ""
    private var botId = ""
    private var folder: URL!

    private func prepare() throws {
        paths = temporaryPaths()
        harness = try Harness(paths: paths, environment: ProcessInfo.processInfo.environment, drivers: [])
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
