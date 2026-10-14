// DeepSeek Harness connection and model management —
// `server/deepseek-harness-settings.ts` and its routes in `server/index.ts`:
//
//   GET   /api/instances/:id/deepseek-harness           connection + what can be managed
//   PATCH /api/instances/:id/deepseek-harness           {baseUrl?, transport?, agentPreset?}
//   POST  /api/instances/:id/deepseek-harness/pair      {pairingLink}  one-time pairing
//   POST  /api/instances/:id/deepseek-harness/discover  {provider}     candidate models
//   POST  /api/instances/:id/deepseek-harness/upsert    {provider, model}
//
// Errors answer `{code, error}` with a fixed public sentence per code: the
// Host's own messages never reach the client. Management goes through the
// Host API for a direct connection and through the dsh-remote-web-ui plugin
// routes (`/api/pair/model-catalog…`) for a paired device.
import Foundation

// MARK: - Config

/// `decodeConfig`: strict — unknown keys, a non-origin URL, or paired
/// without a cookie are refused, so a bad config shadows instead of guessing.
public struct DeepSeekHarnessConfig: Equatable, Sendable {
    public static let defaultBaseUrl = "http://127.0.0.1:3080"
    public var baseUrl: String
    public var transport: String
    public var deviceCookie: String?
    public var agentPreset: String?

    public struct Invalid: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public init(baseUrl: String, transport: String, deviceCookie: String?, agentPreset: String?) {
        self.baseUrl = baseUrl
        self.transport = transport
        self.deviceCookie = deviceCookie
        self.agentPreset = agentPreset
    }

    public init(_ raw: JSON) throws {
        let object: JSONObject
        switch raw {
        case .null: object = JSONObject()
        case let .object(value): object = value
        default: throw Invalid(message: "deepseekHarness config must be an object")
        }
        let allowed: Set<String> = ["baseUrl", "transport", "deviceCookie", "agentPreset"]
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) { throw Invalid(message: "deepseekHarness: unknown key \(unknown)") }
        if let value = object["baseUrl"], value.string == nil { throw Invalid(message: "deepseekHarness.baseUrl must be a string") }
        if let value = object["transport"], value.string != "direct", value.string != "paired" {
            throw Invalid(message: "deepseekHarness.transport must be direct or paired")
        }
        if let value = object["deviceCookie"], !DeepSeekSettings.validCookie(value.string) {
            throw Invalid(message: "deepseekHarness.deviceCookie is invalid")
        }
        if let value = object["agentPreset"] {
            guard let preset = value.string, !preset.isEmpty, preset.count <= 512 else { throw Invalid(message: "deepseekHarness.agentPreset is invalid") }
        }
        guard let origin = Self.origin(object["baseUrl"]?.string ?? Self.defaultBaseUrl, trim: false) else {
            throw Invalid(message: "deepseekHarness.baseUrl must be an absolute HTTP or HTTPS origin")
        }
        transport = object["transport"]?.string ?? "direct"
        deviceCookie = object["deviceCookie"]?.string
        agentPreset = object["agentPreset"]?.string
        baseUrl = origin
        if transport == "paired", deviceCookie == nil { throw Invalid(message: "deepseekHarness.deviceCookie is required for paired transport") }
    }

    /// `url.origin` for an http(s) URL with nothing but scheme, host and port.
    public static func origin(_ value: String, trim: Bool = true) -> String? {
        let text = trim ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        var origin = "\(scheme)://\(host.lowercased())"
        if let port = components.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) { origin += ":\(port)" }
        return origin
    }

    public var json: JSON {
        var o: JSONObject = ["baseUrl": .string(baseUrl), "transport": .string(transport)]
        if let deviceCookie { o["deviceCookie"] = .string(deviceCookie) }
        if let agentPreset { o["agentPreset"] = .string(agentPreset) }
        return .object(o)
    }

    /// `publicDeepSeekHarnessConnection`: never the cookie itself.
    public func publicConnection(_ instanceId: String) -> JSON {
        var o: JSONObject = ["instanceId": .string(instanceId), "transport": .string(transport), "baseUrl": .string(baseUrl),
                             "paired": .bool(transport == "paired" && deviceCookie != nil), "hasDeviceCredential": .bool(deviceCookie != nil)]
        if let agentPreset { o["agentPreset"] = .string(agentPreset) }
        return .object(o)
    }
}

// MARK: - Errors

public struct DeepSeekSettingsError: Error {
    public let status: Int
    public let code: String
    public let message: String

