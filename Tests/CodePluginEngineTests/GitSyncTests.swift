@testable import CodePluginEngine
@testable import HarnessCore
import XCTest

/// Commits ahead and behind the branch's upstream, and fetch, pull and push: run by the engine, in the chat's folder.
@MainActor
final class GitSyncTests: XCTestCase {
    /// A repository whose `main` follows `origin/main` (a bare repository next to it), and a colleague's clone of it.
    private func pushedRepo() async throws -> (repo: RepoFixture, bare: URL, colleague: URL) {
        let repo = try await RepoFixture()
        let bare = repo.paths.root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try repo.git("init", "-q", "--bare", "-b", "main", in: bare)
        try repo.initRepo()
        try repo.git("remote", "add", "origin", bare.path)
        try repo.git("push", "-q", "-u", "origin", "main")
        let colleague = repo.paths.root.appendingPathComponent("colleague", isDirectory: true)
        try repo.git("clone", "-q", bare.path, colleague.path, in: repo.paths.root)
        return (repo, bare, colleague)
    }

    private func colleagueCommits(_ repo: RepoFixture, _ clone: URL, file: String, text: String) throws {
        try Data(text.utf8).write(to: clone.appendingPathComponent(file))
        try repo.git("add", ".", in: clone)
        try repo.git("commit", "-qm", "colleague: \(file)", in: clone)
        try repo.git("push", "-q", "origin", "main", in: clone)
    }

    private func head(_ repo: RepoFixture) throws -> String {
        try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: ahead and behind

    func testTheStateCountsCommitsAheadAndBehindItsUpstreamAsOfTheLastFetch() async throws {
        let (repo, _, colleague) = try await pushedRepo()
        var state = await repo.call("GET", "git")
        XCTAssertEqual(state.json?["upstream"], "origin/main")
        XCTAssertEqual(state.json?["ahead"], 0)
        XCTAssertEqual(state.json?["behind"], 0)

        try repo.write("mine.txt", "mine\n")
        try repo.git("add", ".")
        try repo.git("commit", "-qm", "mine")
        state = await repo.call("GET", "git")
        XCTAssertEqual(state.json?["ahead"], 1)
        XCTAssertEqual(state.json?["behind"], 0)

        try colleagueCommits(repo, colleague, file: "theirs.txt", text: "theirs\n")
        state = await repo.call("GET", "git")
        XCTAssertEqual(state.json?["behind"], 0, "the remote's news is not known until it is fetched")
        let fetched = await repo.call("POST", "git/fetch", body: [:])
        XCTAssertEqual(fetched.status, 200, String(describing: fetched.json))
        XCTAssertEqual(fetched.json?["behind"], 1)
        XCTAssertEqual(fetched.json?["ahead"], 1)
        XCTAssertEqual(try repo.git("status", "--porcelain").trimmingCharacters(in: .whitespacesAndNewlines), "", "fetching changes no file")
    }

    func testABranchThatFollowsNothingHasNoCounts() async throws {
        let repo = try await RepoFixture()
        try repo.initRepo()
        let state = await repo.call("GET", "git")
        XCTAssertEqual(state.status, 200)
        XCTAssertNil(state.json?["upstream"])
        XCTAssertNil(state.json?["ahead"])
        XCTAssertNil(state.json?["behind"])
        let fetch = await repo.call("POST", "git/fetch", body: [:])
        XCTAssertEqual(fetch.status, 409, "no remote to fetch from")
        let pull = await repo.call("POST", "git/pull", body: [:])
        XCTAssertEqual(pull.status, 400)
        XCTAssertTrue(pull.json?["error"]?.string?.contains("follows no remote branch") == true, String(describing: pull.json))
    }

    // MARK: pull

    func testPullBringsWhatTheColleaguePushedAndOnlyByFastForward() async throws {
        let (repo, _, colleague) = try await pushedRepo()
        try colleagueCommits(repo, colleague, file: "theirs.txt", text: "theirs\n")
        _ = await repo.call("POST", "git/fetch", body: [:])
        let pulled = await repo.call("POST", "git/pull", body: [:])
        XCTAssertEqual(pulled.status, 200, String(describing: pulled.json))
        XCTAssertEqual(pulled.json?["behind"], 0)
        XCTAssertEqual(pulled.json?["ahead"], 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.folder.appendingPathComponent("theirs.txt").path))
        // nothing new: a pull that does nothing is still fine
        let again = await repo.call("POST", "git/pull", body: [:])
        XCTAssertEqual(again.status, 200)
    }

