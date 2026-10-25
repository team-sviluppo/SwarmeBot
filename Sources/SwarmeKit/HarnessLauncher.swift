// Starting the Node harness, and keeping it alive.
//
// Phase 1 of the native app runs the existing TypeScript harness unchanged:
// the UI is new, the engine is not. This is the Swift half of what
// `electron/main.mjs` does with `utilityProcess.fork` — pick a port, start
// the server, wait until `/api/health` answers *as our child*, restart it if
// it dies, stop it when the app quits.
//
// Where the harness comes from, in order:
//
// 1. `SWARMEBOT_HARNESS_URL` — attach to a server someone else runs (a
//    `pnpm dev:server` in a terminal). Nothing is spawned.
// 2. A harness already answering on one of the known ports. Two harnesses on
//    one `~/.swarmebot` would both write `bots.json` and both run routines,
//    so while the Electron app is still around, attaching beats starting.
// 3. Bundled: `Contents/Helpers/node` + `Contents/Resources/server/index.js`.
// 4. Development: a SwarmeBot checkout (`SWARMEBOT_REPO`, default
//    `../SwarmeBot` next to this project), run with the node on the login
//    shell's PATH — `server/index.ts` through `--experimental-strip-types`,
//    or `dist-server/index.js` with `SWARMEBOT_HARNESS_DIST=1`.
import Foundation
import OSLog

private let log = Logger(subsystem: "com.swarmebot.mac", category: "harness")

public enum HarnessState: Equatable, Sendable {
    case idle
    case starting(String)
    /// `owned` is false when we attached to a server we did not start.
    case running(port: Int, owned: Bool)
    case failed(String)
}

/// How to start a harness process. Pure data, so the resolution rules are
/// testable without spawning anything.
public struct HarnessCommand: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    /// Extra environment on top of the inherited one.
    public var environment: [String: String]

    public init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// The harness is the Swift engine, on the real data in `~/.swarmebot`.
/// The Node case remains only so a process still answering `engine: node`
/// is not mistaken for this one.
public enum HarnessEngine: String, CaseIterable, Sendable {
    case node
    case swift

    public static var selected: HarnessEngine { .swift }

    /// Where the bots, messages and config actually live.
    public static var realDataDir: URL {
        AppPaths.home.appendingPathComponent(".swarmebot", isDirectory: true)
    }

    /// `Process` will not start if its working directory is missing, and it
    /// reports that as a failed launch rather than letting the engine create
    /// the folder. A new Mac has no `~/.swarmebot` yet, so the first open
    /// died on every port before the server existed.
    public static func ensureRuntimeDirectories() throws {
        try ensureDirectories([realDataDir, HarnessLocator.userData, HarnessLocator.logDirectory])
    }

