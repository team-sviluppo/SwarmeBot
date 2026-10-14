// Spawning the agent CLIs — `server/procs.ts`, macOS only.
//
// Foundation's `Process` cannot put the child in its own process group, and
// that is the one thing a CLI driver needs: `claude` spawns MCP servers of its
// own, and stopping a turn must reap them too (kill(-pid), as the Node engine
// does with `detached: true`). So this is posix_spawn with
// POSIX_SPAWN_SETPGROUP, three pipes, and a reader thread per output stream.
//
// Delivery is on the main queue, in order: stdout lines, then stderr chunks,
// then — only once the process has exited AND both streams hit EOF — `close`,
// which is what Node's `close` event means and what every driver settles on.
import Foundation

public struct SpawnFailure: LocalizedError {
    public var message: String
    /// A setup problem the user can fix (not installed, not executable).
    public var setup: Bool
    public var errorDescription: String? { message }

    public init(message: String, setup: Bool) {
        self.message = message
        self.setup = setup
    }

    /// `describeSpawnFailure`: errno strings read as crashes; say what they mean.
    public static func describe(errno code: Int32, cli: String) -> SpawnFailure {
        switch code {
        case ENOENT: return SpawnFailure(message: "`\(cli)` isn't installed, or isn't on this app's PATH", setup: true)
        case EACCES, EPERM: return SpawnFailure(message: "`\(cli)` isn't executable — check its file permissions", setup: true)
        default: return SpawnFailure(message: "spawn failed: \(String(cString: strerror(code)))", setup: false)
        }
    }
}

public final class CLIProcess: @unchecked Sendable {
    public let pid: pid_t
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private var stdinOpen = true
    private let lock = NSLock()
    private var exited = false
    private var exitSource: DispatchSourceProcess?

    /// One complete stdout line (without the newline), UTF-8 decoded whole.
    public var onLine: (@MainActor (String) -> Void)?
    public var onStderr: (@MainActor (String) -> Void)?
    /// Exit code, nil when killed by a signal (Node's `code === null`).
    public var onClose: (@MainActor (Int32?) -> Void)?

    /// The argv a configured CLI string resolves to: an existing path with
    /// spaces is taken whole, otherwise the string is tokenized and its head
    /// looked up on the augmented PATH (fixed wrapper args lead).
    public static func resolve(_ cli: String, args: [String]) -> (executable: String, args: [String])? {
        let trimmed = cli.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(" "), FileManager.default.fileExists(atPath: trimmed) { return (trimmed, args) }
        let split = EnvPath.split(cli)
        guard let head = split.first else { return nil }
        guard let executable = EnvPath.which(head) else { return nil }
        return (executable, Array(split.dropFirst()) + args)
    }

