import CompanionCore
@testable import SwarmeBotUI
import XCTest

final class SkillChoicesTests: XCTestCase {
    private func skill(_ id: String, scripts: Bool = false) throws -> Skill {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "name": id, "description": "Test skill",
            "files": ["SKILL.md"], "bytes": 10, "tokens": 3, "hasScripts": scripts, "updatedAt": 0])
        return try JSONDecoder().decode(Skill.self, from: data)
    }

    private var group: PluginSkillGroup {
        PluginSkillGroup(id: "suite", title: "Suite", description: "All the skills", skillIDs: ["plan", "run", "review", "missing"])
    }

    func testGroupReplacesMembersOnceInOrderAndLeavesOtherSkillsAlone() throws {
        let skills = try [skill("alpha"), skill("plan"), skill("other"), skill("run", scripts: true), skill("review")]
        let choices = SkillChoice.list(skills, groups: [group])
        XCTAssertEqual(choices.map(\.title), ["alpha", "Suite", "other"])
        XCTAssertEqual(choices[1].skills.map(\.id), ["plan", "run", "review"])
        XCTAssertTrue(choices[1].hasScripts)
        XCTAssertTrue(choices[1].isGroup)
        XCTAssertEqual(SkillChoice.list(skills, groups: []).map(\.title), skills.map(\.name))
    }

    func testGroupToggleSetsEveryDefaultWithOneListAndPreservesUnrelatedEntries() throws {
        let choice = try XCTUnwrap(SkillChoice.list(try [skill("plan"), skill("run"), skill("review")], groups: [group]).first)
        let unrelated = BotSkill(id: "unavailable-local-skill", defaultOn: false)
        let before = [unrelated, BotSkill(id: "run", defaultOn: false)]
        let enabled = choice.assigning(true, in: before)
        XCTAssertEqual(Set(enabled.map(\.id)), ["unavailable-local-skill", "plan", "run", "review"])
        XCTAssertEqual(enabled.first, unrelated)
        XCTAssertEqual(choice.defaultOnCount(in: enabled), 3)
        XCTAssertEqual(choice.assignedCount(in: enabled), 3)
        XCTAssertEqual(choice.assigning(true, in: enabled), enabled, "no duplicate entries")
        let disabled = choice.assigning(false, in: enabled)
        XCTAssertEqual(disabled.first, unrelated)
        XCTAssertEqual(choice.defaultOnCount(in: disabled), 0)
        XCTAssertEqual(choice.assignedCount(in: disabled), 3, "explicit off entries must beat automatic source assignments")
        XCTAssertEqual(choice.assigning(false, in: disabled), disabled)
    }

    func testPartialGroupsCanBeEnabledOrDisabledTogether() throws {
        let choice = try XCTUnwrap(SkillChoice.list(try [skill("plan"), skill("run"), skill("review")], groups: [group]).first)
        let partial = [BotSkill(id: "plan", defaultOn: true), BotSkill(id: "run", defaultOn: false)]
        XCTAssertEqual(choice.defaultOnCount(in: partial), 1)
        XCTAssertEqual(choice.assignedCount(in: partial), 2)
        XCTAssertEqual(choice.defaultOnCount(in: choice.assigning(true, in: partial)), 3)
        XCTAssertEqual(choice.defaultOnCount(in: choice.assigning(false, in: partial)), 0)
    }

    func testUngroupedAssignmentAndDefaultBehaviorIsPreserved() throws {
        let choice = try XCTUnwrap(SkillChoice.list(try [skill("solo")], groups: [group]).first)
        XCTAssertFalse(choice.isGroup)
        let assigned = choice.assigning(true, in: [])
        XCTAssertEqual(assigned, [BotSkill(id: "solo", defaultOn: true)])
        let off = choice.settingDefault(false, in: assigned)
        XCTAssertEqual(off, [BotSkill(id: "solo", defaultOn: false)])
        XCTAssertTrue(choice.assigning(false, in: off).isEmpty)
    }

    func testOverlappingAndDuplicateGroupsNeverDuplicateOrHideSkills() throws {
        let other = PluginSkillGroup(id: "other", title: "Other", description: "", skillIDs: ["run", "extra"])
        let choices = SkillChoice.list(try [skill("run"), skill("extra"), skill("solo")], groups: [group, group, other])
        XCTAssertEqual(choices.map(\.title), ["Suite", "Other", "solo"])
        XCTAssertEqual(choices.flatMap(\.skills).map(\.id), ["run", "extra", "solo"])
    }
}
