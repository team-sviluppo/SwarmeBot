// `config.json` — `server/config.ts`.
//
// Held as JSON so every section this engine does not understand (composio,
// tts, future keys) survives a save untouched. Credentials follow the same
// precedence as the Node engine: the process environment (the app hands
// them over from the Keychain at spawn) wins over the file.
import Foundation

@MainActor
public final class AppConfig {
    public private(set) var json: JSONObject
    private let paths: DataPaths
    private var environment: [String: String]

    static let credentialEnv: [(section: String, field: String, env: String)] = [
        ("xai", "key", "XAI_API_KEY"),
        ("composio", "apiKey", "COMPOSIO_API_KEY"),
        ("box", "token", "BOX_TOKEN"),
        ("opencodeGo", "apiKey", "OPENCODE_API_KEY"),
        ("localEndpoint", "apiKey", "LOCAL_ENDPOINT_AUTH_KEY"),
        ("tts", "key", "OMB_TTS_KEY"),
    ]

    /// Fields the app may ask to keep out of the file (`secretStorage=external`).
    static let externalSecretFields = credentialEnv.map { ($0.section, $0.field) }

    public init(paths: DataPaths, environment: [String: String]) {
        self.paths = paths
        self.environment = environment.merging(Self.readSecrets(paths)) { current, _ in current }
        json = FileIO.readJSON(paths.config)?.object ?? JSONObject()
    }

    /// `~/.swarmebot/secrets.json`, mode 0600. The Keychain is a copy the app
    /// keeps; this file is what a restarted harness still sees when the
    /// process environment no longer carries the key.
    public static func readSecrets(_ paths: DataPaths) -> [String: String] {
        guard let data = try? Data(contentsOf: paths.root.appendingPathComponent("secrets.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object.filter { !$0.value.isEmpty }
    }

    public static func writeSecrets(_ paths: DataPaths, _ values: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted])
        try FileIO.writeAtomic(data, to: paths.root.appendingPathComponent("secrets.json"), mode: 0o600)
    }

    /// A credential: env first, then the file.
    public func secret(_ section: String, _ field: String) -> String? {
        if let entry = Self.credentialEnv.first(where: { $0.section == section && $0.field == field }),
           let value = environment[entry.env] {
            return value.isEmpty ? nil : value
        }
        let value = json[section]?[field]?.string
        return value?.isEmpty == false ? value : nil
    }

    public func string(_ section: String, _ field: String) -> String? {
        json[section]?[field]?.string
    }

    public var localEndpointBaseUrl: String? {
        LocalHosts.normalizeGatewayBaseUrl(string("localEndpoint", "baseUrl"))
    }

    public var vpsSshAlias: String? {
        guard let alias = string("vps", "sshAlias"), alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { return nil }
        return alias
    }

    public var pickerVisibility: [String: Bool] {
        var out: [String: Bool] = [:]
        for (key, value) in json["pickerVisibility"]?.object ?? JSONObject() {
            if let visible = value.bool { out[key] = visible }
        }
        return out
    }

    public var roomTurnTimeoutMinutes: Int {
        json["rooms"]?["turnTimeoutMinutes"]?.int ?? 5
    }

    // MARK: Fleet

    static let defaultFleet: [(String, String)] = [
        ("grok", "grokAgent"), ("kimi", "kimiAgent"), ("droid", "droidAgent"), ("cursor", "cursorAgent"),
        ("claude", "claudeAgent"), ("codex", "codex"), ("antigravity", "antigravityAgent"), ("opencodeGo", "opencodeGo"),
        ("computer", "boxAgent"), ("qwen", "qwenAgent"), ("hermes", "hermesAgent"), ("pi", "piAgent"),
        ("localEndpoint", "localEndpoint"), ("deepseekHarness", "deepseekHarness"),
    ]

    static let productFleetAdditions: [(String, String)] = [
        ("cursor", "cursorAgent"), ("deepseekHarness", "deepseekHarness"),
        ("qwen", "qwenAgent"), ("hermes", "hermesAgent"), ("pi", "piAgent"), ("localEndpoint", "localEndpoint"),
    ]

    /// `instanceConfigs(cfg)`, in order.
    public func instanceConfigs() -> [(InstanceID, InstanceConfig)] {
        var entries: [(String, JSONObject)] = []
        if let configured = json["instances"]?.object, !configured.isEmpty {
            for (id, value) in configured { entries.append((id, value.object ?? JSONObject())) }
            let ids = Set(entries.map(\.0))
            if ids.contains("claude") || ids.contains("grok") || ids.contains("codex") {
                for (id, driver) in Self.productFleetAdditions where !ids.contains(id) {
                    entries.append((id, JSONObject([("driver", .string(driver))])))
                }
            }
        } else {
            entries = Self.defaultFleet.map { ($0.0, JSONObject([("driver", .string($0.1))])) }
        }
        return entries.compactMap { id, entry in
            guard let driver = entry["driver"]?.string, !driver.isEmpty else { return nil }
            var env: [String: String] = [:]
            for (key, value) in entry["environment"]?.object ?? JSONObject() {
                if let string = value.string { env[key] = string }
            }
            for (key, value) in injectedEnvironment(driver: driver) { env[key] = value }
            return (id, InstanceConfig(
                driver: driver,
                displayName: entry["displayName"]?.string,
                environment: env,
                enabled: entry["enabled"]?.bool ?? true,
                config: entry["config"] ?? .null
            ))
        }
    }

