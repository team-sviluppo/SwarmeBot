@testable import CodePluginApp
import CompanionCore
import SwarmeBotUI
@testable import SwarmeKit
import XCTest

final class DiffParserTests: XCTestCase {
    private let sample = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,4 +10,5 @@ struct App {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        @@ -40,2 +41,2 @@
        -old
        +new
        \\ No newline at end of file

        """

    func testTheHeaderIsDroppedAndTheLinesAreNumbered() {
        let lines = DiffParser.parse(sample.replacingOccurrences(of: "        ", with: ""))
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .removed, .added, .added, .context, .hunk, .removed, .added, .note])
        XCTAssertEqual(lines[0].text, "@@ -10,4 +10,5 @@ struct App {")
        XCTAssertEqual(lines[1].oldNumber, 10)
        XCTAssertEqual(lines[1].newNumber, 10)
        XCTAssertEqual(lines[2].oldNumber, 11)
        XCTAssertNil(lines[2].newNumber)
        XCTAssertEqual(lines[2].text, "let b = 2")
        XCTAssertEqual(lines[3].newNumber, 11)
        XCTAssertEqual(lines[4].newNumber, 12)
        XCTAssertEqual(lines[5].oldNumber, 12)
        XCTAssertEqual(lines[5].newNumber, 13)
        XCTAssertEqual(lines[7].oldNumber, 40, "the second hunk starts over from its own header")
        XCTAssertEqual(lines[8].newNumber, 41)
    }

    func testACommentPointsAtTheNewLineOrTheOldOneForARemovedLine() {
        let lines = DiffParser.parse("@@ -5,2 +5,2 @@\n-gone\n+here\n")
        XCTAssertEqual(lines[1].anchor, 5)
        XCTAssertEqual(lines[2].anchor, 5)
        XCTAssertNil(DiffLine(id: 0, kind: .hunk, text: "@@").anchor)
    }

    func testAHunkHeaderWithoutCountsStillStarts() {
        XCTAssertEqual(DiffParser.hunkStart("@@ -1 +1 @@")?.old, 1)
        XCTAssertEqual(DiffParser.hunkStart("@@ -0,0 +1,3 @@")?.new, 1)
        XCTAssertNil(DiffParser.hunkStart("not a header"))
    }

    func testAnEmptyDiffHasNoLines() {
        XCTAssertTrue(DiffParser.parse("").isEmpty)
        XCTAssertTrue(DiffParser.parse("Binary files a/x and b/x differ\n").isEmpty)
    }

    func testAnEmptyContextLineKeepsItsNumber() {
        let lines = DiffParser.parse("@@ -1,3 +1,3 @@\n a\n \n-b\n+c\n")
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .context, .removed, .added])
        XCTAssertEqual(lines[2].text, "")
        XCTAssertEqual(lines[3].oldNumber, 3)
    }

    func testTheReviewNamesEveryFileAndLine() {
        let comments = [
            DiffComment(path: "b.swift", line: 9, removed: false, excerpt: "let y = 2", body: "Why 2?"),
            DiffComment(path: "a.swift", line: 12, removed: true, excerpt: "let x = 1", body: "Keep this."),
            DiffComment(path: "a.swift", line: 3, removed: false, excerpt: "import Foo", body: "Unused."),
        ]
        let text = Review.message(comments)
        XCTAssertTrue(text.hasPrefix("Review of my uncommitted changes."))
        let a3 = text.range(of: "a.swift:3")!.lowerBound, a12 = text.range(of: "a.swift:12 (the removed line")!.lowerBound, b9 = text.range(of: "b.swift:9")!.lowerBound
        XCTAssertTrue(a3 < a12 && a12 < b9, "by file, then by line")
        XCTAssertTrue(text.contains("    + import Foo\nUnused."))
        XCTAssertTrue(text.contains("    - let x = 1\nKeep this."))
    }
}

final class ChangeTreeTests: XCTestCase {
    private func change(_ path: String) -> ThreadGitState.Change {
        ThreadGitState.Change(path: path, name: (path as NSString).lastPathComponent, status: "M", bytes: 1)
    }

    func testChangesAreGroupedByFolderRootFirst() {
        let changes = ["/r/Sources/b.swift", "/r/README.md", "/r/Sources/a.swift", "/r/Tests/t.swift"].map(change)
        let groups = ChangeTree.groups(changes, root: "/r")
        XCTAssertEqual(groups.map(\.folder), ["", "Sources", "Tests"])
        XCTAssertEqual(groups[1].files.map(\.name), ["a.swift", "b.swift"])
    }

    func testRelativeNeedsTheRootToContainThePath() {
        XCTAssertEqual(ChangeTree.relative("/r/Sources/a.swift", root: "/r"), "Sources/a.swift")
        XCTAssertEqual(ChangeTree.relative("/elsewhere/a", root: "/r"), "/elsewhere/a")
        XCTAssertEqual(ChangeTree.relative("/r2/a", root: "/r"), "/r2/a", "a sibling folder with the same prefix is not inside")
        XCTAssertEqual(ChangeTree.relative("/r/a", root: nil), "/r/a")
    }
}

@MainActor
final class CodeReferencesTests: XCTestCase {
    func testAFileIsReferencedOnceAndTheMessageTakesItAway() {
        let state = CodeState()
        state.addReference(FileReference(path: "/p/a.swift"), threadId: "t")
        state.addReference(FileReference(path: "/p/a.swift"), threadId: "t")
        state.addReference(FileReference(path: "/p/b.swift"), threadId: "t")
        state.addReference(FileReference(path: "/p/c.swift"), threadId: "other")
        XCTAssertEqual(state.references["t"]?.map(\.name), ["a.swift", "b.swift"])
        XCTAssertEqual(state.takeReferences(threadId: "t").count, 2)
        XCTAssertNil(state.references["t"], "they went with that message")
        XCTAssertEqual(state.references["other"]?.count, 1, "another chat's are its own")
        XCTAssertTrue(state.takeReferences(threadId: "t").isEmpty)
    }

    func testARemovedReferenceIsGone() {
        let state = CodeState()
        state.addReference(FileReference(path: "/p/a"), threadId: "t")
        state.addReference(FileReference(path: "/p/b"), threadId: "t")
        state.removeReference("/p/a", threadId: "t")
        XCTAssertEqual(state.references["t"]?.map(\.path), ["/p/b"])
    }

    func testTheAgentIsToldTheFilesByPath() {
        let block = CodeState.referencesBlock([FileReference(path: "/p/a.swift"), FileReference(path: "/p/b.swift")])
        XCTAssertEqual(block, "Files I am referring to (read them as you need):\n- /p/a.swift\n- /p/b.swift")
    }

    func testOnlyAMessageWithFilesGetsTheBlock() throws {
        let plugin = CodeAppPlugin()
        let chat = ChatContext(model: AppModel(), bot: nil, room: nil, threadId: "t", isBusy: false)
        XCTAssertEqual(plugin.outgoingText("Hello", chat), "Hello", "nothing referenced: the text is as typed")
        plugin.state.addReference(FileReference(path: "/p/a.swift"), threadId: "t")
        XCTAssertEqual(plugin.outgoingText("Hello", chat), "Hello\n\nFiles I am referring to (read them as you need):\n- /p/a.swift")
        XCTAssertEqual(plugin.outgoingText("Next", chat), "Next", "and they do not repeat")
        XCTAssertEqual(plugin.composerChips(chat).count, 0)
    }

    func testChipsFollowTheReferences() {
        let plugin = CodeAppPlugin()
        let chat = ChatContext(model: AppModel(), bot: nil, room: nil, threadId: "t", isBusy: false)
        plugin.state.addReference(FileReference(path: "/p/a.swift"), threadId: "t")
        plugin.state.addReference(FileReference(path: "/p/b.swift"), threadId: "t")
        XCTAssertEqual(plugin.composerChips(chat).count, 2)
    }

    func testCommentsWaitForTheReviewAndAreSentOnce() {
        let state = CodeState()
        let comment = DiffComment(path: "a", line: 1, removed: false, excerpt: "x", body: "y")
        state.addComment(comment, threadId: "t")
        XCTAssertEqual(state.comments["t"]?.count, 1)
        state.removeComment(comment.id, threadId: "t")
        XCTAssertEqual(state.comments["t"]?.count, 0)
    }

    func testVersionsCompareAsNumbers() {
        XCTAssertTrue(CodeState.version("1.1.0", atLeast: "1.1.0"))
        XCTAssertTrue(CodeState.version("1.10.0", atLeast: "1.9.0"))
        XCTAssertTrue(CodeState.version("2.0", atLeast: "1.1.0"))
        XCTAssertFalse(CodeState.version("1.0.0", atLeast: "1.1.0"))
        XCTAssertFalse(CodeState.version("1.0.9", atLeast: "1.1"))
        XCTAssertTrue(CodeState.version("1.1", atLeast: "1.1.0"), "a missing part is a zero")
    }

    func testAnOlderEnginePluginHasNoWorkflow() {
        let model = AppModel()
        let state = CodeState()
        XCTAssertFalse(state.engineHasWorkflow(model), "no plugin at all")
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1.0.0", enabled: true)]
        XCTAssertFalse(state.engineHasWorkflow(model), "the first version: git and a terminal only")
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1.1.0", enabled: true)]
        XCTAssertTrue(state.engineHasWorkflow(model))
    }

    func testThePluginOffersItsTabAndChipsOnlyToANewEnoughEngine() throws {
        let model = AppModel()
        let plugin = CodeAppPlugin()
        let bot = try JSONDecoder().decode(Bot.self, from: Data(#"{"id":"b","threadId":"t","name":"N","title":"","description":"","notifications":true,"color":"blue","unread":false,"modelSelection":{"instanceId":"i","model":"m"},"createdAt":1,"codeMode":true}"#.utf8))
        let chat = ChatContext(model: model, bot: bot, room: nil, threadId: "t", isBusy: false)
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1.0.0", enabled: true)]
        XCTAssertTrue(plugin.inspectorTabs(chat).isEmpty)
        XCTAssertEqual(plugin.composerAccessories(chat).count, 3)
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1.1.0", enabled: true)]
        XCTAssertEqual(plugin.inspectorTabs(chat).map(\.id), ["code.diff"])
        XCTAssertEqual(plugin.inspectorTabs(chat).first?.width, CodeDiffPanel.width)
        XCTAssertEqual(plugin.composerAccessories(chat).count, 5, "the file search and the shortcuts join")
    }
}

final class DroppedFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("src/a.swift"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("pic.png"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testAFileInsideTheFolderIsAReference() {
        let inside = folder.appendingPathComponent("src/a.swift")
        XCTAssertEqual(DroppedFiles.claimable([inside], folders: [folder.path]), [inside])
    }

    func testTheFolderMayBeNamedThroughASymlink() {
        // /var is /private/var on a Mac: the same folder under two names
        let viaVar = URL(fileURLWithPath: folder.path.replacingOccurrences(of: "/private", with: "")).appendingPathComponent("src/a.swift")
        XCTAssertEqual(DroppedFiles.claimable([viaVar], folders: [folder.path]).count, 1)
    }

    func testImagesFoldersAndOutsiderStayAttachments() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let urls = [folder.appendingPathComponent("pic.png"), folder.appendingPathComponent("src"), outside, folder.appendingPathComponent("src/missing.swift")]
        XCTAssertTrue(DroppedFiles.claimable(urls, folders: [folder.path]).isEmpty)
    }

    func testASiblingFolderWithTheSamePrefixIsNotInside() throws {
        let sibling = URL(fileURLWithPath: folder.path + "-other", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let file = sibling.appendingPathComponent("a.swift")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(DroppedFiles.claimable([file], folders: [folder.path]).isEmpty)
    }

    func testNoFoldersClaimNothing() {
        XCTAssertTrue(DroppedFiles.claimable([folder.appendingPathComponent("src/a.swift")], folders: []).isEmpty)
    }
}
