@testable import CodePluginApp
import CompanionCore
import XCTest

// Plan mode, the review by another bot and the pull request, as the app reads them. The JSON is what the
// engine's routes answer (Plugins/Code/Engine/CodePullRequests.swift, CodeReviews.swift).
@MainActor
final class CodePhaseFourTests: XCTestCase {
    private let failing = """
        {"available":true,"pr":{"number":7,"url":"https://github.com/o/r/pull/7","title":"Add login","state":"open","draft":false,\
        "base":"main","head":"feature","comments":2,"merge":"blocked","mergeable":"mergeable","reviewDecision":"changes_requested","author":"me",\
        "checks":{"state":"failure","total":3,"passed":1,"failed":1,"pending":1,"items":[\
        {"name":"build","state":"success","workflow":"CI","url":"https://github.com/o/r/actions/runs/1/job/1"},\
        {"name":"test","state":"failure","workflow":"CI","url":"https://github.com/o/r/actions/runs/1/job/2"},\
        {"name":"deploy/preview","state":"pending"}]}}}
        """

    private func status(_ json: String) throws -> CodePullRequestStatus {
        try JSONDecoder().decode(CodePullRequestStatus.self, from: Data(json.utf8))
    }

    func testThePullRequestIsReadAsTheEngineFoldsIt() throws {
        let pr = try XCTUnwrap(status(failing).pr)
        XCTAssertEqual(pr.number, 7)
        XCTAssertEqual(pr.head, "feature")
        XCTAssertEqual(pr.comments, 2)
        XCTAssertEqual(pr.checks.failed, 1)
        XCTAssertEqual(pr.checks.items.map(\.state), ["success", "failure", "pending"])
        XCTAssertEqual(pr.checks.items[1].title, "CI / test")
        XCTAssertEqual(pr.checks.items[2].title, "deploy/preview", "a status with no workflow is just its name")
        XCTAssertTrue(pr.isOpen)
    }