    static func ensureDirectories(_ urls: [URL]) throws {
        let fm = FileManager.default
        for url in urls {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    /// Written once, before the Swift engine is allowed to open the real data.
    public static var backupDir: URL {
        HarnessLocator.userData.appendingPathComponent("backup-before-swift-engine", isDirectory: true)
    }

    /// A full copy of `~/.swarmebot`. `messages.db` is taken with `VACUUM INTO`,
    /// which stays consistent even if another process still has the database open.
    /// Returns the backup folder. Does nothing when that backup already exists.
    public static func backupRealDataIfNeeded() throws -> URL {
        let fm = FileManager.default
        let source = realDataDir
        let target = backupDir
        let marker = target.appendingPathComponent("COMPLETE")
        if fm.fileExists(atPath: marker.path) { return target }
        guard fm.fileExists(atPath: source.path) else { return target }
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copyEngineData(from: source, to: target)
        let copied = target.appendingPathComponent("messages.db")
        let wal = target.appendingPathComponent("messages.db-wal")
        let shm = target.appendingPathComponent("messages.db-shm")
        if fm.fileExists(atPath: source.appendingPathComponent("messages.db").path) {
            try? fm.removeItem(at: copied)
            try? fm.removeItem(at: wal)
            try? fm.removeItem(at: shm)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            let destination = copied.path.replacingOccurrences(of: "'", with: "''")
            process.arguments = ["-readonly", source.appendingPathComponent("messages.db").path, "VACUUM INTO '\(destination)'"]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { throw BackupError(tr("VACUUM INTO di messages.db è uscito con codice %@", String(process.terminationStatus))) }
        }
        try Data("ok\n".utf8).write(to: marker)
        return target
    }

    /// `copyItem`, minus what is not engine data or cannot be copied: the ssh
    /// identities (private keys, and the control sockets ssh keeps there) and
    /// any socket or FIFO, which `copyItem` refuses (ENOTSUP) and so stopped
    /// the engine from starting.
    static func copyEngineData(from source: URL, to target: URL, skipping skipped: Set<String> = ["ssh"]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) {
            if skipped.contains(name) { continue }
            let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
            let type = (try fm.attributesOfItem(atPath: from.path))[.type] as? FileAttributeType
            switch type {
            case .typeDirectory?: try copyEngineData(from: from, to: to, skipping: [])
            case .typeRegular?, .typeSymbolicLink?: try fm.copyItem(at: from, to: to)
            default: continue
            }
        }
    }

    public struct BackupError: Error, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

}

public enum HarnessLocator {
    /// The ports Electron tries, in the same order, so either app finds the
    /// other's server.
    public static let ports = [8799, 18799, 28799]

    /// Where SwarmeBot keeps app-scoped data (logs, credentials). The harness
    /// itself keeps its data in `~/.swarmebot` regardless.
    public static var userData: URL {
        AppPaths.home
            .appendingPathComponent("Library/Application Support/SwarmeBot", isDirectory: true)
    }

    public static var logDirectory: URL {
        AppPaths.home
            .appendingPathComponent("Library/Logs/SwarmeBot", isDirectory: true)
    }

    /// Build the command for a given port. Nil means there is nothing to run.
    /// The Swift engine binary: bundled in Helpers, or next to the app's own
    /// binary in a SwiftPM build directory.
    public static func swiftEngine(bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        let candidates = [
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/swarme-harness"),
            bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("swarme-harness"),
        ].compactMap { $0 }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    public static func swiftCommand(port: Int, bundle: Bundle = .main) -> HarnessCommand? {
        guard let binary = swiftEngine(bundle: bundle) else { return nil }
        return HarnessCommand(
            executable: binary, arguments: [],
            workingDirectory: HarnessEngine.realDataDir,
            environment: {
                var env = [
                    "OMB_PORT": String(port), "OMB_WEBHOOK_PORT": String(port + 1),
                    "OMB_DATA_DIR": HarnessEngine.realDataDir.path, "OMB_USER_DATA": userData.path,
                ]
                // Absent unless the person turned it on. The driver still
                // does not start until a bot's turn asks for this Mac.
                if AppPaths.defaults.bool(forKey: "localComputerEnabled") { env["OMB_LOCAL_COMPUTER"] = "1" }
                return env
            }()
        )
    }
}

/// The PATH a login shell would have.
///
/// A GUI app launched from Finder inherits launchd's PATH — `/usr/bin:/bin:…`
/// — which has neither Homebrew nor nvm in it. The harness already augments
/// PATH itself before spawning CLIs. The engine is a native binary, so this
/// PATH is only for the CLIs that binary launches.
public enum LoginShell {
    public static func path() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '%s' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        // an interactive shell may print a banner first; PATH is the last line
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").last.map(String.init)
    }

