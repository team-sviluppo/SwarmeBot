// The secrets vault (docs/plans/2026-10-25-vault.md).
//
// Named secrets a bot uses in shell commands without the model ever seeing
// the value: the model knows the name, the engine puts the value in the
// environment of the command it runs for the bot (`run_with_secrets`,
// VaultTurns.swift) or, when the user chose so, of the bot's CLI.
//
// Two files in the data dir, both 0600:
// - `vault.json` — `{secrets: [{name, preset, description, hint, createdAt,
//   updatedAt}], grants: {botId: {secrets: [{name, mode}], note}}}`. No value
//   ever. Grants live here and not in `bots.json` because on a remote engine
//   this file is written by `swarme-harness vault …` over ssh while the engine
//   runs: the engine only reads it;
// - `vault-secrets.json` — `{v: 1, values: {NAME: value}}`, or with
//   `alg: "AES-GCM"` each value sealed with the key the Mac app hands over in
//   SWARMEBOT_VAULT_KEY (Keychain). No key and a sealed file: the vault is
//   locked, its secrets listed but not usable.
//
// Both files are re-read when they change, so a write from the ssh command
// counts from the next turn without a restart.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct VaultError: Error, LocalizedError {
    public var status: Int
    public var message: String
    public var errorDescription: String? { message }

    public init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

public final class Vault {
    public static let keyEnv = "SWARMEBOT_VAULT_KEY"
    public static let presets = ["generic", "github", "huggingface", "npm"]
    public static let modes = ["safe", "env"]
    /// Shorter values would mask ordinary words in every transcript.
    static let minimumMaskedLength = 6

    private let paths: DataPaths
    private let key: SymmetricKey?
    private var metaStamp: Date?
    private var valuesStamp: Date?
    private var meta = JSONObject()
    private var values: [String: String] = [:]
    /// A sealed file this engine has no key for (or the wrong one).
    public private(set) var locked = false
    private var maskForms: [(form: String, name: String)] = []

    var metaFile: URL { paths.root.appendingPathComponent("vault.json") }
    var valuesFile: URL { paths.root.appendingPathComponent("vault-secrets.json") }

    /// `key`: 32 bytes, nil where the engine has none (remote engines).
    public init(paths: DataPaths, key: Data?) {
        self.paths = paths
        self.key = key.flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
        reload()
        // a key arrived for a vault written without one: seal it now
        if self.key != nil, !locked, !values.isEmpty, FileIO.readJSON(valuesFile)?["alg"] == nil { try? saveValues() }
    }

    /// The key from the environment, base64; nil when absent or malformed.
    public static func key(from environment: [String: String]) -> Data? {
        guard let text = environment[keyEnv], let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return data
    }

    public var encrypted: Bool { key != nil }

    // MARK: Reading

