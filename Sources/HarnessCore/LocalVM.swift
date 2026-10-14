// The shared Local VM — `server/container-computer.ts` and `local-vm-lease.ts`.
//
// One desktop container (`swarmebot-computer`) for every bot. Agents do not
// get a reimplemented click API: they mount Cua Driver's own MCP server
// through `swarme-harness mcp-container`. Docker, Podman and Apple's
// `container` are detected the same way as the Node engine.
import Foundation

@MainActor
final class LocalVM {
    nonisolated static let driverVersion = "0.20.0"
    static let baseDigest = "sha256:274eb636f5cf3fc58f705916ee72b7a701270b3877369d08533a385c5325be9b"
    static let baseImage = "docker.io/trycua/xfce-cua@\(baseDigest)"
    static let image = "localhost/swarmebot/cua-local-vm:driver-\(driverVersion)-v3"
    nonisolated static let container = "swarmebot-computer"
    nonisolated static let socket = "/run/user/1000/swarmebot-cua.sock"
    nonisolated static let executable = "/usr/local/libexec/swarmebot/cua-driver"
    static let guestWorkspace = "/home/cua/workspace"
    nonisolated static let display = ":1"
    static let idleMs = 8 * 60 * 60_000
    static let viewer = "http://127.0.0.1:6080/vnc.html"

    let paths: DataPaths
    let lease = LocalVmLease(ttlMs: 30 * 60_000)
    var lifecycleBusy = false
    var activeThread: String?
    private var idleTask: Task<Void, Never>?

    init(paths: DataPaths) { self.paths = paths }

    var workspace: String { paths.root.appendingPathComponent("vm-home").path }

