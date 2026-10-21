import CompanionCore
@testable import SwarmeKit
import XCTest

/// Reading a skill off this Mac (docs/plans/2026-10-21-skill.md S3), and the
/// "Copia su server" path against a real remote engine when one is given.
final class SkillFolderTests: XCTestCase {
    private func skillFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skillfolder-\(UUID().uuidString.prefix(8))/report-test")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("references/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("---\nname: report-test\ndescription: A skill for the copy test.\n---\n\nRun scripts/run.sh.\n".utf8)
            .write(to: dir.appendingPathComponent("SKILL.md"))
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: dir.appendingPathComponent("scripts/run.sh"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("scripts/run.sh").path)
        try Data("# Notes\n".utf8).write(to: dir.appendingPathComponent("references/deep/notes.md"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".git/config"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link.md"), withDestinationURL: dir.appendingPathComponent("SKILL.md"))
        return dir
    }

    func testFolderKeepsSubfoldersAndTheExecutableBitAndLeavesHiddenFilesAndLinks() throws {
        let files = try SkillFolder.read(try skillFolder())
        XCTAssertEqual(files.map(\.path), ["SKILL.md", "references/deep/notes.md", "scripts/run.sh"])
        XCTAssertEqual(files.map(\.executable), [false, false, true])
        XCTAssertTrue(SkillFolder.hasScripts(files))
        XCTAssertFalse(SkillFolder.hasScripts(files.filter { $0.path.hasSuffix(".md") }))
    }

    /// Claude exports a skill as a zip holding its folder.
    func testZipWithTheFolderInside() throws {
        let folder = try skillFolder()
        let zip = folder.deletingLastPathComponent().appendingPathComponent("report-test.skill")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        let files = try SkillFolder.read(zip)
        XCTAssertEqual(files.map(\.path), ["SKILL.md", "references/deep/notes.md", "scripts/run.sh"])
        XCTAssertEqual(files.last?.executable, true)
    }

    func testAFolderWithoutSkillMdIsRefused() throws {
        let folder = try skillFolder()
        XCTAssertThrowsError(try SkillFolder.read(folder.appendingPathComponent("references")))
    }

    /// `SWARMEBOT_SKILL_REMOTE_URL` (the chat URL) and `_TOKEN` (a device
    /// token): import there the way "Copia su server" does, read it back,
    /// refuse a second copy without replace, then delete it.
    func testCopyToARemoteEngine() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SWARMEBOT_SKILL_REMOTE_URL"], let token = env["SWARMEBOT_SKILL_REMOTE_TOKEN"] else {
            throw XCTSkip("SWARMEBOT_SKILL_REMOTE_URL / _TOKEN not set")
        }
        let client = CompanionClient(connection: try XCTUnwrap(Connection.remote(chatURL: url)), token: token)
        let files = try SkillFolder.read(try skillFolder())
        let skill = try await client.addSkill(files, replace: false)
        XCTAssertEqual(skill.id, "report-test")
        XCTAssertEqual(skill.files, ["SKILL.md", "references/deep/notes.md", "scripts/run.sh"])
        XCTAssertTrue(skill.hasScripts)
        do {
            _ = try await client.addSkill(files, replace: false)
            XCTFail("a second copy must be refused")
        } catch let APIError.status(code, _) {
            XCTAssertEqual(code, 409)
        }
        let replaced = try await client.addSkill(files, replace: true)
        XCTAssertEqual(replaced.id, "report-test")
        let content = try await client.skillContent("report-test").content
        XCTAssertTrue(content.contains("Run scripts/run.sh."))
        let listed = try await client.skills()
        XCTAssertTrue(listed.contains { $0.id == "report-test" })
        let folder = try await client.skillsFolder()
        XCTAssertTrue(folder.folder.hasSuffix("/.swarmebot/skills"), folder.folder)
        try await client.deleteSkill("report-test")
        let after = try await client.skills()
        XCTAssertFalse(after.contains { $0.id == "report-test" })
    }
}
