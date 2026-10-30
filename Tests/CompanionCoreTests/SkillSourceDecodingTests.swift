@testable import CompanionCore
import XCTest

/// What the engine's `/api/skill-sources` answers (Sources/HarnessCore/SkillSources.swift).
final class SkillSourceDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> [SkillSource] {
        try JSONDecoder().decode(SkillSourceList.self, from: Data(json.utf8)).sources
    }

    func testASourceThatInstalledSkillsAndSaysWhatIsMissing() throws {
        let json = """
        {"sources":[{"id":"s1","name":"Team skills","repo":"acme/skills","path":"skills","ref":"main","secret":"CYLON_TOKEN","secretPresent":true,\
        "enabled":true,"assign":{"all":false,"botIds":["b1","b2"]},"requires":{"commands":["bru"],"connectors":["clickup"]},\
        "installed":{"sha":"2ce8aa15d05bd57213e6f746f953aafb7ded7a8b","shortSha":"2ce8aa1","at":1793301982267,"skills":[{"name":"alpha","present":true},{"name":"beta","present":false}]},\
        "previousSha":"aaaaaaa","canRollback":true,"syncing":false,"held":true,\
        "missing":[{"kind":"command","name":"bru"},{"kind":"connector","name":"clickup"}],\
        "last":{"checkedAt":1793302001000,"ok":true,"updated":{"added":["alpha"],"changed":[],"removed":["old"]},"conflicts":["mine"]}}]}
        """
        let source = try XCTUnwrap(decode(json).first)
        XCTAssertEqual(source.repo, "acme/skills")
        XCTAssertEqual(source.secret, "CYLON_TOKEN")
        XCTAssertEqual(source.assign.botIds, ["b1", "b2"])
        XCTAssertEqual(source.installed?.shortSha, "2ce8aa1")
        XCTAssertEqual(source.installed?.skills.map(\.present), [true, false])
        XCTAssertTrue(source.canRollback)
        XCTAssertTrue(source.held)
        XCTAssertEqual(source.missing.map(\.id), ["command:bru", "connector:clickup"])
        XCTAssertEqual(source.last?.updated?.removed, ["old"])
        XCTAssertEqual(source.last?.updated?.isEmpty, false)
        XCTAssertEqual(source.last?.conflicts, ["mine"])
    }

    func testASourceNotDownloadedYetHasNoInstalledAndNoLast() throws {
        let json = #"{"sources":[{"id":"s2","name":"x","repo":"a/b","path":"","ref":"main","enabled":false,"assign":{"all":true,"botIds":[]},"requires":{"commands":[],"connectors":[]},"canRollback":false,"syncing":false,"held":false,"missing":[]}]}"#
        let source = try XCTUnwrap(decode(json).first)
        XCTAssertNil(source.installed)
        XCTAssertNil(source.last)
        XCTAssertNil(source.secret)
        XCTAssertTrue(source.assign.all)
        XCTAssertFalse(source.enabled)
    }

    func testAFailedRunKeepsItsReason() throws {
        let json = #"{"sources":[{"id":"s3","name":"x","repo":"a/b","path":"skills","ref":"main","enabled":true,"assign":{"all":false,"botIds":[]},"requires":{"commands":[],"connectors":[]},"canRollback":false,"syncing":false,"held":false,"missing":[],"last":{"checkedAt":1,"ok":false,"error":"a skill is not valid, so nothing was changed"}}]}"#
        let last = try XCTUnwrap(decode(json).first?.last)
        XCTAssertFalse(last.ok)
        XCTAssertEqual(last.error, "a skill is not valid, so nothing was changed")
    }

    func testASkillSaysWhereItComesFrom() throws {
        let managed = try JSONDecoder().decode(Skill.self, from: Data(#"{"id":"alpha","name":"alpha","description":"d","files":["SKILL.md"],"bytes":1,"tokens":1,"hasScripts":false,"updatedAt":1,"source":{"id":"s1","name":"acme/skills","sha":"2ce8aa1"}}"#.utf8))
        XCTAssertEqual(managed.source?.sha, "2ce8aa1")
        let own = try JSONDecoder().decode(Skill.self, from: Data(#"{"id":"mine","name":"mine","description":"d","files":["SKILL.md"],"bytes":1,"tokens":1,"hasScripts":false,"updatedAt":1}"#.utf8))
        XCTAssertNil(own.source)
    }
}
