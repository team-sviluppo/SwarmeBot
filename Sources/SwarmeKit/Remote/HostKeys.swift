// The server's host key, approved in SwarmeBot — bot-remoto §5.3 (R10).
//
// ssh-keyscan reads what the server offers; the person compares the SHA256
// fingerprint with the server's console and approves one key. Only approved
// keys reach SwarmeBot's known_hosts, and ssh runs with strict checking, so a
// key that changes later stops every call until it is approved again.
import CommonCrypto
import Foundation

public struct ScannedHostKey: Hashable, Sendable {
    public var type: String
    public var fingerprint: String
    /// `host type base64`, as known_hosts takes it (with `[host]:port` off port 22).
    public var line: String
}

public enum HostKeys {
    /// Preference when the server offers several: ed25519, then ECDSA, then RSA.
    static let preference = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "rsa-sha2-512", "ssh-rsa"]

    /// The known_hosts name for a host and port.
    static func knownHostsName(_ host: String, _ port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Lines of `ssh-keyscan` output, comments and noise dropped.
    static func parseScan(_ output: String) -> [(name: String, type: String, key: String)] {
        output.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, Data(base64Encoded: String(parts[2])) != nil else { return nil }
            return (String(parts[0]), String(parts[1]), String(parts[2]))
        }
    }

    /// `SHA256:…` as `ssh-keygen -l` prints it: base64 of the digest, no padding.
    static func fingerprint(base64Key: String) -> String? {
        guard let blob = Data(base64Encoded: base64Key) else { return nil }
        return "SHA256:" + SHA256Digest.of(blob).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// Every key the server offers, best first.
    public static func scan(host: String, port: Int) async throws -> [ScannedHostKey] {
        let result = try await ProcessRunner.run("/usr/bin/ssh-keyscan", ["-T", "10", "-p", String(port), "--", host], timeout: 30)
        let name = knownHostsName(host, port)
        let keys = parseScan(result.text).compactMap { entry -> ScannedHostKey? in
            guard let fingerprint = fingerprint(base64Key: entry.key) else { return nil }
            return ScannedHostKey(type: entry.type, fingerprint: fingerprint, line: "\(name) \(entry.type) \(entry.key)")
        }
        guard !keys.isEmpty else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHFailure.unreachable(detail.isEmpty ? "nessuna risposta ssh da \(host):\(port)" : detail)
        }
        return keys.sorted { (preference.firstIndex(of: $0.type) ?? 99) < (preference.firstIndex(of: $1.type) ?? 99) }
    }

    /// Store the approved key on the identity (and so in known_hosts).
    public static func approve(_ key: ScannedHostKey, for identity: SSHIdentity, store: SSHIdentityStore) async throws -> SSHIdentity {
        var approved = identity
        approved.hostKey = .init(type: key.type, fingerprint: key.fingerprint, line: key.line, approvedAt: Date())
        try store.update(approved)
        // a master opened under the previous key must not outlive the approval
        await SSHCommand(identity: approved, store: store).closeMaster()
        return approved
    }
}

/// SHA-256 without CryptoKit's availability floor in this target.
enum SHA256Digest {
    static func of(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }
}
