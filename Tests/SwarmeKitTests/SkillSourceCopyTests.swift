import CompanionCore
@testable import SwarmeKit
import XCTest

/// "Copia su server" for a GitHub skill source: what is sent, and when a server's source is the same one.
final class SkillSourceCopyTests: XCTestCase {
    private func source(_ json: String) throws -> SkillSource {
        try JSONDecoder().decode(SkillSource.self, from: Data(json.utf8))
    }

    private let full = """
    {"id":"s1","name":"Team skills","repo":"acme/skills","path":"skills","ref":"main","secret":"CYLON_TOKEN","secretPresent":true,\
    "enabled":true,"assign":{"all":false,"botIds":["b1","b2"]},"requires":{"commands":["bru"],"connectors":["clickup"]},\
    "installed":{"sha":"abc","shortSha":"abc","at":1,"skills":[{"name":"alpha","present":true}]},"canRollback":true,"syncing":false,"held":true,\
    "missing":[],"last":{"checkedAt":1,"ok":true}}
    """

    func testTheSettingsTravelButNotWhatBelongsToThisEngine() throws {
        let fields = SkillSourceCopy.fields(try source(full))
        XCTAssertEqual(fields["repo"] as? String, "acme/skills")
        XCTAssertEqual(fields["path"] as? String, "skills")
        XCTAssertEqual(fields["ref"] as? String, "main")
        XCTAssertEqual(fields["name"] as? String, "Team skills")
        XCTAssertEqual(fields["secret"] as? String, "CYLON_TOKEN", "the secret's name: its value goes by another road")
        XCTAssertEqual(fields["enabled"] as? Bool, true)
        let assign = try XCTUnwrap(fields["assign"] as? [String: Any])
        XCTAssertEqual(assign["all"] as? Bool, false)
        XCTAssertEqual(assign["botIds"] as? [String], [], "the bots are this engine's, not the server's")
        let requires = try XCTUnwrap(fields["requires"] as? [String: Any])
        XCTAssertEqual(requires["commands"] as? [String], ["bru"])
        XCTAssertEqual(requires["connectors"] as? [String], ["clickup"])
        for local in ["id", "installed", "last", "canRollback", "held", "syncing", "missing", "previousSha"] {
            XCTAssertNil(fields[local], "\(local) is what this engine knows of its own install")
        }
    }

