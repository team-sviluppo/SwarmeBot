// AWS Signature Version 4, just enough for the push relay's calls to Amazon
// SNS (PushRelay.swift): a signed POST of a form body. No AWS SDK: it would
// bring a large dependency tree to an engine that must also build on Linux.
//
// https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv4-create-signed-request.html
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct AWSCredentials: Sendable {
    public var accessKeyId: String
    public var secretAccessKey: String

    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }
}

public enum AWSSigV4 {
    /// `20150830T123600Z`.
    static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// RFC 3986 unreserved characters stay, everything else is %XX: what AWS
    /// expects in a form body and in a canonical query string.
    public static func percentEncode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// The `Authorization` header value. `headers` are exactly the ones that
    /// get signed (lowercase names; at least `host` and `x-amz-date`).
    static func authorization(method: String, path: String, query: String, headers: [(name: String, value: String)], body: Data,
                              credentials: AWSCredentials, region: String, service: String, date: Date) -> String {
        let stamp = amzDate(date)
        let day = String(stamp.prefix(8))
        let sorted = headers.map { ($0.name.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }.sorted { $0.0 < $1.0 }
        let canonicalHeaders = sorted.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = sorted.map(\.0).joined(separator: ";")
        let canonicalRequest = [method, path, query, canonicalHeaders, signedHeaders, sha256Hex(body)].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        var key = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), day)
        for part in [region, service, "aws4_request"] { key = hmac(key, part) }
        let signature = hex(hmac(key, toSign))
        return "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    /// A signed POST of `form` fields to `url` (the service's root path).
    static func signedFormRequest(url: URL, form: [(String, String)], credentials: AWSCredentials, region: String, service: String,
                                  date: Date = Date()) -> URLRequest {
        let body = Data(form.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&").utf8)
        let contentType = "application/x-www-form-urlencoded; charset=utf-8"
        let host = (url.host ?? "") + (url.port.map { ":\($0)" } ?? "")
        let stamp = amzDate(date)
        let authorization = authorization(method: "POST", path: url.path.isEmpty ? "/" : url.path, query: "",
                                          headers: [("content-type", contentType), ("host", host), ("x-amz-date", stamp)], body: body,
                                          credentials: credentials, region: region, service: service, date: date)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(stamp, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }
}
