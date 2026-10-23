// Setting a server up from the Mac — bot-remoto §5.3–§5.5.
//
// The steps the setup screen walks through, each one callable on its own so
// the screen can show where it stopped and retry from there:
//
//   host key → key (password once) → probe → root (Caddy, socket folder,
//   linger) → engine binary → service → Caddy routes → first device token
//
// Only the ssh calls live here; the screen decides when to ask for a
// password and shows every root command before it runs.
import CompanionCore
import Foundation

public struct RemoteProbe: Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String]) { self.values = values }

    public var os: String { values["os"] ?? "" }
    public var version: String { values["version"] ?? "" }
    public var arch: String { values["arch"] ?? "" }
    public var user: String { values["user"] ?? "" }
    public var home: String { values["home"] ?? "" }
    public var isRoot: Bool { values["root"] == "yes" }
    /// `nopassword`, `password` or `none`.
    public var sudo: String { values["sudo"] ?? "none" }
    public var engineHash: String? { values["engineHash"] }
    public var claude: String? { values["claude"] }
    public var pi: String? { values["pi"] }
    public var caddy: String? { values["caddy"] }
    public var serviceActive: Bool { values["service"] == "active" }
    /// The iOS app's push relay runs next to the engine (docs/push-relay.md).
    public var pushRelayActive: Bool { values["pushRelay"] == "active" }
    public var isLinux: Bool { os != "macos" && !os.isEmpty }

    /// Ubuntu 24.04 and 26.04 are what the Linux engine is built for (R2);
    /// on a Mac, the app's own floor (macOS 14).
    public var supported: Bool {
        if os == "macos" { return (Int(version.split(separator: ".").first ?? "") ?? 0) >= 14 }
        return os == "ubuntu" && ["24.04", "26.04"].contains(version)
    }

    public var isMac: Bool { os == "macos" }

    /// `aarch64` / `x86_64`, as the bundled binaries are named.
    public var engineArch: String? {
        switch arch {
        case "aarch64", "arm64": return "aarch64"
        case "x86_64", "amd64": return "x86_64"
        default: return nil
        }
    }
}

/// How the server's Caddy serves this user's engine (§6.2).
public struct CaddySettings: Equatable, Sendable {
    public enum TLS: String, Sendable, CaseIterable {
        /// Caddy gets a public certificate for `site` (the server is reachable on 80/443).
        case `public`
        /// Plain HTTP on a private network, behind a proxy that terminates TLS (§6.3).
        case off
    }

    /// `bot.example.it`, or `:8080` behind a proxy.
    public var site: String
    /// `/srv1/deploy`.
    public var prefix: String
    public var tls: TLS

    public init(site: String, prefix: String, tls: TLS) {
        self.site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prefix = Connection.cleanBasePath(prefix)
        self.tls = tls
    }

    /// The chat URL when nothing else sits in front of Caddy.
    public var directChatURL: String {
        let scheme = tls == .public ? "https" : "http"
        let host = site.hasPrefix(":") ? "SERVER\(site)" : site
        return "\(scheme)://\(host)\(prefix)"
    }

    public func validate() throws {
        guard site.range(of: #"^(:[0-9]{1,5}|[a-z0-9.-]+(:[0-9]{1,5})?)$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw ProcessRunner.Failure(message: tr("Indirizzo del sito Caddy non valido: un dominio (bot.example.it) o :porta"))
        }
        guard !prefix.isEmpty, prefix.range(of: #"^(/[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil else {
            throw ProcessRunner.Failure(message: tr("Il prefisso deve essere un percorso come /srv1/deploy"))
        }
        if tls == .public, site.hasPrefix(":") {
            throw ProcessRunner.Failure(message: tr("Un certificato pubblico richiede un dominio, non solo una porta"))
        }
    }
}

public struct RemoteAdmin: Sendable {
    public let identity: SSHIdentity
    public let store: SSHIdentityStore
    var ssh: SSHCommand { SSHCommand(identity: identity, store: store) }

    public init(identity: SSHIdentity, store: SSHIdentityStore) {
        self.identity = identity
        self.store = store
    }

    // MARK: Key

    /// True when the key already gets in: no password needed (R9).
    public func keyWorks() async -> Bool {
        guard identity.hostKey != nil, FileManager.default.fileExists(atPath: store.keyFile(identity).path) else { return false }
        return (try? await ssh.run("true", timeout: 30)) != nil
    }

