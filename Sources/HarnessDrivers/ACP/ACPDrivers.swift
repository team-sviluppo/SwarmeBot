// The ACP harnesses — `server/drivers/acp/{hermes,gemini,qwen,kimi,droid,
// opencode-go,grok,cursor}.ts`, one ACPSupport each.
//
// Local models picked as `host::model` reach each CLI the way that CLI wants
// them, so several of these write the CLI's own config file (Hermes YAML,
// Kimi/Grok TOML, Qwen/Droid/OpenCode JSON) before the spawn. Those writers
// are kept line for line: they edit files the user also edits by hand.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HarnessCore

enum ACPHarnesses {
    static func home(_ env: [String: String]) -> String { env["HOME"] ?? NSHomeDirectory() }

    static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    static func write(_ text: String, to path: String, mode: Int? = nil) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: false, encoding: .utf8)
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func quoteToml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Text-only label from an id: `kimi-k3` → `Kimi K3`.
    static func titleCase(_ id: String, separators: String) -> String {
        id.components(separatedBy: CharacterSet(charactersIn: separators)).filter { !$0.isEmpty }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The persona prefix every ACP harness uses — none has a working system flag.
    static func localCatalog(_ env: [String: String]) async -> ModelCatalog {
        let catalog = await LocalHosts.merge(.empty, env: env)
        return ModelCatalog(default: catalog.options.first?.id ?? "", options: catalog.options)
    }

    static let all: [ACPSupport] = [grok, gemini, kimi, droid, cursor, opencodeGo, qwen, hermes]

    // MARK: - Hermes

    static func hermesHome(_ env: [String: String]) -> String {
        env["HERMES_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home(env))/.hermes"
    }

    static func quoteYaml(_ value: String) -> String {
        matches(value, #"^[\w./:+-]+$"#) ? value : JSON.string(value).serialized()
    }

    static func upsertHermesProvider(_ text: String, hostId: String, baseUrl: String, apiKey: String) -> String {
        let block = ["  \(hostId):", "    base_url: \(quoteYaml(baseUrl))", "    api_key: \(quoteYaml(apiKey))", ""].joined(separator: "\n")
        var lines = text.components(separatedBy: "\n")
        if let providers = lines.firstIndex(where: { matches($0, #"^providers:\s*$"#) }) {
            if let start = lines.firstIndex(of: "  \(hostId):") {
                var end = start + 1
                while end < lines.count, !(matches(lines[end], #"^  \S"#) || matches(lines[end], #"^\S"#)) { end += 1 }
                while end > start + 1, lines[end - 1].isEmpty { end -= 1 }
                lines.replaceSubrange(start..<end, with: block.trimmingSuffix("\n").components(separatedBy: "\n"))
                return lines.joined(separator: "\n")
            }
            lines[providers] = "providers:\n" + block.trimmingCharacters(in: .newlines)
            return lines.joined(separator: "\n")
        }
        let prefix = !text.isEmpty && !text.hasSuffix("\n") ? text + "\n" : text
        return "\(prefix)\nproviders:\n\(block)"
    }

    /// `custom:<host>:<model>`, the id Hermes's parse_model_input understands.
    static func hermesModelId(_ modelId: String?) -> String? {
        LocalHosts.decode(modelId).map { "custom:\($0.host):\($0.model)" }
    }

    static func ensureHermesProvider(_ modelId: String, env: [String: String]) {
        guard let inject = LocalHosts.decode(modelId), let host = LocalHosts.resolve(inject.host, env: env) else { return }
        let path = "\(hermesHome(env))/config.yaml"
        let text = read(path) ?? ""
        let next = upsertHermesProvider(text, hostId: inject.host, baseUrl: host.baseUrl, apiKey: LocalHosts.apiKey(host, env: env))
        if next != text { write(next, to: path) }
    }

    static let hermes = ACPSupport(
        driverKind: "hermesAgent", displayName: "Hermes", access: "custom", models: .empty, defaultCli: "hermes",
        nativeSource: "hermes.acp", loginNote: "Hermes CLI is not installed",
        install: EngineInstall(darwinCommand: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash",
                               docsUrl: "https://hermes-agent.nousresearch.com/docs/getting-started/quickstart", signInCommand: "hermes setup"),
        // ACP ignores `hermes -m`: the model goes over the wire (configureSession)
        spawnArgs: { _, _, _ in ["acp"] },
        // a leftover OPENAI_API_KEY makes Hermes auto-resolve to OpenRouter
        // with no Authorization header ("HTTP 401: Missing Authentication header")
        transformEnv: { env, _ in
            env["OPENAI_API_KEY"] = nil
            env["OPENROUTER_API_KEY"] = nil
        },
        pickAuthMethod: { _ in nil }, authFailure: .continue, isAuthenticated: { _, _ in true },
        resolveModels: { env, _ in await localCatalog(env) },
        resolveTurnModel: { model, env in
            if let model { ensureHermesProvider(model, env: env) }
            return model
        },
        configureSession: { session, _, model in
            guard let native = hermesModelId(model) else { return }
            do {
                _ = try await session.request("session/set_model", ["sessionId": .string(session.sessionId), "modelId": .string(native)])
            } catch {
                throw RPCError(message: "Hermes rejected model \"\(native)\" via session/set_model: \(error.localizedDescription)")
            }
        }
    )

    // MARK: - Gemini

    /// A stored OAuth credential counts only while it looks alive.
    static func liveGeminiCredential() -> Bool {
        guard let creds = FileIO.readJSON(URL(fileURLWithPath: NSHomeDirectory() + "/.gemini/oauth_creds.json")),
              let access = creds["access_token"]?.string, !access.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let hasRefresh = !(creds["refresh_token"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if let expiry = creds["expiry_date"] {
            guard let date = expiry.double, date.isFinite else { return false }
            return Date().timeIntervalSince1970 * 1000 < date || hasRefresh
        }
        return true
    }

    static func geminiIsAuthenticated(_ env: [String: String]) -> Bool {
        let nonBlank = { (key: String) in !(env[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        return nonBlank("GEMINI_API_KEY") || nonBlank("GOOGLE_API_KEY") || liveGeminiCredential()
    }

    static let gemini = ACPSupport(
        driverKind: "geminiAgent", displayName: "Gemini",
        models: ModelCatalog(default: "gemini-2.5-pro", options: [
            ModelOption(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro"), ModelOption(id: "gemini-2.5-flash", label: "Gemini 2.5 Flash"),
        ]),
        defaultCli: "gemini", nativeSource: "gemini.acp",
        loginNote: "Gemini CLI needs a GEMINI_API_KEY, a Vertex AI setup, or an enterprise Code Assist login — consumer Google logins stopped working on 2026-06-18 (use the Antigravity engine for those accounts)",
        spawnArgs: { _, model, _ in ["--experimental-acp"] + (model.map { ["-m", $0] } ?? []) },
        credentialEnv: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        pickAuthMethod: { ids in
            for preferred in ["gemini-api-key", "oauth-personal", "vertex-ai"] where ids.contains(preferred) { return preferred }
            return ids.first
        },
        authFailure: .continue, isAuthenticated: { env, _ in geminiIsAuthenticated(env) }
    )

    // MARK: - Qwen

    static func ensureQwenModel(_ modelId: String, env: [String: String]) -> String {
        guard let inject = LocalHosts.decode(modelId), let host = LocalHosts.resolve(inject.host, env: env) else { return modelId }
        let path = "\(home(env))/.qwen/settings.json"
        var settings = (read(path).flatMap { try? JSON.parse($0) })?.object ?? JSONObject()
        let keyName = "SWARMEBOT_QWEN_\(inject.host.uppercased().replacingOccurrences(of: #"[^A-Z0-9]+"#, with: "_", options: .regularExpression))_API_KEY"
        var envMap = settings["env"]?.object ?? JSONObject()
        envMap[keyName] = .string(LocalHosts.apiKey(host, env: env))
        settings["env"] = .object(envMap)
        var providers = settings["modelProviders"]?.object ?? JSONObject()
        var openai = providers["openai"]?.array ?? []
        if !openai.contains(where: { $0["id"]?.string == inject.model && $0["baseUrl"]?.string == host.baseUrl }) {
            openai.append(["id": .string(inject.model), "name": .string("\(inject.model) (\(host.label))"),
                           "baseUrl": .string(host.baseUrl), "envKey": .string(keyName)])
            providers["openai"] = .array(openai)
            settings["modelProviders"] = .object(providers)
        }
        write(JSON.object(settings).pretty() + "\n", to: path, mode: 0o600)
        return inject.model
    }

    static let qwen = ACPSupport(
        driverKind: "qwenAgent", displayName: "Qwen", access: "custom", models: .empty, defaultCli: "qwen",
        nativeSource: "qwen.acp", loginNote: "Qwen Code CLI is not installed",
        install: EngineInstall(darwinCommand: "curl -fsSL https://qwen-code-assets.oss-cn-hangzhou.aliyuncs.com/installation/install-qwen-standalone.sh | bash",
                               docsUrl: "https://qwenlm.github.io/qwen-code-docs/en/users/overview/"),
        spawnArgs: { _, model, _ in ["--acp"] + (model.map { ["-m", $0] } ?? []) },
        pickAuthMethod: { _ in nil }, authFailure: .continue, isAuthenticated: { _, _ in true },
        resolveModels: { env, _ in await localCatalog(env) },
        resolveTurnModel: { model, env in model.map { ensureQwenModel($0, env: env) } }
    )

    // MARK: - Kimi

    static let kimiModels = ModelCatalog(default: "kimi-code/k3", options: [
        ModelOption(id: "kimi-code/k3", label: "Kimi K3"), ModelOption(id: "kimi-code/k3-256k", label: "Kimi K3 256K"),
        ModelOption(id: "kimi-code/kimi-for-coding", label: "Kimi for Coding"),
        ModelOption(id: "kimi-code/kimi-for-coding-highspeed", label: "Kimi for Coding Highspeed"),
    ])

    static func kimiRoot(_ env: [String: String]) -> String {
        env["KIMI_CODE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home(env))/.kimi-code"
    }

    static func quoteTomlKey(_ key: String) -> String { matches(key, #"^[A-Za-z0-9_-]+$"#) ? key : quoteToml(key) }

    static func hasTomlTable(_ text: String, _ heading: String) -> Bool {
        text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == heading }
    }

    /// `[providers.host]` + `[models."host/alias"]`, so `kimi -m` reaches the host.
    static func ensureKimiAlias(_ modelId: String, env: [String: String]) -> String {
        guard let inject = LocalHosts.decode(modelId), let host = LocalHosts.resolve(inject.host, env: env) else { return modelId }
        let alias = "\(inject.host)/\(inject.model.replacingOccurrences(of: "/", with: "-"))"
        let path = "\(kimiRoot(env))/config.toml"
        let text = read(path) ?? ""
        let providerHeading = "[providers.\(inject.host)]"
        let modelHeading = "[models.\(quoteTomlKey(alias))]"
        var blocks: [String] = []
        if !hasTomlTable(text, providerHeading) {
            blocks.append([providerHeading, "type = \"openai_legacy\"", "base_url = \(quoteToml(host.baseUrl))",
                           "api_key = \(quoteToml(LocalHosts.apiKey(host, env: env)))", ""].joined(separator: "\n"))
        }
        if !hasTomlTable(text, modelHeading) {
            blocks.append([modelHeading, "provider = \(quoteToml(inject.host))", "model = \(quoteToml(inject.model))", ""].joined(separator: "\n"))
        }
        if !blocks.isEmpty {
            let prefix = text.isEmpty ? "" : text.hasSuffix("\n") ? text + "\n" : text + "\n\n"
            write(prefix + blocks.joined(separator: "\n"), to: path)
        }
        return alias
    }

    /// One pass over `[model.x]`/`[models.x]` tables: slug and its name.
    static func tomlModelTables(_ text: String, prefixes: [String]) -> [(slug: String, fields: [String: String])] {
        var tables: [(String, [String: String])] = []
        var current: (String, [String: String])?
        for line in text.components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("["), stripped.hasSuffix("]") {
                if let current { tables.append(current) }
                current = nil
                if let prefix = prefixes.first(where: { stripped.hasPrefix($0) }) {
                    var inner = String(stripped.dropFirst(prefix.count).dropLast())
                    if inner.count >= 2, inner.hasPrefix("\""), inner.hasSuffix("\"") { inner = String(inner.dropFirst().dropLast()) }
                    current = (inner, [:])
                }
                continue
            }
            guard current != nil, !stripped.isEmpty, !stripped.hasPrefix("#"), let eq = stripped.firstIndex(of: "=") else { continue }
            let key = stripped[..<eq].trimmingCharacters(in: .whitespaces)
            var value = stripped[stripped.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            current?.1[key] = value
        }
        if let current { tables.append(current) }
        return tables
    }

    static func kimiCatalog(_ env: [String: String]) -> ModelCatalog {
        guard let text = read("\(kimiRoot(env))/config.toml") else { return kimiModels }
        let localPrefixes = LocalHosts.all.map { "\($0.id)/" }
        var options = kimiModels.options
        for table in tomlModelTables(text, prefixes: ["[models.", "[model."]) {
            let slug = table.slug
            guard ClaudeCatalog.isModelId(slug), !options.contains(where: { $0.id == slug }),
                  !localPrefixes.contains(where: { slug.hasPrefix($0) }) else { continue }
            let name = table.fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? table.fields["label"].flatMap { $0.isEmpty ? nil : $0 }
            options.append(ModelOption(id: slug, label: name ?? slug, custom: true))
        }
        return ModelCatalog(default: kimiModels.default, options: options)
    }

    static let kimi = ACPSupport(
        driverKind: "kimiAgent", displayName: "Kimi", models: kimiModels, defaultCli: "kimi", nativeSource: "kimi.acp",
        loginNote: "Kimi Code CLI is not signed in — run `kimi login` in a terminal",
        install: EngineInstall(darwinCommand: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash",
                               docsUrl: "https://moonshotai.github.io/kimi-code/en/guides/getting-started.html", signInCommand: "kimi login"),
        // -m is global and must precede `acp`
        spawnArgs: { _, model, _ in (model.map { ["-m", $0] } ?? []) + ["acp"] },
        // subscription CLI: a leaked API key must not flip billing
        transformEnv: { env, _ in
            env["MOONSHOT_API_KEY"] = nil
            env["KIMI_API_KEY"] = nil
        },
        // the only advertised method is a terminal device-code flow
        pickAuthMethod: { _ in nil }, authFailure: .continue,
        isAuthenticated: { env, _ in FileManager.default.fileExists(atPath: "\(kimiRoot(env))/credentials/kimi-code.json") },
        resolveModels: { env, _ in await LocalHosts.merge(kimiCatalog(env), env: env) },
        resolveTurnModel: { model, env in model.map { ensureKimiAlias($0, env: env) } }
    )

    // MARK: - Droid

    static let droidModels = ModelCatalog(default: "claude-opus-5", options: [
        ModelOption(id: "auto", label: "Auto (Factory picks)"), ModelOption(id: "claude-opus-5", label: "Claude Opus 5"),
        ModelOption(id: "claude-sonnet-5", label: "Claude Sonnet 5"), ModelOption(id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5"),
        ModelOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol"), ModelOption(id: "gpt-5.6-terra", label: "GPT-5.6 Terra"),
        ModelOption(id: "gemini-3.1-pro-preview", label: "Gemini 3.1 Pro"), ModelOption(id: "glm-5.2", label: "GLM 5.2"),
        ModelOption(id: "kimi-k3", label: "Kimi K3"), ModelOption(id: "grok-4.6", label: "Grok 4.6"),
    ])
    static let droidInjectPrefix = "custom:swarmebot-"

    /// FACTORY_HOME_OVERRIDE replaces HOME, not the data root: `.factory` stays.
    static func factoryHome(_ env: [String: String]) -> String {
        env["FACTORY_HOME_OVERRIDE"].flatMap { $0.isEmpty ? nil : $0 } ?? home(env)
    }

    static func droidInjectId(host: String, model: String) -> String {
        droidInjectPrefix + "\(host)-\(model)".replacingOccurrences(of: #"[^a-zA-Z0-9._+-]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
    }

    struct DroidSettingsUnreadable: LocalizedError {
        var errorDescription: String? { "~/.factory/settings.json is not valid JSON — fix it before using a local model with Droid" }
    }

    /// A BYOK custom model, so session/set_model can reach the local host.
    static func ensureDroidModel(_ modelId: String, env: [String: String]) throws -> String {
        guard let inject = LocalHosts.decode(modelId), let host = LocalHosts.resolve(inject.host, env: env) else { return modelId }
        let id = droidInjectId(host: inject.host, model: inject.model)
        let path = "\(factoryHome(env))/.factory/settings.json"
        var settings = JSONObject()
        if let text = read(path) {
            guard let parsed = (try? JSON.parse(text))?.object else { throw DroidSettingsUnreadable() }
            settings = parsed
        }
        var custom = settings["customModels"]?.array ?? []
        if let index = custom.firstIndex(where: { $0["id"]?.string == id || ($0["model"]?.string == inject.model && $0["baseUrl"]?.string == host.baseUrl) }) {
            if let existing = custom[index]["id"]?.string, !existing.isEmpty { return existing }
            var row = custom[index].object ?? JSONObject()
            row["id"] = .string(id)
            custom[index] = .object(row)
            settings["customModels"] = .array(custom)
            write(JSON.object(settings).pretty() + "\n", to: path)
            return id
        }
        custom.append(["id": .string(id), "model": .string(inject.model), "displayName": .string("\(inject.model) (\(host.label))"),
                       "baseUrl": .string(host.baseUrl), "apiKey": .string(LocalHosts.apiKey(host, env: env)),
                       "provider": "generic-chat-completion-api"])
        settings["customModels"] = .array(custom)
        write(JSON.object(settings).pretty() + "\n", to: path)
        return id
    }

    /// Custom models, favourites first, the CLI's own default — then local hosts.
    static func droidCatalog(_ env: [String: String]) async -> ModelCatalog {
        var catalog = droidModels
        if let settings = FileIO.readJSON(URL(fileURLWithPath: "\(factoryHome(env))/.factory/settings.json")), settings.object != nil {
            let custom: [ModelOption] = (settings["customModels"]?.array ?? []).compactMap { row in
                if row["id"]?.string?.hasPrefix(droidInjectPrefix) == true { return nil }
                let id = row["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? row["model"]?.string.map { "custom:\($0)" } ?? ""
                guard !id.isEmpty else { return nil }
                let label = row["displayName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? row["model"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? id
                return ModelOption(id: id, label: label, custom: true)
            }
            let merged = custom + droidModels.options.filter { option in !custom.contains { $0.id == option.id } }
            let favorites = (settings["modelFavorites"]?.array ?? []).compactMap(\.string)
            let rank = { (id: String) in favorites.firstIndex(of: id) ?? Int.max }
            // stable: everything that is not a favourite keeps its order
            let options = merged.enumerated().sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }.map(\.element)
            let configured = settings["sessionDefaultSettings"]?["model"]?.string
            catalog = ModelCatalog(default: configured.flatMap { id in options.contains { $0.id == id } ? id : nil } ?? options.first?.id ?? droidModels.default,
                                   options: options)
        }
        return await LocalHosts.merge(catalog, env: env)
    }

    static func droidSetting(_ session: ACPSession, _ method: String, _ params: JSON, _ what: String) async throws {
        do {
            _ = try await session.request(method, params)
        } catch {
            throw RPCError(message: "Droid rejected \(what) via \(method): \(error.localizedDescription). "
                + "Check that `droid` is current (0.196.0+ supports it) and that this account can use that value.")
        }
    }

    static let droid = ACPSupport(
        driverKind: "droidAgent", displayName: "Droid", models: droidModels, defaultCli: "droid", nativeSource: "droid.acp",
        loginNote: "Droid CLI is not signed in — run `droid` once and log in, or set FACTORY_API_KEY",
        install: EngineInstall(darwinCommand: "curl -fsSL https://app.factory.ai/cli | sh",
                               docsUrl: "https://docs.factory.ai/droid-cli/quickstart", signInCommand: "droid"),
        // droid ignores argv for session settings: model and mode go over the wire
        spawnArgs: { _, _, _ in ["exec", "-o", "acp"] },
        credentialEnv: ["FACTORY_API_KEY"],
        pickAuthMethod: { _ in nil }, authFailure: .continue,
        isAuthenticated: { env, _ in
            ["auth.v2.file", "auth.v2.loginkeychain", "auth.v2.keyring"].contains {
                FileManager.default.fileExists(atPath: "\(factoryHome(env))/.factory/\($0)")
            } || !(env["FACTORY_API_KEY"] ?? "").isEmpty
        },
        resolveModels: { env, _ in await droidCatalog(env) },
        // a malformed settings file is never overwritten: the send fails instead
        resolveTurnModel: { model, env in try model.map { try ensureDroidModel($0, env: env) } },
        configureSession: { session, config, model in
            // always explicit: settings.json may pin a mode or a custom: model
            let mode = config.fullAuto ? "auto-high" : "normal"
            try await droidSetting(session, "session/set_mode", ["sessionId": .string(session.sessionId), "modeId": .string(mode)], "autonomy mode \"\(mode)\"")
            let modelId = model ?? droidModels.default
            try await droidSetting(session, "session/set_model", ["sessionId": .string(session.sessionId), "modelId": .string(modelId)], "model \"\(modelId)\"")
        }
    )

    // MARK: - OpenCode Go

    static let opencodeModels = ModelCatalog(default: "opencode-go/minimax-m3", options: [
        ModelOption(id: "opencode-go/minimax-m3", label: "Minimax M3"), ModelOption(id: "opencode-go/kimi-k3", label: "Kimi K3"),
        ModelOption(id: "opencode-go/glm-5.2", label: "GLM 5.2"),
    ])
    @MainActor static var lastOpencodeCatalog: ModelCatalog?

    @MainActor
    static func fetchOpencodeModels(session: URLSession = .shared) async -> ModelCatalog {
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/models")!)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
              let payload = try? JSON.parse(data) else { return lastOpencodeCatalog ?? opencodeModels }
        let ids = (payload.array ?? payload["data"]?.array ?? []).compactMap { $0["id"]?.string }
            .filter { matches($0, #"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"#) }
        guard !ids.isEmpty else { return lastOpencodeCatalog ?? opencodeModels }
        var options = opencodeModels.options
        for id in ids where !options.contains(where: { $0.id == "opencode-go/\(id)" }) {
            options.append(ModelOption(id: "opencode-go/\(id)", label: titleCase(id, separators: "-_."), custom: true))
        }
        let catalog = ModelCatalog(default: opencodeModels.default, options: options)
        lastOpencodeCatalog = catalog
        return catalog
    }

    static func opencodeConfigDir(_ env: [String: String]) -> String {
        "\(env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home(env))/.config")/opencode"
    }

    static func ensureOpencodeModel(_ modelId: String, env: [String: String]) -> String {
        guard let inject = LocalHosts.decode(modelId), let host = LocalHosts.resolve(inject.host, env: env) else { return modelId }
        let path = "\(opencodeConfigDir(env))/opencode.json"
        var config = (read(path).flatMap { try? JSON.parse($0) })?.object ?? JSONObject([("$schema", "https://opencode.ai/config.json")])
        var providers = config["provider"]?.object ?? JSONObject()
        var existing = providers[inject.host]?.object
            ?? JSONObject([("npm", "@ai-sdk/openai-compatible"), ("name", .string(host.label)), ("options", [:]), ("models", [:])])
        var options = existing["options"]?.object ?? JSONObject()
        options["baseURL"] = .string(host.baseUrl)
        if options["apiKey"]?.truthy != true { options["apiKey"] = .string(LocalHosts.apiKey(host, env: env)) }
        var models = existing["models"]?.object ?? JSONObject()
        if models[inject.model]?.truthy != true { models[inject.model] = ["name": .string("\(inject.model) (\(host.label))")] }
        if existing["npm"]?.truthy != true { existing["npm"] = "@ai-sdk/openai-compatible" }
        if existing["name"]?.truthy != true { existing["name"] = .string(host.label) }
        existing["options"] = .object(options)
        existing["models"] = .object(models)
        providers[inject.host] = .object(existing)
        config["provider"] = .object(providers)
        write(JSON.object(config).pretty() + "\n", to: path)
        return "\(inject.host)/\(inject.model)"
    }

    /// xdg first on every platform: that is where real logins land.
    static func opencodeSignedIn(_ env: [String: String]) -> Bool {
        if !(env["OPENCODE_API_KEY"] ?? "").isEmpty { return true }
        var candidates = env["OPENCODE_AUTH_CONTENT"].map { [$0] } ?? []
        let roots = [env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home(env))/.local/share",
                     "\(home(env))/Library/Application Support"]
        for root in Set(roots) { if let text = read("\(root)/opencode/auth.json") { candidates.append(text) } }
        return candidates.contains { raw in
            guard let parsed = try? JSON.parse(raw) else { return false }
            return ["opencode-go", "opencode"].contains { id in
                guard let entry = parsed[id], entry.object != nil else { return false }
                return entry["key"]?.truthy == true || entry["access"]?.truthy == true || entry["refresh"]?.truthy == true
            }
        }
    }

    static func classifyOpencode(_ error: Error) -> String? {
        let code = (error as? RPCError)?.code
        if code?.double == -32000 { return "invalid_credentials" }
        switch code?.string {
        case "AUTH_REQUIRED", "INVALID_API_KEY", "UNAUTHORIZED": return "invalid_credentials"
        case "SUBSCRIPTION_INACTIVE": return "inactive_subscription"
        case "QUOTA_EXCEEDED", "REGION_RESTRICTED": return "quota_or_region_restriction"
        case "UPSTREAM_UNAVAILABLE", "SERVICE_UNAVAILABLE": return "upstream_outage"
        case "MODEL_CATALOG_UNAVAILABLE": return "model_catalog_outage"
        default: return nil
        }
    }

    static let opencodeGo = ACPSupport(
        driverKind: "opencodeGo", displayName: "OpenCode Go", models: opencodeModels, defaultCli: "opencode",
        nativeSource: "opencode-go.acp",
        loginNote: "OpenCode is not signed in — run `opencode auth login` and pick OpenCode, or add an OPENCODE_API_KEY in SwarmeBot settings",
        install: EngineInstall(darwinCommand: "npm install -g opencode-ai", docsUrl: "https://opencode.ai/docs/",
                               signInCommand: "opencode auth login", needsNode: true),
        spawnArgs: { _, _, _ in ["acp"] },
        credentialEnv: ["OPENCODE_API_KEY"],
        // opencode's ACP takes no -m: the model is a session config option, confirmed before prompting
        selectModelConfigId: "model",
        transformEnv: { env, _ in
            for key in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "XAI_API_KEY", "KIMI_API_KEY", "MOONSHOT_API_KEY"] {
                env[key] = nil
            }
        },
        pickAuthMethod: { _ in nil }, authFailure: .continue, isAuthenticated: { env, _ in opencodeSignedIn(env) },
        classifyError: classifyOpencode,
        resolveModels: { env, _ in await LocalHosts.merge(await fetchOpencodeModels(), env: env) },
        resolveTurnModel: { model, env in model.map { ensureOpencodeModel($0, env: env) } }
    )

    // MARK: - Grok (grok.com subscription CLI)

    static let grokModels = ModelCatalog(default: "grok-4.6", options: [
        ModelOption(id: "grok-4.6", label: "Grok 4.6"), ModelOption(id: "grok-4.5", label: "Grok 4.5"),
    ])

    static func grokHome(_ env: [String: String]) -> String {
        env["GROK_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home(env))/.grok"
    }

    static func isGrokSlug(_ slug: String) -> Bool { matches(slug, #"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"#) }

    /// Local slugs from ~/.grok/config.toml plus the cloud defaults.
    static func grokCatalog(_ env: [String: String]) -> ModelCatalog {
        guard let text = read("\(grokHome(env))/config.toml") else { return grokModels }
        var options = grokModels.options
        var configuredDefault: String?
        var inModels = false
        for line in text.components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("[") { inModels = stripped == "[models]"; continue }
            guard inModels, let eq = stripped.firstIndex(of: "="), stripped[..<eq].trimmingCharacters(in: .whitespaces) == "default" else { continue }
            var value = stripped[stripped.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            configuredDefault = value
        }
        for table in tomlModelTables(text, prefixes: ["[model."]) where isGrokSlug(table.slug) && !options.contains(where: { $0.id == table.slug }) {
            let name = table.fields["name"].flatMap { $0.isEmpty ? nil : $0 }
            options.append(ModelOption(id: table.slug, label: name ?? table.slug, custom: true))
        }
        let ids = Set(options.map(\.id))
        return ModelCatalog(default: configuredDefault.flatMap { ids.contains($0) ? $0 : nil } ?? grokModels.default, options: options)
    }

    /// A `[model.slug]` block, so `grok -m` reaches the injected host.
    static func ensureGrokSlug(_ modelId: String, env: [String: String]) -> String {
        guard let inject = LocalHosts.decode(modelId), let host = LocalHosts.resolve(inject.host, env: env) else { return modelId }
        let path = "\(grokHome(env))/config.toml"
        let text = read(path) ?? ""
        var taken = Set(grokModels.options.map(\.id))
        for table in tomlModelTables(text, prefixes: ["[model."]) {
            taken.insert(table.slug)
            if table.fields["model"] == inject.model, table.fields["base_url"] == host.baseUrl { return table.slug }
        }
        var base = "\(inject.host)-\(inject.model)".lowercased()
            .replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"^-|-$"#, with: "", options: .regularExpression)
        if base.isEmpty || !matches(base, "^[a-z]") { base = "m-\(base.isEmpty ? "model" : base)" }
        var slug = base
        var n = 2
        while taken.contains(slug) { slug = "\(base)-\(n)"; n += 1 }
        let heading = matches(slug, #"[^a-zA-Z0-9_-]"#) ? "[model.\"\(slug)\"]" : "[model.\(slug)]"
        let block = [heading, "model = \(quoteToml(inject.model))", "base_url = \(quoteToml(host.baseUrl))",
                     "name = \(quoteToml("\(inject.model) (\(host.label))"))", "api_backend = \"chat_completions\"",
                     "api_key = \(quoteToml(LocalHosts.apiKey(host, env: env)))", ""].joined(separator: "\n")
        let next = !text.isEmpty && !text.hasSuffix("\n") ? "\(text)\n\n\(block)" : "\(text)\(text.isEmpty ? "" : "\n")\(block)"
        write(next, to: path)
        return slug
    }

    static let grok = ACPSupport(
        driverKind: "grokAgent", displayName: "Grok", models: grokModels,
        // the intersection every model in the picker accepts (grok-4.5 rejects xhigh)
        effortLevels: ["low", "medium", "high"],
        defaultCli: "grok", nativeSource: "grok.acp", images: false,
        loginNote: "Grok CLI is not signed in — run `grok login` in a terminal",
        install: EngineInstall(darwinCommand: "curl -fsSL https://x.ai/cli/install.sh | bash", docsUrl: "https://x.ai/cli", signInCommand: "grok login"),
        // -m and --reasoning-effort only apply between `agent` and `stdio`
        spawnArgs: { config, model, effort in
            ["--permission-mode", config.fullAuto ? "bypassPermissions" : "default", "agent"]
                + (model.map { ["-m", $0] } ?? []) + (effort.map { ["--reasoning-effort", $0] } ?? []) + ["stdio"]
        },
        // the CLI owns its grok.com login; a leaked API key flips billing
        transformEnv: { env, _ in env["XAI_API_KEY"] = nil },
        pickAuthMethod: { ids in ids.contains("cached_token") ? "cached_token" : nil },
        authFailure: .fail,
        isAuthenticated: { _, _ in FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.grok/auth.json") },
        resolveModels: { env, _ in await LocalHosts.merge(grokCatalog(env), env: env) },
        resolveTurnModel: { model, env in model.map { ensureGrokSlug($0, env: env) } },
        // argv is not enough: session/new still starts on [models].default
        configureSession: { session, _, model in
            guard let model else { return }
            do {
                _ = try await session.request("session/set_model", ["sessionId": .string(session.sessionId), "modelId": .string(model)])
            } catch {
                throw RPCError(message: "Grok rejected model \"\(model)\" via session/set_model: \(error.localizedDescription). "
                    + "Check that grok is current (1.0.6+ supports it) and that this slug exists in ~/.grok/config.toml.")
            }
        }
    )

    // MARK: - Cursor

    static let cursorModels = ModelCatalog(default: "auto", options: [
        ModelOption(id: "auto", label: "Auto"), ModelOption(id: "composer-2.5", label: "Composer 2.5"),
        ModelOption(id: "composer-2.5-fast", label: "Composer 2.5 Fast"), ModelOption(id: "gpt-5.3-codex", label: "Codex 5.3"),
        ModelOption(id: "claude-sonnet-5-thinking-high", label: "Claude Sonnet 5 1M Thinking"),
    ])

    static func isCursorSlug(_ id: String) -> Bool { matches(id, #"^[a-zA-Z0-9][a-zA-Z0-9._:+-]*$"#) }

    static func cursorLabel(_ id: String, _ explicit: String?) -> String {
        if let explicit = explicit?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty { return explicit }
        return titleCase(id, separators: "-_./")
    }

    /// Static rows lead (a stable rail), live ids follow.
    static func cursorMerged(_ live: [ModelOption], default defaultId: String) -> ModelCatalog {
        var options = cursorModels.options
        for option in live where !options.contains(where: { $0.id == option.id }) { options.append(option) }
        return ModelCatalog(default: defaultId, options: options)
    }

    /// The first JSON value in stdout, past any banner.
    static func firstJSON(_ text: String) -> JSON? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let json = try? JSON.parse(trimmed) { return json }
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        var end = trimmed.endIndex
        while end > trimmed.index(after: start) {
            let slice = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if slice.hasSuffix("}") || slice.hasSuffix("]"), let json = try? JSON.parse(slice) { return json }
            end = trimmed.index(before: end)
        }
        return nil
    }

    static func cursorCatalog(json payload: JSON?) -> ModelCatalog? {
        let records = payload?.array ?? payload?["models"]?.array ?? payload?["data"]?.array ?? payload?["modelIds"]?.array ?? []
        var options: [ModelOption] = []
        for row in records {
            let id: String?
            var label: String?
            if let string = row.string { id = string } else {
                id = [row["id"], row["modelId"], row["slug"], row["name"]].lazy.compactMap { $0?.string }.first
                label = row["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? row["displayName"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                    ?? row["name"]?.string.flatMap { $0 == id ? nil : $0 }
            }
            guard let id, isCursorSlug(id), !options.contains(where: { $0.id == id }) else { continue }
            options.append(ModelOption(id: id, label: cursorLabel(id, label)))
        }
        guard !options.isEmpty else { return nil }
        let seen = Set(options.map(\.id))
        let defaultId = payload?["default"]?.string.flatMap { seen.contains($0) ? $0 : nil }
            ?? (seen.contains(cursorModels.default) ? cursorModels.default : options[0].id)
        return cursorMerged(options, default: defaultId)
    }

    /// Plain `cursor-agent models`: a slug per line, `id - Label`, `(default)`/`(current)`.
    static func cursorCatalog(text: String) -> ModelCatalog? {
        var options: [ModelOption] = []
        var markedDefault: String?, markedCurrent: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || matches(line, #"(?i)^available\s+models?\b"#) || matches(line, #"(?i)^models?\b"#) { continue }
            let stripped = line.replacingOccurrences(of: #"^[\s*•\-]+\s*"#, with: "", options: .regularExpression)
            let parts = stripped.replacingOccurrences(of: #"\s+[—–|:]\s+|\s+-\s+|\s{2,}"#, with: "\u{1}", options: .regularExpression)
                .components(separatedBy: "\u{1}")
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            var label = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            var isDefault = false, isCurrent = false
            if let range = label.range(of: #"\s*\(default\)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
                isDefault = true
                label = String(label[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if let range = label.range(of: #"\s*\(current\)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
                isCurrent = true
                label = String(label[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            guard isCursorSlug(id), !options.contains(where: { $0.id == id }) else { continue }
            options.append(ModelOption(id: id, label: cursorLabel(id, label.isEmpty ? nil : label)))
            if isDefault { markedDefault = id }
            if isCurrent { markedCurrent = id }
        }
        guard !options.isEmpty else { return nil }
        let seen = Set(options.map(\.id))
        let defaultId = markedDefault.flatMap { seen.contains($0) ? $0 : nil } ?? markedCurrent.flatMap { seen.contains($0) ? $0 : nil }
            ?? (seen.contains(cursorModels.default) ? cursorModels.default : options[0].id)
        return cursorMerged(options, default: defaultId)
    }

    static func authFlag(_ value: JSON?) -> Bool? {
        if let bool = value?.bool { return bool }
        guard let text = value?.string?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if ["true", "authenticated", "logged_in", "logged-in", "yes"].contains(text) { return true }
        if ["false", "unauthenticated", "logged_out", "logged-out", "no"].contains(text) { return false }
        return nil
    }

    static func cursorAuth(json payload: JSON?) -> Bool? {
        guard let payload, payload.object != nil else { return nil }
        let auth = payload["auth"]
        for candidate in [payload["isAuthenticated"], payload["authenticated"], payload["loggedIn"], payload["logged_in"],
                          auth?["isAuthenticated"], auth?["authenticated"], payload["status"], auth?["status"]] {
            if let flag = authFlag(candidate) { return flag }
        }
        return nil
    }

    static func cursorAuth(text: String) -> Bool? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return nil }
        if matches(normalized, "not (?:logged|signed) in|not authenticated|unauthenticated|logged out") { return false }
        if matches(normalized, "login successful|logged in|signed in|authenticated") { return true }
        return nil
    }

    static func classifyCursor(_ error: Error) -> String? {
        let rpc = error as? RPCError
        let code = rpc?.code
        let blob = "\(code.map { $0.string ?? $0.serialized() } ?? "") \(rpc?.message ?? error.localizedDescription)".lowercased()
        if code?.double == -32000
            || matches(blob, "unauthoriz|unauthenticated|not signed in|not logged in|invalid api key|invalid_credentials|authentication required") {
            return "invalid_credentials"
        }
        if matches(blob, #"inactive subscription|subscription.*(expired|inactive)|upgrade your (plan|subscription)"#) { return "inactive_subscription" }
        return nil
    }

    static let cursor = ACPSupport(
        driverKind: "cursorAgent", displayName: "Cursor", models: cursorModels, defaultCli: "cursor-agent", nativeSource: "cursor.acp",
        loginNote: "Cursor CLI is not signed in — run `cursor-agent login` in a terminal, or set CURSOR_API_KEY",
        install: EngineInstall(darwinCommand: "curl https://cursor.com/install -fsS | bash",
                               docsUrl: "https://cursor.com/docs/cli/installation", signInCommand: "cursor-agent login"),
        // global flags precede `acp`; --force is the documented auto-approve
        spawnArgs: { config, model, _ in (config.fullAuto ? ["--force"] : []) + (model.map { ["--model", $0] } ?? []) + ["acp"] },
        credentialEnv: ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"],
        pickAuthMethod: { ids in ids.contains("cursor_login") ? "cursor_login" : nil },
        authFailure: .continue,
        isAuthenticated: { env, config in
            let nonBlank = { (key: String) in !(env[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            if nonBlank("CURSOR_API_KEY") || nonBlank("CURSOR_AUTH_TOKEN") { return true }
            for args in [["status", "--format", "json"], ["status"]] {
                guard let output = await CLIProcess.run(config.cli, args, environment: env, timeout: 8), output.ok else { continue }
                if let decoded = cursorAuth(json: firstJSON(output.stdout)) ?? cursorAuth(text: output.stdout) { return decoded }
            }
            return false
        },
        classifyError: classifyCursor,
        resolveModels: { env, config in
            for args in [["models"], ["--list-models"]] {
                guard let output = await CLIProcess.run(config.cli, args, environment: env, timeout: 8), output.ok else { continue }
                if let catalog = cursorCatalog(text: output.stdout) ?? cursorCatalog(json: firstJSON(output.stdout)) { return catalog }
            }
            return cursorModels
        },
        // best effort: argv --model is the reliable pin, a missing method is fine. Newer CLIs only accept
        // their ACP ids here ("grok-4.7[context=256k,…]") and answer -32602 to the `cursor-agent models` slug
        // already applied through argv; an unknown model fails the spawn itself, so nothing is hidden.
        configureSession: { session, _, model in
            guard let model else { return }
            do {
                _ = try await session.request("session/set_model", ["sessionId": .string(session.sessionId), "modelId": .string(model)])
            } catch let error as RPCError where error.code?.double == -32601 || error.code?.double == -32602 {
                return
            } catch {
                throw RPCError(message: "Cursor rejected model \"\(model)\" via session/set_model: \(error.localizedDescription). "
                    + "Check that `cursor-agent` is current and that this account can use that model.")
            }
        }
    )
}
