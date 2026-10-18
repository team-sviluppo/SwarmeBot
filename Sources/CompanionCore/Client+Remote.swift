// A remote engine's device routes — docs/plans/2026-10-16-bot-remoto.md §4.
import Foundation

public struct RemoteDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var createdAt: Double?
    public var lastSeenAt: Double?
    public var revokedAt: Double?
}

public struct RemoteDeviceList: Codable, Sendable {
    public var devices: [RemoteDevice]
    public var current: String?
}

public struct RemotePairingCode: Codable, Sendable {
    public var code: String
    public var expiresAt: Double
    public var chatUrl: String?
}

public struct RemoteHealth: Codable, Sendable {
    public var app: String
    public var remote: Bool?
    public var contract: Int?

    /// The remote contract this client speaks (HarnessCore's RemoteContract.version).
    public static let supportedContract = 1

    public var isCompatible: Bool { remote == true && contract == Self.supportedContract }
}

public enum RemoteDevices {
    public struct Claimed: Sendable {
        public var token: String
        public var deviceId: String
    }

    private struct ClaimResponse: Codable {
        var token: String
        var device: RemoteDevice
    }

    /// Trade a one-time pairing code for this device's token (no token needed).
    public static func claim(connection: Connection, code: String, deviceName: String, kind: String = "mac",
                             session: URLSession = .shared) async throws -> Claimed {
        let client = CompanionClient(connection: connection, token: nil, session: session)
        let request = try client.makeRequest("POST", "/api/devices/claim", body: ["code": code, "name": deviceName, "kind": kind])
        let response = try await client.send(request, as: ClaimResponse.self)
        return Claimed(token: response.token, deviceId: response.device.id)
    }
}

extension CompanionClient {
    public func remoteHealth() async throws -> RemoteHealth {
        try await send(try makeRequest("GET", "/api/health"), as: RemoteHealth.self)
    }

    public func devices() async throws -> RemoteDeviceList {
        try await send(try makeRequest("GET", "/api/devices"), as: RemoteDeviceList.self)
    }

    public func pairingCode() async throws -> RemotePairingCode {
        try await send(try makeRequest("POST", "/api/devices/pairing"), as: RemotePairingCode.self)
    }

    public func revokeDevice(_ id: String) async throws {
        try await send(try makeRequest("DELETE", "/api/devices/\(id)"))
    }
}

/// What the pairing QR carries (§4.3): where the engine is and a one-time
/// code — never a token. `swarmebot://pair?url=…&code=…&name=…`
public struct RemotePairingLink: Equatable, Sendable {
    public var chatURL: String
    public var code: String
    public var name: String?

    public init(chatURL: String, code: String, name: String? = nil) {
        self.chatURL = chatURL
        self.code = code
        self.name = name
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "swarmebot"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "url", value: chatURL), URLQueryItem(name: "code", value: code)]
            + (name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme == "swarmebot", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let chatURL = items.first(where: { $0.name == "url" })?.value, Connection.remote(chatURL: chatURL) != nil,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { return nil }
        self.init(chatURL: chatURL, code: code, name: items.first(where: { $0.name == "name" })?.value)
    }
}
