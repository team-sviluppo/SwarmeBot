@testable import CodePluginApp
import XCTest

// What the Code plugin's engine routes answer: the folder's git state.
final class CodeWireTests: XCTestCase {
    func testDecodesARepoWithItsChanges() throws {
        let json = #"{"repo":true,"root":"/p","branch":"main","detached":false,"changes":[{"path":"/p/a.swift","name":"a.swift","status":"M","bytes":12},{"path":"/p/b.swift","name":"b.swift","status":"D","bytes":0}]}"#
        let state = try JSONDecoder().decode(ThreadGitState.self, from: Data(json.utf8))
        XCTAssertTrue(state.repo)
        XCTAssertEqual(state.branch, "main")
        XCTAssertEqual(state.changes.map(\.name), ["a.swift", "b.swift"])
        XCTAssertEqual(state.changes.map(\.exists), [true, false])
        XCTAssertEqual(state.changes[0].file.path, "/p/a.swift")
    }

    func testAFolderOutsideARepoHasNoBranchAndNoChanges() throws {
        let state = try JSONDecoder().decode(ThreadGitState.self, from: Data(#"{"repo":false}"#.utf8))
        XCTAssertFalse(state.repo)
        XCTAssertNil(state.branch)
        XCTAssertTrue(state.changes.isEmpty)
    }
}
