// Settings the Mac hands to the phone (docs/plans/2026-10-22-app-ios.md §7,
// D11): an OpenAI-compatible endpoint and MCP connectors over HTTP, with their
// secrets. Never chats. Two ways across, both encrypted with AES-GCM:
//
// - a QR on the Mac: `swarmebot://import?host=…&port=…&code=…&key=…`; the
//   phone fetches `http://host:port/<code>` once, on the local network, and
//   the key in the QR opens it (the Mac serves it for two minutes, once);
// - a `.swarmeconfig` file (AirDrop, Files, mail) sealed with a passphrase
//   the user types on both sides (PBKDF2-SHA256).
//
// OAuth connectors travel without tokens: the phone signs in on its own.
import CommonCrypto
import CryptoKit
import Foundation

public struct PhoneConfig: Codable, Equatable, Sendable {
    public struct Endpoint: Codable, Equatable, Sendable {
        public var name: String
        public var baseUrl: String
        public var model: String?
        public var apiKey: String?
        public var headers: [String: String]?

        public init(name: String, baseUrl: String, model: String? = nil, apiKey: String? = nil, headers: [String: String]? = nil) {
            self.name = name
            self.baseUrl = baseUrl
            self.model = model
            self.apiKey = apiKey
            self.headers = headers
        }
    }

    public struct Connector: Codable, Equatable, Sendable {
        /// none · headers · oauth
        public var auth: String
        public var name: String
        public var url: String
        public var headers: [String: String]?
        public var oauthClientId: String?

        public init(name: String, url: String, auth: String, headers: [String: String]? = nil, oauthClientId: String? = nil) {
            self.name = name
            self.url = url
            self.auth = auth
            self.headers = headers
            self.oauthClientId = oauthClientId
        }
    }

    public static let format = "swarmebot.phone-config"
    public var format = PhoneConfig.format
    public var version = 1
    public var endpoints: [Endpoint]
    public var connectors: [Connector]

    public init(endpoints: [Endpoint] = [], connectors: [Connector] = []) {
        self.endpoints = endpoints
        self.connectors = connectors
    }

    public var isEmpty: Bool { endpoints.isEmpty && connectors.isEmpty }

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    // MARK: Sealing

    /// AES-GCM with a 256-bit key: nonce, ciphertext and tag in one blob.
    public func sealed(with key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(try JSONEncoder().encode(self), using: key).combined else {
            throw Failure(message: "seal failed")
        }
        return combined
    }

    public static func open(_ blob: Data, with key: SymmetricKey) throws -> PhoneConfig {
        let plain: Data
        do { plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: key) } catch {
            throw Failure(message: "wrong key or damaged data")
        }
        let config = try JSONDecoder().decode(PhoneConfig.self, from: plain)
        guard config.format == format, config.version == 1 else { throw Failure(message: "not a SwarmeBot phone configuration") }
        return config
    }

    // MARK: File with a passphrase

    static let iterations: UInt32 = 310_000

    static func key(passphrase: String, salt: Data) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let password = Array(passphrase.utf8)
        _ = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, password.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count)
            }
        }
        return SymmetricKey(data: derived)
    }

    /// `{"format":"swarmebot.phone-config.sealed","salt":…,"data":…}`
    public func file(passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let blob = try sealed(with: Self.key(passphrase: passphrase, salt: salt))
        let wrapper = ["format": Self.format + ".sealed", "salt": salt.base64EncodedString(), "data": blob.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys])
    }

    public static func open(file: Data, passphrase: String) throws -> PhoneConfig {
        guard let wrapper = try? JSONSerialization.jsonObject(with: file) as? [String: String], wrapper["format"] == format + ".sealed",
              let salt = wrapper["salt"].flatMap({ Data(base64Encoded: $0) }), let blob = wrapper["data"].flatMap({ Data(base64Encoded: $0) }) else {
            throw Failure(message: "not a SwarmeBot phone configuration")
        }
        return try open(blob, with: key(passphrase: passphrase, salt: salt))
    }
}

/// What the Mac's QR carries: where to fetch the sealed configuration, once,
/// and the key that opens it.
public struct PhoneConfigLink: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var code: String
    public var key: Data

    public init(host: String, port: Int, code: String, key: Data) {
        self.host = host
        self.port = port
        self.code = code
        self.key = key
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "swarmebot"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                                 URLQueryItem(name: "code", value: code), URLQueryItem(name: "key", value: Self.base64url(key))]
        return components.url
    }

    public init?(url: URL) {
        guard url.scheme == "swarmebot", url.host == "import",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
              let port = items.first(where: { $0.name == "port" })?.value.flatMap(Int.init), (1...65535).contains(port),
              let code = items.first(where: { $0.name == "code" })?.value, code.count >= 16,
              let raw = items.first(where: { $0.name == "key" })?.value else { return nil }
        var base = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let key = Data(base64Encoded: base), key.count == 32 else { return nil }
        self.init(host: host, port: port, code: code, key: key)
    }

    /// The sealed configuration, fetched once from the Mac.
    public func fetch(session: URLSession = .shared) async throws -> PhoneConfig {
        guard let url = URL(string: "http://\(Connection.urlHost(host)):\(port)/\(code)") else { throw PhoneConfig.Failure(message: "bad address") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PhoneConfig.Failure(message: "the Mac is no longer offering this configuration")
        }
        return try PhoneConfig.open(data, with: SymmetricKey(data: key))
    }
}
