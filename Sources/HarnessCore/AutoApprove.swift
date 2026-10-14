// Auto mode, always-allow, and the guards that stop both — `server/auto-approve.ts`.
import Foundation

public enum AutoApprove {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let destructive: [(source: String, regex: NSRegularExpression)] = [
        #"\brm\s+(-[a-z]*\s+)*-[a-z]*[rf]"#,
        #"\bmkfs\b|\bdiskutil\s+erase|\bdd\s+[^|]*\bof=\/dev\/"#,
        #"\bshutdown\b|\breboot\b|\bhalt\b"#,
        #":\(\)\s*\{.*\}\s*;?\s*:"#,
        #"\bgit\s+push\s+[^|]*--force(-with-lease)?\b|\bgit\s+reset\s+--hard\b"#,
        #"\bDROP\s+(TABLE|DATABASE)\b|\bTRUNCATE\s+TABLE\b"#,
        #"\bsudo\s+rm\b|\bchmod\s+-R\s+777\s+\/"#,
    ].map { ($0, regex($0, $0.hasPrefix(":") ? [] : .caseInsensitive)) }

    static let sensitive: [(source: String, regex: NSRegularExpression)] = [
        #"(^|[\s/"'])\.env(\.|$|["'\s])"#,
        #"\.ssh\/|id_rsa|id_ed25519|authorized_keys"#,
        #"\.aws\/credentials|\.netrc|\.npmrc|\.pypirc|\.docker\/config\.json"#,
        #"security\s+find-(generic|internet)-password|\bkeychain\b"#,
        #"\bcredentials?\.json\b|\bserviceaccount\b"#,
    ].map { ($0, regex($0, .caseInsensitive)) }

    static func matchFirst(_ rules: [(source: String, regex: NSRegularExpression)], _ text: String) -> String? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return rules.first { $0.regex.firstMatch(in: text, range: range) != nil }?.source
    }

    static let commandTools: Set<String> = ["bash", "shell", "execute", "run_command", "computer_exec", "terminal"]

    /// The narrow grant "Always allow" remembers: command tools by program.
    public static func approvalKey(tool: String, summary: String, scope: String? = nil) -> String {
        let bare = tool.replacingOccurrences(of: #"^mcp__[^_]+__"#, with: "", options: .regularExpression).lowercased()
        guard commandTools.contains(bare) else { return scope.map { "\($0):\(tool)" } ?? tool }
        let words = summary.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).map(String.init)
        var index = 0
        while index < words.count,
              words[index] == "sudo" || words[index].range(of: #"^[A-Z_][A-Z0-9_]*="#, options: .regularExpression) != nil {
            index += 1
        }
        let program = (index < words.count ? words[index] : "").split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: #"[^\w.-]"#, with: "", options: .regularExpression) ?? ""
        let key = program.isEmpty ? tool : "\(tool):\(program)"
        return scope.map { "\($0):\(key)" } ?? key
    }

    public struct Verdict: Equatable {
        /// Chip text when the bot may answer itself; nil means a human decides.
        public var approve: String?
        public var source: String
        public var rule: String?
    }

    public static func verdict(autoApprove: Bool, alwaysAllow: [String], tool: String, summary: String,
                               unattended: Bool = false, scope: String? = nil) -> Verdict {
        let destructiveRule = matchFirst(destructive, summary) ?? matchFirst(destructive, tool)
        let sensitiveRule = destructiveRule == nil ? matchFirst(sensitive, summary) : nil
        let key = approvalKey(tool: tool, summary: summary, scope: scope)
        var grant: Verdict?
        if destructiveRule == nil, sensitiveRule == nil {
            if alwaysAllow.contains(key) {
                grant = Verdict(approve: "auto-approved \(key) (always allowed)", source: "always-allow", rule: key)
            } else if autoApprove {
                grant = Verdict(approve: "auto-approved \(tool)", source: "auto-mode", rule: nil)
            }
        }
        if unattended || scope == "local-computer" {
            if let grant { return Verdict(approve: nil, source: unattended ? "unattended-block" : "local-computer-block", rule: grant.rule) }
        }
        if let destructiveRule { return Verdict(approve: nil, source: "destructive-guard", rule: destructiveRule) }
        if let sensitiveRule { return Verdict(approve: nil, source: "sensitive-guard", rule: sensitiveRule) }
        if let grant { return grant }
        return Verdict(approve: nil, source: "no-grant", rule: nil)
    }
}

/// The fleet-wide authorization log, `decisions.ndjson` — append only.
public enum DecisionLog {
    public static func append(_ paths: DataPaths, _ entry: JSONObject) {
        var line = JSONObject([("at", .number(nowMillis()))])
        line = line.merging(entry)
        FileIO.appendLine(Redact.json(.object(line)).serialized(), to: paths.decisions)
    }

    public static func read(_ paths: DataPaths, limit: Int) -> [JSON] {
        guard let text = try? String(contentsOf: paths.decisions, encoding: .utf8) else { return [] }
        let rows = text.split(separator: "\n").compactMap { try? JSON.parse(String($0)) }
        return Array(rows.suffix(limit).reversed())
    }
}