    func testEveryBotStaysEveryBot() throws {
        let all = try source(full.replacingOccurrences(of: #""all":false,"botIds":["b1","b2"]"#, with: #""all":true,"botIds":[]"#))
        XCTAssertEqual((SkillSourceCopy.fields(all)["assign"] as? [String: Any])?["all"] as? Bool, true)
    }

    func testAPublicSourceSendsNoSecretAndAServerKeepsNone() throws {
        let publicOne = try source(full.replacingOccurrences(of: #""secret":"CYLON_TOKEN","secretPresent":true,"#, with: ""))
        XCTAssertTrue(SkillSourceCopy.fields(publicOne)["secret"] is NSNull, "null clears any token the server's copy had")
    }

    func testTheServersSourceIsTheOneOfTheSameFolderWhateverItIsCalled() throws {
        let mine = try source(full)
        let renamed = try source(full.replacingOccurrences(of: "Team skills", with: "Il loro nome").replacingOccurrences(of: #""id":"s1""#, with: #""id":"other""#))
        XCTAssertTrue(SkillSourceCopy.same(mine, renamed))
        XCTAssertFalse(SkillSourceCopy.same(mine, try source(full.replacingOccurrences(of: #""path":"skills""#, with: #""path":"other""#))))
        XCTAssertFalse(SkillSourceCopy.same(mine, try source(full.replacingOccurrences(of: #""ref":"main""#, with: #""ref":"develop""#))))
        XCTAssertFalse(SkillSourceCopy.same(mine, try source(full.replacingOccurrences(of: #""repo":"acme/skills""#, with: #""repo":"acme/more""#))))
    }

    /// `SWARMEBOT_SKILL_REMOTE_URL` (the chat URL) and `_TOKEN` (a device token): copy a public source there the way
    /// "Copia su server" does, see the server install from it, copy it again (it is changed, not made twice), then delete it.
    func testCopyingASourceToAnEngine() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SWARMEBOT_SKILL_REMOTE_URL"], let token = env["SWARMEBOT_SKILL_REMOTE_TOKEN"] else {
            throw XCTSkip("SWARMEBOT_SKILL_REMOTE_URL / _TOKEN not set")
        }
        let remote = CompanionClient(connection: try XCTUnwrap(Connection.remote(chatURL: url)), token: token)
        let mine = try source(#"{"id":"local","name":"Superpowers","repo":"obra/superpowers","path":"skills","ref":"main","enabled":true,"assign":{"all":false,"botIds":["not-the-servers"]},"requires":{"commands":[],"connectors":[]},"canRollback":false,"syncing":false,"held":false,"missing":[]}"#)
        let first = try await SkillSourceCopy.copy(mine, to: remote)
        XCTAssertEqual(first.last?.ok, true, String(describing: first.last))
        XCTAssertGreaterThan(first.installed?.skills.count ?? 0, 0, "the server installed the skills itself")
        XCTAssertEqual(first.assign.botIds, [])
        let again = try await SkillSourceCopy.copy(mine, to: remote)
        XCTAssertEqual(again.id, first.id, "the same source, not a second one")
        let sources = try await remote.skillSources()
        XCTAssertEqual(sources.filter { SkillSourceCopy.same($0, mine) }.count, 1)
        try await remote.deleteSkillSource(first.id)
        let after = try await remote.skillSources()
        XCTAssertFalse(after.contains { $0.id == first.id })
    }

    // MARK: telling an update

    private func run(_ id: String, at: Double, ok: Bool = true, updated: String? = nil) throws -> SkillSource {
        let updatedJSON = updated.map { #","updated":\#($0)"# } ?? ""
        return try source(#"{"id":"\#(id)","name":"S \#(id)","repo":"a/b","path":"skills","ref":"main","enabled":true,"assign":{"all":false,"botIds":[]},"requires":{"commands":[],"connectors":[]},"canRollback":false,"syncing":false,"held":false,"missing":[],"last":{"checkedAt":\#(at),"ok":\#(ok)\#(updatedJSON)}}"#)
    }

    private let changed = #"{"added":["new-one"],"changed":["alpha"],"removed":[]}"#

    func testAnUpdateThatChangedSkillsIsToldOnceAndAnOldOneIsNot() throws {
        // first seen: nothing to tell, whatever it holds
        var result = SkillUpdates.news(in: [try run("s1", at: 100, updated: changed)], seen: [:])
        XCTAssertTrue(result.news.isEmpty, "already there when the app first saw it")
        XCTAssertEqual(result.seen, ["s1": 100])
        // a newer run that changed skills: told
        result = SkillUpdates.news(in: [try run("s1", at: 200, updated: changed)], seen: result.seen)
        XCTAssertEqual(result.news.map(\.source.id), ["s1"])
        XCTAssertEqual(result.news.first?.updated.added, ["new-one"])
        XCTAssertEqual(result.seen, ["s1": 200])
        // the same run again (the app asked twice): not told again
        result = SkillUpdates.news(in: [try run("s1", at: 200, updated: changed)], seen: result.seen)
        XCTAssertTrue(result.news.isEmpty)
    }

    func testARunThatChangedNothingOrFailedIsNotNewsButIsNotedAsSeen() throws {
        let seen = ["a": 100.0, "b": 100.0, "c": 100.0]
        let result = SkillUpdates.news(in: [try run("a", at: 200), try run("b", at: 200, ok: false),
                                            try run("c", at: 200, updated: #"{"added":[],"changed":[],"removed":[]}"#)], seen: seen)
        XCTAssertTrue(result.news.isEmpty)
        XCTAssertEqual(result.seen, ["a": 200, "b": 200, "c": 200], "so that an older one cannot be told later")
    }

    func testSeveralSourcesAndOneStillRunning() throws {
        let running = try source(#"{"id":"s3","name":"x","repo":"a/b","path":"skills","ref":"main","enabled":true,"assign":{"all":false,"botIds":[]},"requires":{"commands":[],"connectors":[]},"canRollback":false,"syncing":true,"held":false,"missing":[]}"#)
        let result = SkillUpdates.news(in: [try run("s1", at: 300, updated: changed), try run("s2", at: 50, updated: changed), running],
                                       seen: ["s1": 100, "s2": 100])
        XCTAssertEqual(result.news.map(\.source.id), ["s1"], "s2's is older than what was seen, s3 has no run yet")
        XCTAssertNil(result.seen["s3"])
        XCTAssertEqual(result.seen["s2"], 100, "the time never goes back")
    }
}

