@testable import SwarmeKit
import XCTest

@MainActor
final class RemoteHarnessUpdateTests: XCTestCase {
    private let probe = RemoteProbe(values: ["os": "ubuntu", "arch": "x86_64", "codex": "codex-cli 0.165.0",
                                             "claude": "2.1.304 (Claude Code)", "omp": "omp/18.12.3"])

    func testVersionsCompareNumericallyAndRejectUnstableOrMalformedValues() {
        XCTAssertLessThan(HarnessVersion("0.9.9")!, HarnessVersion("0.10.0")!)
        XCTAssertLessThan(HarnessVersion("18.12.3")!, HarnessVersion("18.17.0")!)
        XCTAssertEqual(HarnessVersion.installed("codex-cli 0.167.0", kind: .codex), HarnessVersion("0.167.0"))
        XCTAssertEqual(HarnessVersion.installed("omp/18.17.0", kind: .omp), HarnessVersion("18.17.0"))
        for value in ["1.2", "1..2", "1.2.3-beta", "1.2.-3", "1.2.３", "999999999999999999999999.2.3"] {
            XCTAssertNil(HarnessVersion(value), value)
        }
    }

    func testOfficialReleaseRequiresStableTagMatchingAssetAndSHA256() throws {
        for (os, arch, target) in [("ubuntu", "x86_64", "x86_64-unknown-linux-musl"),
                                   ("ubuntu", "aarch64", "aarch64-unknown-linux-musl"),
                                   ("macos", "arm64", "aarch64-apple-darwin"),
                                   ("macos", "x86_64", "x86_64-apple-darwin")] {
            let release = HarnessRelease(tag_name: "rust-v0.167.0", prerelease: false, draft: false,
                assets: [.init(name: "codex-package-\(target).tar.gz", digest: "sha256:" + String(repeating: "a", count: 64))])
            let package = try release.package(kind: .codex, probe: RemoteProbe(values: ["os": os, "arch": arch]))
            XCTAssertEqual(package.version, "0.167.0")
            XCTAssertEqual(package.asset, "codex-package-\(target)")
        }
        let valid = HarnessRelease(tag_name: "v18.17.0", prerelease: false, draft: false,
            assets: [.init(name: "omp-linux-x64", digest: "sha256:" + String(repeating: "f", count: 64))])
        XCTAssertEqual(try valid.package(kind: .omp, probe: probe).asset, "omp-linux-x64")
        var invalid = valid
        invalid.prerelease = true
        XCTAssertThrowsError(try invalid.package(kind: .omp, probe: probe))
        invalid = valid; invalid.draft = true
        XCTAssertThrowsError(try invalid.package(kind: .omp, probe: probe))
        invalid = valid; invalid.tag_name = "v18.17.0;echo bad"
        XCTAssertThrowsError(try invalid.package(kind: .omp, probe: probe))
        for digest in [nil, "sha256:abc", "sha256:" + String(repeating: "x", count: 64), "sha512:" + String(repeating: "a", count: 64)] {
            invalid = valid; invalid.assets[0].digest = digest
            XCTAssertThrowsError(try invalid.package(kind: .omp, probe: probe))
        }
        XCTAssertThrowsError(try valid.package(kind: .omp, probe: RemoteProbe(values: ["os": "macos", "arch": "arm64"])))
    }

    func testBusyAndUnreachableServersNeverStartUpdates() async throws {
        var touched = false
        var operations = RemoteHarnessUpdater.Operations(probe: { touched = true; return self.probe }, busy: { ["Mailup"] },
            update: { _, _, _ in touched = true; return "" })
        let waiting = try await RemoteHarnessUpdater.run(operations)
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertEqual(waiting.busyNames, ["Mailup"])
        XCTAssertFalse(touched)
        operations.busy = { throw URLError(.notConnectedToInternet) }
        do { _ = try await RemoteHarnessUpdater.run(operations); XCTFail("An offline server is not idle") }
        catch { XCTAssertFalse(touched) }
    }

    func testOnlyInstalledHarnessesUpdateAndOneFailureDoesNotHideOtherResults() async throws {
        var updated: [RemoteHarness] = []
        let operations = RemoteHarnessUpdater.Operations(probe: { self.probe }, busy: { [] }, update: { kind, _, idle in
            try await idle()
            updated.append(kind)
            if kind == .codex { throw URLError(.cannotConnectToHost) }
            return kind == .omp ? "omp/18.17.0" : "2.1.305 (Claude Code)"
        })
        let report = try await RemoteHarnessUpdater.run(operations)
        XCTAssertEqual(updated, [.codex, .claude, .omp])
        XCTAssertEqual(report.phase, .failed)
        XCTAssertEqual(report.lines.count, 3)
        var absent = operations
        absent.probe = { RemoteProbe(values: [:]) }
        updated = []
        let empty = try await RemoteHarnessUpdater.run(absent)
        XCTAssertEqual(empty.phase, .finished)
        XCTAssertTrue(updated.isEmpty)
    }

    func testAChatStartingDuringReleaseLookupDefersInstallation() async throws {
        var busy = false
        var installed = false
        let operations = RemoteHarnessUpdater.Operations(probe: { self.probe }, busy: { busy ? ["Mailup"] : [] }, update: { _, _, idle in
            busy = true // release metadata returned after a new turn started
            try await idle()
            installed = true
            return "codex-cli 0.167.0"
        })
        let report = try await RemoteHarnessUpdater.run(operations)
        XCTAssertEqual(report.phase, .waiting)
        XCTAssertFalse(installed)
    }

