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
            throw ProcessRunner.Failure(message: "Indirizzo del sito Caddy non valido: un dominio (bot.example.it) o :porta")
        }
        guard !prefix.isEmpty, prefix.range(of: #"^(/[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil else {
            throw ProcessRunner.Failure(message: "Il prefisso deve essere un percorso come /srv1/deploy")
        }
        if tls == .public, site.hasPrefix(":") {
            throw ProcessRunner.Failure(message: "Un certificato pubblico richiede un dominio, non solo una porta")
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
            throw ProcessRunner.Failure(message: "La chiave è stata aggiunta, ma il server non la accetta: controlla PubkeyAuthentication in sshd")
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
        guard values["probe"] == "ok" else { throw ProcessRunner.Failure(message: "Risposta inattesa dal server") }
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
            guard let sudoPassword, !sudoPassword.isEmpty else { throw ProcessRunner.Failure(message: "Serve la password di sudo") }
            let line = Data((sudoPassword + "\n").utf8)
            do {
                try await ssh.run("sudo -k -S -p '' -v", stdin: line, timeout: 30)
            } catch {
                throw ProcessRunner.Failure(message: "Password di sudo non accettata")
            }
            return try await ssh.run("sudo -k -S -p '' " + command, stdin: line, timeout: timeout)
        default:
            throw ProcessRunner.Failure(message: "L'utente \(identity.user) non può usare sudo: serve root una volta per Caddy e il servizio")
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
        else { throw ProcessRunner.Failure(message: "Il motore non ha restituito un token") }
        return AddedDevice(deviceId: id, token: token)
    }
}
