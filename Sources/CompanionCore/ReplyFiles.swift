import Foundation

/// A file a bot's reply points at, as the engine resolved it
/// (`POST /api/threads/:tid/files`). The path is the engine's: on a remote
/// engine it is a path on the server.
public struct ReplyFile: Decodable, Hashable, Sendable, Identifiable {
    /// The reference as it appeared in the reply.
    public var ref: String
    public var path: String
    public var name: String
    public var bytes: Int

    public var id: String { path }
}

/// The references to files in a reply's text: link targets that are not web
/// addresses, code spans that look like a file, and absolute paths in the
/// prose. Code blocks are skipped: what is there is mostly commands. The
/// engine checks each one, so a reference that names no file costs nothing.
public enum ReplyFiles {
    public static let limit = 20

    public static func candidates(in text: String) -> [String] {
        let prose = without(#"(?ms)^\s*(```|~~~).*?^\s*(```|~~~)\s*$"#, in: text)
        var found: [String] = []
        for target in matches(#"\[[^\]\n]*\]\(<?([^)>\s]+)>?(?:\s+"[^"]*")?\)"#, in: prose) {
            let decoded = target.removingPercentEncoding ?? target
            if decoded.hasPrefix("file://") || (!decoded.hasPrefix("#") && !hasScheme(decoded)) { found.append(decoded) }
        }
        for span in matches(#"`([^`\n]{1,400})`"#, in: prose) where looksLikeFile(span) {
            found.append(span)
        }
        let plain = without(#"`[^`\n]*`|\[[^\]\n]*\]\([^)\n]*\)"#, in: prose)
        found += matches(#"(?<![\w/~.:])(~?/[^\s`'"<>()\[\]]*\.[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*)(?=[\s.,;:!?)\]]|$)"#, in: plain)
        var seen = Set<String>()
        return Array(found.filter { seen.insert($0).inserted }.prefix(limit))
    }

    /// `report.pdf`, `out/data.csv`, `/abs/path/x.md`, `~/Desktop/a b.docx`, `Report finale.md`.
    static func looksLikeFile(_ span: String) -> Bool {
        let text = span.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !hasScheme(text) || text.hasPrefix("file://"),
              text.range(of: #"[^./\s]\.[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil else { return false }
        // a name may have spaces; a command line has options, pipes or redirects
        return text.range(of: #"(^|\s)-|[|;<>]|&&"#, options: .regularExpression) == nil
    }

    static func hasScheme(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let range = match.range(at: 1)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    private static func without(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
    }
}