    func testStartupChecksOnceManualCheckRetriesAndBusyServersResume() async throws {
        let monitor = RemoteHarnessUpdateMonitor()
        var busy = true
        var probes = 0
        var installs = 0
        monitor.waitUntilRetry = { busy = false }
        let operations = RemoteHarnessUpdater.Operations(probe: { probes += 1; return RemoteProbe(values: ["claude": "2.1.304"]) },
            busy: { busy ? ["Mailup"] : [] }, update: { _, _, _ in installs += 1; return "2.1.305" })
        monitor.check("server", operations: operations)
        monitor.check("server", operations: operations, force: true) // no concurrent sweep
        for _ in 0..<100 where monitor.statuses["server"]?.phase != .finished { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(probes, 1)
        monitor.check("server", operations: operations)
        await Task.yield()
        XCTAssertEqual(installs, 1)
        monitor.check("server", operations: operations, force: true)
        for _ in 0..<100 where installs < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(installs, 2)
        monitor.stop()
    }

    func testForgettingAServerCancelsItsPendingRetry() async throws {
        let monitor = RemoteHarnessUpdateMonitor()
        var installs = 0
        let operations = RemoteHarnessUpdater.Operations(probe: { self.probe }, busy: { ["Mailup"] },
            update: { _, _, _ in installs += 1; return "" })
        monitor.check("server", operations: operations)
        for _ in 0..<100 where monitor.statuses["server"]?.phase != .waiting { try await Task.sleep(nanoseconds: 10_000_000) }
        monitor.retain([])
        await Task.yield()
        XCTAssertTrue(monitor.statuses.isEmpty)
        XCTAssertEqual(installs, 0)
    }

    func testOfficialReleaseRequestsAreSharedAndManualCheckCanRefresh() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessReleaseStub.self]
        let source = HarnessReleaseSource(session: URLSession(configuration: configuration))
        HarnessReleaseStub.reset()
        async let first = source.latest(.codex)
        async let second = source.latest(.codex)
        _ = try await (first, second)
        XCTAssertEqual(HarnessReleaseStub.requestCount, 1)
        source.reset()
        _ = try await source.latest(.codex)
        XCTAssertEqual(HarnessReleaseStub.requestCount, 2)
        HarnessReleaseStub.fail = true
        source.reset()
        do { _ = try await source.latest(.codex); XCTFail("A failed lookup must not be cached as success") } catch { }
        HarnessReleaseStub.fail = false
        _ = try await source.latest(.codex)
        XCTAssertEqual(HarnessReleaseStub.requestCount, 4)
    }

    func testANewerInstalledCodexNeverStartsSSHOrDowngrades() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessReleaseStub.self]
        let source = HarnessReleaseSource(session: URLSession(configuration: configuration))
        HarnessReleaseStub.reset()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let identity = try SSHIdentityStore(root: home).findOrCreate(host: "127.0.0.1", port: 1, user: "fixture")
        let admin = RemoteAdmin(identity: identity, store: SSHIdentityStore(root: home))
        var called = false
        var newer = probe
        newer.values["codex"] = "codex-cli 0.168.0"
        let result = try await admin.updateHarness(.codex, probe: newer, source: source, ensureIdle: { called = true })
        XCTAssertEqual(result, "codex-cli 0.168.0")
        XCTAssertFalse(called)
    }

    func testOmpUpdateVerifiesTheBinaryAndClaudeUsesItsOwnUpdater() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func executable(_ name: String, _ script: String) throws -> URL {
            let url = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let fixture = try executable("new-omp", "#!/bin/sh\necho omp/18.17.0\n")
        let old = try executable("omp", "#!/bin/sh\necho omp/18.12.3\n")
        _ = try executable("curl", "#!/bin/sh\ncp \"$FIXTURE_BINARY\" \"$3\"\n")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["FIXTURE_BINARY"] = fixture.path
        let digest = try await ProcessRunner.run("/usr/bin/shasum", ["-a", "256", fixture.path]).text.split(separator: " ").first.map(String.init)!
        let initial = try Data(contentsOf: old)
        let bad = try await ProcessRunner.run("/bin/sh", ["-c", RemoteScripts.installOmp, "sh", "18.17.0", "omp-linux-x64", String(repeating: "0", count: 64)], environment: environment)
        XCTAssertEqual(bad.status, 4)
        XCTAssertEqual(try Data(contentsOf: old), initial)
        let good = try await ProcessRunner.run("/bin/sh", ["-c", RemoteScripts.installOmp, "sh", "18.17.0", "omp-linux-x64", digest], environment: environment)
        XCTAssertEqual(good.status, 0, good.stderr)
        XCTAssertEqual(good.text, "omp=omp/18.17.0\n")
        _ = try executable("claude", "#!/bin/sh\nif [ \"$1\" = update ]; then touch \"$HOME/updated\"; else echo '2.1.305 (Claude Code)'; fi\n")
        let claude = try await ProcessRunner.run("/bin/sh", ["-c", RemoteScripts.updateClaude], environment: environment)
        XCTAssertEqual(claude.status, 0, claude.stderr)
        XCTAssertEqual(claude.text, "claude=2.1.305 (Claude Code)\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("updated").path))
    }
}

private final class HarnessReleaseStub: URLProtocol {
    static var requestCount = 0
    static var fail = false
    static func reset() { requestCount = 0; fail = false }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        let body = #"{"tag_name":"rust-v0.167.0","draft":false,"prerelease":false,"assets":[{"name":"codex-package-x86_64-unknown-linux-musl.tar.gz","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.fail ? 403 : 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