    /// Credentials go only to the driver that consumes them.
    func injectedEnvironment(driver: String) -> [String: String] {
        var env: [String: String] = [:]
        if driver == "grok", let key = secret("xai", "key") { env["XAI_API_KEY"] = key }
        if driver == "boxAgent", let token = secret("box", "token") { env["BOX_TOKEN"] = token }
        if driver == "opencodeGo", let key = secret("opencodeGo", "apiKey") { env["OPENCODE_API_KEY"] = key }
        if driver == "localEndpoint", let key = secret("localEndpoint", "apiKey") { env[LocalHosts.apiKeyEnv] = key }
        // the URL is no secret: the Node engine sets it process-wide, so every
        // driver's picker lists the endpoint's models under Custom
        if let url = localEndpointBaseUrl { env[LocalHosts.baseUrlEnv] = url }
        return env
    }

    // MARK: Status and saving

    public func status() -> JSON {
        var o = JSONObject()
        o["xai"] = ["configured": .bool(secret("xai", "key") != nil)]
        o["composio"] = ["configured": .bool(secret("composio", "apiKey") != nil), "mode": "unavailable"]
        o["box"] = ["configured": .bool(secret("box", "token") != nil)]
        o["vps"] = ["configured": .bool(vpsSshAlias != nil), "sshAlias": .string(vpsSshAlias ?? "")]
        o["opencodeGo"] = ["configured": .bool(secret("opencodeGo", "apiKey") != nil)]
        o["localEndpoint"] = ["configured": .bool(secret("localEndpoint", "apiKey") != nil), "baseUrl": .string(localEndpointBaseUrl ?? "")]
        o["tts"] = ["configured": .bool(secret("tts", "key") != nil), "ready": false, "voice": .string(string("tts", "voice") ?? "")]
        o["profile"] = ["name": .string(string("profile", "name") ?? ""), "email": .string(string("profile", "email") ?? "")]
        o["rooms"] = ["turnTimeoutMinutes": .number(Double(roomTurnTimeoutMinutes))]
        return .object(o)
    }

    public enum SaveError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    static let patchableSections = ["xai", "composio", "box", "vps", "opencodeGo", "localEndpoint", "tts", "profile", "rooms"]

    /// Merge a `PUT /api/config` patch. With `externalSecrets`, credential
    /// fields are applied to the live environment and removed from the file.
    /// Returns whether the fleet must be rebuilt.
    @discardableResult
    public func save(patch: JSONObject, externalSecrets: Bool) throws -> Bool {
        guard !patch.isEmpty else { throw SaveError.invalid("nothing to save") }
        for key in patch.keys where !Self.patchableSections.contains(key) {
            throw SaveError.invalid("Invalid configuration: unknown section \(key)")
        }
        if let url = patch["localEndpoint"]?["baseUrl"]?.string, !url.isEmpty, LocalHosts.normalizeGatewayBaseUrl(url) == nil {
            throw SaveError.invalid("Invalid configuration: localEndpoint.baseUrl must be an http(s) URL")
        }
        if let minutes = patch["rooms"]?["turnTimeoutMinutes"]?.double, !(1...1440).contains(minutes) {
            throw SaveError.invalid("Invalid configuration: rooms.turnTimeoutMinutes must be 1–1440")
        }
        var disk = FileIO.readJSON(paths.config)?.object ?? JSONObject()
        for (section, value) in patch {
            guard let fields = value.object else { continue }
            var merged = disk[section]?.object ?? JSONObject()
            for (field, fieldValue) in fields { merged[field] = fieldValue }
            disk[section] = .object(merged)
        }
        // credentials follow the newest value in the live environment too
        for entry in Self.credentialEnv {
            guard let value = patch[entry.section]?[entry.field]?.string else { continue }
            if value.isEmpty { environment.removeValue(forKey: entry.env) } else { environment[entry.env] = value }
            if externalSecrets, var section = disk[entry.section]?.object {
                section[entry.field] = nil
                disk[entry.section] = .object(section)
            }
        }
        try FileIO.writeAtomic(Data(JSON.object(disk).pretty().utf8), to: paths.config)
        if externalSecrets { try Self.writeSecrets(paths, secretsOnDisk(patch)) }
        json = disk
        let quiet: Set<String> = ["profile", "tts", "vps", "rooms"]
        return !Set(patch.keys).isSubset(of: quiet)
    }