    /// Install this identity's key with the password, once; then prove the key alone gets in.
    public func installKey(password: String) async throws -> SSHIdentity {
        guard identity.hostKey != nil else { throw SSHFailure.hostKeyUnknown }
        let key = try await store.ensureKey(identity)
        try await ssh.runWithPassword(RemoteScripts.command(RemoteScripts.installKey), password: password,
                                      stdin: Data((key.publicKey + "\n").utf8), timeout: 60)
        guard await keyWorks() else {
            throw ProcessRunner.Failure(message: tr("La chiave è stata aggiunta, ma il server non la accetta: controlla PubkeyAuthentication in sshd"))
        }
        var installed = identity
        installed.keyInstalledAt = Date()
        try store.update(installed)
        return installed
    }

    public func removeKey() async throws {
        try await ssh.run(RemoteScripts.command(RemoteScripts.removeKey, [identity.id]), timeout: 30)
        await ssh.closeMaster()
    }

    // MARK: Probe

    public func probe() async throws -> RemoteProbe {
        let result = try await ssh.run(RemoteScripts.command(RemoteScripts.probe), timeout: 60)
        let values = RemoteScripts.values(result.text)
        guard values["probe"] == "ok" else { throw ProcessRunner.Failure(message: tr("Risposta inattesa dal server")) }
        return RemoteProbe(values: values)
    }

    // MARK: Root

    /// Run a root script the one way that fits this login: as root directly,
    /// `sudo -n` without a password, or `sudo -k -S` with the password as
    /// stdin's only content (`-k`: never a cached ticket, so sudo always reads it).
    public func runAsRoot(_ script: String, _ arguments: [String], probe: RemoteProbe, sudoPassword: String?, timeout: TimeInterval = 600) async throws -> ProcessRunner.Result {
        let command = RemoteScripts.command(script, arguments)
        if probe.isRoot {
            return try await ssh.run(command, timeout: timeout)
        }
        switch probe.sudo {
        case "nopassword":
            return try await ssh.run("sudo -n " + command, timeout: timeout)
        case "password":
            guard let sudoPassword, !sudoPassword.isEmpty else { throw ProcessRunner.Failure(message: tr("Serve la password di sudo")) }
            let line = Data((sudoPassword + "\n").utf8)
            do {
                try await ssh.run("sudo -k -S -p '' -v", stdin: line, timeout: 30)
            } catch {
                throw ProcessRunner.Failure(message: tr("Password di sudo non accettata"))
            }
            return try await ssh.run("sudo -k -S -p '' " + command, stdin: line, timeout: timeout)
        default:
            throw ProcessRunner.Failure(message: tr("L'utente %@ non può usare sudo: serve root una volta per Caddy e il servizio", identity.user))
        }
    }

    /// The commands a root step runs, as the setup screen shows them before asking.
    public static func rootPreview(_ script: String) -> String { script }

    // MARK: Engine

    /// Upload the engine binary unless the server already has this exact one.
    public func installEngine(binary: URL, sha256: String, probe: RemoteProbe) async throws {
        if probe.engineHash == sha256 { return }
        let data = try Data(contentsOf: binary)
        try await ssh.run(RemoteScripts.command(RemoteScripts.installEngine, [sha256]), stdin: data, timeout: 900)
    }

    // MARK: Linux setup

    public struct LinuxSetup: Sendable {
        public var socketDirectory: String
        public var chatURL: String
    }

    /// Caddy, the socket folder and linger (root), then the service (user), then the routes (root).
    public func setupLinux(caddy: CaddySettings, chatURL: String, probe: RemoteProbe, sudoPassword: String?) async throws -> LinuxSetup {
        try caddy.validate()
        let root = try await runAsRoot(RemoteScripts.rootLinux, [identity.user], probe: probe, sudoPassword: sudoPassword)
        let socketDirectory = RemoteScripts.values(root.text)["socketDir"] ?? "/run/swarmebot/\(identity.user)"
        try await ssh.run(RemoteScripts.command(RemoteScripts.serviceLinux, [socketDirectory, chatURL]), timeout: 120)
        _ = try await runAsRoot(RemoteScripts.caddyLinux, [identity.user, caddy.site, caddy.prefix, socketDirectory, caddy.tls.rawValue],
                                probe: probe, sudoPassword: sudoPassword, timeout: 180)
        return LinuxSetup(socketDirectory: socketDirectory, chatURL: chatURL)
    }