    public init(_ status: Int, _ code: String, _ message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    static let publicCopy: [String: String] = [
        "settings-busy": "Another provider update is still finishing. Wait a moment and try again.",
        "invalid-request": "The DeepSeek Harness settings request was invalid.",
        "invalid-base-url": "Enter an absolute HTTP or HTTPS origin, including its port when needed.",
        "pairing-required": "No approved paired device is stored. Paste a pairing link generated by DSH to connect this device.",
        "pairing-unavailable": "SwarmeBot could not reach the DSH pairing endpoint. Check the base URL and network or Tailscale access, then retry.",
        "pairing-rejected": "DSH rejected this pairing link or token because it is invalid or expired. Generate a fresh pairing link and try again.",
        "host-unavailable": "DeepSeek Harness is unreachable from this SwarmeBot host.",
        "paired-device-unauthorized": "Pair this DeepSeek Harness again to restore paired access.",
        "paired-plugin-update-required": "Update @linxin666/dsh-remote-web-ui, then check again.",
        "provider-not-eligible": "This provider is not eligible for pi-ai model management.",
        "model-update-conflict": "DSH settings changed elsewhere. Refresh the catalog and try again.",
        "model-update-rejected": "DeepSeek Harness rejected the model update.",
        "invalid-response": "DeepSeek Harness returned an invalid model-management response.",
        "request-failed": "DeepSeek Harness request failed. Check the connection and try again.",
    ]

    /// `publicDeepSeekHarnessSettingsError`: internal code → public code.
    public var publicCode: String {
        switch code {
        case "invalid-request", "invalid-pairing-link", "invalid-deepseek-config", "deepseek-instance-not-found": return "invalid-request"
        case "invalid-base-url": return "invalid-base-url"
        case "pairing-required": return "pairing-required"
        case "pairing-unavailable", "pairing-redirect-refused": return "pairing-unavailable"
        case "pairing-rejected": return "pairing-rejected"
        case "paired-device-unauthorized": return "paired-device-unauthorized"
        case "paired-model-catalog-unavailable": return "paired-plugin-update-required"
        case "provider-not-eligible": return "provider-not-eligible"
        case "model-update-conflict": return "model-update-conflict"
        case "model-update-rejected": return "model-update-rejected"
        case "invalid-dsh-response", "invalid-paired-response": return "invalid-response"
        case "paired-host-unavailable", "paired-redirect-refused", "paired-model-management-failed", "dsh-management-failed": return "host-unavailable"
        default: return "request-failed"
        }
    }

    public var publicBody: JSON {
        ["code": .string(publicCode), "error": .string(Self.publicCopy[publicCode] ?? "")]
    }
}

// MARK: - Parsing

public enum DeepSeekSettings {
    static let maxBodyBytes = 16 * 1024
    static let maxResponseBytes = 256 * 1024
    static let maxTokenLimit = 10_000_000.0
    static let reasoningEfforts = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    static let pairedCatalogReason = "Update @linxin666/dsh-remote-web-ui to a version that supports paired model management."

    static func validCookie(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.count <= 4_096 else { return false }
        return !value.contains("\r") && !value.contains("\n")
    }

    /// `safeString(max)`: trimmed, 1…max, no newline or NUL.
    static func safeString(_ value: JSON?, max: Int) -> String? {
        guard let raw = value?.string else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= max, !text.contains("\r"), !text.contains("\n"), !text.contains("\0") else { return nil }
        return text
    }

    static func positiveInt(_ value: JSON?, max: Double) -> Int?? {
        guard let value else { return .some(nil) }
        guard let number = value.double, number == number.rounded(), number > 0, number <= max else { return nil }
        return .some(Int(number))
    }

    static func invalid(_ message: String, bytes: Int) -> DeepSeekSettingsError {
        DeepSeekSettingsError(bytes > maxBodyBytes ? 413 : 400, "invalid-request", message)
    }

    static func bounded(_ body: JSONObject, _ message: String, allowed: Set<String>) throws -> (JSONObject, Int) {
        let bytes = JSON.object(body).serialized().utf8.count
        guard bytes <= maxBodyBytes, body.keys.allSatisfy(allowed.contains) else { throw invalid(message, bytes: bytes) }
        return (body, bytes)
    }

    public struct ConnectionPatch {
        public var baseUrl: String?
        public var transport: String?
        /// .some(nil) clears the preset
        public var agentPreset: String??
    }

    public static func parseConnectionPatch(_ body: JSONObject) throws -> ConnectionPatch {
        let message = "invalid DeepSeek Harness connection settings"
        let (object, bytes) = try bounded(body, message, allowed: ["baseUrl", "transport", "agentPreset"])
        guard !object.isEmpty else { throw invalid(message, bytes: bytes) }
        var patch = ConnectionPatch()
        if let raw = object["baseUrl"] {
            guard let text = raw.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 2_048 else {
                throw invalid(message, bytes: bytes)
            }
            guard let origin = DeepSeekHarnessConfig.origin(text) else {
                throw DeepSeekSettingsError(400, "invalid-base-url", "DeepSeek Harness base URL must be an absolute HTTP or HTTPS origin")
            }
            patch.baseUrl = origin
        }
        if let raw = object["transport"] {
            guard raw.string == "direct" || raw.string == "paired" else { throw invalid(message, bytes: bytes) }
            patch.transport = raw.string
        }
        if let raw = object["agentPreset"] {
            if raw.isNull { patch.agentPreset = .some(nil) } else {
                guard let preset = safeString(raw, max: 512) else { throw invalid(message, bytes: bytes) }
                patch.agentPreset = .some(preset)
            }
        }
        return patch
    }

