@testable import HarnessCore
import XCTest

/// Skills kept from a GitHub folder (docs/plans/2026-10-28-code-mode-t3.md §11): a fake GitHub that
/// hands out tarballs, so that nothing here touches the network.
@MainActor
final class SkillSourceTests: XCTestCase {
    /// A repository that moves: one commit at a time, each with its files.
    final class FakeGitHub: @unchecked Sendable {
        var sha = String(repeating: "a", count: 40)
        var tarball = Data()
        var headCalls = 0
        var downloads = 0
        var tokens: [String?] = []
        var failure: SkillSourceError?

        var fetcher: GitHubSkillFetcher {
            GitHubSkillFetcher(
                head: { [self] _, _, token in
                    headCalls += 1
                    tokens.append(token)
                    if let failure { throw failure }
                    return sha
                },
                tarball: { [self] _, _, token in
                    downloads += 1
                    tokens.append(token)
                    return tarball
                })
        }
    }

    private var github = FakeGitHub()
    private var scratch: URL!

    override func setUp() async throws {
        github = FakeGitHub()
        SkillSources.fetcher = github.fetcher
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("skill-source-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        SkillSources.fetcher = GitHubSkillFetcher.live
        try? FileManager.default.removeItem(at: scratch)
    }

    private func manifest(_ name: String, _ body: String = "Do the thing.") -> String {
        "---\nname: \(name)\ndescription: Does \(name) work for the team.\n---\n\n\(body)\n"
    }

    /// What GitHub makes: the files under one top folder named after the repository and the commit.
    private func makeTarball(_ files: [String: String], executables: Set<String> = [], links: [String: String] = [:]) throws -> Data {
        let root = scratch.appendingPathComponent("tar-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let top = root.appendingPathComponent("acme-skills-abc1234", isDirectory: true)
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = top.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executables.contains(path) ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        for (path, target) in links {
            try FileManager.default.createSymbolicLink(atPath: top.appendingPathComponent(path).path, withDestinationPath: target)
        }
        let out = root.appendingPathComponent("repo.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", out.path, "-C", root.path, "acme-skills-abc1234"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: out)
    }

    private func repoV1() throws -> Data {
        try makeTarball([
            "README.md": "# skills\n",
            "skills/alpha/SKILL.md": manifest("alpha"),
            "skills/alpha/scripts/run.sh": "echo alpha\n",
            "skills/alpha/references/notes.md": "notes\n",
            "skills/beta/SKILL.md": manifest("beta"),
            "skills/not-a-skill/readme.md": "no manifest here\n",
        ], executables: ["skills/alpha/scripts/run.sh"])
    }

    private func engine() throws -> Harness {
        let dir = scratch.appendingPathComponent("engine-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Harness(paths: DataPaths(root: dir), environment: ProcessInfo.processInfo.environment, drivers: [])
    }

    private func newSource(_ harness: Harness, _ extra: JSONObject = [:]) throws -> String {
        var body: JSONObject = ["repo": "acme/skills"]
        for (key, value) in extra { body[key] = value }
        return try XCTUnwrap(harness.skillSources.create(body)["id"]?.string)
    }

    private func call(_ harness: Harness, _ method: String, _ path: String, _ body: JSON? = nil) async -> (status: Int, json: JSON?) {
        let request = HTTPRequest(method: method, path: path, query: [:], headers: ["content-type": "application/json"], body: body?.data ?? Data())
        guard case let .response(response) = await Routes(harness: harness).handle(request) else { return (-1, nil) }
        return (response.status, try? JSON.parse(response.body))
    }

    // MARK: settings

    func testASourceNeedsARepositoryAndAcceptsOnlySafeFolders() throws {
        let harness = try engine()
        let sources = harness.skillSources
        for bad in [[:], ["repo": "no-slash"], ["repo": "a/b/c"], ["repo": "../x"], ["repo": "acme/skills", "path": "../up"], ["repo": "acme/skills", "path": "/abs"],
                    ["repo": "acme/skills", "path": "a/../b"], ["repo": "acme/skills", "ref": "a..b"], ["repo": "acme/skills", "ref": "has space"],
                    ["repo": "acme/skills", "secret": "NOPE"], ["repo": "acme/skills", "assign": ["botIds": ["ghost"]]],
                    ["repo": "acme/skills", "requires": ["commands": ["bru; rm -rf /"]]], ["repo": "acme/skills", "enabled": "yes"]] as [JSONObject] {
            XCTAssertThrowsError(try sources.create(bad), "\(bad)")
        }
        let made = try sources.create(["repo": "acme/skills", "path": "skills/", "ref": "release/1.0"])
        XCTAssertEqual(made["path"], "skills", "a trailing slash is not part of it")
        XCTAssertEqual(made["ref"], "release/1.0")
        XCTAssertEqual(made["enabled"], true)
        XCTAssertThrowsError(try sources.create(["repo": "acme/skills", "path": "skills", "ref": "release/1.0"]), "the same folder twice")
        XCTAssertNotNil(try? sources.create(["repo": "acme/skills", "path": "other"]), "another folder of the same repository is another source")
        let root = try sources.create(["repo": "acme/more", "path": "."])
        XCTAssertEqual(root["path"], "", "the repository's root")
        for index in 0..<SkillSources.maxSources { _ = try? sources.create(["repo": .string("acme/r\(index)")]) }
        XCTAssertThrowsError(try sources.create(["repo": "acme/one-too-many"]))
        let reloaded = SkillSources(paths: harness.paths, skills: harness.skills, vault: harness.vault, botExists: { _ in true }, connectorNames: { [] })
        XCTAssertEqual(reloaded.sources.count, sources.sources.count, "kept on disk")
    }

    func testTheTokenIsNamedNotStored() async throws {
        let harness = try engine()
        try harness.vault.create(["name": "CYLON_TOKEN", "preset": "github", "value": "ghp_secretvalue1234567890"])
        let id = try newSource(harness, ["secret": "CYLON_TOKEN"])
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        XCTAssertEqual(github.tokens.compactMap { $0 }, ["ghp_secretvalue1234567890", "ghp_secretvalue1234567890"], "the engine reads it from the vault when it asks GitHub")
        let stored = try String(contentsOf: harness.paths.root.appendingPathComponent("skill-sources.json"), encoding: .utf8)
        XCTAssertFalse(stored.contains("ghp_secretvalue"), "the file names the secret and never holds the value")
        let wire = await call(harness, "GET", "/api/skill-sources")
        XCTAssertFalse(String(describing: wire.json).contains("ghp_secretvalue"))
        XCTAssertEqual(wire.json?["sources"]?.array?.first?["secret"], "CYLON_TOKEN")
        XCTAssertEqual(wire.json?["sources"]?.array?.first?["secretPresent"], true)
        // a secret that is gone says so, instead of asking GitHub with nothing
        try harness.vault.remove("CYLON_TOKEN")
        let after = try await harness.skillSources.sync(id, force: true)
        XCTAssertTrue(after["last"]?["error"]?.string?.contains("CYLON_TOKEN is not in this engine's vault") == true, String(describing: after["last"]))
    }

    // MARK: installing

    func testTheSkillsOfTheFolderAreInstalledAndMarkedAsManaged() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        github.sha = String(repeating: "b", count: 40)
        github.tarball = try repoV1()
        let source = try await harness.skillSources.sync(id)
        XCTAssertEqual(source["last"]?["ok"], true, String(describing: source["last"]))
        XCTAssertEqual(source["last"]?["updated"]?["added"], ["alpha", "beta"])
        XCTAssertEqual(source["installed"]?["shortSha"], "bbbbbbb")
        XCTAssertEqual(source["installed"]?["skills"]?.array?.compactMap { $0["name"]?.string }, ["alpha", "beta"])
        XCTAssertEqual(harness.skills.list().map(\.id), ["alpha", "beta"], "a folder with no SKILL.md is not a skill")
        let alpha = try XCTUnwrap(harness.skills.skill("alpha"))
        XCTAssertEqual(alpha.files, ["SKILL.md", "references/notes.md", "scripts/run.sh"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: harness.skills.directory("alpha").appendingPathComponent("scripts/run.sh").path), "the executable bit comes through")
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: harness.skills.directory("alpha").appendingPathComponent("SKILL.md").path))
        XCTAssertEqual(harness.skillSources.managed("alpha")?.sourceId, id)
        let list = await call(harness, "GET", "/api/skills")
        let marked = list.json?["skills"]?.array?.first { $0["id"] == "alpha" }
        XCTAssertEqual(marked?["source"]?["sha"], "bbbbbbb")
        XCTAssertEqual(marked?["source"]?["name"], "acme/skills")
    }