    // MARK: Mac setup

    /// The engine and Caddy as LaunchDaemons, the user's routes (root, one step).
    public func setupMac(caddy: CaddySettings, chatURL: String, probe: RemoteProbe, sudoPassword: String?) async throws -> LinuxSetup {
        try caddy.validate()
        let result = try await runAsRoot(RemoteScripts.rootMac, [identity.user, caddy.site, caddy.prefix, caddy.tls.rawValue, chatURL],
                                         probe: probe, sudoPassword: sudoPassword, timeout: 180)
        let socketDirectory = RemoteScripts.values(result.text)["socketDir"] ?? "~/.swarmebot/run"
        return LinuxSetup(socketDirectory: socketDirectory, chatURL: chatURL)
    }

    // MARK: Push relay (docs/push-relay.md)

    /// The iOS app's push relay next to the engine: the same binary
    /// (`swarme-harness push-relay`), its own service, `<prefix>/push` in
    /// Caddy. The OneSignal key goes on stdin into a 0600 file the engine
    /// does not read; the relay's secret is made on the server. Returns the
    /// relay's URL, for the app's build (`SWARMEBOT_PUSH_RELAY`).
    public func installPushRelay(appId: String, apiKey: String, caddy: CaddySettings, chatURL: String, probe: RemoteProbe,
                                 sudoPassword: String?) async throws -> String {
        let keys = try JSONSerialization.data(withJSONObject: ["appId": appId.trimmingCharacters(in: .whitespacesAndNewlines),
                                                               "apiKey": apiKey.trimmingCharacters(in: .whitespacesAndNewlines)])
        try await ssh.run(RemoteScripts.command(RemoteScripts.configurePushRelay), stdin: keys, timeout: 60)
        if probe.isMac {
            _ = try await runAsRoot(RemoteScripts.rootMacPush, [identity.user, caddy.prefix], probe: probe, sudoPassword: sudoPassword,
                                    timeout: 120)
        } else {
            let socketDirectory = "/run/swarmebot/\(identity.user)"
            try await ssh.run(RemoteScripts.command(RemoteScripts.servicePushLinux, [socketDirectory]), timeout: 90)
            _ = try await runAsRoot(RemoteScripts.caddyLinux, [identity.user, caddy.site, caddy.prefix, socketDirectory, caddy.tls.rawValue],
                                    probe: probe, sudoPassword: sudoPassword, timeout: 180)
        }
        let relay = (chatURL.hasSuffix("/") ? String(chatURL.dropLast()) : chatURL) + "/push"
        try await Self.waitForRelay(relay)
        return relay
    }

