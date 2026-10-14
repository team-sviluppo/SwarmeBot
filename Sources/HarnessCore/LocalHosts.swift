// Local and self-hosted model servers — `server/drivers/local-inject.ts`.
//
// oMLX, Ollama, EXO, LM Studio, Unsloth, vLLM and the user's own Local
// Endpoint (LiteLLM, a hosted proxy…) are probed for their models, which
// appear in the picker as `host::model`; a pick decodes back into a host
// and the API id to send.
import Foundation

public struct LocalHost: Sendable, Equatable {
    public var id: String
    public var label: String
    public var baseUrl: String
    public var apiKey: String?
    public var apiKeyEnv: String?
    public var baseUrlEnv: String?
}

public enum LocalHosts {
    public static let baseUrlEnv = "LOCAL_ENDPOINT_BASE_URL"
    public static let apiKeyEnv = "LOCAL_ENDPOINT_AUTH_KEY"
    public static let separator = "::"

    public static let all: [LocalHost] = [
        LocalHost(id: "omlx", label: "oMLX", baseUrl: "http://127.0.0.1:8080/v1", apiKey: "omlx"),
        LocalHost(id: "ollama", label: "Ollama", baseUrl: "http://127.0.0.1:11434/v1", apiKey: "ollama"),
        LocalHost(id: "local_ollama", label: "Ollama", baseUrl: "http://127.0.0.1:11434/v1", apiKey: "ollama"),
        LocalHost(id: "exo", label: "EXO", baseUrl: "http://127.0.0.1:52415/v1", apiKey: "exo"),
        LocalHost(id: "lmstudio", label: "LM Studio", baseUrl: "http://127.0.0.1:1234/v1", apiKey: "lm-studio"),
        LocalHost(id: "unsloth", label: "Unsloth", baseUrl: "http://127.0.0.1:8888/v1", apiKeyEnv: "UNSLOTH_STUDIO_AUTH_TOKEN"),
        LocalHost(id: "unsloth_api", label: "Unsloth", baseUrl: "http://127.0.0.1:8888/v1", apiKeyEnv: "UNSLOTH_STUDIO_AUTH_TOKEN"),
        LocalHost(id: "vllm_api", label: "Local Server", baseUrl: "http://127.0.0.1:8000/v1", apiKeyEnv: "local"),
        LocalHost(id: "local_endpoint", label: "Local Endpoint", baseUrl: "", apiKeyEnv: apiKeyEnv, baseUrlEnv: baseUrlEnv),
    ]

