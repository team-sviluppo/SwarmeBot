@testable import CodePluginApp
@testable import SwarmeKit
import XCTest

final class CodePickerTests: XCTestCase {
    private func branch(_ name: String, remote: Bool = false, date: Double? = nil) -> GitBranch {
        GitBranch(ref: (remote ? "refs/remotes/" : "refs/heads/") + name, name: name, remote: remote, date: date)
    }

    func testBranchesDecodeWithAndWithoutADate() throws {
        let json = #"{"ref":"refs/heads/a","name":"a","remote":false,"date":1700000000}"#
        XCTAssertEqual(try JSONDecoder().decode(GitBranch.self, from: Data(json.utf8)).date, 1_700_000_000)
        let old = #"{"ref":"refs/heads/a","name":"a","remote":false}"#
        XCTAssertNil(try JSONDecoder().decode(GitBranch.self, from: Data(old.utf8)).date, "an older engine sends none")
    }

    func testTheNewestLocalBranchesComeFirstWithoutTheCurrentOne() {
        let all = ["cur", "b1", "b2", "b3", "b4", "b5", "b6", "b7"].map { branch($0) } + [branch("origin/x", remote: true)]
        let sections = BranchSections(all, current: "cur", searching: false)
        XCTAssertEqual(sections.recent.map(\.name), ["b1", "b2", "b3", "b4", "b5"])
        XCTAssertEqual(sections.local.map(\.name), ["cur", "b6", "b7"], "the current one stays where the check mark can find it")
        XCTAssertEqual(sections.remote.map(\.name), ["origin/x"])
    }

    func testSearchingDropsTheRecentShortcut() {
        let all = ["cur", "b1", "b2"].map { branch($0) }
        let sections = BranchSections(all, current: "cur", searching: true)
        XCTAssertTrue(sections.recent.isEmpty)
        XCTAssertEqual(sections.local.map(\.name), ["cur", "b1", "b2"])
    }

    func testADetachedHeadHasNoCurrentBranchToLeaveOut() {
        let all = ["a", "b"].map { branch($0) }
        XCTAssertEqual(BranchSections(all, current: nil, searching: false).recent.map(\.name), ["a", "b"])
    }

    func testAnEmptyListHasNoSections() {
        XCTAssertEqual(BranchSections([], current: "main", searching: false), BranchSections([], current: nil, searching: true))
    }

    func testRemoteFoldersOpenInVSCodeAndCursorOverSSH() {
        let identity = SSHIdentity(id: "i", host: "srv.example.it", port: 22, user: "bot", hostKey: nil, keyInstalledAt: nil, createdAt: Date())
        XCTAssertEqual(EditorApp.vscode.remoteURL(identity: identity, folder: "/srv/my app")?.absoluteString,
                       "vscode://vscode-remote/ssh-remote+bot@srv.example.it/srv/my%20app")
        XCTAssertEqual(EditorApp.cursor.remoteURL(identity: identity, folder: "/srv/api")?.absoluteString,
                       "cursor://vscode-remote/ssh-remote+bot@srv.example.it/srv/api")
        XCTAssertNil(EditorApp.zed.remoteURL(identity: identity, folder: "/srv/api"))
        XCTAssertNil(EditorApp.xcode.remoteURL(identity: identity, folder: "/srv/api"))
        XCTAssertEqual(EditorApp.allCases.filter(\.opensServerFolders), [.vscode, .cursor])
    }

    func testAnotherSSHPortTravelsAsHexJSON() throws {
        let identity = SSHIdentity(id: "i", host: "h.example.it", port: 2222, user: "u", hostKey: nil, keyInstalledAt: nil, createdAt: Date())
        let url = try XCTUnwrap(EditorApp.vscode.remoteURL(identity: identity, folder: "/p"))
        let host = url.absoluteString.replacingOccurrences(of: "vscode://vscode-remote/ssh-remote+", with: "").replacingOccurrences(of: "/p", with: "")
        let bytes = stride(from: 0, to: host.count, by: 2).map { UInt8(host.dropFirst($0).prefix(2), radix: 16)! }
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"{"hostName":"h.example.it","user":"u","port":2222}"#)
    }

    func testTheEditorsKnowTheirApps() {
        XCTAssertEqual(EditorApp.allCases.map(\.name), ["VS Code", "Cursor", "Zed", "Xcode"])
        XCTAssertEqual(Set(EditorApp.allCases.map(\.bundleId)).count, 4)
    }

    func testResumeAnswersDecode() throws {
        let yes = try JSONDecoder().decode(ResumeCommand.self, from: Data(#"{"supported":true,"tool":"claude","folder":"/p","command":"x"}"#.utf8))
        XCTAssertTrue(yes.supported)
        XCTAssertEqual(yes.command, "x")
        let no = try JSONDecoder().decode(ResumeCommand.self, from: Data(#"{"supported":false,"reason":"no session"}"#.utf8))
        XCTAssertFalse(no.supported)
        XCTAssertEqual(no.reason, "no session")
    }
}