    /// The relay answers on its public URL (Caddy reloads in a moment).
    static func waitForRelay(_ relay: String, session: URLSession = .shared) async throws {
        guard let url = URL(string: relay + "/health") else { throw ProcessRunner.Failure(message: tr("L'URL del relay non è valido")) }
        let deadline = Date().addingTimeInterval(30)
        var last = ""
        while Date() < deadline {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            if let (data, response) = try? await session.data(for: request) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200, String(decoding: data, as: UTF8.self).contains("swarme-push-relay") { return }
                last = "HTTP \(status)"
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ProcessRunner.Failure(message: tr("Il relay è installato, ma %@ non risponde da qui (%@)", relay, last.isEmpty ? tr("nessuna risposta") : last))
    }

    // MARK: CLI logins

    /// The token `claude setup-token` prints, for the engine on the server (§4.2).
    public func setClaudeToken(_ token: String) async throws {
        try await storeClaudeToken(token)
        try await restartEngine()
    }

    /// The token in the engine's secrets; live from the next restart.
    public func storeClaudeToken(_ token: String) async throws {
        let trimmed = try ServerClaudeToken.validated(token)
        try await ssh.run(RemoteScripts.command(RemoteScripts.setClaudeToken), stdin: Data((trimmed + "\n").utf8), timeout: 60)
    }

    public func restartEngine() async throws {
        try await ssh.run(RemoteScripts.command(RemoteScripts.restartEngine), timeout: 60)
    }

    /// pi's login on the server: its agent config, copied from this Mac (keys and custom providers).
    @discardableResult
    public func copyPiConfig(from directory: URL = PiConfig.localDirectory) async throws -> [String] {
        let present = PiConfig.files.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard !present.isEmpty else { throw ProcessRunner.Failure(message: tr("Su questo Mac non c'è una configurazione di pi (%@)", directory.path)) }
        for name in present {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            try await ssh.run(RemoteScripts.command(RemoteScripts.installPiFile, [name]), stdin: data, timeout: 60)
        }
        try await restartEngine()
        return present
    }

    /// Claude Code on the server, from its installer. Returns its version line.
    public func installClaude() async throws -> String {
        let result = try await ssh.run(RemoteScripts.command(RemoteScripts.installClaude), timeout: 300)
        return RemoteScripts.values(result.text)["claude"] ?? ""
    }

    /// omp `version` on the server, the release build for its system.
    public func installOmp(version: String, probe: RemoteProbe) async throws -> String {
        guard let asset = OmpConfig.asset(for: probe) else {
            throw ProcessRunner.Failure(message: tr("omp non ha una build per %@ %@", probe.os, probe.arch))
        }
        let result = try await ssh.run(RemoteScripts.command(RemoteScripts.installOmp, [version, asset]), timeout: 600)
        return RemoteScripts.values(result.text)["omp"] ?? ""
    }

    /// omp's login on the server: its agent config, copied from this Mac (keys, providers, settings).
    @discardableResult
    public func copyOmpConfig(from directory: URL = OmpConfig.localDirectory) async throws -> [String] {
        let present = OmpConfig.files.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        guard present.contains("agent.db") else { throw ProcessRunner.Failure(message: tr("Su questo Mac non c'è una configurazione di omp (%@)", directory.path)) }
        for name in present {
            let data = name == "agent.db" ? try OmpConfig.snapshot(directory.appendingPathComponent(name))
                                          : try Data(contentsOf: directory.appendingPathComponent(name))
            try await ssh.run(RemoteScripts.command(RemoteScripts.installOmpFile, [name]), stdin: data, timeout: 120)
        }
        return present
    }

    // MARK: Engine updates (§5.5)

    /// The binary this app would install on that server, and its digest — without downloading.
    public static func expectedEngine(for probe: RemoteProbe, linux: LinuxEngines = .standard) -> String? {
        guard let arch = probe.engineArch else { return nil }
        if probe.isMac { return ServerSetupFlow.macEngine(arch)?.sha256 }
        if let local = linux.localBuild(arch) { return local.sha256 }
        return linux.manifest?.engines[arch]?.sha256.lowercased()
    }

    /// Replace the engine and restart it. Turns running at that moment are cut
    /// short, so the caller checks for them first (AppModel.updateEngine).
    public func updateEngine(probe: RemoteProbe, linux: LinuxEngines = .standard) async throws {
        guard let arch = probe.engineArch else { throw ProcessRunner.Failure(message: tr("Architettura %@ non supportata", probe.arch)) }
        let binary: (url: URL, sha256: String)
        if probe.isMac {
            guard let mac = ServerSetupFlow.macEngine(arch) else {
                throw ProcessRunner.Failure(message: tr("Il motore di questa app non è per Mac %@", probe.arch))
            }
            binary = mac
        } else {
            binary = try await linux.engine(arch)
        }
        guard probe.engineHash != binary.sha256 else { return }
        try await installEngine(binary: binary.url, sha256: binary.sha256, probe: probe)
        try await restartEngine()
    }

    // MARK: Devices

    public struct AddedDevice: Sendable {
        public var deviceId: String
        public var token: String
    }

    /// The first device token, over ssh (§4.2). The token is returned once.
    public func addDevice(name: String, kind: String = "mac") async throws -> AddedDevice {
        let result = try await ssh.run(RemoteScripts.command(RemoteScripts.addDevice, [name, kind]), timeout: 60)
        guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let token = object["token"] as? String,
              let device = object["device"] as? [String: Any], let id = device["id"] as? String
        else { throw ProcessRunner.Failure(message: tr("Il motore non ha restituito un token")) }
        return AddedDevice(deviceId: id, token: token)
    }
}

/// pi keeps its keys and providers in ~/.pi/agent (Pi.swift): these files make its login.
public enum PiConfig {
    public static let files = ["auth.json", "models.json", "settings.json"]
    /// The person's own pi, not the app's data: the real home even on test data.
    public static var localDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true)
    }
}