    static func modelIdIsValid(_ id: String) -> Bool {
        id.range(of: #"^[\w][\w./:+-]*$"#, options: .regularExpression) != nil
    }

    public static func encode(host: String, model: String) -> String { "\(host)\(separator)\(model)" }

    public static func decode(_ id: String?) -> (host: String, model: String)? {
        guard let id, let range = id.range(of: separator), range.lowerBound > id.startIndex else { return nil }
        let host = String(id[..<range.lowerBound])
        let model = String(id[range.upperBound...])
        guard all.contains(where: { $0.id == host }), modelIdIsValid(model) else { return nil }
        return (host, model)
    }

    /// What a user pastes → the OpenAI-compatible base, `/v1` added to a bare origin.
    public static func normalizeGatewayBaseUrl(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.fragment = nil
        components.query = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path.isEmpty ? "/v1" : path
        guard var out = components.string else { return nil }
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    public static func resolve(_ id: String, env: [String: String]) -> LocalHost? {
        guard var host = all.first(where: { $0.id == id }) else { return nil }
        if let key = host.baseUrlEnv, let url = normalizeGatewayBaseUrl(env[key]) { host.baseUrl = url }
        return host.baseUrl.isEmpty ? nil : host
    }

    public static func apiKey(_ host: LocalHost, env: [String: String]) -> String {
        if let name = host.apiKeyEnv, let value = env[name], !value.isEmpty { return value }
        if let key = host.apiKey { return key }
        if host.id == "unsloth" || host.id == "unsloth_api" {
            let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".unsloth/studio/auth/agent_api_key.json")
            if let key = FileIO.readJSON(file)?["api_key"]?.string, !key.isEmpty { return key }
        }
        return "local"
    }

    /// Picker text: a Local Endpoint id is `namespace/model` → `namespace (model)`.
    public static func label(_ host: LocalHost, model: String) -> String {
        if host.id == "local_endpoint" {
            if let slash = model.firstIndex(of: "/"), slash > model.startIndex {
                return "\(model[..<slash]) (\(model[model.index(after: slash)...]))"
            }
            return model
        }
        return "\(model) (\(host.label))"
    }

    static func ids(fromModelsPayload payload: JSON?) -> [String] {
        let records = payload?.array ?? payload?["data"]?.array ?? payload?["models"]?.array ?? []
        return records.compactMap { record in
            let id = record.string ?? record["id"]?.string ?? record["name"]?.string
            guard let id, modelIdIsValid(id) else { return nil }
            let low = id.lowercased()
            if low.contains("embed") || low.contains("bge-") || low.contains("nomic") { return nil }
            return id
        }
    }

    /// One GET with the 1.2 s budget the Node engine gives loopback probes.
    static func timedJSON(_ url: String, host: LocalHost, env: [String: String], session: URLSession) async -> JSON? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.timeoutInterval = 1.2
        request.setValue("Bearer \(apiKey(host, env: env))", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true
        else { return nil }
        return try? JSON.parse(data)
    }

    /// Live models from the given hosts, as custom catalog rows.
    public static func probe(hostIds: [String], env: [String: String], session: URLSession = .shared) async -> [ModelOption] {
        var seen = Set<String>()
        let hosts = hostIds.compactMap { resolve($0, env: env) }.filter {
            seen.insert($0.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted
        }
        var options: [ModelOption] = []
        for host in hosts {
            let base = host.baseUrl.hasSuffix("/") ? String(host.baseUrl.dropLast()) : host.baseUrl
            let catalog = await timedJSON("\(base)/models", host: host, env: env, session: session)
            var unique = Set<String>()
            for model in ids(fromModelsPayload: catalog) where unique.insert(model).inserted {
                options.append(ModelOption(id: encode(host: host.id, model: model), label: label(host, model: model), custom: true))
            }
        }
        return options
    }

    /// Anthropic-compatible base: Claude Code wants it without the trailing /v1.
    public static func anthropicBaseUrl(_ host: LocalHost) -> String {
        host.baseUrl.replacingOccurrences(of: #"/v1/?$"#, with: "", options: .regularExpression)
    }

    /// `applyClaudeInject`: point Claude Code at the injected host instead of
    /// Anthropic's cloud. The model comes back as the API id to pass.
    @discardableResult
    public static func applyClaudeInject(_ env: inout [String: String], modelId: String?) -> (model: String?, injected: Bool) {
        guard let inject = decode(modelId), let host = resolve(inject.host, env: env) else { return (modelId, false) }
        let key = apiKey(host, env: env)
        env["ANTHROPIC_BASE_URL"] = anthropicBaseUrl(host)
        env["ANTHROPIC_AUTH_TOKEN"] = key
        env["ANTHROPIC_API_KEY"] = key
        env["ANTHROPIC_MODEL"] = inject.model
        return (inject.model, true)
    }

    /// `applyOpenAIInject`: the same for OpenAI-compatible CLIs.
    @discardableResult
    public static func applyOpenAIInject(_ env: inout [String: String], modelId: String?) -> (model: String?, injected: Bool) {
        guard let inject = decode(modelId), let host = resolve(inject.host, env: env) else { return (modelId, false) }
        env["OPENAI_BASE_URL"] = host.baseUrl
        env["OPENAI_API_KEY"] = apiKey(host, env: env)
        return (inject.model, true)
    }

    /// `mergeLocalInject`: live local models appended as custom rows,
    /// official rows first. Nil host ids probe every known host.
    public static func merge(_ catalog: ModelCatalog, env: [String: String], hostIds: [String]? = nil,
                             session: URLSession = .shared) async -> ModelCatalog {
        let extras = await probe(hostIds: hostIds ?? all.map(\.id), env: env, session: session)
        guard !extras.isEmpty else { return catalog }
        var options = catalog.options
        for extra in extras where !options.contains(where: { $0.id == extra.id }) { options.append(extra) }
        return ModelCatalog(default: catalog.default, options: options)
    }
}

/// `WORKSPACE_CREDENTIAL_ENV`: keys the harness may hold that no spawned CLI
/// is entitled to see.
public enum WorkspaceCredentials {
    public static let env = [
        "XAI_API_KEY", "BOX_TOKEN", "OPENCODE_API_KEY", LocalHosts.apiKeyEnv,
        "OMB_TTS_KEY", "COMPOSIO_API_KEY", "OMB_COMPOSIO_BROKER_TOKEN",
    ]

    public static func strip(_ environment: inout [String: String]) {
        for key in env { environment[key] = nil }
    }
}
