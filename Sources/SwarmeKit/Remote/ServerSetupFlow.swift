// The "Aggiungi server" walk-through — bot-remoto §5.4, as a state machine
// the settings sheet draws. Each step runs when the person asks for it;
// a failure stays on its step with the reason, and `run()` resumes there.
import CompanionCore
import Foundation
import Observation

@MainActor
@Observable
public final class ServerSetupFlow {
    public enum Step: Int, CaseIterable, Comparable, Sendable {
        case hostKey, key, probe, root, engine, service, device, agents, done

        public static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .hostKey: return tr("Fingerprint del server")
            case .key: return tr("Chiave dedicata")
            case .probe: return tr("Controllo del server")
            case .root: return tr("Caddy, cartella dei socket, avvio automatico (root)")
            case .engine: return tr("Motore SwarmeBot")
            case .service: return tr("Servizio e rotte HTTPS")
            case .device: return tr("Token di questo Mac")
            case .agents: return tr("Claude Code, Codex e omp")
            case .done: return tr("Pronto")
            }
        }
    }

    // what the form asks
    public var name = ""
    public var host = ""
    public var port = 22
    public var user = ""
    public var site = ""
    public var prefix = ""
    public var tls: CaddySettings.TLS = .public
    /// Empty: the one Caddy serves directly. Set it when a proxy in a DMZ fronts the server (§6.3).
    public var chatURLOverride = ""

    // what the steps found
    public private(set) var step: Step = .hostKey
    public private(set) var running = false
    public private(set) var error: String?
    public private(set) var scannedKeys: [ScannedHostKey] = []
    public private(set) var identity: SSHIdentity?
    public private(set) var probe: RemoteProbe?
    public private(set) var engine: RemoteEngine?
    /// Asked for only when the key does not get in; never written anywhere.
    public var sshPassword = ""
    /// Asked for only when sudo wants one (often the same as the ssh password).
    public var sudoPassword = ""
    public private(set) var needsPassword = false
    public private(set) var needsSudoPassword = false

    @ObservationIgnored let identities: SSHIdentityStore
    @ObservationIgnored let engines: RemoteEngineStore
    @ObservationIgnored let linuxEngines: LinuxEngines
    @ObservationIgnored let agents: LocalAgents
    @ObservationIgnored let macBinary: (String) -> (url: URL, sha256: String)?
    /// What a long step is doing right now ("Scarico il motore Linux…"), for the sheet.
    public private(set) var activity: String?
    /// What the agents step did, one line per agent.
    public private(set) var agentsReport: [String] = []

    public init(identities: SSHIdentityStore, engines: RemoteEngineStore,
                linuxEngines: LinuxEngines = .standard, agents: LocalAgents = .thisMac,
                macBinary: @escaping (String) -> (url: URL, sha256: String)? = ServerSetupFlow.macEngine) {
        self.identities = identities
        self.engines = engines
        self.linuxEngines = linuxEngines
        self.agents = agents
        self.macBinary = macBinary
    }

    public var caddy: CaddySettings { CaddySettings(site: site, prefix: prefix, tls: tls) }

    public var chatURL: String {
        let override = chatURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        return caddy.directChatURL.replacingOccurrences(of: "SERVER", with: host)
    }

    /// A sensible prefix from the server and user names: `/srv1/deploy`.
    public func suggestPrefix() {
        guard prefix.isEmpty else { return }
        let server = host.split(separator: ".").first.map(String.init) ?? "server"
        prefix = "/\(server)/\(user)".lowercased().replacingOccurrences(of: #"[^a-z0-9/_-]"#, with: "-", options: .regularExpression)
    }

    public var formError: String? {
        if host.isEmpty || user.isEmpty { return tr("Indica server e utente") }
        if site.isEmpty { return tr("Indica il dominio (o :porta) su cui Caddy risponde") }
        do { try caddy.validate() } catch { return error.localizedDescription }
        if Connection.remote(chatURL: chatURL) == nil { return tr("L'URL di chat non è valido") }
        return nil
    }

    /// The root script the next step will run, to show before it runs.
    public var rootPreview: String {
        if probe?.isMac == true { return RemoteScripts.rootMac }
        return RemoteScripts.rootLinux + "\n\n" + tr("# poi, per le rotte:") + "\n" + RemoteScripts.caddyLinux
    }

    // MARK: Running

    /// Advance as far as possible; stops for an approval, a password or an error.
    public func run() async {
        guard !running else { return }
        running = true
        error = nil
        defer { running = false }
        do {
            while step != .done {
                guard try await perform(step) else { return }
                step = Step(rawValue: step.rawValue + 1) ?? .done
            }
        } catch let failure as SSHFailure where failure == .authentication && step == .key {
            needsPassword = true
            error = tr("Password non accettata")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The fingerprint shown matched the console: keep it and go on.
    public func approve(_ key: ScannedHostKey) async {
        guard let identity else { return }
        do {
            self.identity = try await HostKeys.approve(key, for: identity, store: identities)
            scannedKeys = []
            step = .key
            await run()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// False: waiting for the person (approval or password).
    private func perform(_ step: Step) async throws -> Bool {
        switch step {
        case .hostKey:
            if let message = formError { throw ProcessRunner.Failure(message: message) }
            let found = try identities.findOrCreate(host: host, port: port, user: user)
            identity = found
            if found.hostKey != nil { return true }
            scannedKeys = try await HostKeys.scan(host: found.host, port: found.port)
            return false
        case .key:
            guard let identity else { return false }
            let admin = RemoteAdmin(identity: identity, store: identities)
            if await admin.keyWorks() { return true }
            guard !sshPassword.isEmpty else { needsPassword = true; return false }
            self.identity = try await admin.installKey(password: sshPassword)
            needsPassword = false
            if sudoPassword.isEmpty { sudoPassword = sshPassword }
            return true
        case .probe:
            guard let identity else { return false }
            let found = try await RemoteAdmin(identity: identity, store: identities).probe()
            probe = found
            guard found.supported else {
                throw ProcessRunner.Failure(message: found.isMac ? tr("macOS %@: serve macOS 14 o successivo", found.version)
                                                                  : tr("Server %@ %@: servono Ubuntu 24.04 o 26.04 (o un Mac)", found.os, found.version))
            }
            guard found.engineArch != nil else { throw ProcessRunner.Failure(message: tr("Architettura %@ non supportata", found.arch)) }
            needsSudoPassword = !found.isRoot && found.sudo == "password"
            if found.sudo == "none", !found.isRoot {
                throw ProcessRunner.Failure(message: tr("L'utente %@ non può usare sudo: serve root una volta sola per Caddy e l'avvio automatico", user))
            }
            return true
        case .root:
            // the root step runs inside .service, with the routes; nothing to do yet but ask
            if needsSudoPassword, sudoPassword.isEmpty { return false }
            return true
        case .engine:
            guard let identity, let probe, let arch = probe.engineArch else { return false }
            let binary: (url: URL, sha256: String)
            if probe.isMac {
                guard let mac = macBinary(arch) else {
                    throw ProcessRunner.Failure(message: tr("Il motore di questa app non è per Mac %@: usa la build dell'app per quell'architettura", probe.arch))
                }
                binary = mac
            } else {
                activity = tr("Scarico e verifico il motore Linux %@…", arch)
                defer { activity = nil }
                binary = try await linuxEngines.engine(arch)
            }
            try await RemoteAdmin(identity: identity, store: identities).installEngine(binary: binary.url, sha256: binary.sha256, probe: probe)
            return true
        case .service:
            guard let identity, let probe else { return false }
            let admin = RemoteAdmin(identity: identity, store: identities)
            let password = needsSudoPassword ? sudoPassword : nil
            if probe.isMac {
                _ = try await admin.setupMac(caddy: caddy, chatURL: chatURL, probe: probe, sudoPassword: password)
            } else {
                _ = try await admin.setupLinux(caddy: caddy, chatURL: chatURL, probe: probe, sudoPassword: password)
            }
            return true
        case .device:
            guard let identity else { return false }
            let deviceName = Host.current().localizedName ?? "Mac"
            let added = try await RemoteAdmin(identity: identity, store: identities).addDevice(name: deviceName, kind: "mac")
            let record = RemoteEngine(id: "eng_" + identity.id, name: name.isEmpty ? identity.label : name, chatURL: chatURL,
                                      identityId: identity.id, deviceId: added.deviceId, site: site, prefix: caddy.prefix,
                                      tls: tls.rawValue, createdAt: Date())
            try RemoteEngineStore.setToken(added.token, engineId: record.id)
            try engines.save(record)
            engine = record
            // the chat path, the way every client will use it
            if let connection = record.connection {
                do {
                    let health = try await reachChat(CompanionClient(connection: connection, token: added.token))
                    guard health.remote == true else { throw ProcessRunner.Failure(message: tr("all'URL di chat risponde un altro servizio")) }
                } catch {
                    throw ProcessRunner.Failure(message: tr("Server pronto, ma l'URL di chat %@ non risponde da qui: %@. Se c'è un proxy davanti, configuralo e riprova.", chatURL, error.localizedDescription))
                }
            }
            sshPassword = ""
            sudoPassword = ""
            return true
        case .agents:
            guard let identity, let probe, let engine, let connection = engine.connection,
                  let token = RemoteEngineStore.token(engineId: engine.id) else { return false }
            activity = tr("Installo Claude Code, Codex e omp sul server…")
            defer { activity = nil }
            agentsReport = try await ServerAgents.configure(admin: RemoteAdmin(identity: identity, store: identities),
                                                            client: CompanionClient(connection: connection, token: token),
                                                            probe: probe, local: agents)
            return true
        case .done:
            return true
        }
    }

    /// With a public certificate Caddy asks Let's Encrypt only after its reload,
    /// so the first HTTPS calls fail until it arrives (seconds, longer on retries).
    private func reachChat(_ client: CompanionClient) async throws -> RemoteHealth {
        guard tls == .public else { return try await client.remoteHealth() }
        activity = tr("Attendo il certificato di Let's Encrypt…")
        defer { activity = nil }
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                return try await client.remoteHealth()
            } catch APIError.transport where Date() < deadline {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

extension ServerSetupFlow {
    /// This app's own engine (Contents/Helpers, or next to a development build),
    /// when it runs on the server Mac's architecture (`arm64` reads as `aarch64`).
    public nonisolated static func macEngine(_ arch: String) -> (url: URL, sha256: String)? {
        guard let binary = HarnessLocator.swiftEngine() else { return nil }
        let wanted = arch == "aarch64" ? "arm64" : arch
        guard let archs = try? machOArchitectures(binary), archs.contains(wanted),
              let data = try? Data(contentsOf: binary) else { return nil }
        return (binary, SHA256Digest.of(data).map { String(format: "%02x", $0) }.joined())
    }

    /// The slices of a Mach-O, thin or universal, without running lipo.
    nonisolated static func machOArchitectures(_ url: URL) throws -> Set<String> {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4096) ?? Data()
        func u32(_ at: Int, big: Bool) -> UInt32 {
            guard head.count >= at + 4 else { return 0 }
            let value = head[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return big ? value : value.byteSwapped
        }
        func name(_ cpu: UInt32) -> String? {
            switch cpu {
            case 0x0100000C: return "arm64"
            case 0x01000007: return "x86_64"
            default: return nil
            }
        }
        switch u32(0, big: true) {
        case 0xCAFEBABE: // universal, big-endian header
            let count = Int(u32(4, big: true))
            return Set((0..<min(count, 8)).compactMap { name(u32(8 + $0 * 20, big: true)) })
        case 0xCFFAEDFE: // thin 64-bit, little-endian
            return Set([name(u32(4, big: false))].compactMap { $0 })
        default:
            return []
        }
    }
}

/// A Terminal window logged in on the server with SwarmeBot's key, for what
/// only a person can do there: the CLIs' own logins (`claude`, `codex`, `pi`).
public enum ServerTerminal {
    /// The ssh command line that logs in on the server, running `command` there if given.
    public static func line(_ identity: SSHIdentity, store: SSHIdentityStore, command: String? = nil) -> String {
        let ssh = SSHCommand(identity: identity, store: store)
        var argv = ["/usr/bin/ssh", "-t"] + ssh.options() + ["--", identity.host]
        if let command { argv.append(command) }
        return argv.map(RemoteScripts.quote).joined(separator: " ")
    }

    /// In Terminal, for a caller that has no way to open the terminal the user picked.
    public static func open(_ identity: SSHIdentity, store: SSHIdentityStore, command: String? = nil) throws {
        let line = line(identity, store: store, command: command)
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
    }

    /// What to type there, shown next to the button.
    public static let claudeInstall = "curl -fsSL https://claude.ai/install.sh | bash"
    public static let claudeLogin = "claude"
    public static let codexLogin = RemoteScripts.command(#"""
    export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    exec codex login --device-auth
    """#)
    public static let piInstall = "npm install -g @earendil-works/pi-coding-agent"
}