    func testAnUpToDateSourceAsksGitHubForTheCommitAndNothingMore() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        XCTAssertEqual(github.downloads, 1)
        let again = try await harness.skillSources.sync(id)
        XCTAssertEqual(github.downloads, 1, "the same commit is not downloaded again")
        XCTAssertEqual(github.headCalls, 2)
        XCTAssertEqual(again["last"]?["unchanged"], true)
        // a skill that went missing from the folder is reinstalled even for the same commit
        try FileManager.default.removeItem(at: harness.skills.directory("beta"))
        _ = try await harness.skillSources.sync(id)
        XCTAssertEqual(github.downloads, 2)
        XCTAssertNotNil(harness.skills.skill("beta"))
        _ = try await harness.skillSources.sync(id, force: true)
        XCTAssertEqual(github.downloads, 3, "a forced update downloads again")
    }

    func testAnUpdateSaysWhatChangedAndKeepsTheVersionItReplaced() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        github.sha = String(repeating: "c", count: 40)
        github.tarball = try makeTarball([
            "skills/alpha/SKILL.md": manifest("alpha", "A new way of doing it."),
            "skills/gamma/SKILL.md": manifest("gamma"),
        ])
        let updated = try await harness.skillSources.sync(id)
        XCTAssertEqual(updated["last"]?["updated"]?["added"], ["gamma"])
        XCTAssertEqual(updated["last"]?["updated"]?["changed"], ["alpha"])
        XCTAssertEqual(updated["last"]?["updated"]?["removed"], ["beta"])
        XCTAssertEqual(harness.skills.list().map(\.id), ["alpha", "gamma"], "a skill dropped upstream goes")
        XCTAssertTrue(harness.skills.content("alpha")?.contains("A new way") == true)
        XCTAssertEqual(updated["canRollback"], true)
        XCTAssertEqual(updated["previousSha"], "aaaaaaa")
    }

    func testOneBrokenSkillStopsTheWholeUpdateAndNothingChanges() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        let before = harness.skills.content("alpha")
        github.sha = String(repeating: "d", count: 40)
        github.tarball = try makeTarball([
            "skills/alpha/SKILL.md": manifest("alpha", "Changed, and fine."),
            "skills/broken/SKILL.md": "no front matter at all\n",
            "skills/mismatch/SKILL.md": manifest("someone-else"),
        ])
        let failed = try await harness.skillSources.sync(id)
        XCTAssertEqual(failed["last"]?["ok"], false)
        let error = try XCTUnwrap(failed["last"]?["error"]?.string)
        XCTAssertTrue(error.contains("2 skills are not valid, so nothing was changed"), error)
        XCTAssertTrue(error.contains("broken:") && error.contains("mismatch:"), error)
        XCTAssertEqual(harness.skills.content("alpha"), before, "the good skill of a bad update is not installed either")
        XCTAssertNotNil(harness.skills.skill("beta"))
        XCTAssertEqual(failed["installed"]?["shortSha"], "aaaaaaa")
        XCTAssertEqual(failed["canRollback"], false, "nothing was replaced")
    }

    func testAnEmptyOrWrongFolderIsSaid() async throws {
        let harness = try engine()
        let id = try newSource(harness, ["path": "elsewhere"])
        github.tarball = try repoV1()
        let missing = try await harness.skillSources.sync(id)
        XCTAssertTrue(missing["last"]?["error"]?.string?.contains("is not in acme/skills") == true, String(describing: missing["last"]))
        github.tarball = try makeTarball(["elsewhere/readme.md": "nothing"])
        let empty = try await harness.skillSources.sync(id, force: true)
        XCTAssertTrue(empty["last"]?["error"]?.string?.contains("no skills in") == true)
        github.tarball = Data("not a tarball".utf8)
        let garbage = try await harness.skillSources.sync(id, force: true)
        XCTAssertEqual(garbage["last"]?["ok"], false)
        XCTAssertTrue(harness.skills.list().isEmpty)
    }

    func testLinksHiddenFilesAndEscapesAreNotTaken() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        github.tarball = try makeTarball([
            "skills/alpha/SKILL.md": manifest("alpha"),
            "skills/alpha/.secret": "hidden",
            "skills/alpha/.git/config": "[core]",
            "outside.txt": "not in a skill",
        ], links: ["skills/alpha/passwd": "/etc/passwd", "skills/linked": "/etc"])
        let source = try await harness.skillSources.sync(id)
        XCTAssertEqual(source["last"]?["ok"], true, String(describing: source["last"]))
        XCTAssertEqual(harness.skills.skill("alpha")?.files, ["SKILL.md"], "no link, nothing hidden")
        XCTAssertNil(harness.skills.skill("linked"), "a link to a folder is not a skill")
    }

    func testASkillTheUserMadeIsNeverReplaced() async throws {
        let harness = try engine()
        try harness.skills.add([Skills.UploadFile(path: "SKILL.md", data: Data(manifest("alpha", "Mine.").utf8), executable: false)], replace: false)
        let id = try newSource(harness)
        github.tarball = try repoV1()
        let source = try await harness.skillSources.sync(id)
        XCTAssertEqual(source["last"]?["conflicts"], ["alpha"])
        XCTAssertTrue(harness.skills.content("alpha")?.contains("Mine.") == true)
        XCTAssertNil(harness.skillSources.managed("alpha"))
        XCTAssertNotNil(harness.skillSources.managed("beta"), "the rest is installed")
        // and a second source cannot take what the first keeps
        let other = try newSource(harness, ["repo": "acme/more"])
        let taken = try await harness.skillSources.sync(other)
        XCTAssertEqual(taken["last"]?["conflicts"], ["alpha", "beta"], "the user's own and the first source's")
        XCTAssertEqual(harness.skillSources.managed("beta")?.sourceId, id)
    }

    func testManagedSkillsAreNotEditedByHand() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        let edit = await call(harness, "PUT", "/api/skills/alpha", ["content": .string(manifest("alpha", "Edited."))])
        XCTAssertEqual(edit.status, 409)
        XCTAssertTrue(edit.json?["error"]?.string?.contains("GitHub source acme/skills") == true)
        let delete = await call(harness, "DELETE", "/api/skills/alpha")
        XCTAssertEqual(delete.status, 409)
        let replace = await call(harness, "POST", "/api/skills", ["replace": true, "files": [["path": "SKILL.md", "content": .string(Data(manifest("alpha").utf8).base64EncodedString())]]])
        XCTAssertEqual(replace.status, 409)
        XCTAssertTrue(harness.skills.content("alpha")?.contains("Do the thing.") == true)
        // a copy under another name is fine
        let copy = await call(harness, "POST", "/api/skills", ["files": [["path": "SKILL.md", "content": .string(Data(manifest("alpha-mine").utf8).base64EncodedString())]]])
        XCTAssertEqual(copy.status, 201)
    }

    // MARK: going back

    func testGoingBackBringsTheOldVersionAndDoesNotInstallTheBadOneAgain() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        let original = harness.skills.content("alpha")
        github.sha = String(repeating: "e", count: 40)
        github.tarball = try makeTarball(["skills/alpha/SKILL.md": manifest("alpha", "Broken in a way no check sees."), "skills/delta/SKILL.md": manifest("delta")])
        _ = try await harness.skillSources.sync(id)
        XCTAssertNotNil(harness.skills.skill("delta"))
        XCTAssertNil(harness.skills.skill("beta"))

        let back = try await harness.skillSources.rollback(id)
        XCTAssertEqual(back["installed"]?["shortSha"], "aaaaaaa")
        XCTAssertEqual(back["canRollback"], false)
        XCTAssertEqual(back["held"], true)
        XCTAssertEqual(harness.skills.content("alpha"), original)
        XCTAssertNotNil(harness.skills.skill("beta"), "what the update removed is back")
        XCTAssertNil(harness.skills.skill("delta"), "what the update added is gone")

        let downloads = github.downloads
        let later = try await harness.skillSources.sync(id)
        XCTAssertEqual(github.downloads, downloads, "the commit it went back from is not installed again")
        XCTAssertEqual(later["last"]?["held"], true)
        // the repository moves on, and updating resumes
        github.sha = String(repeating: "f", count: 40)
        github.tarball = try makeTarball(["skills/alpha/SKILL.md": manifest("alpha", "Fixed.")])
        let resumed = try await harness.skillSources.sync(id)
        XCTAssertEqual(resumed["installed"]?["shortSha"], "fffffff")
        XCTAssertEqual(resumed["held"], false)
        // forcing overrides the hold
        let again = try await harness.skillSources.rollback(id)
        XCTAssertEqual(again["installed"]?["shortSha"], "aaaaaaa")
        let forced = try await harness.skillSources.sync(id, force: true)
        XCTAssertEqual(forced["installed"]?["shortSha"], "fffffff")
        let throughRoute = await call(harness, "POST", "/api/skill-sources/\(id)/rollback", [:])
        XCTAssertEqual(throughRoute.status, 200, "the forced update kept the version before it")
        let nothingEarlier = await call(harness, "POST", "/api/skill-sources/\(id)/rollback", [:])
        XCTAssertEqual(nothingEarlier.status, 409, "and there is nothing earlier than that")
    }

    // MARK: failures

    func testGitHubsRefusalsAreSaidInPlainWords() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        for (status, expected) in [(401, "refused the token"), (404, "was not found, or the token cannot see it")] {
            github.failure = GitHubSkillFetcher.failure(status, repo: "acme/skills", ref: "main", limited: false)
            let source = try await harness.skillSources.sync(id)
            XCTAssertEqual(source["last"]?["ok"], false)
            XCTAssertTrue(source["last"]?["error"]?.string?.contains(expected) == true, "\(status): \(String(describing: source["last"]))")
        }
        XCTAssertTrue(GitHubSkillFetcher.failure(403, repo: "acme/skills", ref: "main", limited: true).message.contains("rate limit"))
        XCTAssertTrue(GitHubSkillFetcher.failure(403, repo: "acme/skills", ref: "main", limited: false).message.contains("read access to Contents"))
        github.failure = nil
        github.tarball = try repoV1()
        let ok = try await harness.skillSources.sync(id)
        XCTAssertEqual(ok["last"]?["ok"], true, "a failure does not stay: the next run is a new run")
    }

    func testASourceThatIsRemovedTakesItsSkillsWithIt() async throws {
        let harness = try engine()
        let id = try newSource(harness)
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        XCTAssertEqual(harness.skills.list().count, 2)
        let gone = await call(harness, "DELETE", "/api/skill-sources/\(id)")
        XCTAssertEqual(gone.status, 200)
        XCTAssertTrue(harness.skills.list().isEmpty)
        let again = await call(harness, "DELETE", "/api/skill-sources/\(id)")
        XCTAssertEqual(again.status, 404)
    }

    func testTheRoutesCreateUpdateAndSync() async throws {
        let harness = try engine()
        github.tarball = try repoV1()
        let unsafe = await call(harness, "POST", "/api/skill-sources", ["repo": "acme/skills", "path": "../x"])
        XCTAssertEqual(unsafe.status, 400)
        let created = await call(harness, "POST", "/api/skill-sources", ["repo": "acme/skills", "name": "Team skills"])
        XCTAssertEqual(created.status, 201, String(describing: created.json))
        let id = try XCTUnwrap(created.json?["source"]?["id"]?.string)
        XCTAssertEqual(created.json?["source"]?["name"], "Team skills")
        let renamed = await call(harness, "PATCH", "/api/skill-sources/\(id)", ["ref": "develop", "enabled": false])
        XCTAssertEqual(renamed.json?["source"]?["ref"], "develop")
        XCTAssertEqual(renamed.json?["source"]?["enabled"], false)
        let synced = await call(harness, "POST", "/api/skill-sources/\(id)/update", ["force": true])
        XCTAssertEqual(synced.status, 200)
        XCTAssertEqual(synced.json?["source"]?["last"]?["ok"], true)
        let unknown = await call(harness, "POST", "/api/skill-sources/nope/update", [:])
        XCTAssertEqual(unknown.status, 404)
        let plain = HTTPRequest(method: "POST", path: "/api/skill-sources", query: [:], headers: [:], body: Data(#"{"repo":"a/b"}"#.utf8))
        guard case let .response(refused) = await Routes(harness: harness).handle(plain) else { return XCTFail("not a response") }
        XCTAssertEqual(refused.status, 415)
    }

    func testRequirementsThatAreMissingAreListed() async throws {
        let harness = try engine()
        let id = try newSource(harness, ["requires": ["commands": ["sh", "definitely-not-a-command-xyz"], "connectors": ["clickup"]]])
        let source = try await harness.skillSources.wire(id)
        let missing = source["missing"]?.array?.compactMap { $0["name"]?.string } ?? []
        XCTAssertEqual(missing.sorted(), ["clickup", "definitely-not-a-command-xyz"], "sh is there, the rest is not")
    }

    // MARK: who gets them

    func testSkillsOfASourceGoToTheBotsItIsAssignedTo() async throws {
        let harness = try engine()
        let alice = harness.store.createBot(seedMessages: false)["id"]!.string!
        let bob = harness.store.createBot(seedMessages: false)["id"]!.string!
        let id = try newSource(harness, ["assign": ["botIds": [.string(alice)]]])
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        func names(_ botId: String) -> [String] {
            Skills.active(bot: harness.skillSources.augment(harness.store.bot(botId)!), task: nil) { harness.skills.skill($0) != nil }
        }
        XCTAssertEqual(names(alice), ["alpha", "beta"])
        XCTAssertEqual(names(bob), [], "not assigned")
        _ = try harness.skillSources.update(id, ["assign": ["all": true]])
        XCTAssertEqual(names(bob), ["alpha", "beta"], "assigned to every bot")
        _ = try harness.skillSources.update(id, ["assign": ["all": false, "botIds": []]])
        try harness.skillSources.assign(botIds: [bob, "ghost"], to: id)
        XCTAssertEqual(names(bob), ["alpha", "beta"], "a plugin can hand them to a bot, and an unknown bot is ignored")
        XCTAssertEqual(names(alice), [])
        // a bot that switched one off keeps it off
        harness.store.patchBot(bob, ["skills": [["id": "alpha", "defaultOn": false]]])
        XCTAssertEqual(names(bob), ["beta"])
        // `/name` works for what is assigned
        XCTAssertEqual(Skills.invoked("please /alpha now", bot: harness.skillSources.augment(harness.store.bot(bob)!)), ["alpha"])
        _ = try harness.skillSources.update(id, ["enabled": false])
        XCTAssertEqual(names(bob), [], "a source that is off hands out nothing")
        _ = harness.store.deleteBot(bob)
        harness.skillSources.forgetBot(bob)
        XCTAssertEqual(harness.skillSources.sources.first?.assignBots, [])
    }

    // MARK: channels

    func testAChannelMembersTurnGetsItsSkills() async throws {
        let adapter = SkillFakeAdapter()
        let harness = try Harness(paths: DataPaths(root: scratch.appendingPathComponent("room", isDirectory: true)), environment: ProcessInfo.processInfo.environment,
                                  drivers: [SkillFakeDriver(adapter: adapter)])
        await harness.boot()
        let skilled = harness.store.createBot(seedMessages: false)["id"]!.string!
        let plain = harness.store.createBot(seedMessages: false)["id"]!.string!
        let selection: JSON = ["instanceId": "claude", "model": "fake-1"]
        harness.store.patchBot(skilled, ["modelSelection": selection, "name": "Skilled"])
        harness.store.patchBot(plain, ["modelSelection": selection, "name": "Plain"])
        let id = try newSource(harness, ["assign": ["botIds": [.string(skilled)]]])
        github.tarball = try repoV1()
        _ = try await harness.skillSources.sync(id)
        let group = harness.store.createGroup(name: "Team", memberIds: [skilled, plain])
        let groupId = group["id"]!.string!

        try harness.startGroupTurn(groupId: groupId, text: "@Skilled /alpha do it")
        for _ in 0..<200 where adapter.received.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        let input = try XCTUnwrap(adapter.received.first)
        XCTAssertTrue(input.text.hasPrefix("[The user called /alpha for this message."), String(input.text.prefix(120)))
        XCTAssertTrue(input.text.contains("Do the thing."), "the skill's whole text is in the turn")
        XCTAssertTrue(input.system?.contains("Skills available in this chat") == true, "and the other skills are an index")
        XCTAssertTrue(input.system?.contains("- beta:") == true)
        XCTAssertFalse(input.system?.contains("- alpha:") == true, "the one called is not also listed")
        for _ in 0..<200 where harness.store.group(groupId)?["busyBotId"]?.string != nil { try await Task.sleep(nanoseconds: 25_000_000) }

        // a member with no skills, spoken to the same way, gets none
        try harness.startGroupTurn(groupId: groupId, text: "@Plain /alpha do it")
        for _ in 0..<200 where adapter.received.count < 2 { try await Task.sleep(nanoseconds: 25_000_000) }
        let second = try XCTUnwrap(adapter.received.last)
        XCTAssertFalse(second.text.contains("The user called"))
        XCTAssertFalse(second.system?.contains("Skills available") == true)
    }
}

// MARK: - a model that only answers

@MainActor
final class SkillFakeAdapter: ProviderAdapter {
    let provider = "claudeAgent"
    var capabilities = AdapterCapabilities()
    private let emitter = EventEmitter()
    private(set) var received: [SendTurnInput] = []

    func sendTurn(_ input: SendTurnInput) async throws -> String {
        received.append(input)
        for body: RuntimeEvent.Body in [.turnStarted, .textCompleted(text: "ok"), .turnCompleted(ok: true, stopReason: nil, cost: nil, denials: nil, usage: nil)] {
            emitter.emit(RuntimeEvent(provider: provider, providerInstanceId: "claude", threadId: input.threadId, requestId: nil, body))
        }
        return "turn"
    }

    func interruptTurn(threadId: ThreadID) async {}
    func respond(threadId: ThreadID, requestId: String, decision: RequestDecision) async -> RequestOutcome { .rejected }
    func hasSession(threadId: ThreadID) -> Bool { false }
    func stopAll() async {}

    @discardableResult
    func onEvent(_ listener: @escaping RuntimeEventListener) -> () -> Void { emitter.add(listener) }
}

@MainActor
final class SkillFakeInstance: ProviderInstance {
    let instanceId: InstanceID
    let driverKind = "claudeAgent"
    let displayName: String? = "Fake"
    let enabled = true
    let models = ModelCatalog(default: "fake-1", options: [ModelOption(id: "fake-1", label: "Fake 1")])
    let adapter: ProviderAdapter

    init(instanceId: InstanceID, adapter: ProviderAdapter) {
        self.instanceId = instanceId
        self.adapter = adapter
    }

    func refreshModels() async {}
    func snapshot() async -> ProviderSnapshot { .available(version: "0") }
    func dispose() async {}
}

@MainActor
struct SkillFakeDriver: ProviderDriver {
    let adapter: SkillFakeAdapter
    var driverKind: String { "claudeAgent" }
    var displayName: String { "Fake" }
    var access: String { "subscription" }

    func create(_ input: DriverCreateInput) async throws -> ProviderInstance {
        SkillFakeInstance(instanceId: input.instanceId, adapter: adapter)
    }
}
