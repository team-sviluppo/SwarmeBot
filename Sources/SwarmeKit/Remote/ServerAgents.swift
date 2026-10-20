// The coding agents a server gets from this Mac (bot-remoto §4.2), so that a
// new server works like this Mac does without a terminal: Claude Code with the
// `claude setup-token` token this Mac remembers, and omp (oh my pi) at this
// Mac's version with its login, as the CLI of the engine's pi driver.
import CompanionCore
import Foundation
import SQLite3

/// omp keeps its keys, providers and settings in ~/.omp/agent: these files make its login.
public enum OmpConfig {
    public static let files = ["agent.db", "config.yml", "models.yml"]

    /// The person's own omp, not the app's data: the real home even on test data.
    public static var localDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omp/agent", isDirectory: true)
    }

    static func localBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/omp", "/usr/local/bin/omp", "\(home)/.local/bin/omp", "\(home)/.bun/bin/omp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `18.12.3`: the version this Mac runs, so the server reads the same config.
    public static func localVersion() async -> String? {
        guard let binary = localBinary(), let result = try? await ProcessRunner.run(binary, ["--version"], timeout: 15) else { return nil }
        return version(result.text)
    }

    /// `omp/18.12.3` → `18.12.3`.
    static func version(_ output: String) -> String? {
        let line = output.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let version = line.hasPrefix("omp/") ? String(line.dropFirst(4)) : line
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return version
    }

    /// The release build for the server: `omp-linux-x64`, `omp-darwin-arm64`…
    public static func asset(for probe: RemoteProbe) -> String? {
        let arch: String
        switch probe.engineArch {
        case "aarch64": arch = "arm64"
        case "x86_64": arch = "x64"
        default: return nil
        }
        return "omp-\(probe.isMac ? "darwin" : "linux")-\(arch)"
    }

    /// agent.db as one consistent file, with what is still in its WAL, while omp may be writing it.
    static func snapshot(_ database: URL) throws -> Data {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("omp-agent-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: copy) }
        var source: OpaquePointer?
        var target: OpaquePointer?
        defer {
            sqlite3_close(source)
            sqlite3_close(target)
        }
        guard sqlite3_open_v2(database.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open(copy.path, &target) == SQLITE_OK,
              let backup = sqlite3_backup_init(target, "main", source, "main")
        else { throw ProcessRunner.Failure(message: tr("Non riesco a leggere %@", database.path)) }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { throw ProcessRunner.Failure(message: tr("Copia di %@ non riuscita (%@)", database.lastPathComponent, String(step))) }
        sqlite3_close(target)
        target = nil
        return try Data(contentsOf: copy)
    }
}

/// The `claude setup-token` token, kept on this Mac so every server it sets up gets it.
public enum ServerClaudeToken {
    static let key = "claude-setup-token"

    public static var saved: String? { RemoteEngineStore.token(engineId: key) }

    public static func save(_ token: String) throws {
        try RemoteEngineStore.setToken(try validated(token), engineId: key)
    }

    static func validated(_ token: String) throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-ant-"), !trimmed.contains(where: \.isWhitespace) else {
            throw ProcessRunner.Failure(message: tr("Non sembra un token di claude setup-token (inizia con sk-ant-)"))
        }
        return trimmed
    }

    public static func forget() { RemoteEngineStore.deleteToken(engineId: key) }
}

/// What this Mac hands a server: by default its own Claude token and omp.
public struct LocalAgents: Sendable {
    public var claudeToken: @Sendable () -> String?
    public var ompVersion: @Sendable () async -> String?
    public var ompDirectory: URL

    public init(claudeToken: @escaping @Sendable () -> String?, ompVersion: @escaping @Sendable () async -> String?, ompDirectory: URL) {
        self.claudeToken = claudeToken
        self.ompVersion = ompVersion
        self.ompDirectory = ompDirectory
    }

    public static let thisMac = LocalAgents(claudeToken: { ServerClaudeToken.saved }, ompVersion: { await OmpConfig.localVersion() },
                                            ompDirectory: OmpConfig.localDirectory)
    /// Only Claude Code's install: nothing of this Mac leaves it (tests on throwaway servers).
    public static let none = LocalAgents(claudeToken: { nil }, ompVersion: { nil }, ompDirectory: URL(fileURLWithPath: "/nonexistent"))
}

public enum ServerAgents {
    /// Install and log in the agents; one line per agent says what happened. Safe to repeat.
    public static func configure(admin: RemoteAdmin, client: CompanionClient, probe: RemoteProbe,
                                 local: LocalAgents = .thisMac) async throws -> [String] {
        var report: [String] = []
        let claude = try await admin.installClaude()
        let token = local.claudeToken()
        if let token {
            try await admin.storeClaudeToken(token)
            report.append(tr("Claude Code %@: login con il token salvato su questo Mac", claude))
        } else {
            report.append(tr("Claude Code %@: manca il login (menu del server › Login di Claude sul server…)", claude))
        }

        var omp: String?
        if FileManager.default.fileExists(atPath: local.ompDirectory.appendingPathComponent("agent.db").path) {
            if let version = await local.ompVersion() {
                let installed = try await admin.installOmp(version: version, probe: probe)
                let copied = try await admin.copyOmpConfig(from: local.ompDirectory)
                report.append(tr("%@: configurazione di questo Mac copiata (%@), usato dai bot con pi", installed.isEmpty ? "omp" : installed, copied.joined(separator: ", ")))
                omp = installed
            } else {
                report.append(tr("omp: c'è la configurazione ma non il programma su questo Mac, quindi non so quale versione installare"))
            }
        }

        // the token is read at start: one restart, then the engine as every client sees it
        if token != nil {
            try await admin.restartEngine()
            try await waitForEngine(client)
        }
        if omp != nil {
            let instances = try await client.instances()
            if let pi = instances.first(where: { $0.driverKind == "piAgent" }) {
                _ = try await client.setInstanceCLI(pi.instanceId, cli: "omp")
            }
        }
        return report
    }

    static func waitForEngine(_ client: CompanionClient) async throws {
        for _ in 0..<60 {
            if let health = try? await client.remoteHealth(), health.remote == true { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw EngineUpdateError.didNotComeBack
    }
}
