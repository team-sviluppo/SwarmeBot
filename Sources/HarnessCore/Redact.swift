// Keeping secrets out of logs and transcripts — `server/redact.ts`, ported
// rule for rule. The log keeps the SHAPE and loses the VALUES: a redacted
// entry still says a token was passed, under which name, and how long it was.
import Foundation

public enum Redact {
    private static let secretKeyParts = ["token", "secret", "password", "passwd", "apikey", "api_key", "authorization", "auth_token"]

    /// `key` alone is too broad (keyboard, hotkey): only as a whole word or suffix.
    static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if secretKeyParts.contains(where: lower.contains) { return true }
        return lower.range(of: #"(^|[_.-])keys?$"#, options: .regularExpression) != nil
    }

    static func mask(_ value: String) -> String { "«redacted \(value.utf16.count) chars»" }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // patterns are constants: a failure here is a programming error
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let keyPrefixes: [NSRegularExpression] = [
        regex(#"\bsk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_-]{16,}"#),
        regex(#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#),
        regex(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
        regex(#"\bxox[abposr]-[A-Za-z0-9-]{20,}"#),
        regex(#"\bAKIA[0-9A-Z]{16}\b"#),
        regex(#"\bAIza[0-9A-Za-z_-]{30,}"#),
        regex(#"\bnpm_[A-Za-z0-9]{20,}"#),
        regex(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#),
    ]
    private static let bearer = regex(#"(\bBearer\s+)([A-Za-z0-9._~+/=-]{12,})"#)
    private static let pemBlock = regex(#"(-----BEGIN [A-Z ]*PRIVATE KEY-----)([\s\S]*?)(-----END [A-Z ]*PRIVATE KEY-----)"#)
    private static let keyValue = regex(
        #"\b((?:[A-Za-z0-9_-]*_)?(?:api[_-]?key|apikey|secret|token|password|passwd|authorization|auth[_-]?token|access[_-]?key|private[_-]?key)s?)(["']?\s*[=:]\s*)(["']?)([A-Za-z0-9._~+/=-]{8,})\3"#,
        .caseInsensitive
    )

    /// Replace each match through `transform(groups)`.
    private static func replace(_ text: String, _ regex: NSRegularExpression, _ transform: ([String]) -> String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    public static func text(_ input: String) -> String {
        guard input.utf16.count >= 8 else { return input }
        var out = replace(input, pemBlock) { g in
            "\(g[1])\n\(mask(g[2].trimmingCharacters(in: .whitespacesAndNewlines)))\n\(g[3])"
        }
        for pattern in keyPrefixes { out = replace(out, pattern) { mask($0[0]) } }
        out = replace(out, bearer) { "\($0[1])\(mask($0[2]))" }
        out = replace(out, keyValue) { "\($0[1])\($0[2])\($0[3])\(mask($0[4]))\($0[3])" }
        return out
    }

    /// Deep copy with credential values replaced: env objects, ACP
    /// `[{name, value}]` arrays, and any string's content.
    public static func json(_ input: JSON, depth: Int = 0) -> JSON {
        switch input {
        case let .string(value):
            return .string(text(value))
        case let .array(items) where depth <= 12:
            return .array(items.map { item in
                if case let .object(entry) = item, let name = entry["name"]?.string, let value = entry["value"]?.string {
                    var copy = entry
                    if isSecretName(name) { copy["value"] = .string(mask(value)) }
                    return .object(copy)
                }
                return json(item, depth: depth + 1)
            })
        case let .object(object) where depth <= 12:
            var out = JSONObject()
            for (key, value) in object {
                if case let .string(string) = value, isSecretName(key) {
                    out[key] = .string(mask(string))
                } else {
                    out[key] = json(value, depth: depth + 1)
                }
            }
            return .object(out)
        default:
            return input
        }
    }
}
