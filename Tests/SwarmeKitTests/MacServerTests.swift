@testable import SwarmeKit
import XCTest

final class MacServerTests: XCTestCase {
    func testEngineArchitectureIsReadFromTheBinary() throws {
        // this test bundle's own executable stands in for the engine: thin arm64 or x86_64
        let me = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        let archs = try ServerSetupFlow.machOArchitectures(me)
        #if arch(arm64)
        XCTAssertTrue(archs.contains("arm64"), "\(archs)")
        #else
        XCTAssertTrue(archs.contains("x86_64"), "\(archs)")
        #endif
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("not-macho-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        XCTAssertEqual(try ServerSetupFlow.machOArchitectures(text), [])
    }

    func testMacProbeIsSupportedFrom14() {
        XCTAssertTrue(RemoteProbe(values: ["os": "macos", "version": "27.0.1", "arch": "arm64"]).supported)
        XCTAssertFalse(RemoteProbe(values: ["os": "macos", "version": "13.6"]).supported)
        XCTAssertEqual(RemoteProbe(values: ["os": "macos", "arch": "arm64"]).engineArch, "aarch64")
        XCTAssertFalse(RemoteProbe(values: ["os": "debian", "version": "12"]).supported)
    }

    func testTheMacRootScriptIsValidShell() async throws {
        // syntax only (sh -n): nothing runs
        let result = try await ProcessRunner.run("/bin/sh", ["-n", "-c", RemoteScripts.rootMac])
        XCTAssertEqual(result.status, 0, result.stderr)
        for script in [RemoteScripts.rootLinux, RemoteScripts.caddyLinux, RemoteScripts.serviceLinux, RemoteScripts.probe,
                       RemoteScripts.installKey, RemoteScripts.installEngine, RemoteScripts.removeKey, RemoteScripts.addDevice,
                       RemoteScripts.restartEngine, RemoteScripts.configurePushRelay, RemoteScripts.servicePushLinux,
                       RemoteScripts.rootMacPush] {
            let check = try await ProcessRunner.run("/bin/sh", ["-n", "-c", script])
            XCTAssertEqual(check.status, 0, check.stderr)
        }
    }
}