    /// Starts `cli args…`. Callbacks must be set before `start()`.
    public init(cli: String, args: [String], cwd: String?, environment: [String: String]) throws {
        guard let resolved = Self.resolve(cli, args: args) else { throw SpawnFailure.describe(errno: ENOENT, cli: cli) }
        // posix_spawn reports a failed chdir as ENOENT too, which would blame
        // the CLI for a working folder that was moved or deleted
        if let cwd {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SpawnFailure(message: "the working folder \(cwd) doesn't exist anymore — pick another one from the folder button under the composer", setup: true)
            }
        }

        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw SpawnFailure.describe(errno: errno, cli: cli)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // own process group, so killTree reaps the MCP servers it spawns;
        // close-on-exec by default, so no harness fd (sockets, the db) leaks
        // default signal handling and an empty mask: the engine ignores SIGTERM
        // itself (main.swift), and an ignored signal survives exec — a CLI
        // that inherited it could never be interrupted
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                   | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = [resolved.executable] + resolved.args
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var cArgs = argv.map { strdup($0) } + [nil]
        var cEnv = envp.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var child: pid_t = 0
        let result = posix_spawn(&child, resolved.executable, &actions, &attributes, &cArgs, &cEnv)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard result == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw SpawnFailure.describe(errno: result, cli: cli)
        }
        pid = child
        stdinFD = inPipe[1]
        // a write to a dead child must be an error, not a SIGPIPE that kills us
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
        stdoutFD = outPipe[0]
        stderrFD = errPipe[0]
    }

    private enum Stream {
        case line(String)
        case stderr(String)
        case streamClosed
        case exited(Int32?)
    }

    /// Begin delivering output and exit. Separate from init so callers can
    /// set the callbacks first without racing the first line.
    ///
    /// Everything funnels through one AsyncStream drained by one main-actor
    /// task: that keeps the order, and it does not depend on the main queue
    /// being the main thread (`dispatchMain()` parks the main thread, so
    /// `MainActor.assumeIsolated` on a main-queue block traps).
    public func start() {
        let (stream, continuation) = AsyncStream<Stream>.makeStream()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in
            if let code = self?.reap() { continuation.yield(.exited(code)) }
        }
        exitSource = source
        source.resume()
        // the child may already be gone before the source was armed
        if let code = reap() { continuation.yield(.exited(code)) }

        let out = stdoutFD, err = stderrFD
        Thread.detachNewThread {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(out, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                buffer.append(contentsOf: chunk[0..<count])
                // split on raw bytes: a multibyte character never straddles a line
                while let newline = buffer.firstIndex(of: 0x0A) {
                    continuation.yield(.line(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { continuation.yield(.line(String(decoding: buffer, as: UTF8.self))) }
            close(out)
            continuation.yield(.streamClosed)
        }
        Thread.detachNewThread {
            var chunk = [UInt8](repeating: 0, count: 16384)
            while true {
                let count = read(err, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                continuation.yield(.stderr(String(decoding: chunk[0..<count], as: UTF8.self)))
            }
            close(err)
            continuation.yield(.streamClosed)
        }
        Task { @MainActor in
            var openStreams = 2
            var exit: Int32?? = nil
            for await output in stream {
                switch output {
                case let .line(line): self.onLine?(line)
                case let .stderr(text): self.onStderr?(text)
                case .streamClosed: openStreams -= 1
                case let .exited(code): exit = .some(code)
                }
                if openStreams == 0, let code = exit {
                    continuation.finish()
                    self.closeStdin()
                    self.onClose?(code)
                    // drop the callbacks: they capture the driver's turn state
                    self.onLine = nil
                    self.onStderr = nil
                    self.onClose = nil
                }
            }
        }
    }

    /// waitpid once: the first time the child is seen gone, its exit code
    /// (itself nil when a signal killed it); nil while it runs.
    private func reap() -> Int32?? {
        lock.lock()
        defer { lock.unlock() }
        if exited { return nil }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return nil }
        exited = true
        exitSource?.cancel()
        // WIFEXITED / WEXITSTATUS, which Swift does not import
        return .some((status & 0x7F) == 0 ? (status >> 8) & 0xFF : nil)
    }

    public var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    public func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard stdinOpen else { return }
        let data = Array(text.utf8)
        let total = data.count
        var offset = 0
        while offset < total {
            let written = data.withUnsafeBytes { Darwin.write(stdinFD, $0.baseAddress! + offset, total - offset) }
            if written < 0 { if errno == EINTR { continue }; return }
            offset += written
        }
    }

    public func closeStdin() {
        lock.lock()
        defer { lock.unlock() }
        guard stdinOpen else { return }
        stdinOpen = false
        close(stdinFD)
    }

    /// `killCliTree`: SIGTERM the whole group — the CLI and every process it
    /// spawned. A no-op once the CLI has exited.
    public func killTree() {
        guard !hasExited else { return }
        if kill(-pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
    }

    deinit {
        exitSource?.cancel()
    }

    // MARK: - One-shot runs

    public struct Output: Sendable {
        public var code: Int32?
        public var stdout: String
        public var stderr: String
        public var ok: Bool { code == 0 }
    }

    /// `execCli`: run to completion, with a timeout after which the tree is
    /// killed and nil returned. Nil also when it could not be spawned.
    @MainActor
    public static func run(_ cli: String, _ args: [String], environment: [String: String], cwd: String? = nil,
                           timeout: TimeInterval) async -> Output? {
        guard let process = try? CLIProcess(cli: cli, args: args, cwd: cwd, environment: environment) else { return nil }
        return await withCheckedContinuation { continuation in
            var stdout = "", stderr = ""
            var finished = false
            let finish: (Output?) -> Void = { output in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: output)
            }
            process.onLine = { stdout += $0 + "\n" }
            process.onStderr = { stderr += $0 }
            process.onClose = { code in finish(Output(code: code, stdout: stdout, stderr: stderr)) }
            process.closeStdin()
            process.start()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !finished else { return }
                process.killTree()
                finish(nil)
            }
        }
    }
}