    func testNoPullRequestAndNoGhAreBothNothingToShow() throws {
        let none = try status(#"{"available":true,"pr":null}"#)
        XCTAssertNil(none.pr)
        XCTAssertTrue(none.available)
        let missing = try status(#"{"available":false,"reason":"the GitHub CLI (gh) is not installed on this machine","pr":null}"#)
        XCTAssertFalse(missing.available)
        XCTAssertNil(missing.pr)
        XCTAssertTrue(missing.reason?.contains("not installed") == true)
    }

    func testTheChipSaysWhatTheChecksSay() throws {
        func look(_ checks: String, state: String = "open", draft: Bool = false) throws -> PullRequestLook.Look {
            let json = #"{"available":true,"pr":{"number":1,"url":"u","title":"t","state":"\#(state)","draft":\#(draft),"comments":0,"checks":{"state":"\#(checks)","total":1,"passed":0,"failed":2,"pending":0,"items":[]}}}"#
            return PullRequestLook.look(try XCTUnwrap(status(json).pr))
        }
        XCTAssertEqual(try look("success").tint, .ok)
        XCTAssertEqual(try look("failure").tint, .bad)
        XCTAssertEqual(try look("pending").tint, .wait)
        XCTAssertEqual(try look("none").tint, .quiet)
        XCTAssertEqual(try look("failure", state: "merged").tint, .merged, "a merged pull request is not a failing one")
        XCTAssertEqual(try look("failure", state: "closed").tint, .quiet)
        XCTAssertEqual(try look("success", draft: true).tint, .quiet, "a draft is a draft whatever the checks say")
        XCTAssertEqual(PullRequestLook.checkIcon("failure").1, .bad)
        XCTAssertEqual(PullRequestLook.checkIcon("skipped").1, .quiet)
    }

    func testMergeProblemsAreNamed() throws {
        func note(mergeable: String?, merge: String?) throws -> String? {
            let extras = (mergeable.map { #","mergeable":"\#($0)""# } ?? "") + (merge.map { #","merge":"\#($0)""# } ?? "")
            let json = #"{"available":true,"pr":{"number":1,"url":"u","title":"t","state":"open","draft":false,"base":"main","comments":0\#(extras),"checks":{"state":"none","total":0,"passed":0,"failed":0,"pending":0,"items":[]}}}"#
            return PullRequestLook.mergeNote(try XCTUnwrap(status(json).pr))
        }
        XCTAssertNotNil(try note(mergeable: "conflicting", merge: "dirty"))
        XCTAssertNotNil(try note(mergeable: nil, merge: "behind"))
        XCTAssertNil(try note(mergeable: "mergeable", merge: "clean"))
        XCTAssertNil(try note(mergeable: nil, merge: nil))
    }

    func testGitHubIsAskedAgainSoonWhileChecksRunAndRarelyWhenThereIsNothingToWaitFor() throws {
        XCTAssertEqual(CodeState.pollInterval(try status(failing)), .seconds(120))
        let pending = try status(failing.replacingOccurrences(of: #""state":"failure","total""#, with: #""state":"pending","total""#))
        XCTAssertEqual(CodeState.pollInterval(pending), .seconds(30))
        XCTAssertEqual(CodeState.pollInterval(try status(#"{"available":true,"pr":null}"#)), .seconds(180))
        XCTAssertEqual(CodeState.pollInterval(try status(#"{"available":false,"pr":null}"#)), .seconds(600), "without gh there is nothing to wait for")
        XCTAssertEqual(CodeState.pollInterval(nil), .seconds(600))
        let merged = try status(failing.replacingOccurrences(of: #""state":"open""#, with: #""state":"merged""#))
        XCTAssertEqual(CodeState.pollInterval(merged), .seconds(900))
    }

    func testAReviewRunIsReadWithItsReviewerAndItsEnd() throws {
        let json = #"{"id":"r1","reviewerId":"b2","reviewerName":"Revisore","reviewerThread":"t9","status":"running","branch":"feature","scope":"changes","startedAt":1}"#
        let run = try JSONDecoder().decode(CodeReviewRun.self, from: Data(json.utf8))
        XCTAssertTrue(run.running)
        XCTAssertEqual(run.reviewerName, "Revisore")
        let failed = try JSONDecoder().decode(CodeReviewRun.self, from: Data(#"{"id":"r1","reviewerId":"b2","reviewerName":"R","reviewerThread":"t","status":"failed","error":"model is down","startedAt":1,"finishedAt":2}"#.utf8))
        XCTAssertFalse(failed.running)
        XCTAssertEqual(failed.error, "model is down")
    }

    func testApplyingAReviewTellsTheBotWhoWrotePointByPoint() {
        let text = CodeState.reviewMessage(reviewer: "@Revisore", review: "a.txt:1 — hard-coded")
        XCTAssertTrue(text.hasPrefix("@Revisore reviewed your changes."))
        XCTAssertTrue(text.contains("a.txt:1 — hard-coded"))
        XCTAssertTrue(text.contains("what you would not change and why"), "it may push back, not only comply")
    }

    func testAMessageCarriesItsReviewMarkAndOthersDoNot() throws {
        let review = try JSONDecoder().decode(Message.self, from: Data(#"{"id":"m1","role":"bot","kind":"text","text":"Verdict","at":1,"from":{"botId":"b2","name":"Revisore","color":"blue"},"review":{"applied":false}}"#.utf8))
        XCTAssertEqual(review.review?.applied, false)
        XCTAssertEqual(review.from?.name, "Revisore")
        let plain = try JSONDecoder().decode(Message.self, from: Data(#"{"id":"m2","role":"bot","kind":"text","text":"x","at":1}"#.utf8))
        XCTAssertNil(plain.review)
        let applied = try JSONDecoder().decode(Message.self, from: Data(#"{"id":"m3","role":"bot","kind":"text","text":"x","at":1,"review":{"applied":true}}"#.utf8))
        XCTAssertEqual(applied.review?.applied, true)
    }

    func testTheEngineVersionThatHasPhaseFourIsOneDotFiveAndLater() {
        XCTAssertTrue(CodeState.version("1.5.0", atLeast: "1.5.0"))
        XCTAssertTrue(CodeState.version("1.10.0", atLeast: "1.5.0"))
        XCTAssertFalse(CodeState.version("1.4.0", atLeast: "1.5.0"))
    }

    // MARK: ahead, behind and syncing

    func testTheStateReadsWhatItFollowsAndHowFarApart() throws {
        let following = try JSONDecoder().decode(ThreadGitState.self, from: Data(#"{"repo":true,"root":"/p","branch":"main","detached":false,"changes":[],"upstream":"origin/main","ahead":2,"behind":1}"#.utf8))
        XCTAssertEqual(following.upstream, "origin/main")
        XCTAssertEqual(following.ahead, 2)
        XCTAssertEqual(following.behind, 1)
        let alone = try JSONDecoder().decode(ThreadGitState.self, from: Data(#"{"repo":true,"root":"/p","branch":"feature","detached":false,"changes":[]}"#.utf8))
        XCTAssertNil(alone.upstream, "a branch that follows nothing, or an engine before 1.6.0")
        XCTAssertNil(alone.ahead)
        XCTAssertNil(alone.behind)
    }

    func testSyncBringsBeforeItSendsAndDoesNothingWhenInStep() {
        XCTAssertEqual(GitSyncPlan.steps(ahead: 0, behind: 0), [])
        XCTAssertEqual(GitSyncPlan.steps(ahead: 3, behind: 0), [.push])
        XCTAssertEqual(GitSyncPlan.steps(ahead: 0, behind: 2), [.pull])
        XCTAssertEqual(GitSyncPlan.steps(ahead: 1, behind: 1), [.pull, .push], "a push of a branch that is behind would be refused")
        XCTAssertEqual(GitSyncPlan.Step.pull.rawValue, "pull", "the engine's route")
        XCTAssertEqual(GitSyncPlan.Step.push.rawValue, "push")
    }

    func testTheEngineVersionWithGitSyncIsOneDotSixAndLater() {
        XCTAssertTrue(CodeState.version("1.6.0", atLeast: "1.6.0"))
        XCTAssertTrue(CodeState.version("1.10.0", atLeast: "1.6.0"))
        XCTAssertFalse(CodeState.version("1.5.0", atLeast: "1.6.0"))
    }
}