    /// Credential env vars after this patch, starting from the file already on disk.
    private func secretsOnDisk(_ patch: JSONObject) -> [String: String] {
        var secrets = Self.readSecrets(paths)
        for entry in Self.credentialEnv {
            guard let value = patch[entry.section]?[entry.field]?.string else { continue }
            if value.isEmpty { secrets.removeValue(forKey: entry.env) } else { secrets[entry.env] = value }
        }
        return secrets
    }

    /// Where the skills live, when the user moved them (a shared folder,
    /// so several machines see the same ones). Nil: `<data>/skills`.
    public var skillsFolder: String? {
        guard let path = json["skills"]?["folder"]?.string, path.hasPrefix("/") else { return nil }
        return path
    }

    public func setSkillsFolder(_ path: String?) throws {
        var disk = FileIO.readJSON(paths.config)?.object ?? JSONObject()
        var section = disk["skills"]?.object ?? JSONObject()
        // explicit Optional: a bare nil here would be JSON null, not a removal
        section["folder"] = path.map(JSON.string) ?? Optional<JSON>.none
        disk["skills"] = section.isEmpty ? Optional<JSON>.none : .object(section)
        try FileIO.writeAtomic(Data(JSON.object(disk).pretty().utf8), to: paths.config)
        json = disk
    }

    public func setSharedFolder(_ kind: String, _ path: String?) throws {
        var disk = FileIO.readJSON(paths.config)?.object ?? JSONObject()
        var section = disk["sharedRepositories"]?.object ?? JSONObject()
        section[kind] = path.map(JSON.string) ?? Optional<JSON>.none
        disk["sharedRepositories"] = .object(section)
        try FileIO.writeAtomic(Data(JSON.object(disk).pretty().utf8), to: paths.config)
        json = disk
    }

    /// Set (or clear) one instance's picker visibility. False for unknown ids.
    public func setPickerVisibility(_ instanceId: InstanceID, _ visible: Bool?) throws -> Bool {
        guard instanceConfigs().contains(where: { $0.0 == instanceId }) else { return false }
        var disk = FileIO.readJSON(paths.config)?.object ?? JSONObject()
        var map = disk["pickerVisibility"]?.object ?? JSONObject()
        map[instanceId] = visible.map(JSON.bool)
        disk["pickerVisibility"] = .object(map)
        try FileIO.writeAtomic(Data(JSON.object(disk).pretty().utf8), to: paths.config)
        json = disk
        return true
    }

    /// Set (or clear) one instance's CLI override, materializing the fleet
    /// map the same way `withInstanceCli` does. False for unknown ids.
    public func setInstanceCli(_ instanceId: InstanceID, _ cli: String) throws -> Bool {
        let fleet = instanceConfigs()
        guard fleet.contains(where: { $0.0 == instanceId }) else { return false }
        var disk = FileIO.readJSON(paths.config)?.object ?? JSONObject()
        var instances = disk["instances"]?.object ?? JSONObject()
        if instances.isEmpty {
            // persist the implicit fleet, without injected credentials
            for (id, entry) in fleet { instances[id] = ["driver": .string(entry.driver)] }
        }
        var entry = instances[instanceId]?.object ?? JSONObject([("driver", .string(fleet.first { $0.0 == instanceId }!.1.driver))])
        var config = entry["config"]?.object ?? JSONObject()
        let trimmed = cli.trimmingCharacters(in: .whitespaces)
        // explicit Optional: `JSON` is nil-literal convertible, so a bare `nil`
        // in a ternary would become JSON null instead of removing the key
        config["cli"] = trimmed.isEmpty ? Optional<JSON>.none : .string(trimmed)
        entry["config"] = config.isEmpty ? Optional<JSON>.none : .object(config)
        instances[instanceId] = .object(entry)
        disk["instances"] = .object(instances)
        try FileIO.writeAtomic(Data(JSON.object(disk).pretty().utf8), to: paths.config)
        json = disk
        return true
    }

    /// `withInstanceDriverConfig`: replace one instance's driver config,
    /// materializing the fleet map like the Node engine. Nil for an unknown id
    /// or a different driver; otherwise whether anything changed.
    public func setInstanceDriverConfig(_ instanceId: InstanceID, driver: String, config: JSON?) throws -> Bool? {
        let fleet = instanceConfigs()
        guard let target = fleet.first(where: { $0.0 == instanceId }), target.1.driver == driver else { return nil }
        guard target.1.config != (config ?? .null) else { return false }
        var disk = FileIO.readJSON(paths.config)?.object ?? JSONObject()
        let existing = disk["instances"]?.object ?? JSONObject()
        var instances = JSONObject()
        for (id, entry) in fleet { instances[id] = existing[id] ?? ["driver": .string(entry.driver)] }
        var entry = instances[instanceId]?.object ?? JSONObject([("driver", .string(driver))])
        entry["config"] = config
        instances[instanceId] = .object(entry)
        disk["instances"] = .object(instances)
        try FileIO.writeAtomic(Data(JSON.object(disk).pretty().utf8), to: paths.config)
        json = disk
        return true
    }
}