    func touchIdle() {
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleMs) * 1_000_000)
            guard !Task.isCancelled, !self.lifecycleBusy, self.activeThread == nil else { return }
            self.lifecycleBusy = true
            defer { self.lifecycleBusy = false }
            let status = await self.status()
            if status["container"]?.string == "running", let runtime = status["runtime"]?.string {
                _ = try? await Self.run(runtime, ["rm", "-f", Self.container], timeout: 120)
            }
        }
    }

    func cancelIdle() { idleTask?.cancel(); idleTask = nil }

    /// `exec … cua-driver`, the one argv the panel, the bridge and a VPS share.
    nonisolated static func cuaExecArgs(_ args: [String], container: String = container, interactive: Bool = false) -> [String] {
        var argv = ["exec"]
        if interactive { argv.append("-i") }
        argv += ["-u", "cua", "-e", "HOME=/home/cua", "-e", "DISPLAY=\(display)",
                 "-e", "CUA_DRIVER_INSTALL_CHANNEL=python_package", "-e", "CUA_DRIVER_RS_TELEMETRY_ENABLED=0",
                 container, executable]
        return argv + args
    }

    func status() async -> JSONObject {
        let platform = "darwin"
        var row = JSONObject([
            ("platform", .string(platform)), ("runtime", .null), ("available", .array([])),
            ("daemonUp", false), ("image", false), ("imageMatches", false), ("managed", false),
            ("container", "missing"), ("network", "unknown"), ("security", "unknown"), ("persistence", "unknown"),
            ("desktopReady", false), ("desktop_error", .null), ("ready", false),
            ("problem", "Install a supported container runtime first"),
            ("image_ref", .string(Self.image)), ("image_id", .null), ("base_image_ref", .string(Self.baseImage)),
            ("driver_version", .string(Self.driverVersion)), ("container_name", .string(Self.container)),
            ("workspace_path", .string(workspace)), ("workspace_guest_path", .string(Self.guestWorkspace)),
            ("viewer_url", .string(Self.viewer)),
        ])
        let candidates = ["docker", "podman", "container"]
        var available: [String] = []
        for name in candidates {
            if (try? await Self.run("/usr/bin/which", [name], timeout: 4)) != nil { available.append(name) }
        }
        row["available"] = .strings(available)
        var runtime: String?
        for name in available {
            let args = name == "container" ? ["system", "status"] : ["info", "--format", "{{.ServerVersion}}"]
            if (try? await Self.run(name, args, timeout: 10)) != nil { runtime = name; break }
        }
        row["runtime"] = runtime.map(JSON.string) ?? .null
        row["daemonUp"] = .bool(runtime != nil)
        guard let runtime else { return row }

        var imageId: String?
        if let stdout = try? await Self.run(runtime, ["image", "inspect", Self.image], timeout: 8),
           let parsed = try? JSON.parse(stdout).array?.first {
            let labels = parsed["Config"]?["Labels"]?.object ?? parsed["config"]?["Labels"]?.object
                ?? parsed["config"]?["labels"]?.object ?? parsed["configuration"]?["labels"]?.object
            row["image"] = .bool(Self.imageLabels(labels))
            imageId = Self.imageId(parsed["Id"]?.string ?? parsed["id"]?.string ?? parsed["configuration"]?["descriptor"]?["digest"]?.string)
            row["image_id"] = imageId.map(JSON.string) ?? .null
        }

        if let stdout = try? await Self.run(runtime, ["inspect", Self.container], timeout: 8),
           let detail = try? JSON.parse(stdout).array?.first {
            if runtime == "container" {
                row["container"] = .string(detail["status"]?["state"]?.string == "running" ? "running" : "stopped")
            } else {
                let running = detail["State"]?["Running"]?.bool == true
                row["container"] = .string(running ? "running" : "stopped")
                let bindings = detail["HostConfig"]?["PortBindings"]?.object
                row["network"] = .string(Self.portsAreLocal(bindings) ? "loopback" : "unsafe")
                let configImage = detail["Config"]?["Image"]?.string
                let containerImage = Self.imageId(detail["Image"]?.string)
                row["imageMatches"] = .bool(configImage == Self.image && Self.imageLabels(detail["Config"]?["Labels"]?.object)
                    && imageId != nil && containerImage == imageId)
                row["managed"] = .bool(Self.containerLabels(detail["Config"]?["Labels"]?.object))
                row["persistence"] = .string(Self.mountIsSafe(detail["Mounts"]?.array, workspace: workspace) ? "durable" : "unsafe")
                row["security"] = .string(Self.hardened(detail["HostConfig"]?.object) ? "hardened" : "unsafe")
                row["viewer_url"] = .string(Self.viewerURL(detail["Config"]?["Env"]?.array))
            }
        }

        let canProbe = row["container"]?.string == "running" && row["imageMatches"]?.bool == true && row["managed"]?.bool == true
            && row["network"]?.string == "loopback" && row["security"]?.string == "hardened" && row["persistence"]?.string == "durable"
        if canProbe {
            do {
                let version = try await Self.run(runtime, Self.cuaExecArgs(["--version"]), timeout: 8)
                if version.trimmingCharacters(in: .whitespacesAndNewlines) != "cua-driver \(Self.driverVersion)" {
                    throw VMError(message: "expected cua-driver \(Self.driverVersion)")
                }
                _ = try await Self.run(runtime, Self.cuaExecArgs(["status", "--socket", Self.socket]), timeout: 8)
                let health = try await Self.run(runtime, Self.cuaExecArgs(["call", "health_report", "{}", "--socket", Self.socket]), timeout: 15)
                let report = try JSON.parse(health)
                let overall = report["overall"]?.string
                if report["schema_version"]?.string != "1" || report["checks"]?.array == nil || (overall != "ok" && overall != "degraded") {
                    throw VMError(message: "Cua health report is \(overall ?? "invalid")")
                }
                let shot = "/tmp/swarmebot-readiness.png"
                _ = try await Self.run(runtime, Self.cuaExecArgs(["call", "get_desktop_state", "{}", "--socket", Self.socket, "--screenshot-out-file", shot]), timeout: 20)
                let captured = try await Self.run(runtime, ["exec", Self.container, "base64", "-w0", shot], timeout: 20)
                if !Self.wholeScreenshot(Data(base64Encoded: captured.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Data()) {
                    throw VMError(message: "Cua Driver returned an incomplete readiness screenshot")
                }
                row["desktopReady"] = true
            } catch {
                var note = String(error.localizedDescription.prefix(320))
                if let log = try? await Self.run(runtime, ["exec", Self.container, "tail", "-n", "4", "/var/log/supervisor/cua-driver.error.log"], timeout: 4) {
                    let trimmed = log.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    if !trimmed.isEmpty { note = String(trimmed.prefix(320)) }
                }
                row["desktop_error"] = .string(note)
            }
        }
        let problem = Self.problem(row)
        row["problem"] = problem.map(JSON.string) ?? .null
        row["ready"] = .bool(problem == nil)
        return row
    }

    func payload() async -> JSONObject {
        var row = await status()
        row["commands"] = .object(Self.commands(row["runtime"]?.string, workspace: workspace))
        row["idle_timeout_ms"] = .number(Double(Self.idleMs))
        return row
    }

    func action(_ name: String) async throws -> JSONObject {
        let before = await status()
        guard let runtime = before["runtime"]?.string else {
            throw VMError(message: before["problem"]?.string ?? "No container runtime is installed")
        }
        if before["daemonUp"]?.bool != true { throw VMError(message: before["problem"]?.string ?? "\(runtime) is not running") }
        if name == "run", before["container"]?.string != "missing" {
            throw VMError(message: "A Local VM already exists; remove it before creating a replacement")
        }
        if name == "run", before["image"]?.bool != true {
            throw VMError(message: "Prepare the Cua desktop image before creating the Local VM")
        }
        if name == "start" { throw VMError(message: "This desktop image cannot safely resume; remove and recreate the Local VM") }
        if name == "stop", before["container"]?.string != "running" { throw VMError(message: "The Local VM is not running") }
        if name == "remove", before["container"]?.string == "missing" { return await payload() }
        if name == "pull" {
            _ = try await Self.run(runtime, ["pull", Self.baseImage], timeout: 120)
        } else if name == "run" {
            try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
            _ = try await Self.run(runtime, Self.runArgs(workspace: workspace), timeout: 120)
        } else if name == "remove" {
            _ = try await Self.run(runtime, ["rm", "-f", Self.container], timeout: 120)
        } else if name == "stop" {
            _ = try await Self.run(runtime, ["stop", Self.container], timeout: 120)
        }
        return await payload()
    }

    /// The spawn contract Claude, Codex and ACP mount as the `computer` server.
    func mcp(runtime: String, controlURL: String, token: String) -> MCPServer {
        MCPServer(command: HelperCommand.executable, args: ["mcp-container", runtime, Self.container, Self.socket], env: [
            "ELECTRON_RUN_AS_NODE": "1", "OMB_CONTROL_URL": .string(controlURL), "OMB_CONTROL_TOKEN": .string(token),
        ])
    }

    static func commands(_ runtime: String?, workspace: String) -> JSONObject {
        let install = "brew install podman; podman machine init; podman machine start"
        let view = JSON.string(viewer)
        guard let runtime else {
            return JSONObject([("install", .string(install)), ("runtimeStart", .null), ("pull", .null), ("run", .null),
                               ("start", .null), ("stop", .null), ("remove", .null), ("view", view)])
        }
        let command = { (args: [String]) in JSON.string(([runtime] + args).joined(separator: " ")) }
        let start: JSON = runtime == "container" ? "container system start"
            : runtime == "podman" ? "podman machine init; podman machine start"
            : runtime == "docker" ? "colima start || open -a Docker" : .null
        return JSONObject([
            ("install", .string(install)), ("runtimeStart", start),
            ("pull", command(["pull", baseImage])), ("run", command(runArgs(workspace: workspace))),
            ("start", .null), ("stop", command(["stop", container])),
            ("remove", command(["rm", runtime == "container" ? "--force" : "-f", container])), ("view", view),
        ])
    }

    /// `containerRunArgs` for Docker and Podman, password left at the documented default.
    static func runArgs(workspace: String) -> [String] {
        ["run", "-d", "--name", container,
         "--label", "com.swarmebot.local-vm=1", "--label", "com.swarmebot.cua-driver=\(driverVersion)",
         "--label", "com.swarmebot.cua-base=\(baseDigest)", "--label", "com.swarmebot.image-layer=3",
         "--label", "com.swarmebot.workspace=1",
         "--hostname", container, "--memory", "4g", "--memory-swap", "4g", "--cpus", "2", "--pids-limit", "512",
         "--ipc", "private", "--cgroupns", "private", "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID",
         "--shm-size", "512m",
         "--mount", "type=bind,source=\(workspace),target=\(guestWorkspace)",
         "-e", "VNC_PW=CHANGE_ME", "-p", "127.0.0.1:6080:6901", image]
    }

    private static func problem(_ row: JSONObject) -> String? {
        if row["runtime"]?.isNull != false { return "Install a supported container runtime first" }
        if row["daemonUp"]?.bool != true { return "Start \(row["runtime"]?.string ?? "") first" }
        if row["image"]?.bool != true { return "Prepare the Cua desktop image with Driver \(driverVersion)" }
        if row["container"]?.string == "missing" { return "Create the Local VM" }
        if row["imageMatches"]?.bool != true { return "The existing Local VM uses an older desktop or Cua Driver; recreate it" }
        if row["managed"]?.bool != true { return "The existing container was not created by SwarmeBot; recreate it" }
        if row["network"]?.string == "unsafe" { return "The existing Local VM exposes its viewer publicly; recreate it" }
        if row["security"]?.string == "unsafe" { return "The existing Local VM is missing safety limits; recreate it" }
        if row["persistence"]?.string == "unsafe" { return "The existing Local VM is missing its durable workspace; recreate it" }
        if row["container"]?.string == "stopped" { return "This desktop image cannot safely resume; recreate the Local VM" }
        if let error = row["desktop_error"]?.string { return "The Local VM desktop failed to start: \(error)" }
        if row["desktopReady"]?.bool != true { return "The Local VM started, but Cua Driver is not ready yet" }
        return nil
    }

    private static func imageLabels(_ labels: JSONObject?) -> Bool {
        labels?["com.swarmebot.local-vm"]?.string == "1"
            && labels?["com.swarmebot.cua-driver"]?.string == driverVersion
            && labels?["com.swarmebot.cua-base"]?.string == baseDigest
            && labels?["com.swarmebot.image-layer"]?.string == "3"
    }

    private static func containerLabels(_ labels: JSONObject?) -> Bool {
        imageLabels(labels) && labels?["com.swarmebot.workspace"]?.string == "1"
    }

    private static func imageId(_ id: String?) -> String? {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "sha256:", with: "")
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private static func portsAreLocal(_ bindings: JSONObject?) -> Bool {
        let viewer = bindings?["6901/tcp"]?.array ?? []
        let published = (bindings ?? JSONObject()).flatMap { $0.value.array ?? [] }
        return !viewer.isEmpty && published.count == viewer.count && published.allSatisfy { entry in
            ["127.0.0.1", "::1", "[::1]"].contains(entry["HostIp"]?.string ?? "")
        }
    }

    private static func mountIsSafe(_ mounts: [JSON]?, workspace: String) -> Bool {
        guard mounts?.count == 1, let mount = mounts?.first else { return false }
        return mount["Type"]?.string == "bind" && mount["Source"]?.string == workspace
            && mount["Destination"]?.string == guestWorkspace && mount["RW"]?.bool != false
    }

    private static func hardened(_ config: JSONObject?) -> Bool {
        guard let config else { return false }
        let drop = (config["CapDrop"]?.array ?? []).compactMap { $0.string?.lowercased() }
        let add = (config["CapAdd"]?.array ?? []).compactMap { $0.string?.lowercased().replacingOccurrences(of: "cap_", with: "") }.sorted()
        let unsafe = (config["SecurityOpt"]?.array ?? []).contains { option in
            option.string?.range(of: #"(?:^|=)(?:unconfined|disable)$"#, options: .regularExpression) != nil
        }
        let restart = config["RestartPolicy"]?["Name"]?.string
        let restartOK = restart == nil || restart?.isEmpty == true || restart == "no"
        let memory = config["Memory"]?.double
        return memory == 4_294_967_296 && (config["MemorySwap"]?.double ?? 0) == 4_294_967_296
            && (config["NanoCpus"]?.double ?? 0) == 2_000_000_000 && config["PidsLimit"]?.double == 512
            && drop.contains("all") && add.joined(separator: ",") == "setgid,setuid"
            && config["Privileged"]?.bool == false && config["PidMode"]?.string?.isEmpty != false
            && config["IpcMode"]?.string == "private" && config["UTSMode"]?.string?.isEmpty != false
            && config["ShmSize"]?.double == 536_870_912
            && (config["Devices"]?.array ?? []).isEmpty && (config["DeviceRequests"]?.array ?? []).isEmpty
            && !unsafe && config["UsernsMode"]?.string?.isEmpty != false && config["CgroupnsMode"]?.string == "private"
            && config["OomKillDisable"]?.bool != true && config["AutoRemove"]?.bool != true && restartOK
    }

    private static func viewerURL(_ env: [JSON]?) -> String {
        let password = env?.compactMap(\.string).first { $0.hasPrefix("VNC_PW=") }.map { String($0.dropFirst("VNC_PW=".count)) }
        guard let password, !password.isEmpty else { return viewer }
        let query = "autoconnect=true&resize=scale&password=\(password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? password)"
        return "\(viewer)#\(query)"
    }

    private static func wholeScreenshot(_ bytes: Data) -> Bool {
        guard bytes.count >= 512 else { return false }
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47]) {
            return bytes.suffix(12).contains(0x49) && String(decoding: bytes.suffix(12), as: UTF8.self).contains("IEND")
        }
        return bytes.starts(with: [0xff, 0xd8]) && bytes.suffix(32).contains(0xff) && bytes.suffix(32).contains(0xd9)
    }

    static func run(_ command: String, _ args: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command == "docker" || command == "podman" || command == "container"
                ? (EnvPath.which(command) ?? command) : command)
            process.arguments = args
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            let box = ResumeBox()
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 { box.resume(continuation, .success(text)) }
                else { box.resume(continuation, .failure(VMError(message: "exit \(process.terminationStatus)"))) }
            }
            do { try process.run() } catch {
                box.resume(continuation, .failure(error))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func resume(_ continuation: CheckedContinuation<String, Error>, _ result: Result<String, Error>) {
        lock.lock()
        let first = !resumed
        resumed = true
        lock.unlock()
        if first { continuation.resume(with: result) }
    }
}

