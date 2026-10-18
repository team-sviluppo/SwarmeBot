// The Linux engine binaries, fetched when a server needs one — bot-remoto §3.6.
//
// The app does not carry them (two × 60 MB). It carries `linux-engines.json`:
// for each architecture the URL of the release asset, its size and its
// SHA-256. A binary is used only if its digest is the pinned one, so a
// tampered or truncated download is refused, whoever serves it. Downloads
// are kept in Caches by digest and reused.
//
// Development: SWARMEBOT_LINUX_ENGINES=build/linux uses local builds
// (`swarme-harness-<arch>` + `.sha256`, scripts/build-linux-engine.sh), and
// SWARMEBOT_LINUX_MANIFEST points at another manifest.
import CommonCrypto
import Foundation

public struct LinuxEngineManifest: Codable, Equatable, Sendable {
    public struct Engine: Codable, Equatable, Sendable {
        public var url: String
        public var sha256: String
        public var size: Int
    }

    public var version: String
    public var engines: [String: Engine]
}

public enum LinuxEngineError: LocalizedError, Equatable {
    case noManifest
    case noEngine(String)
    case digestMismatch(expected: String, got: String)
    case sizeMismatch(expected: Int, got: Int)
    case download(String)

    public var errorDescription: String? {
        switch self {
        case .noManifest:
            return "Questa build dell'app non dice dove scaricare il motore Linux (manca linux-engines.json)"
        case let .noEngine(arch):
            return "Non c'è un motore Linux per l'architettura \(arch)"
        case let .digestMismatch(expected, got):
            return "Il motore Linux scaricato non è quello atteso (SHA-256 \(got.prefix(12))…, atteso \(expected.prefix(12))…): scartato"
        case let .sizeMismatch(expected, got):
            return "Il motore Linux scaricato è incompleto (\(got) byte invece di \(expected)): scartato"
        case let .download(detail):
            return "Download del motore Linux non riuscito: \(detail)"
        }
    }
}

public struct LinuxEngines: Sendable {
    public let manifest: LinuxEngineManifest?
    public let cache: URL
    public let localBuilds: URL?

    public init(manifest: LinuxEngineManifest?, cache: URL, localBuilds: URL? = nil) {
        self.manifest = manifest
        self.cache = cache
        self.localBuilds = localBuilds
    }

    /// The app's own: the bundled manifest, Caches/SwarmeBot/linux, the dev overrides.
    public static var standard: LinuxEngines {
        let env = ProcessInfo.processInfo.environment
        let manifestURL = env["SWARMEBOT_LINUX_MANIFEST"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "linux-engines", withExtension: "json")
        let manifest = manifestURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(LinuxEngineManifest.self, from: $0) }
        return LinuxEngines(manifest: manifest,
                            cache: AppPaths.home.appendingPathComponent("Library/Caches/SwarmeBot/linux", isDirectory: true),
                            localBuilds: env["SWARMEBOT_LINUX_ENGINES"].map { URL(fileURLWithPath: $0, isDirectory: true) })
    }

    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            chunk.withUnsafeBytes { _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG(chunk.count)) }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A local build for `arch`, if development points at one.
    func localBuild(_ arch: String) -> (url: URL, sha256: String)? {
        guard let localBuilds else { return nil }
        let binary = localBuilds.appendingPathComponent("swarme-harness-\(arch)")
        guard FileManager.default.fileExists(atPath: binary.path),
              let sha = try? String(contentsOf: URL(fileURLWithPath: binary.path + ".sha256"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), sha.count == 64 else { return nil }
        return (binary, sha)
    }

    /// The binary for `arch`, verified: a local build, the cache, or a fresh download.
    public func engine(_ arch: String, session: URLSession = .shared) async throws -> (url: URL, sha256: String) {
        if let local = localBuild(arch) { return local }
        guard let manifest else { throw LinuxEngineError.noManifest }
        guard let entry = manifest.engines[arch] else { throw LinuxEngineError.noEngine(arch) }
        let expected = entry.sha256.lowercased()
        let cached = cache.appendingPathComponent("swarme-harness-\(arch)-\(expected)")
        if FileManager.default.fileExists(atPath: cached.path) {
            // a cache file is trusted only for as long as it still hashes right
            if (try? Self.digest(of: cached)) == expected { return (cached, expected) }
            try? FileManager.default.removeItem(at: cached)
        }
        guard let source = URL(string: entry.url) else { throw LinuxEngineError.download("URL non valido") }
        let downloaded: URL
        do {
            let (file, response) = try await session.download(from: source)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: file)
                throw LinuxEngineError.download("HTTP \(http.statusCode)")
            }
            downloaded = file
        } catch let error as LinuxEngineError {
            throw error
        } catch {
            throw LinuxEngineError.download(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? Int) ?? 0
        guard size == entry.size else { throw LinuxEngineError.sizeMismatch(expected: entry.size, got: size) }
        let got = try Self.digest(of: downloaded)
        guard got == expected else { throw LinuxEngineError.digestMismatch(expected: expected, got: got) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: downloaded, to: cached)
        return (cached, expected)
    }
}
