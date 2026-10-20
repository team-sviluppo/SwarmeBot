import SQLite3
@testable import SwarmeKit
import XCTest

final class ServerAgentsTests: XCTestCase {
    func testOmpVersionAndReleaseBuild() {
        XCTAssertEqual(OmpConfig.version("omp/18.12.3\n"), "18.12.3")
        XCTAssertEqual(OmpConfig.version("18.12.3"), "18.12.3")
        XCTAssertNil(OmpConfig.version("omp/18.12.3; rm -rf ~"))
        XCTAssertNil(OmpConfig.version(""))
        XCTAssertEqual(OmpConfig.asset(for: RemoteProbe(values: ["os": "ubuntu", "arch": "x86_64"])), "omp-linux-x64")
        XCTAssertEqual(OmpConfig.asset(for: RemoteProbe(values: ["os": "ubuntu", "arch": "aarch64"])), "omp-linux-arm64")
        XCTAssertEqual(OmpConfig.asset(for: RemoteProbe(values: ["os": "macos", "arch": "arm64"])), "omp-darwin-arm64")
        XCTAssertNil(OmpConfig.asset(for: RemoteProbe(values: ["os": "ubuntu", "arch": "riscv64"])))
    }

    func testClaudeTokenShape() {
        XCTAssertEqual(try ServerClaudeToken.validated(" sk-ant-oat01-abc\n"), "sk-ant-oat01-abc")
        XCTAssertThrowsError(try ServerClaudeToken.validated("sk-ant- two words"))
        XCTAssertThrowsError(try ServerClaudeToken.validated("ghp_123"))
    }

    /// omp keeps agent.db open in WAL mode: the copy must carry what is still only in the WAL.
    func testAgentDBSnapshotIncludesTheWAL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0",
                    "CREATE TABLE auth_credentials (provider TEXT)", "INSERT INTO auth_credentials VALUES ('litellm')"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        // still open: the row is in agent.db-wal, not yet in agent.db
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: file.path + "-wal")[.size] as? Int) ?? 0, 0)

        let copy = dir.appendingPathComponent("copy.db")
        try OmpConfig.snapshot(file).write(to: copy)
        var read: OpaquePointer?
        XCTAssertEqual(sqlite3_open(copy.path, &read), SQLITE_OK) // as omp opens it
        defer { sqlite3_close(read) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(read, "SELECT provider FROM auth_credentials", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "litellm")
    }
}