struct VMError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// A short renewable fence for the one shared desktop. Synchronous, like the Node class.
final class LocalVmLease: @unchecked Sendable {
    struct Record { var threadId: String; var botId: String; var expiresAt: Double }
    private let ttlMs: Double
    private var record: Record?
    private let lock = NSLock()

    init(ttlMs: Double) { self.ttlMs = ttlMs }

    func current(busy: (String) -> Bool, now: Double = Date().timeIntervalSince1970 * 1000) -> Record? {
        lock.lock(); defer { lock.unlock() }
        if let record, record.expiresAt <= now || !busy(record.botId) { self.record = nil }
        return record
    }

    func claim(threadId: String, botId: String, busy: (String) -> Bool, now: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let record, record.expiresAt <= now || !busy(record.botId) { self.record = nil }
        if let record, record.threadId != threadId { return false }
        record = Record(threadId: threadId, botId: botId, expiresAt: now + ttlMs)
        return true
    }

    func touch(threadId: String, now: Double = Date().timeIntervalSince1970 * 1000) {
        lock.lock(); defer { lock.unlock() }
        if let record, record.expiresAt <= now { self.record = nil; return }
        if record?.threadId == threadId { record?.expiresAt = now + ttlMs }
    }

    func release(threadId: String) {
        lock.lock(); defer { lock.unlock() }
        if record?.threadId == threadId { record = nil }
    }
}
