@testable import SwarmeKit
import XCTest

/// The Linux engine is downloaded and used only if its SHA-256 is the pinned one.
final class LinuxEnginesTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/sble-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A "release asset" served from a file URL, and a manifest pinning it.
    func published(_ bytes: Data, pin: Data? = nil, size: Int? = nil) throws -> LinuxEngines {
        let asset = root.appendingPathComponent("asset-\(UUID().uuidString.prefix(4))")
        try bytes.write(to: asset)
        let pinned = pin ?? bytes
        let probe = root.appendingPathComponent("pin-\(UUID().uuidString.prefix(4))")
        try pinned.write(to: probe)
        let sha = try LinuxEngines.digest(of: probe)
        let manifest = LinuxEngineManifest(version: "9.9.9", engines: [
            "aarch64": .init(url: asset.absoluteString, sha256: sha, size: size ?? pinned.count),
        ])
        return LinuxEngines(manifest: manifest, cache: root.appendingPathComponent("cache"))
    }

    func testTheRightBinaryIsDownloadedVerifiedAndCached() async throws {
        let engines = try published(Data("an engine".utf8))
        let first = try await engines.engine("aarch64")
        XCTAssertEqual(try Data(contentsOf: first.url), Data("an engine".utf8))
        XCTAssertTrue(first.url.path.hasPrefix(engines.cache.path))
        // the asset can go away: the cache answers
        let manifestURL = try XCTUnwrap(URL(string: engines.manifest!.engines["aarch64"]!.url))
        try FileManager.default.removeItem(at: manifestURL)
        let second = try await engines.engine("aarch64")
        XCTAssertEqual(second.url, first.url)
        XCTAssertEqual(second.sha256, first.sha256)
    }

    func testATamperedDownloadIsRefused() async throws {
        let engines = try published(Data("evil engine".utf8), pin: Data("good engine".utf8))
        do {
            _ = try await engines.engine("aarch64")
            XCTFail("a binary with the wrong digest was accepted")
        } catch let error as LinuxEngineError {
            guard case .digestMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: engines.cache.appendingPathComponent("swarme-harness-aarch64-\(engines.manifest!.engines["aarch64"]!.sha256)").path))
    }

    func testATruncatedDownloadIsRefused() async throws {
        let engines = try published(Data("short".utf8), size: 999)
        do {
            _ = try await engines.engine("aarch64")
            XCTFail("a truncated binary was accepted")
        } catch let error as LinuxEngineError {
            XCTAssertEqual(error, .sizeMismatch(expected: 999, got: 5))
        }
    }

    func testATamperedCacheIsDiscardedAndFetchedAgain() async throws {
        let engines = try published(Data("an engine".utf8))
        let first = try await engines.engine("aarch64")
        try Data("swapped".utf8).write(to: first.url)
        let again = try await engines.engine("aarch64")
        XCTAssertEqual(try Data(contentsOf: again.url), Data("an engine".utf8))
    }

    func testMissingManifestOrArchitecture() async throws {
        do {
            _ = try await LinuxEngines(manifest: nil, cache: root).engine("aarch64")
            XCTFail()
        } catch let error as LinuxEngineError { XCTAssertEqual(error, .noManifest) }
        let engines = try published(Data("x".utf8))
        do {
            _ = try await engines.engine("x86_64")
            XCTFail()
        } catch let error as LinuxEngineError { XCTAssertEqual(error, .noEngine("x86_64")) }
    }

    func testDigestMatchesShasum() async throws {
        let file = root.appendingPathComponent("f")
        try Data(repeating: 7, count: 3_000_000).write(to: file)
        let shasum = try await ProcessRunner.run("/usr/bin/shasum", ["-a", "256", file.path]).text.split(separator: " ").first.map(String.init)
        XCTAssertEqual(try LinuxEngines.digest(of: file), shasum)
    }
}