    private static func stamp(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Re-read whichever file changed since the last look.
    public func reload() {
        let metaNow = Self.stamp(metaFile), valuesNow = Self.stamp(valuesFile)
        if metaNow != metaStamp || metaNow == nil {
            meta = FileIO.readJSON(metaFile)?.object ?? JSONObject()
            metaStamp = metaNow
        }
        if valuesNow != valuesStamp || valuesNow == nil {
            readValues()
            valuesStamp = valuesNow
            rebuildMask()
        }
    }

    private func readValues() {
        values = [:]
        locked = false
        guard let file = FileIO.readJSON(valuesFile)?.object else { return }
        let stored = file["values"]?.object ?? JSONObject()
        guard file["alg"]?.string == "AES-GCM" else {
            for (name, value) in stored { if let text = value.string, !text.isEmpty { values[name] = text } }
            return
        }
        guard let key else {
            locked = !stored.isEmpty
            return
        }
        for (name, value) in stored {
            guard let sealed = value.string.flatMap({ Data(base64Encoded: $0) }),
                  let box = try? AES.GCM.SealedBox(combined: sealed),
                  let plain = try? AES.GCM.open(box, using: key, authenticating: Data(name.utf8)) else {
                // the wrong key opens nothing: say locked rather than lose the file on the next write
                values = [:]
                locked = true
                return
            }
            values[name] = String(decoding: plain, as: UTF8.self)
        }
    }

    public var secrets: [JSONObject] { meta["secrets"]?.array?.compactMap(\.object) ?? [] }

    public func secret(_ name: String) -> JSONObject? { secrets.first { $0["name"]?.string == name } }

    public func value(_ name: String) -> String? { values[name] }

    /// What a client sees: never a value, only whether one is set.
    public func wire() -> JSON {
        let rows: [JSON] = secrets.map { secret in
            var row = secret
            row["set"] = .bool(values[secret["name"]?.string ?? ""] != nil || (locked && secret["name"] != nil))
            return .object(row)
        }
        return ["locked": .bool(locked), "encrypted": .bool(encrypted), "secrets": .array(rows),
                "grants": meta["grants"] ?? .object(JSONObject())]
    }

    // MARK: Grants

    public struct Grant: Equatable {
        public var name: String
        public var mode: String
    }

    /// The bot's grants that still name a secret of the vault.
    public func grants(botId: String) -> (secrets: [Grant], note: String) {
        let entry = meta["grants"]?[botId]
        let known = Set(secrets.compactMap { $0["name"]?.string })
        let list = (entry?["secrets"]?.array ?? []).compactMap { item -> Grant? in
            guard let name = item["name"]?.string, known.contains(name) else { return nil }
            return Grant(name: name, mode: item["mode"]?.string == "env" ? "env" : "safe")
        }
        return (list, entry?["note"]?.string ?? "")
    }

    // MARK: Writing

    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Z][A-Z0-9_]{1,63}$"#, options: .regularExpression) != nil && !isReserved(name)
    }

    static func isReserved(_ name: String) -> Bool {
        let exact: Set<String> = ["PATH", "HOME", "SHELL", "USER", "LOGNAME", "PWD", "TMPDIR", "TERM", "LANG"]
        let prefixes = ["OMB_", "OGB_", "SWARMEBOT_", "ANTHROPIC_", "CLAUDE_", "OPENAI_", "CODEX_", "LD_", "DYLD_", "GIT_"]
        return exact.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }

    private static func now() -> JSON { .number((Date().timeIntervalSince1970 * 1000).rounded()) }

    private static func text(_ body: JSONObject, _ field: String, max: Int) throws -> String? {
        guard let value = body[field], !value.isNull else { return nil }
        guard let text = value.string else { throw VaultError(400, "\(field) must be a string") }
        guard text.count <= max else { throw VaultError(400, "\(field) is longer than \(max) characters") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func checkValue(_ value: String) throws {
        guard !value.isEmpty else { throw VaultError(400, "value must not be empty") }
        guard value.count <= 16_384 else { throw VaultError(400, "value is longer than 16384 characters") }
        guard !value.contains(where: \.isNewline) else { throw VaultError(400, "value must be one line") }
    }

    private func checkWritable() throws {
        if locked { throw VaultError(409, "the vault is locked: its key is missing on this engine") }
    }

    /// `{name, preset, description, hint, value}`.
    @discardableResult
    public func create(_ body: JSONObject) throws -> JSONObject {
        reload()
        try checkWritable()
        guard let name = body["name"]?.string, Self.isValidName(name) else {
            throw VaultError(400, "name must be capital letters, digits and _ (2-64, starting with a letter), and not a reserved variable")
        }
        guard secret(name) == nil else { throw VaultError(409, "a secret named \(name) already exists") }
        let preset = try Self.text(body, "preset", max: 32) ?? "generic"
        guard Self.presets.contains(preset) else { throw VaultError(400, "preset must be one of \(Self.presets.joined(separator: ", "))") }
        guard let value = body["value"]?.string else { throw VaultError(400, "value required") }
        try Self.checkValue(value)
        let stamp = Self.now()
        let record = JSONObject([
            ("name", .string(name)), ("preset", .string(preset)),
            ("description", .string(try Self.text(body, "description", max: 500) ?? "")),
            ("hint", .string(try Self.text(body, "hint", max: 2000) ?? "")),
            ("createdAt", stamp), ("updatedAt", stamp),
        ])
        var list = meta["secrets"]?.array ?? []
        list.append(.object(record))
        meta["secrets"] = .array(list)
        values[name] = value
        try saveValues()
        try saveMeta()
        return record
    }

    /// Any of `preset, description, hint, value`; the name stays.
    @discardableResult
    public func update(_ name: String, _ body: JSONObject) throws -> JSONObject {
        reload()
        try checkWritable()
        var list = meta["secrets"]?.array ?? []
        guard let index = list.firstIndex(where: { $0["name"]?.string == name }), var record = list[index].object else {
            throw VaultError(404, "no such secret")
        }
        if let preset = try Self.text(body, "preset", max: 32) {
            guard Self.presets.contains(preset) else { throw VaultError(400, "preset must be one of \(Self.presets.joined(separator: ", "))") }
            record["preset"] = .string(preset)
        }
        if let description = try Self.text(body, "description", max: 500) { record["description"] = .string(description) }
        if let hint = try Self.text(body, "hint", max: 2000) { record["hint"] = .string(hint) }
        if let value = body["value"], !value.isNull {
            guard let text = value.string else { throw VaultError(400, "value must be a string") }
            try Self.checkValue(text)
            values[name] = text
            try saveValues()
        }
        record["updatedAt"] = Self.now()
        list[index] = .object(record)
        meta["secrets"] = .array(list)
        try saveMeta()
        return record
    }

    /// The secret, its value and every grant naming it.
    public func remove(_ name: String) throws {
        reload()
        try checkWritable()
        var list = meta["secrets"]?.array ?? []
        guard let index = list.firstIndex(where: { $0["name"]?.string == name }) else { throw VaultError(404, "no such secret") }
        list.remove(at: index)
        meta["secrets"] = .array(list)
        var grants = meta["grants"]?.object ?? JSONObject()
        for (botId, entry) in grants {
            guard var object = entry.object else { continue }
            object["secrets"] = .array((object["secrets"]?.array ?? []).filter { $0["name"]?.string != name })
            grants[botId] = .object(object)
        }
        meta["grants"] = .object(grants)
        values[name] = nil
        try saveValues()
        try saveMeta()
    }

    /// `{secrets: [{name, mode}], note}` replaces the bot's grants.
    @discardableResult
    public func setGrants(botId: String, _ body: JSONObject) throws -> JSON {
        reload()
        guard !botId.isEmpty, botId.count <= 128 else { throw VaultError(400, "invalid bot id") }
        guard let entries = body["secrets"]?.array, entries.count <= 50 else { throw VaultError(400, "secrets must be a list (at most 50)") }
        var seen = Set<String>()
        var clean: [JSON] = []
        for entry in entries {
            guard let name = entry["name"]?.string, secret(name) != nil else {
                throw VaultError(400, "secrets: unknown secret \(entry["name"]?.string ?? "")")
            }
            let mode = entry["mode"]?.string ?? "safe"
            guard Self.modes.contains(mode) else { throw VaultError(400, "mode must be safe or env") }
            if seen.insert(name).inserted { clean.append(["name": .string(name), "mode": .string(mode)]) }
        }
        let note = try Self.text(body, "note", max: 2000) ?? ""
        var grants = meta["grants"]?.object ?? JSONObject()
        if clean.isEmpty, note.isEmpty {
            grants[botId] = Optional<JSON>.none
        } else {
            grants[botId] = ["secrets": .array(clean), "note": .string(note)]
        }
        meta["grants"] = .object(grants)
        try saveMeta()
        return grants[botId] ?? ["secrets": [], "note": ""]
    }

    /// A deleted bot leaves nothing behind.
    public func forgetBot(_ botId: String) {
        reload()
        guard meta["grants"]?[botId] != nil, var grants = meta["grants"]?.object else { return }
        grants[botId] = Optional<JSON>.none
        meta["grants"] = .object(grants)
        try? saveMeta()
    }

    private func saveMeta() throws {
        var out = JSONObject()
        out["secrets"] = meta["secrets"] ?? .array([])
        out["grants"] = meta["grants"] ?? .object(JSONObject())
        meta = out
        try FileIO.writeAtomic(Data(JSON.object(out).pretty().utf8), to: metaFile, mode: 0o600)
        metaStamp = Self.stamp(metaFile)
    }

    private func saveValues() throws {
        var stored = JSONObject()
        for name in values.keys.sorted() {
            let value = values[name] ?? ""
            if let key {
                let sealed = try AES.GCM.seal(Data(value.utf8), using: key, authenticating: Data(name.utf8))
                guard let combined = sealed.combined else { throw VaultError(500, "could not seal \(name)") }
                stored[name] = .string(combined.base64EncodedString())
            } else {
                stored[name] = .string(value)
            }
        }
        var file = JSONObject([("v", 1)])
        if key != nil { file["alg"] = "AES-GCM" }
        file["values"] = .object(stored)
        try FileIO.writeAtomic(Data(JSON.object(file).pretty().utf8), to: valuesFile, mode: 0o600)
        valuesStamp = Self.stamp(valuesFile)
        rebuildMask()
    }

    // MARK: Environment

    /// The variables a command gets for `names`, by preset. The secret's own
    /// name always; then what the tools of that service read.
    public func environment(for names: [String]) -> [String: String] {
        var env: [String: String] = [:]
        var gitConfig: [(String, String)] = []
        for name in names {
            guard let value = values[name] else { continue }
            env[name] = value
            switch secret(name)?["preset"]?.string {
            case "github":
                env["GH_TOKEN"] = value
                env["GITHUB_TOKEN"] = value
                // git over https without the token in the URL or in .git/config
                let basic = Data("x-access-token:\(value)".utf8).base64EncodedString()
                gitConfig.append(("http.https://github.com/.extraheader", "AUTHORIZATION: basic \(basic)"))
            case "huggingface":
                env["HF_TOKEN"] = value
                env["HUGGING_FACE_HUB_TOKEN"] = value
            case "npm":
                env["NPM_TOKEN"] = value
                env["NODE_AUTH_TOKEN"] = value
            default:
                break
            }
        }
        if !gitConfig.isEmpty {
            env["GIT_CONFIG_COUNT"] = String(gitConfig.count)
            for (index, entry) in gitConfig.enumerated() {
                env["GIT_CONFIG_KEY_\(index)"] = entry.0
                env["GIT_CONFIG_VALUE_\(index)"] = entry.1
            }
        }
        return env
    }

    /// The variable names `environment(for:)` sets for one secret, for the prompt.
    public func variableNames(_ name: String) -> [String] {
        switch secret(name)?["preset"]?.string {
        case "github": return [name, "GH_TOKEN", "GITHUB_TOKEN"].uniqued()
        case "huggingface": return [name, "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"].uniqued()
        case "npm": return [name, "NPM_TOKEN", "NODE_AUTH_TOKEN"].uniqued()
        default: return [name]
        }
    }

    // MARK: Masking

    private func rebuildMask() {
        var forms: [(String, String)] = []
        for (name, value) in values where value.count >= Self.minimumMaskedLength {
            forms.append((value, name))
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != value { forms.append((encoded, name)) }
            forms.append((Data(value.utf8).base64EncodedString(), name))
            forms.append((Data("x-access-token:\(value)".utf8).base64EncodedString(), name))
        }
        // longest first: a value containing another one is replaced whole
        maskForms = forms.sorted { $0.0.count > $1.0.count }
    }

    public var hasValues: Bool { !maskForms.isEmpty }

    /// Every known secret value (and its encoded forms) → «secret NAME».
    public func mask(_ text: String) -> String {
        guard !maskForms.isEmpty, text.count >= Self.minimumMaskedLength else { return text }
        var out = text
        for (form, name) in maskForms where out.contains(form) {
            out = out.replacingOccurrences(of: form, with: "«secret \(name)»")
        }
        return out
    }

    public func mask(_ json: JSON, depth: Int = 0) -> JSON {
        guard !maskForms.isEmpty else { return json }
        switch json {
        case let .string(text): return .string(mask(text))
        case let .array(items) where depth <= 16: return .array(items.map { mask($0, depth: depth + 1) })
        case let .object(object) where depth <= 16:
            var out = JSONObject()
            for (key, value) in object { out[key] = mask(value, depth: depth + 1) }
            return .object(out)
        default: return json
        }
    }

    public func mask(_ object: JSONObject) -> JSONObject {
        guard !maskForms.isEmpty else { return object }
        return mask(.object(object)).object ?? object
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
