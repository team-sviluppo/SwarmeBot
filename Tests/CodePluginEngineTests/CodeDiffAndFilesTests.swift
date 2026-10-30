@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

/// The diff of a changed file and the file search of the composer.
@MainActor
final class CodeDiffAndFilesTests: XCTestCase {
    func testAModifiedFileShowsItsLinesAgainstHead() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        let answer = await repo.call("GET", "git/diff", query: ["path": repo.folder.appendingPathComponent("a.txt").path])
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.json?["path"], "a.txt")
        let diff = answer.json?["diff"]?.string ?? ""
        XCTAssertTrue(diff.contains("-one") && diff.contains("+two"), diff)
        XCTAssertEqual(answer.json?["binary"], false)
        XCTAssertEqual(answer.json?["truncated"], false)
    }

    func testAStagedEditAndAnUnstagedOneReadAsOne() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        try repo.git("add", "a.txt")
        try repo.write("a.txt", "three\n")
        let diff = await repo.call("GET", "git/diff", query: ["path": "a.txt"]).json?["diff"]?.string ?? ""
        XCTAssertTrue(diff.contains("-one") && diff.contains("+three"), "against HEAD, not against the index: \(diff)")
    }

    func testANewFileIsAllAddedLines() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("new.txt", "hello\nworld\n")
        let diff = await repo.call("GET", "git/diff", query: ["path": "new.txt"]).json?["diff"]?.string ?? ""
        XCTAssertTrue(diff.contains("+hello") && diff.contains("+world"), diff)
        XCTAssertTrue(diff.contains("new file mode"), diff)
    }

    func testADeletedFileShowsItsRemovedLines() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try FileManager.default.removeItem(at: repo.folder.appendingPathComponent("a.txt"))
        let answer = await repo.call("GET", "git/diff", query: ["path": repo.folder.appendingPathComponent("a.txt").path])
        XCTAssertEqual(answer.status, 200)
        XCTAssertTrue((answer.json?["diff"]?.string ?? "").contains("-one"), String(describing: answer.json))
    }

    func testABinaryFileHasNoTextToShow() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try Data([0, 1, 2, 0, 255, 0]).write(to: repo.folder.appendingPathComponent("blob.bin"))
        let answer = await repo.call("GET", "git/diff", query: ["path": "blob.bin"])
        XCTAssertEqual(answer.json?["binary"], true)
        XCTAssertEqual(answer.json?["diff"], "")
    }

    func testNoPathShowsEveryChange() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write("a.txt", "two\n")
        try repo.write("new.txt", "fresh\n")
        let diff = await repo.call("GET", "git/diff").json?["diff"]?.string ?? ""
        XCTAssertTrue(diff.contains("+two") && diff.contains("+fresh"), diff)
    }

    func testAPathOutsideTheRepositoryIsRefused() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        for outside in ["/etc/passwd", "../outside.txt", "sub/../../escape", repo.paths.root.path + "/other"] {
            let answer = await repo.call("GET", "git/diff", query: ["path": outside])
            XCTAssertEqual(answer.status, 400, outside)
        }
        let notARepo = try await RepoFixture()
        let none = await notARepo.call("GET", "git/diff")
        XCTAssertEqual(none.status, 400)
    }

    func testRelativePathsAreWorkedOutAgainstTheRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        // git reports /private/var/...; a client may hold /var/...: both are the same folder
        let real = ThreadGit.canonical(root.path)
        XCTAssertEqual(GitDiff.relative(root.path + "/src/x.swift", root: real), "src/x.swift")
        XCTAssertEqual(GitDiff.relative("src/x.swift", root: real), "src/x.swift")
        XCTAssertEqual(GitDiff.relative(real + "/gone.txt", root: root.path), "gone.txt", "a file that no longer exists still has a place")
        XCTAssertNil(GitDiff.relative("../x", root: real))
        XCTAssertNil(GitDiff.relative("", root: real))
        XCTAssertNil(GitDiff.relative("/etc/hosts", root: real))
    }

    func testALongDiffIsCutOnALine() {
        let line = String(repeating: "x", count: 99) + "\n"
        let long = String(repeating: line, count: GitDiff.maxBytes / 100 + 50)
        let cut = GitDiff.truncate(long)
        XCTAssertTrue(cut.truncated)
        XCTAssertLessThanOrEqual(cut.text.utf8.count, GitDiff.maxBytes)
        XCTAssertTrue(cut.text.hasSuffix("\n"))
        XCTAssertEqual(GitDiff.truncate("short\n").truncated, false)
    }

    // MARK: file search

    func testTheNameBeatsTheFoldersAboveIt() {
        let files = ["docs/guide/composer.md", "Sources/App/ComposerView.swift", "Sources/Composer/Other.swift", "README.md"]
        let ranked = CodeFiles.rank(files, query: "composer")
        XCTAssertEqual(ranked.first, "docs/guide/composer.md", "a name that is the query, extension aside, comes first")
        XCTAssertEqual(ranked[1], "Sources/App/ComposerView.swift", "then a name that starts with it")
        XCTAssertEqual(ranked[2], "Sources/Composer/Other.swift", "a folder with it in the name comes after the files named for it")
        XCTAssertFalse(ranked.contains("README.md"), "no letters of it in order: not a match")
    }

    func testTheLettersMustAppearInOrder() {
        XCTAssertNotNil(CodeFiles.score("Sources/SwarmeKit/AppModel.swift", "appmodel"))
        XCTAssertNotNil(CodeFiles.score("Sources/SwarmeKit/AppModel.swift", "skam"), "fuzzy: s…k…a…m")
        XCTAssertNil(CodeFiles.score("Sources/SwarmeKit/AppModel.swift", "lemodapp"))
    }

    func testARunOfLettersBeatsScatteredOnes() {
        let run = CodeFiles.score("src/config.swift", "conf")!
        let scattered = CodeFiles.score("src/computing_of_nothing_finished.swift", "conf")!
        XCTAssertGreaterThan(run, scattered)
    }

    func testWithNoQueryTheChangedFilesLead() {
        let ranked = CodeFiles.rank(["b.txt", "a.txt", "c.txt"], query: " ", preferred: ["c.txt", "gone.txt"])
        XCTAssertEqual(ranked, ["c.txt", "a.txt", "b.txt"])
    }

    func testTheListIsCapped() {
        let files = (0..<500).map { "file\($0).txt" }
        XCTAssertEqual(CodeFiles.rank(files, query: "file").count, CodeFiles.limit)
        XCTAssertEqual(CodeFiles.rank(files, query: "file", limit: 3).count, 3)
    }

    func testTheSearchSkipsWhatGitIgnores() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        try repo.write(".gitignore", "secret.txt\nbuild/\n")
        try repo.write("secret.txt", "x")
        try repo.write("build/out.bin", "x")
        try repo.write("src/App.swift", "x")
        try repo.write("src/Other.swift", "x")
        let all = await repo.call("GET", "files").json?["files"]?.array?.compactMap { $0["relative"]?.string } ?? []
        XCTAssertTrue(all.contains("src/App.swift") && all.contains("a.txt"), "tracked and untracked-but-not-ignored: \(all)")
        XCTAssertFalse(all.contains("secret.txt") || all.contains("build/out.bin"), "ignored: \(all)")
        let found = await repo.call("GET", "files", query: ["q": "app"]).json?["files"]?.array ?? []
        XCTAssertEqual(found.first?["relative"], "src/App.swift")
        XCTAssertEqual(found.first?["name"], "App.swift")
        XCTAssertTrue(found.first?["path"]?.string?.hasSuffix("/src/App.swift") == true && found.first?["path"]?.string?.hasPrefix("/") == true)
    }

    func testOutsideARepositoryTheFolderIsWalkedWithoutTheHeavyOnes() async throws {
        let repo = try await RepoFixture()
        try repo.write("notes/todo.md", "x")
        try repo.write("node_modules/pkg/index.js", "x")
        try repo.write(".hidden/secret", "x")
        let names = await repo.call("GET", "files").json?["files"]?.array?.compactMap { $0["relative"]?.string } ?? []
        XCTAssertEqual(names, ["notes/todo.md"])
    }

    func testUnknownThreadsHaveNoFilesOrDiff() async throws {
        let repo = try await RepoFixture()
        let files = await repo.callRaw("GET", "/api/threads/nope/files")
        XCTAssertEqual(files.status, 404)
        let diff = await repo.callRaw("GET", "/api/threads/nope/git/diff")
        XCTAssertEqual(diff.status, 404)
    }
}
