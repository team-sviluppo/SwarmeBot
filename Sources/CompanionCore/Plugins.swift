import Foundation

/// A plugin the engine says it carries (`GET /api/plugins`). An app shows a
/// plugin's interface only for a plugin the engine has and has switched on;
/// an engine without the route (an older one) carries none.
public struct EnginePluginInfo: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    /// False when the user switched it off, or a plugin it needs is off.
    public var enabled: Bool
    public var requires: [String]

    public init(id: String, name: String, version: String, enabled: Bool, requires: [String] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.requires = requires
    }

    private enum CodingKeys: String, CodingKey { case id, name, version, enabled, requires }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        requires = try container.decodeIfPresent([String].self, forKey: .requires) ?? []
    }
}

extension CompanionClient {
    private struct PluginList: Decodable { var plugins: [EnginePluginInfo] }

    public func plugins() async throws -> [EnginePluginInfo] {
        try await send(try makeRequest("GET", "/api/plugins"), as: PluginList.self).plugins
    }

    public func setPlugin(id: String, enabled: Bool) async throws -> [EnginePluginInfo] {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await send(try makeRequest("PUT", "/api/plugins/\(encoded)", body: ["enabled": enabled]), as: PluginList.self).plugins
    }

    /// A call to a route a plugin adds to the engine, which the core's client
    /// knows nothing about. The plugin owns the path and the shape of the answer.
    /// `timeout` is for a route that waits on something slow (a push, a pull); the usual twenty seconds are for the rest.
    public func pluginRequest<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                            body: [String: Any]? = nil, timeout: TimeInterval? = nil, as type: T.Type) async throws -> T {
        var request = try makeRequest(method, path, query: query, body: body)
        if let timeout { request.timeoutInterval = timeout }
        return try await send(request, as: type)
    }

    public func pluginRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                              timeout: TimeInterval? = nil) async throws {
        var request = try makeRequest(method, path, query: query, body: body)
        if let timeout { request.timeoutInterval = timeout }
        try await send(request)
    }
}