    public static func parsePairingLink(_ value: String) throws -> (baseUrl: String, token: String) {
        let failure = DeepSeekSettingsError(400, "invalid-pairing-link", "DeepSeek Harness pairing link is invalid")
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_096, let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else { throw failure }
        guard scheme == "http" || scheme == "https", components.user == nil, components.password == nil, components.fragment == nil else {
            throw DeepSeekSettingsError(400, "invalid-pairing-link", "DeepSeek Harness pairing link must use HTTP or HTTPS without credentials or a fragment")
        }
        let tokens = (components.queryItems ?? []).filter { $0.name == "pair" }.map { $0.value ?? "" }
        guard tokens.count == 1, let token = safeString(.string(tokens[0]), max: 512), token == tokens[0] else {
            throw DeepSeekSettingsError(400, "invalid-pairing-link", "DeepSeek Harness pairing link must contain one bounded pair token")
        }
        var origin = "\(scheme)://\(host.lowercased())"
        if let port = components.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) { origin += ":\(port)" }
        return (origin, token)
    }

    public static func parsePairRequest(_ body: JSONObject) throws -> String {
        let message = "invalid DeepSeek Harness pairing request"
        let (object, bytes) = try bounded(body, message, allowed: ["pairingLink"])
        guard let link = object["pairingLink"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty, link.count <= 4_096 else {
            throw invalid(message, bytes: bytes)
        }
        _ = try parsePairingLink(link)
        return link
    }

    public static func parseDiscoverRequest(_ body: JSONObject) throws -> String {
        let message = "invalid DeepSeek Harness model discovery request"
        let (object, bytes) = try bounded(body, message, allowed: ["provider"])
        guard let provider = safeString(object["provider"], max: 160) else { throw invalid(message, bytes: bytes) }
        return provider
    }

    public struct ModelProfile {
        public var id: String
        public var name: String?
        public var contextWindow: Int?
        public var maxTokens: Int?
        public var reasoningEfforts: [String]?

        var json: JSON {
            var o: JSONObject = ["id": .string(id)]
            if let name { o["name"] = .string(name) }
            if let contextWindow { o["contextWindow"] = .number(Double(contextWindow)) }
            if let maxTokens { o["maxTokens"] = .number(Double(maxTokens)) }
            if let reasoningEfforts { o["reasoningEfforts"] = .strings(reasoningEfforts) }
            return .object(o)
        }
    }

    public static func parseUpsertRequest(_ body: JSONObject) throws -> (provider: String, model: ModelProfile) {
        let message = "invalid DeepSeek Harness model update request"
        let (object, bytes) = try bounded(body, message, allowed: ["provider", "model"])
        guard let provider = safeString(object["provider"], max: 160), let model = object["model"]?.object,
              model.keys.allSatisfy(["id", "name", "contextWindow", "maxTokens", "reasoningEfforts"].contains),
              let id = safeString(model["id"], max: 160) else { throw invalid(message, bytes: bytes) }
        var profile = ModelProfile(id: id)
        if let raw = model["name"] {
            guard let name = safeString(raw, max: 240) else { throw invalid(message, bytes: bytes) }
            profile.name = name
        }
        guard let window = positiveInt(model["contextWindow"], max: maxTokenLimit), let tokens = positiveInt(model["maxTokens"], max: maxTokenLimit) else {
            throw invalid(message, bytes: bytes)
        }
        profile.contextWindow = window
        profile.maxTokens = tokens
        if let raw = model["reasoningEfforts"] {
            guard let efforts = raw.array?.compactMap(\.string), efforts.count == raw.array?.count, !efforts.isEmpty,
                  efforts.allSatisfy(reasoningEfforts.contains),
                  zip(efforts, efforts.dropFirst()).allSatisfy({ reasoningEfforts.firstIndex(of: $0)! < reasoningEfforts.firstIndex(of: $1)! }) else {
                throw invalid(message, bytes: bytes)
            }
            profile.reasoningEfforts = efforts
        }
        return (provider, profile)
    }

    // MARK: Pairing

    /// One HttpOnly `name=value` from Set-Cookie, or a refusal.
    static func extractDeviceCookie(_ lines: [String]) throws -> String {
        let cookies = lines.compactMap { line -> String? in
            guard line.range(of: #"(?i)(?:^|;)\s*HttpOnly(?:;|$)"#, options: .regularExpression) != nil else { return nil }
            let pair = String(line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
            guard pair.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+=[\x21-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]+$"#, options: .regularExpression) != nil else { return nil }
            return pair
        }
        guard cookies.count == 1, cookies[0].count <= 4_096 else {
            throw DeepSeekSettingsError(502, "invalid-device-cookie", "DeepSeek Harness pairing did not return one valid device cookie")
        }
        return cookies[0]
    }

    static func splitSetCookie(_ value: String) -> [String] {
        guard !value.isEmpty else { return [] }
        var parts: [String] = []
        var current = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == ",", let rest = Optional(String(characters[(index + 1)...])),
               rest.range(of: #"^\s*[!#$%&'*+.^_`|~0-9A-Za-z-]+="#, options: .regularExpression) != nil {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        parts.append(current)
        return parts
    }

    static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    public static func acceptPairing(_ link: String, timeout: TimeInterval = 8) async throws -> (baseUrl: String, deviceCookie: String) {
        let (baseUrl, token) = try parsePairingLink(link)
        var request = URLRequest(url: URL(string: "\(baseUrl)/api/pair/accept")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = JSON.object(["token": .string(token)]).data
        let urlSession = session(timeout: timeout)
        defer { urlSession.finishTasksAndInvalidate() }
        let response: HTTPURLResponse
        do {
            guard let http = try await urlSession.data(for: request).1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            response = http
        } catch {
            throw DeepSeekSettingsError(502, "pairing-unavailable", "DeepSeek Harness pairing could not reach the configured host")
        }
        if (300..<400).contains(response.statusCode) {
            throw DeepSeekSettingsError(502, "pairing-redirect-refused", "DeepSeek Harness pairing refused an unexpected redirect")
        }
        guard (200...299).contains(response.statusCode) else {
            throw DeepSeekSettingsError(400, "pairing-rejected", "DeepSeek Harness rejected the one-time pairing link")
        }
        let raw = response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        return (baseUrl, try extractDeviceCookie(splitSetCookie(raw)))
    }

    static func unavailableManagement(_ error: DeepSeekSettingsError) -> JSON {
        if error.code == "paired-device-unauthorized" {
            return ["available": false, "supported": true, "providers": [], "reasonCode": "paired-device-unauthorized",
                    "reason": "Pair this DeepSeek Harness again to restore model management."]
        }
        return ["available": false, "supported": true, "providers": [], "reasonCode": "host-unavailable",
                "reason": "DeepSeek Harness model management could not reach the configured host."]
    }

    /// `publicCatalog`: the Host catalog with failures reduced to a fixed sentence.
    static func publicCatalog(_ value: JSON?) throws -> JSON {
        let bad = DeepSeekSettingsError(502, "invalid-dsh-response", "DeepSeek Harness returned an invalid model catalog")
        guard let groups = value?["groups"]?.array, let failures = value?["failures"]?.array, groups.count <= 128, failures.count <= 128 else { throw bad }
        let publicGroups: [JSON] = try groups.map { group in
            guard let id = safeString(group["id"], max: 160), let name = safeString(group["name"], max: 240), let models = group["models"]?.array,
                  models.count <= 2_000 else { throw bad }
            let rows: [JSON] = try models.map { model in
                guard let modelId = safeString(model["id"], max: 160), let modelName = safeString(model["name"], max: 240) else { throw bad }
                var row: JSONObject = ["id": .string(modelId), "name": .string(modelName)]
                if let description = model["description"] {
                    guard let text = description.string, text.count <= 2_000 else { throw bad }
                    row["description"] = .string(text)
                }
                if let reasoning = model["reasoning"] {
                    guard let efforts = reasoning["efforts"]?.array, efforts.count <= reasoningEfforts.count else { throw bad }
                    let cleanEfforts: [JSON] = try efforts.map { effort in
                        guard let effortId = safeString(effort["id"], max: 160), let effortName = safeString(effort["name"], max: 240) else { throw bad }
                        var out: JSONObject = ["id": .string(effortId), "name": .string(effortName)]
                        if let description = effort["description"] {
                            guard let text = description.string, text.count <= 2_000 else { throw bad }
                            out["description"] = .string(text)
                        }
                        return .object(out)
                    }
                    var out: JSONObject = ["efforts": .array(cleanEfforts)]
                    if let raw = reasoning["defaultEffort"] {
                        guard let defaultEffort = safeString(raw, max: 160) else { throw bad }
                        out["defaultEffort"] = .string(defaultEffort)
                    }
                    row["reasoning"] = .object(out)
                }
                return .object(row)
            }
            return ["id": .string(id), "name": .string(name), "models": .array(rows)]
        }
        let publicFailures: [JSON] = try failures.map { failure in
            guard let id = safeString(failure["id"], max: 160), let name = safeString(failure["name"], max: 240), failure["message"]?.string != nil else { throw bad }
            return ["id": .string(id), "name": .string(name), "message": .string("model catalog unavailable for provider \(id)")]
        }
        return ["groups": .array(publicGroups), "failures": .array(publicFailures)]
    }

    static func modelFields(_ model: ModelProfile, includeId: Bool) -> JSONObject {
        var fields = JSONObject()
        if includeId { fields["id"] = .string(model.id) }
        if let name = model.name { fields["name"] = .string(name) }
        if let window = model.contextWindow { fields["contextWindow"] = .number(Double(window)) }
        if let tokens = model.maxTokens { fields["maxTokens"] = .number(Double(tokens)) }
        if let efforts = model.reasoningEfforts {
            var map = JSONObject()
            for effort in efforts { map[effort] = effort == "off" ? .null : .string(effort) }
            fields["reasoningEfforts"] = .object(map)
        }
        return fields
    }

    /// `{...a, ...b}` on ordered objects: a's keys keep their place.
    static func spread(_ base: JSONObject, _ patch: JSONObject) -> JSONObject {
        var out = base
        for (key, value) in patch { out[key] = value }
        return out
    }

    static func upsertModel(_ existing: [JSON], _ model: ModelProfile) -> [JSON] {
        var next = existing
        let patch = modelFields(model, includeId: true)
        if let index = next.firstIndex(where: { $0.object?["id"]?.string == model.id }) {
            next[index] = .object(spread(next[index].object ?? JSONObject(), patch))
        } else {
            next.append(.object(patch))
        }
        return next
    }

    /// `modelMutationPlan`: the settings ops that add or update one model
    /// without disturbing how the provider profile already lists its models.
    static func mutationPlan(profile: JSONObject, provider: String, model: ModelProfile, catalog: JSON) throws -> [JSON] {
        let invalidModels = DeepSeekSettingsError(502, "invalid-configured-models", "DeepSeek Harness returned an invalid configured model list")
        var configured: [JSONObject]?
        if let raw = profile["models"] {
            guard let list = raw.array, list.count <= 2_000 else { throw invalidModels }
            if !list.isEmpty {
                configured = try list.map { entry in
                    guard let object = entry.object, let id = object["id"]?.string, safeString(.string(id), max: 160) == id else { throw invalidModels }
                    return object
                }
            }
        }
        var overridesPresent = false
        var overrides: [(String, JSONObject)] = []
        if let raw = profile["modelOverrides"] {
            overridesPresent = true
            let invalid = DeepSeekSettingsError(502, "invalid-model-overrides", "DeepSeek Harness returned invalid model overrides")
            guard let object = raw.object else { throw invalid }
            for (id, value) in object {
                guard safeString(.string(id), max: 160) == id, let override = value.object else { throw invalid }
                overrides.append((id, override))
            }
        }
        let modelsPath: JSON = ["providers", .string(provider), "models"]
        let overridesPath: JSON = ["providers", .string(provider), "modelOverrides"]
        if let configured {
            if !overrides.isEmpty {
                throw DeepSeekSettingsError(502, "conflicting-model-configuration", "DeepSeek Harness returned conflicting models and model overrides")
            }
            var ops: [JSON] = [["op": "set", "path": modelsPath, "value": .array(upsertModel(configured.map(JSON.object), model))]]
            if overridesPresent { ops.append(["op": "unset", "path": overridesPath]) }
            return ops
        }
        guard let group = catalog["groups"]?.array?.first(where: { $0["id"]?.string == provider }),
              !(catalog["failures"]?.array ?? []).contains(where: { $0["id"]?.string == provider }) else {
            throw DeepSeekSettingsError(502, "catalog-unavailable", "DeepSeek Harness model catalog is unavailable for provider \(provider)")
        }
        let installed = (group["models"]?.array ?? []).compactMap { $0["id"]?.string }
        if installed.contains(model.id) {
            let existing = overrides.first { $0.0 == model.id }?.1 ?? JSONObject()
            return [["op": "set", "path": .array(overridesPath.array! + [.string(model.id)]),
                     "value": .object(spread(existing, modelFields(model, includeId: false)))]]
        }
        var materialized: [JSON] = []
        for id in installed {
            materialized.append(.object(spread(overrides.first { $0.0 == id }?.1 ?? JSONObject(), ["id": .string(id)])))
        }
        for (id, override) in overrides where !installed.contains(id) {
            materialized.append(.object(spread(override, ["id": .string(id)])))
        }
        var ops: [JSON] = [["op": "set", "path": modelsPath, "value": .array(upsertModel(materialized, model))]]
        if overridesPresent { ops.append(["op": "unset", "path": overridesPath]) }
        return ops
    }
}

// MARK: - Management client

@MainActor
final class DeepSeekManagement {
    let config: DeepSeekHarnessConfig
    private let direct: DSHClient?
    private let timeout: TimeInterval = 8

    struct Eligible {
        var provider: String
        var displayName: String
        var profile: JSONObject
        var revision: Double
    }

    init(_ config: DeepSeekHarnessConfig) throws {
        guard let baseUrl = DeepSeekHarnessConfig.origin(config.baseUrl) else {
            throw DeepSeekSettingsError(400, "invalid-base-url", "DeepSeek Harness base URL must be an absolute HTTP or HTTPS origin")
        }
        if config.transport == "paired", !DeepSeekSettings.validCookie(config.deviceCookie) {
            throw DeepSeekSettingsError(400, "pairing-required", "DeepSeek Harness paired transport requires a paired device")
        }
        var normalized = config
        normalized.baseUrl = baseUrl
        self.config = normalized
        direct = config.transport == "direct" ? try? DSHClient(baseUrl: baseUrl, transport: "direct", deviceCookie: nil, timeout: 8) : nil
    }

    func close() { direct?.close() }

    static func settingsError(_ error: Error, _ message: String) -> DeepSeekSettingsError {
        if let error = error as? DeepSeekSettingsError { return error }
        if let rpc = error as? DSHRpcError {
            if rpc.code == "settings-conflict" { return DeepSeekSettingsError(409, "model-update-conflict", "DeepSeek Harness model update conflicted with another settings change") }
            if rpc.code == "settings-rejected" { return DeepSeekSettingsError(422, "model-update-rejected", "DeepSeek Harness rejected the model update") }
        }
        return DeepSeekSettingsError(502, "dsh-management-failed", message)
    }

    func describe() async throws -> JSON {
        if config.transport == "paired" { return try await describePaired() }
        do {
            _ = try await direct!.unary("host.describe", [:])
            let eligible = try await directProviders()
            return ["available": true, "supported": true,
                    "providers": .array(eligible.map { ["provider": .string($0.provider), "displayName": .string($0.displayName)] })]
        } catch {
            throw Self.settingsError(error, "DeepSeek Harness model management is unavailable")
        }
    }

    func discover(_ provider: String) async throws -> JSON {
        if config.transport == "paired" {
            let response = try await pairedRequest("/api/pair/model-catalog/discover", method: "POST", body: ["provider": .string(provider)])
            if response.status == 403 || response.status == 404 { try await pairedProviderUnavailable(provider) }
            try requirePairedSuccess(response.status, "DeepSeek Harness paired model discovery failed")
            return try candidates(response.body)
        }
        do {
            _ = try await directProvider(provider)
            let value = try await direct!.unary("llm.discoverModels", ["settingsNs": "llm-pi-ai", "provider": .string(provider)])
            return try candidates(value)
        } catch {
            throw Self.settingsError(error, "DeepSeek Harness model discovery failed for provider \(provider)")
        }
    }

    func upsert(_ provider: String, _ model: DeepSeekSettings.ModelProfile) async throws -> JSON {
        if config.transport == "paired" {
            let response = try await pairedRequest("/api/pair/model-catalog/upsert", method: "POST",
                                                   body: ["provider": .string(provider), "model": model.json])
            if response.status == 403 || response.status == 404 { try await pairedProviderUnavailable(provider) }
            try requirePairedSuccess(response.status, "DeepSeek Harness paired model update failed")
            return ["updated": true, "catalog": try DeepSeekSettings.publicCatalog(response.body)]
        }
        do {
            let eligible = try await directProvider(provider)
            let before = try DeepSeekSettings.publicCatalog(try await direct!.unary("llm.models", [:]))
            let ops = try DeepSeekSettings.mutationPlan(profile: eligible.profile, provider: provider, model: model, catalog: before)
            _ = try await direct!.unary("settings.mutate", ["ns": "llm-pi-ai", "expectedRevision": .number(eligible.revision), "ops": .array(ops)])
            let after = try DeepSeekSettings.publicCatalog(try await direct!.unary("llm.models", [:]))
            return ["updated": true, "catalog": after]
        } catch {
            throw Self.settingsError(error, "DeepSeek Harness model update failed for provider \(provider)")
        }
    }

    private func candidates(_ value: JSON?) throws -> JSON {
        let bad = DeepSeekSettingsError(502, "invalid-dsh-response", "DeepSeek Harness returned an invalid model discovery response")
        guard let models = value?["models"]?.array, models.count <= 2_000 else { throw bad }
        let rows: [JSON] = try models.map { model in
            guard let id = DeepSeekSettings.safeString(model["id"], max: 160) else { throw bad }
            var row: JSONObject = ["id": .string(id)]
            if let raw = model["name"] {
                guard let name = DeepSeekSettings.safeString(raw, max: 240) else { throw bad }
                row["name"] = .string(name)
            }
            for key in ["contextWindow", "maxTokens"] {
                guard let value = DeepSeekSettings.positiveInt(model[key], max: DeepSeekSettings.maxTokenLimit) else { throw bad }
                if let value { row[key] = .number(Double(value)) }
            }
            return .object(row)
        }
        return ["models": .array(rows)]
    }

    private func directProviders() async throws -> [Eligible] {
        async let providerValue = direct!.unary("llm.providers", [:])
        async let settingsValue = direct!.unary("settings.describe", [:])
        let (providers, settings) = try await (providerValue, settingsValue)
        guard let rows = providers["providers"]?.array, rows.count <= 128 else {
            throw DeepSeekSettingsError(502, "invalid-dsh-response", "DeepSeek Harness returned an invalid provider directory")
        }
        guard let writable = settings["writable"]?.bool, let namespaces = settings["namespaces"]?.array else {
            throw DeepSeekSettingsError(502, "invalid-dsh-response", "DeepSeek Harness returned an invalid settings descriptor")
        }
        if !writable { return [] }
        guard let namespace = namespaces.first(where: { $0["ns"]?.string == "llm-pi-ai" }),
              let providerMap = namespace["value"]?["providers"]?.object, let revision = namespace["revision"]?.double else { return [] }
        return rows.compactMap { candidate in
            guard let provider = candidate["provider"]?.string, let displayName = candidate["displayName"]?.string,
                  candidate["active"]?.bool == true, candidate["settingsNs"]?.string == "llm-pi-ai",
                  let path = candidate["settingsPath"]?.array?.compactMap(\.string), path == ["providers", provider],
                  let profile = providerMap[provider]?.object else { return nil }
            return Eligible(provider: provider, displayName: displayName, profile: profile, revision: revision)
        }
    }

    private func directProvider(_ provider: String) async throws -> Eligible {
        guard let eligible = try await directProviders().first(where: { $0.provider == provider }) else {
            throw DeepSeekSettingsError(404, "provider-not-eligible", "DeepSeek Harness provider \(provider) is not an active configurable pi-ai provider")
        }
        return eligible
    }

    private func describePaired() async throws -> JSON {
        let response = try await pairedRequest("/api/pair/model-catalog", method: "GET", body: nil)
        if response.status == 404 {
            return ["available": false, "supported": false, "providers": [], "reasonCode": "paired-plugin-update-required",
                    "reason": .string(DeepSeekSettings.pairedCatalogReason)]
        }
        try requirePairedSuccess(response.status, "DeepSeek Harness paired model management is unavailable")
        guard response.body["capability"]?.string == "paired-model-catalog", let providers = response.body["providers"]?.array, providers.count <= 128 else {
            throw DeepSeekSettingsError(502, "invalid-dsh-response", "DeepSeek Harness returned an invalid paired model catalog response")
        }
        let rows: [JSON] = try providers.map { row in
            guard let provider = DeepSeekSettings.safeString(row["provider"], max: 160),
                  let displayName = DeepSeekSettings.safeString(row["displayName"], max: 240) else {
                throw DeepSeekSettingsError(502, "invalid-dsh-response", "DeepSeek Harness returned an invalid paired model catalog response")
            }
            return ["provider": .string(provider), "displayName": .string(displayName)]
        }
        return ["available": true, "supported": true, "providers": .array(rows)]
    }

    private func pairedProviderUnavailable(_ provider: String) async throws {
        let capability = try await describePaired()
        if capability["available"]?.bool != true {
            throw DeepSeekSettingsError(409, "paired-model-catalog-unavailable", DeepSeekSettings.pairedCatalogReason)
        }
        throw DeepSeekSettingsError(404, "provider-not-eligible", "DeepSeek Harness provider \(provider) is not available for paired model management")
    }

    private func requirePairedSuccess(_ status: Int, _ message: String) throws {
        if (200...299).contains(status) { return }
        if status == 401 || status == 403 { throw DeepSeekSettingsError(403, "paired-device-unauthorized", "DeepSeek Harness paired device is no longer authorized") }
        if status == 409 { throw DeepSeekSettingsError(409, "model-update-conflict", "DeepSeek Harness model update conflicted with another settings change") }
        if status == 422 { throw DeepSeekSettingsError(422, "model-update-rejected", "DeepSeek Harness rejected the model update") }
        throw DeepSeekSettingsError(502, "paired-model-management-failed", message)
    }

    private func pairedRequest(_ path: String, method: String, body: JSON?) async throws -> (status: Int, body: JSON) {
        var request = URLRequest(url: URL(string: config.baseUrl + path)!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(config.deviceCookie, forHTTPHeaderField: "Cookie")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = body.data
        }
        let urlSession = DeepSeekSettings.session(timeout: timeout)
        defer { urlSession.finishTasksAndInvalidate() }
        let data: Data
        let status: Int
        do {
            let result = try await urlSession.data(for: request)
            data = result.0
            status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw DeepSeekSettingsError(502, "paired-host-unavailable", "DeepSeek Harness paired model management could not reach the configured host")
        }
        if (300..<400).contains(status) {
            throw DeepSeekSettingsError(502, "paired-redirect-refused", "DeepSeek Harness paired model management refused an unexpected redirect")
        }
        guard (200...299).contains(status) else { return (status, .null) }
        guard data.count <= DeepSeekSettings.maxResponseBytes, let value = data.isEmpty ? JSON.null : try? JSON.parse(data) else {
            throw DeepSeekSettingsError(502, "invalid-paired-response", "DeepSeek Harness returned an invalid paired model management response")
        }
        return (status, value)
    }
}

// MARK: - Routes

@MainActor
public enum DeepSeekSettingsRoutes {
    /// providerConfigBusy: one settings write at a time.
    static var busy = false

    static func respond(_ status: Int, _ value: JSON) -> RouteResult { .response(.json(status, value)) }

    /// Nil when the path is not a DeepSeek settings route.
    public static func handle(_ r: HTTPRequest, harness: Harness) async -> RouteResult? {
        guard let match = r.path.range(of: #"^/api/instances/[\w.-]+/deepseek-harness(?:/(pair|discover|upsert))?$"#, options: .regularExpression) else {
            return nil
        }
        _ = match
        let tail = r.path.dropFirst("/api/instances/".count)
        let instanceId = String(tail.prefix { $0 != "/" })
        let rest = tail.dropFirst(instanceId.count + "/deepseek-harness".count)
        let action = rest.isEmpty ? nil : String(rest.dropFirst())
        do {
            if r.method == "GET", action == nil {
                let config = try instanceConfig(harness, instanceId)
                let management = try DeepSeekManagement(config)
                defer { management.close() }
                let description: JSON
                do {
                    description = try await management.describe()
                } catch let error as DeepSeekSettingsError {
                    description = DeepSeekSettings.unavailableManagement(error)
                }
                return respond(200, ["connection": config.publicConnection(instanceId), "modelManagement": description])
            }
            let writes = r.method == "PATCH" && action == nil
            let runs = r.method == "POST" && action != nil
            guard writes || runs else { return nil }
            guard r.contentType.hasPrefix("application/json") else {
                return respond(415, ["code": "invalid-request", "error": "content-type must be application/json"])
            }
            let body = try r.json()
            if busy {
                return respond(409, ["code": "settings-busy", "error": "Another provider update is still finishing. Wait a moment and try again."])
            }
            busy = true
            defer { busy = false }
            let current = try instanceConfig(harness, instanceId)
            if writes {
                let patch = try DeepSeekSettings.parseConnectionPatch(body)
                var next = current
                let changingOrigin = patch.baseUrl != nil && patch.baseUrl != current.baseUrl
                let transport = patch.transport ?? current.transport
                let pairingRequired = DeepSeekSettingsError(409, "pairing-required", "Pair this DeepSeek Harness origin before using paired transport")
                if changingOrigin, transport == "paired" { throw pairingRequired }
                if let baseUrl = patch.baseUrl { next.baseUrl = baseUrl }
                if let transport = patch.transport { next.transport = transport }
                if changingOrigin { next.deviceCookie = nil }
                if let preset = patch.agentPreset { next.agentPreset = preset }
                if next.transport == "paired", next.deviceCookie == nil { throw pairingRequired }
                let saved = try await persist(harness, instanceId, next, forceReload: false)
                return respond(200, ["saved": .bool(saved), "connection": next.publicConnection(instanceId)])
            }
            if action == "pair" {
                let link = try DeepSeekSettings.parsePairRequest(body)
                let accepted = try await DeepSeekSettings.acceptPairing(link)
                var next = current
                next.baseUrl = accepted.baseUrl
                next.transport = "paired"
                next.deviceCookie = accepted.deviceCookie
                _ = try await persist(harness, instanceId, next, forceReload: true)
                return respond(200, ["paired": true])
            }
            let management = try DeepSeekManagement(current)
            defer { management.close() }
            if action == "discover" {
                return respond(200, try await management.discover(try DeepSeekSettings.parseDiscoverRequest(body)))
            }
            if action == "upsert" {
                let request = try DeepSeekSettings.parseUpsertRequest(body)
                let result = try await management.upsert(request.provider, request.model)
                await harness.fleet.get(instanceId)?.refreshModels()
                return respond(200, result)
            }
            return nil
        } catch let error as DeepSeekSettingsError {
            return respond(error.status, error.publicBody)
        } catch let error as JSONParseError {
            return .response(.error(400, "invalid JSON: \(error.description)"))
        } catch let error as HTTPError {
            return .response(.error(error.status, error.message))
        } catch {
            return .response(.error(500, error.localizedDescription))
        }
    }

    static func instanceConfig(_ harness: Harness, _ instanceId: String) throws -> DeepSeekHarnessConfig {
        guard let entry = harness.config.instanceConfigs().first(where: { $0.0 == instanceId }), entry.1.driver == "deepseekHarness" else {
            throw DeepSeekSettingsError(404, "deepseek-instance-not-found", "unknown DeepSeek Harness instance \"\(instanceId)\"")
        }
        do {
            return try DeepSeekHarnessConfig(entry.1.config)
        } catch {
            throw DeepSeekSettingsError(400, "invalid-deepseek-config", "DeepSeek Harness instance configuration is invalid")
        }
    }

    /// `persistDeepSeekHarnessConfig`: write, rebuild the fleet, and leave the
    /// instance's catalog ready for an immediate request.
    static func persist(_ harness: Harness, _ instanceId: String, _ config: DeepSeekHarnessConfig, forceReload: Bool) async throws -> Bool {
        guard let changed = try harness.config.setInstanceDriverConfig(instanceId, driver: "deepseekHarness", config: config.json) else {
            throw DeepSeekSettingsError(404, "deepseek-instance-not-found", "unknown DeepSeek Harness instance \"\(instanceId)\"")
        }
        // a re-pair can renew the same cookie: the old client may have latched it as revoked
        if changed || forceReload {
            await harness.reloadProviders(announce: false)
            await harness.fleet.get(instanceId)?.refreshModels()
        }
        return changed
    }
}