    public static func find(_ name: String, in path: String?) -> URL? {
        let fm = FileManager.default
        for dir in (path ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        for fallback in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = URL(fileURLWithPath: fallback).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// Owns the harness process for the life of the app.
@MainActor
public final class HarnessLauncher {
    public private(set) var state: HarnessState = .idle {
        didSet { onChange?(state) }
    }
    public var onChange: ((HarnessState) -> Void)?

    private var process: Process?
    private var stopping = false
    private var restarts = 0
    private var logHandle: FileHandle?
    /// Why the last spawn did not come up. The port list is only a guess.
    private var launchError: String?

    public init() {}

    public var baseURL: URL? {
        guard case let .running(port, _) = state else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    // MARK: - Starting

    public func start() async {
        stopping = false
        state = .starting(tr("Avvio del motore…"))
        let env = ProcessInfo.processInfo.environment

        if let raw = env["SWARMEBOT_HARNESS_URL"], let url = URL(string: raw), let port = url.port {
            if await Self.identify(port: port, pid: nil) {
                state = .running(port: port, owned: false)
            } else {
                state = .failed(tr("Nessun harness risponde su %@.", raw))
            }
            return
        }

        do {
            let backup = try await Task.detached { try HarnessEngine.backupRealDataIfNeeded() }.value
            log.info("backup of ~/.swarmebot at \(backup.path)")
        } catch {
            state = .failed(tr("Backup di ~/.swarmebot non riuscito, il motore non parte: %@", String(describing: error)))
            return
        }
        do {
            try HarnessEngine.ensureRuntimeDirectories()
        } catch {
            state = .failed(tr("Impossibile preparare ~/.swarmebot: %@", error.localizedDescription))
            return
        }
        let engine = HarnessEngine.selected
        for port in HarnessLocator.ports where await Self.identify(port: port, pid: nil, engine: engine) {
            // our own binary, rebuilt since that process started: attaching
            // would keep the app on the old engine until someone kills it
            if let pid = await Self.healthPid(port: port), Self.isStale(pid: pid) {
                writeLog("replacing stale harness pid=\(pid) on \(port)")
                await Self.terminate(pid: pid)
                continue
            }
            log.info("attaching to the harness already on \(port)")
            state = .running(port: port, owned: false)
            return
        }

        let shellPath = await Task.detached { LoginShell.path() }.value
        launchError = nil

        // two passes, like Electron: a quit-and-reopen can race the dying
        // instance's server during teardown
        for attempt in 0..<2 {
            for port in HarnessLocator.ports {
                guard let command = HarnessLocator.swiftCommand(port: port) else {
                    state = .failed(tr("Motore non trovato: swarme-harness non è accanto all'app. Reinstalla SwarmeBot, oppure usa SWARMEBOT_HARNESS_URL per collegarti a un motore già avviato."))
                    return
                }
                state = .starting(tr("Avvio del motore sulla porta %@…", String(port)))
                if await spawn(command, port: port, shellPath: shellPath) {
                    restarts = 0
                    state = .running(port: port, owned: true)
                    return
                }
            }
            if attempt == 0 { try? await Task.sleep(for: .milliseconds(2500)) }
        }
        var message = tr("Impossibile avviare il motore: le porte 8799/18799/28799 sono occupate o il processo esce subito.")
        if let launchError { message += " \(launchError)" }
        message += " " + tr("Vedi ~/Library/Logs/SwarmeBot/server.log.")
        state = .failed(message)
    }

    private func spawn(_ command: HarnessCommand, port: Int, shellPath: String?) async -> Bool {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        do {
            try HarnessEngine.ensureDirectories([command.workingDirectory])
        } catch {
            launchError = error.localizedDescription
            writeLog("data dir: \(error.localizedDescription)")
            return false
        }
        process.currentDirectoryURL = command.workingDirectory
        var environment = ProcessInfo.processInfo.environment
        if let shellPath { environment["PATH"] = shellPath }
        environment.merge(command.environment) { _, new in new }
        // workspace secrets live in the Keychain, never in config.json
        environment.merge(CredentialStore.environment) { _, new in new }
        // the vault's key: the engine takes it out of its environment at once
        if let key = VaultKey.loadOrCreate() { environment[VaultKey.environmentName] = key.base64EncodedString() }
        process.environment = environment

        let handle = openLog()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { readable in
            let data = readable.availableData
            guard !data.isEmpty else { readable.readabilityHandler = nil; return }
            handle?.write(data)
        }
        writeLog("spawn \(command.executable.path) \(command.arguments.joined(separator: " ")) port=\(port)")

        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in self?.exited(finished, code: code) }
        }
        do {
            try process.run()
        } catch {
            launchError = error.localizedDescription
            writeLog("spawn failed: \(error.localizedDescription)")
            return false
        }
        self.process = process
        let pid = Int(process.processIdentifier)

        // fresh machine: first boot writes data dirs, so give it 20s
        for _ in 0..<40 {
            if !process.isRunning {
                let code = process.terminationStatus
                let how = process.terminationReason == .uncaughtSignal ? tr("segnale %@", String(code)) : tr("codice %@", String(code))
                launchError = tr("Il processo è uscito subito (%@).", how)
                self.process = nil
                return false
            }
            if await Self.identify(port: port, pid: pid) { return true }
            if await Self.identify(port: port, pid: nil) {
                // someone else answered — our child lost the bind race
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        process.terminationHandler = nil
        process.terminate()
        self.process = nil
        return false
    }

    private func exited(_ finished: Process, code: Int32) {
        writeLog("exited code=\(code)")
        guard finished === process else { return }
        process = nil
        guard !stopping else { return }
        // A crash mid-session: restart with backoff, but not forever — a
        // harness that dies on boot every time needs a person, not a loop.
        restarts += 1
        guard restarts <= 5 else {
            state = .failed(tr("Il motore si è chiuso %@ volte di seguito. Vedi ~/Library/Logs/SwarmeBot/server.log.", String(restarts)))
            return
        }
        let delay = min(1 << restarts, 15)
        state = .starting(tr("Il motore si è chiuso (codice %@); riavvio tra %@s…", String(code), String(delay)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.start()
        }
    }

    // MARK: - Stopping

    /// SIGTERM, then SIGKILL after a grace period. The harness interrupts
    /// running turns on SIGTERM, which is what lets the CLIs it spawned exit
    /// with it instead of outliving the app.
    public func stop() {
        stopping = true
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        self.process = nil
        state = .idle
    }

    // MARK: - Identity

    /// True when `port` serves a SwarmeBot harness — and, with `pid`, only
    /// when it is *that* process. A dev server has the same API shape, so the
    /// shape alone cannot tell our child from someone else's.
    /// With `engine`, only a harness of that engine counts: attaching the
    /// Swift preview to a running Node engine (or the reverse) would show
    /// the other engine's data under this one's name.
    public nonisolated static func identify(port: Int, pid: Int?, engine: HarnessEngine? = nil) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let health = try? JSONDecoder().decode(HealthProbe.self, from: data),
              health.app == "swarmebot"
        else { return false }
        if let engine, (health.engine ?? "node") != engine.rawValue { return false }
        return pid.map { $0 == health.pid } ?? true
    }

    nonisolated static func healthPid(port: Int) async -> Int32? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let health = try? JSONDecoder().decode(HealthProbe.self, from: data) else { return nil }
        return Int32(health.pid)
    }

    /// True when `pid` runs the very engine binary this app would start, and
    /// that file was written after the process began.
    nonisolated static func isStale(pid: Int32) -> Bool {
        guard let ours = HarnessLocator.swiftEngine()?.resolvingSymlinksInPath().path else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        guard path == ours else { return false }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              let built = (try? FileManager.default.attributesOfItem(atPath: ours))?[.modificationDate] as? Date
        else { return false }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
        return built > started
    }

    /// SIGTERM, which lets it interrupt its turns, then SIGKILL after 3s.
    nonisolated static func terminate(pid: Int32) async {
        kill(pid, SIGTERM)
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        kill(pid, SIGKILL)
        try? await Task.sleep(for: .milliseconds(300))
    }

    private struct HealthProbe: Decodable {
        var app: String
        var pid: Int
        var engine: String?
    }

    // MARK: - Log

    private func openLog() -> FileHandle? {
        if let logHandle { return logHandle }
        let dir = HarnessLocator.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("server.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        logHandle = handle
        return handle
    }

    private func writeLog(_ line: String) {
        log.info("\(line, privacy: .public)")
        let stamp = ISO8601DateFormatter().string(from: Date())
        openLog()?.write(Data("[\(stamp)] \(line)\n".utf8))
    }
}
