@testable import HarnessCore
import XCTest

// The files a reply points at: `POST /api/threads/:tid/files` and
// `GET /api/threads/:tid/files/content`.
@MainActor
final class ThreadFilesTests: XCTestCase {
    private var paths: DataPaths!
    private var harness: Harness!
    private var routes: Routes!
    private var threadId = ""
    private var folder: URL!
    private var outside: URL!

    private func prepare() throws {
        paths = temporaryPaths()
        harness = try Harness(paths: paths, environment: ProcessInfo.processInfo.environment, drivers: [])
        routes = Routes(harness: harness)
        let bot = harness.store.createBot(seedMessages: false)
        threadId = bot["threadId"]!.string!
        folder = paths.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("out"), withIntermediateDirectories: true)
        try Data("a,b\n1,2\n".utf8).write(to: folder.appendingPathComponent("out/report.csv"))
        harness.store.patchBot(bot["id"]!.string!, ["cwd": .string(folder.path)])
        outside = paths.root.appendingPathComponent("elsewhere.txt")
        try Data("not in the folder".utf8).write(to: outside)
    }

    private func call(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil,
                      remote: Bool = false) async -> (Int, Data) {
        var request = HTTPRequest(method: method, path: path, query: query,
                                  headers: body == nil ? [:] : ["content-type": "application/json"], body: body?.data ?? Data())
        if remote { request.deviceId = "dev-1" }
        guard case let .response(response) = await routes.handle(request) else { XCTFail("not a response"); return (0, Data()) }
        return (response.status, response.body)
    }

    private func lookup(_ references: [String], remote: Bool = false) async -> [JSON] {
        let (status, body) = await call("POST", "/api/threads/\(threadId)/files",
                                        body: ["paths": .array(references.map(JSON.string))], remote: remote)
        XCTAssertEqual(status, 200)
        return (try? JSON.parse(body))?["files"]?.array ?? []
    }

    func testResolvesRelativeAbsoluteAndFileURLs() async throws {
        try prepare()
        let real = folder.appendingPathComponent("out/report.csv").resolvingSymlinksInPath().path
        let files = await lookup(["out/report.csv", folder.path + "/out/report.csv", "file://" + folder.path + "/out/report.csv",
                                  "missing.pdf", "out", "../../etc/passwd-none"])
        XCTAssertEqual(files.map { $0["ref"]?.string }, ["out/report.csv", folder.path + "/out/report.csv", "file://" + folder.path + "/out/report.csv"])
        XCTAssertEqual(files.first?["path"]?.string, real)
        XCTAssertEqual(files.first?["name"], "report.csv")
        XCTAssertEqual(files.first?["bytes"], 8)
    }

    func testThisMacReachesAnyFileARemoteClientOnlyTheChatsOwn() async throws {
        try prepare()
        var found = await lookup([outside.path])
        XCTAssertEqual(found.count, 1, "on this Mac nothing is held back")
        found = await lookup([outside.path], remote: true)
        XCTAssertEqual(found.count, 0)
        found = await lookup(["out/report.csv"], remote: true)
        XCTAssertEqual(found.count, 1)
        // a symlink inside the folder that leads out of it stays out
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: outside)
        found = await lookup(["link.txt"], remote: true)
        XCTAssertEqual(found.count, 0)
        // a file a tool of this chat named is the bot's own work
        harness.store.appendMessage(threadId, ["role": "bot", "kind": "activity",
                                               "tool": ["name": "Write", "input": .string("{\"file_path\": \"\(outside.path)\"}")]])
        found = await lookup([outside.path], remote: true)
        XCTAssertEqual(found.count, 1)

        var (status, body) = await call("GET", "/api/threads/\(threadId)/files/content", query: ["path": "out/report.csv"], remote: true)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "a,b\n1,2\n")
        (status, _) = await call("GET", "/api/threads/\(threadId)/files/content", query: ["path": "/etc/hosts"], remote: true)
        XCTAssertEqual(status, 404)
    }

    func testRejectsWhatIsNotAThreadOrAList() async throws {
        try prepare()
        var (status, _) = await call("POST", "/api/threads/nope/files", body: ["paths": ["a.txt"]])
        XCTAssertEqual(status, 404)
        (status, _) = await call("POST", "/api/threads/\(threadId)/files", body: ["paths": "a.txt"])
        XCTAssertEqual(status, 400)
        (status, _) = await call("POST", "/api/threads/\(threadId)/files",
                                 body: ["paths": .array((0...ThreadFiles.maxPaths).map { .string("f\($0).txt") })])
        XCTAssertEqual(status, 400)
    }
}