    func testPullRefusesWhatWouldNeedAMergeAndLeavesTheBranchAlone() async throws {
        let (repo, _, colleague) = try await pushedRepo()
        try repo.write("mine.txt", "mine\n")
        try repo.git("add", ".")
        try repo.git("commit", "-qm", "mine")
        try colleagueCommits(repo, colleague, file: "theirs.txt", text: "theirs\n")
        _ = await repo.call("POST", "git/fetch", body: [:])
        let before = try head(repo)
        let pulled = await repo.call("POST", "git/pull", body: [:])
        XCTAssertEqual(pulled.status, 409, String(describing: pulled.json))
        XCTAssertTrue(pulled.json?["error"]?.string?.lowercased().contains("fast-forward") == true, String(describing: pulled.json))
        XCTAssertEqual(try head(repo), before, "no merge, no rebase")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder.appendingPathComponent("theirs.txt").path))
    }

    func testPullWaitsForABotThatIsWorking() async throws {
        let (repo, _, colleague) = try await pushedRepo()
        try colleagueCommits(repo, colleague, file: "theirs.txt", text: "theirs\n")
        _ = await repo.call("POST", "git/fetch", body: [:])
        repo.harness.store.patchBot(repo.botId, ["busy": true])
        let refused = await repo.call("POST", "git/pull", body: [:])
        XCTAssertEqual(refused.status, 409)
        XCTAssertTrue(refused.json?["error"]?.string?.contains("a bot is working") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.folder.appendingPathComponent("theirs.txt").path))
        let fetch = await repo.call("POST", "git/fetch", body: [:])
        XCTAssertEqual(fetch.status, 200, "fetching does not touch the tree: a bot may be working")
    }

    // MARK: push

    func testPushSendsTheCommitsAndSetsTheUpstreamOfANewBranch() async throws {
        let (repo, bare, _) = try await pushedRepo()
        try repo.write("mine.txt", "mine\n")
        try repo.git("add", ".")
        try repo.git("commit", "-qm", "mine")
        let pushed = await repo.call("POST", "git/push", body: [:])
        XCTAssertEqual(pushed.status, 200, String(describing: pushed.json))
        XCTAssertEqual(pushed.json?["ahead"], 0)
        XCTAssertEqual(try repo.git("rev-parse", "main", in: bare).trimmingCharacters(in: .whitespacesAndNewlines), try head(repo))

        try repo.git("checkout", "-q", "-b", "feature/x")
        try repo.write("x.txt", "x\n")
        try repo.git("add", ".")
        try repo.git("commit", "-qm", "x")
        let before = await repo.call("GET", "git")
        XCTAssertNil(before.json?["upstream"], "a new branch follows nothing yet")
        let first = await repo.call("POST", "git/push", body: [:])
        XCTAssertEqual(first.status, 200, String(describing: first.json))
        XCTAssertEqual(first.json?["upstream"], "origin/feature/x")
        XCTAssertEqual(first.json?["ahead"], 0)
    }

    func testPushSaysWhyItFailed() async throws {
        let (repo, _, colleague) = try await pushedRepo()
        try repo.write("mine.txt", "mine\n")
        try repo.git("add", ".")
        try repo.git("commit", "-qm", "mine")
        try colleagueCommits(repo, colleague, file: "theirs.txt", text: "theirs\n")
        let rejected = await repo.call("POST", "git/push", body: [:])
        XCTAssertEqual(rejected.status, 409, "the remote has commits we do not")
        XCTAssertFalse((rejected.json?["error"]?.string ?? "").isEmpty)
    }

    // MARK: what it is not for

    func testADetachedHeadAndAFolderThatIsNotARepoHaveNothingToSync() async throws {
        let (repo, _, _) = try await pushedRepo()
        try repo.git("checkout", "-q", "--detach")
        for action in ["pull", "push"] {
            let answer = await repo.call("POST", "git/\(action)", body: [:])
            XCTAssertEqual(answer.status, 400, action)
        }
        let plain = try await RepoFixture()
        for action in ["fetch", "pull", "push"] {
            let answer = await plain.call("POST", "git/\(action)", body: [:])
            XCTAssertEqual(answer.status, 400, action)
        }
        let unknown = await repo.callRaw("POST", "/api/threads/nope/git/pull", body: [:])
        XCTAssertEqual(unknown.status, 404)
        let plugins = await repo.callRaw("GET", "/api/plugins")
        XCTAssertEqual(plugins.json?["plugins"]?.array?.first { $0["id"] == "code" }?["version"], "1.6.0")
    }
}
