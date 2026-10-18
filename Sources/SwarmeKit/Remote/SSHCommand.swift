// Running ssh for administration — bot-remoto §5.2–§5.3.
//
// Always the system `/usr/bin/ssh`, with options built in one place:
// SwarmeBot's own key and known_hosts, strict host checking, one master
// connection per login. Nothing secret goes on argv: scripts, files and
// passwords travel on stdin or through askpass.
import Foundation

public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String
        public var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Run to completion; stdin is written then closed. `timeout` kills the process.
    public static func run(_ executable: String, _ args: [String], stdin: Data? = nil, environment: [String: String]? = nil,
                           timeout: TimeInterval = 120) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        // read while running: a full pipe would block the child forever
        let collected = Collected()
        out.fileHandleForReading.readabilityHandler = { handle in collected.append(out: handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in collected.append(err: handle.availableData) }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collected.append(out: out.fileHandleForReading.readDataToEndOfFile())
                collected.append(err: err.fileHandleForReading.readDataToEndOfFile())
                let (stdout, stderr) = collected.take()
                continuation.resume(returning: Result(status: finished.terminationStatus, stdout: stdout,
                                                      stderr: String(decoding: stderr, as: UTF8.self)))
            }
            do { try process.run() } catch {
                continuation.resume(throwing: Failure(message: "\(executable): \(error.localizedDescription)"))
                return
            }
            if let stdin {
                DispatchQueue.global().async {
                    try? input.fileHandleForWriting.write(contentsOf: stdin)
                    try? input.fileHandleForWriting.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        func append(out data: Data) { lock.lock(); out.append(data); lock.unlock() }
        func append(err data: Data) { lock.lock(); err.append(data); lock.unlock() }
        func take() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }
}

/// Why an ssh call failed, in the terms the setup screen shows.
public enum SSHFailure: LocalizedError, Equatable {
    case hostKeyChanged
    case hostKeyUnknown
    case authentication
    case unreachable(String)
    case remote(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .hostKeyChanged: return "La chiave del server è cambiata: va approvata di nuovo prima di continuare"
        case .hostKeyUnknown: return "Il fingerprint del server non è ancora stato approvato"
        case .authentication: return "Accesso rifiutato: chiave non installata o password sbagliata"
        case let .unreachable(detail): return "Server non raggiungibile: \(detail)"
        case let .remote(status, message): return message.isEmpty ? "Comando fallito sul server (codice \(status))" : message
        }
    }

    /// ssh exits 255 for its own failures; the text says which.
    static func classify(status: Int32, stderr: String) -> SSHFailure? {
        guard status != 0 else { return nil }
        let text = stderr.lowercased()
        if text.contains("remote host identification has changed") || text.contains("host key for") && text.contains("has changed") {
            return .hostKeyChanged
        }
        if text.contains("host key verification failed") || text.contains("no matching host key") { return .hostKeyUnknown }
        if text.contains("permission denied") { return .authentication }
        if status == 255, let line = stderr.split(separator: "\n").last(where: { $0.lowercased().contains("ssh:") || $0.lowercased().contains("connect") }) {
            return .unreachable(String(line).trimmingCharacters(in: .whitespaces))
        }
        return .remote(status: status, message: stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").suffix(3).joined(separator: "\n"))
    }
}

public struct SSHCommand: Sendable {
    public let identity: SSHIdentity
    public let store: SSHIdentityStore
    static let ssh = "/usr/bin/ssh"

    public init(identity: SSHIdentity, store: SSHIdentityStore) {
        self.identity = identity
        self.store = store
    }

    /// The options every call shares. `password` switches key-only BatchMode
    /// off for the one call that installs the key.
    public func options(password: Bool = false) -> [String] {
        var options = [
            "-p", String(identity.port),
            "-l", identity.user,
            "-o", "IdentitiesOnly=yes",
            "-o", "IdentityFile=\(store.keyFile(identity).path)",
            "-o", "UserKnownHostsFile=\(store.knownHosts.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
        ]
        if password {
            options += [
                "-o", "BatchMode=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "ControlMaster=no",
            ]
        } else {
            options += [
                "-o", "BatchMode=yes",
                "-o", "PreferredAuthentications=publickey",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(store.controlDirectory.path)/%C",
                "-o", "ControlPersist=10m",
            ]
        }
        return options
    }

    /// argv for one remote command. The command is a fixed string of ours;
    /// anything variable goes on stdin.
    public func arguments(_ remoteCommand: String, password: Bool = false) -> [String] {
        options(password: password) + ["--", identity.host, remoteCommand]
    }

    /// Run `remoteCommand` with the key. Throws an SSHFailure on failure.
    @discardableResult
    public func run(_ remoteCommand: String, stdin: Data? = nil, timeout: TimeInterval = 120) async throws -> ProcessRunner.Result {
        try store.ensure()
        let result = try await ProcessRunner.run(Self.ssh, arguments(remoteCommand), stdin: stdin, environment: Self.cleanEnvironment(), timeout: timeout)
        if let failure = SSHFailure.classify(status: result.status, stderr: result.stderr) { throw failure }
        return result
    }

    /// Close the shared master connection. Calls after it start a fresh one,
    /// which checks the host key and the ssh key again: needed after the key
    /// is removed or another host key approved, or the master (alive up to
    /// ControlPersist) would keep answering for the old state.
    public func closeMaster() async {
        _ = try? await ProcessRunner.run(Self.ssh, options() + ["-O", "exit", "--", identity.host], environment: Self.cleanEnvironment(), timeout: 10)
    }

    /// Run with the password instead of the key (installing the key, §5.3).
    @discardableResult
    public func runWithPassword(_ remoteCommand: String, password: String, stdin: Data? = nil, timeout: TimeInterval = 120) async throws -> ProcessRunner.Result {
        try store.ensure()
        let askpass = try AskPass()
        defer { askpass.finish() }
        var env = Self.cleanEnvironment()
        env[AskPass.variable] = password
        env["SSH_ASKPASS"] = askpass.script.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? "swarmebot:0"
        let result = try await ProcessRunner.run(Self.ssh, arguments(remoteCommand, password: true), stdin: stdin, environment: env, timeout: timeout)
        if let failure = SSHFailure.classify(status: result.status, stderr: result.stderr) { throw failure }
        return result
    }

    /// No agent, no inherited ssh config tricks: only what we pass.
    static func cleanEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = nil
        env["SSH_ASKPASS"] = nil
        env["SSH_ASKPASS_REQUIRE"] = nil
        return env
    }
}

/// The password reaches ssh through askpass: a 0700 script that prints an
/// environment variable set on the ssh process alone. Nothing on disk, nothing
/// on argv, and another user cannot read another's process environment.
final class AskPass {
    static let variable = "SWARMEBOT_SSH_PASSWORD"
    let directory: URL
    let script: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sbask-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        script = directory.appendingPathComponent("askpass")
        try "#!/bin/sh\nprintf '%s\\n' \"$\(Self.variable)\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }

    func finish() {
        try? FileManager.default.removeItem(at: directory)
    }
}
