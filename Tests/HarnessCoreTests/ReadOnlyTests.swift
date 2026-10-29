@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

/// Folders a chat may read and must not change (ReadOnlyGuard.swift).
@MainActor
final class ReadOnlyTests: XCTestCase {
    private let folders = ["/work/rossi-admin", "/work/rossi-api/bruno"]

    func testAWriteToolOnALinkedFolderIsRefused() {
        let edit = ReadOnlyGuard.reason(tool: "Edit", summary: #"{"file_path":"/work/rossi-admin/src/app.ts","old_string":"a"}"#, folders: folders)
        XCTAssertNotNil(edit)
        XCTAssertTrue(edit?.contains("/work/rossi-admin") == true)
        for tool in ["Write", "MultiEdit", "NotebookEdit", "apply_patch", "str_replace_editor", "mcp__fs__write_file", "create_file", "delete_file"] {
            XCTAssertNotNil(ReadOnlyGuard.reason(tool: tool, summary: #"{"path":"/work/rossi-admin/x"}"#, folders: folders), tool)
        }
    }

    func testReadingIsNotRefused() {
        for tool in ["Read", "Glob", "Grep", "LS", "mcp__fs__read_file", "WebFetch"] {
            XCTAssertNil(ReadOnlyGuard.reason(tool: tool, summary: #"{"file_path":"/work/rossi-admin/src/app.ts"}"#, folders: folders), tool)
        }
    }

    func testAWriteElsewhereIsNotRefused() {
        XCTAssertNil(ReadOnlyGuard.reason(tool: "Edit", summary: #"{"file_path":"/work/rossi-api/src/a.cs"}"#, folders: folders), "the working folder")
        XCTAssertNil(ReadOnlyGuard.reason(tool: "Edit", summary: #"{"file_path":"/work/rossi-admin2/a"}"#, folders: folders), "a sibling that starts with the same name")
        XCTAssertNil(ReadOnlyGuard.reason(tool: "Edit", summary: #"{"file_path":"/work/rossi-admin-old/a"}"#, folders: folders))
        XCTAssertNil(ReadOnlyGuard.reason(tool: "Edit", summary: #"{"file_path":"/work/rossi-api/bruno-notes/a"}"#, folders: folders))
        XCTAssertNil(ReadOnlyGuard.reason(tool: "Edit", summary: "anything", folders: []))
    }

    func testAFolderInsideTheWorkingRepoIsStillReadOnly() {
        // the Bruno collection lives in the API repo's folder, and is read-only while working on the API
        XCTAssertNotNil(ReadOnlyGuard.reason(tool: "Write", summary: #"{"file_path":"/work/rossi-api/bruno/login.bru"}"#, folders: folders))
    }

    func testAShellCommandIsReadForTheFolderAndAVerbThatWrites() {
        let writes = ["rm -rf /work/rossi-admin/dist", "echo x > /work/rossi-admin/a.txt", "cp a.txt /work/rossi-admin/", "sed -i '' s/a/b/ /work/rossi-admin/a",
                      "git -C /work/rossi-admin commit -am x", "mv /work/rossi-admin/a /tmp/a", "touch /work/rossi-admin/new", "tee /work/rossi-admin/f"]
        for command in writes {
            XCTAssertNotNil(ReadOnlyGuard.reason(tool: "Bash", summary: command, folders: folders), command)
        }
        let reads = ["cat /work/rossi-admin/package.json", "ls -la /work/rossi-admin", "grep -rn login /work/rossi-admin/src", "git -C /work/rossi-admin log --oneline",
                     "rm /tmp/build.log"]
        for command in reads {
            XCTAssertNil(ReadOnlyGuard.reason(tool: "Bash", summary: command, folders: folders), command)
        }
    }

    func testAFolderBehindPrivateIsRecognizedByItsShortName() {
        let real = ["/private/var/folders/x/repo"]
        XCTAssertNotNil(ReadOnlyGuard.reason(tool: "Edit", summary: #"{"file_path":"/var/folders/x/repo/a"}"#, folders: real))
        XCTAssertNotNil(ReadOnlyGuard.reason(tool: "Edit", summary: #"{"file_path":"/private/var/folders/x/repo/a"}"#, folders: real))
    }

    func testCanonicalIsTheRealPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ReadOnlyGuard.canonical(dir.path).hasPrefix("/private/var/") || ReadOnlyGuard.canonical(dir.path) == dir.path)
        XCTAssertEqual(ReadOnlyGuard.canonical("/nonexistent/../nonexistent/x"), "/nonexistent/x", "a path that is not there is tidied, not lost")
        XCTAssertEqual(ReadOnlyGuard.canonical(dir.path + "/not/yet"), ReadOnlyGuard.canonical(dir.path) + "/not/yet", "the part that exists is made real, the rest kept")
        XCTAssertEqual(ReadOnlyGuard.canonical("/"), "/")
    }

    // MARK: Claude's side

    func testClaudeGetsTheFoldersAndARuleAgainstEditingThem() async throws {
        let paths = temporaryPaths()
        paths.ensure()
        let out = paths.root.appendingPathComponent("args.txt")
        let script = paths.root.appendingPathComponent("cli.sh")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ARGS_OUT\"\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var env = ProcessInfo.processInfo.environment
        env["OMB_DATA_DIR"] = paths.root.path
        env["ARGS_OUT"] = out.path
        let instance = try ClaudeInstance(input: DriverCreateInput(instanceId: "claude", displayName: nil, environment: env, enabled: true,
                                                                   config: ["cli": .string(script.path), "permissionMode": "bypassPermissions"]))
        var input = SendTurnInput(threadId: "t-ro", text: "hi", cwd: paths.root.path)
        input.readOnlyFolders = ["/work/admin", "/work/api/bruno"]
        _ = try await instance.sendTurn(input)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: out.path) { try await Task.sleep(nanoseconds: 50_000_000) }
        let args = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(zip(args, args.dropFirst()).filter { $0.0 == "--add-dir" }.map(\.1), ["/work/admin", "/work/api/bruno"])
        let rule = try XCTUnwrap(zip(args, args.dropFirst()).first { $0.0 == "--disallowedTools" }?.1)
        XCTAssertEqual(rule, "Edit(//work/admin/**),Edit(//work/api/bruno/**)")
        await instance.dispose()
    }

    func testClaudeGetsNothingExtraWhenNothingIsLinked() async throws {
        let paths = temporaryPaths()
        paths.ensure()
        let out = paths.root.appendingPathComponent("args.txt")
        let script = paths.root.appendingPathComponent("cli.sh")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ARGS_OUT\"\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var env = ProcessInfo.processInfo.environment
        env["OMB_DATA_DIR"] = paths.root.path
        env["ARGS_OUT"] = out.path
        let instance = try ClaudeInstance(input: DriverCreateInput(instanceId: "claude", displayName: nil, environment: env, enabled: true,
                                                                   config: ["cli": .string(script.path), "permissionMode": "bypassPermissions"]))
        _ = try await instance.sendTurn(SendTurnInput(threadId: "t-plain", text: "hi", cwd: paths.root.path))
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: out.path) { try await Task.sleep(nanoseconds: 50_000_000) }
        let args = try String(contentsOf: out, encoding: .utf8)
        XCTAssertFalse(args.contains("--add-dir") || args.contains("--disallowedTools"))
        await instance.dispose()
    }

    private func temporaryPaths() -> DataPaths {
        DataPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString)", isDirectory: true))
    }
}
