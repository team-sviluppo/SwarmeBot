import SQLite3
@testable import SwarmeKit
import XCTest

final class ServerAgentsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func script(_ script: String, home: URL, arguments: [String] = [], stdin: Data? = nil,
                        extra: [String: String] = [:]) async throws -> ProcessRunner.Result {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env.merge(extra) { _, new in new }
        return try await ProcessRunner.run("/bin/sh", ["-c", script, "sh"] + arguments, stdin: stdin, environment: env)
    }

    func testCodexReleaseMatchesServerArchitecture() throws {
        for (os, arch, asset) in [
            ("ubuntu", "x86_64", "codex-x86_64-unknown-linux-musl"),
            ("ubuntu", "aarch64", "codex-aarch64-unknown-linux-musl"),
            ("macos", "arm64", "codex-aarch64-apple-darwin"),
            ("macos", "x86_64", "codex-x86_64-apple-darwin")
        ] {
            let release = try XCTUnwrap(CodexConfig.release(for: RemoteProbe(values: ["os": os, "arch": arch])))
            XCTAssertEqual(release.asset, asset)
            XCTAssertEqual(release.sha256.count, 64)
        }
        XCTAssertNil(CodexConfig.release(for: RemoteProbe(values: ["os": "ubuntu", "arch": "riscv64"])))
        XCTAssertEqual(RemoteProbe(values: ["codex": "codex-cli 0.165.0"]).codex, "codex-cli 0.165.0")
        XCTAssertNil(LocalAgents.none.codexDirectory)
    }

    func testCodexLoginValidationPreservesDataAndRejectsMissingOrInvalidCredentials() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("auth.json")
        XCTAssertThrowsError(try CodexConfig.login(from: dir))
        for value in [#"{"tokens":{"access_token":"test-access","refresh_token":"test-refresh"},"future":true}"#,
                      #"{"OPENAI_API_KEY":"test-key"}"#] {
            let data = Data(value.utf8)
            try data.write(to: file)
            XCTAssertEqual(try CodexConfig.login(from: dir), data)
        }
        for value in ["not-json-test-secret", "{}", #"{"tokens":{"access_token":" "}}"#, #"{"OPENAI_API_KEY":null}"#] {
            try Data(value.utf8).write(to: file)
            XCTAssertThrowsError(try CodexConfig.login(from: dir)) { error in
                XCTAssertFalse(error.localizedDescription.contains("test-secret"))
            }
        }
    }

    func testCodexLoginCopyIsPrivateBackedUpAndLeavesConfigAlone() async throws {
        let home = try directory()
        let dir = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let auth = dir.appendingPathComponent("auth.json")
        let config = dir.appendingPathComponent("config.toml")
        try Data("old-login".utf8).write(to: auth)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: auth.path)
        try Data("server-config".utf8).write(to: config)
        let data = Data(#"{"tokens":{"access_token":"test-secret"}}"#.utf8)
        let result = try await script(RemoteScripts.installCodexLogin, home: home, stdin: data)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.text, "copied=auth.json\n")
        XCTAssertFalse(result.stderr.contains("test-secret"))
        XCTAssertEqual(try Data(contentsOf: auth), data)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "server-config")
        let backup = dir.appendingPathComponent("auth.json.swarmebot-backup")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "old-login")
        for file in [auth, backup] {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        let empty = try await script(RemoteScripts.installCodexLogin, home: home, stdin: Data())
        XCTAssertNotEqual(empty.status, 0)
        XCTAssertEqual(try Data(contentsOf: auth), data)
    }

    func testCodexInstallerChecksDigestBeforeReplacingAndIsRepeatable() async throws {
        let home = try directory()
        let bin = home.appendingPathComponent(".local/bin")
        let payload = home.appendingPathComponent("payload")
        for dir in [bin, payload] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let asset = "codex-aarch64-unknown-linux-musl"
        let archive = home.appendingPathComponent("release.tar.gz")
        let binary = payload.appendingPathComponent(asset)
        try Data("#!/bin/sh\necho 'codex-cli fixture'\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let packed = try await ProcessRunner.run("/usr/bin/tar", ["-czf", archive.path, "-C", payload.path, asset])
        XCTAssertEqual(packed.status, 0, packed.stderr)
        let digest = try await ProcessRunner.run("/usr/bin/shasum", ["-a", "256", archive.path]).text.split(separator: " ").first.map(String.init)!
        let initial = Data("#!/bin/sh\nexit 1\n".utf8)
        let installed = bin.appendingPathComponent("codex")
        try initial.write(to: installed)
        let curl = bin.appendingPathComponent("curl")
        // curl -fsSL -o destination URL; no network or real credentials in this test.
        try Data("#!/bin/sh\ncp \"$FIXTURE_ARCHIVE\" \"$3\"\n".utf8).write(to: curl)
        for file in [installed, curl] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let bad = try await script(RemoteScripts.installCodex, home: home,
                                   arguments: [CodexConfig.version, asset, String(repeating: "0", count: 64)],
                                   extra: ["FIXTURE_ARCHIVE": archive.path])
        XCTAssertEqual(bad.status, 4)
        XCTAssertEqual(try Data(contentsOf: installed), initial)
        let good = try await script(RemoteScripts.installCodex, home: home, arguments: [CodexConfig.version, asset, digest],
                                    extra: ["FIXTURE_ARCHIVE": archive.path])
        XCTAssertEqual(good.status, 0, good.stderr)
        XCTAssertEqual(good.text, "codex=codex-cli fixture\n")
        // An installed working CLI must be reused without downloading anything.
        let again = try await script(RemoteScripts.installCodex, home: home, arguments: [CodexConfig.version, asset, digest])
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertEqual(again.text, good.text)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: bin.path).contains(where: { $0.hasPrefix(".codex.") }))
    }

    func testCodexScriptsAreValidShellAndRejectUnsupportedBuilds() async throws {
        for value in [RemoteScripts.installCodex, RemoteScripts.installCodexLogin] {
            let result = try await ProcessRunner.run("/bin/sh", ["-n", "-c", value])
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        let home = try directory()
        let result = try await script(RemoteScripts.installCodex, home: home, arguments: ["0.165.0", "../bad", "abc"])
        XCTAssertEqual(result.status, 2)
    }

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
