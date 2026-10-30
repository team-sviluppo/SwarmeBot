import Foundation

/// Presentation-only shortcuts for a final reply that asks the user to choose.
/// Fenced examples and ordinary numbered instructions never become answers.
public enum SuggestedChoices {
    public static func parse(_ text: String) -> [String] {
        let prose = text.replacingOccurrences(of: #"(?s)```.*?```|~~~.*?~~~"#, with: "", options: .regularExpression)
        let asksToChoose = prose.contains("?") || prose.range(of: #"(?i)\b(scegli|choose|select|dimmi quale|tell me which)\b"#,
                                                             options: .regularExpression) != nil
        guard asksToChoose, prose.range(of: #"(?i)quale|quali|scegli|prefer|vuoi|volete|opzion|choose|which|select|would you|want me|option"#,
                                               options: .regularExpression) != nil else { return [] }
        let pattern = #"(?m)^\s*(?:[-*]\s+)?(?:\*\*)?([A-Za-z]|[1-9][0-9]?)[.)](?:\*\*)?\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let lines = prose.replacingOccurrences(of: #"(?<!\S)([A-Za-z]|[1-9][0-9]?)[.)]\s+"#,
                                               with: "\n$1) ", options: .regularExpression)
        let ns = lines as NSString
        let matches = regex.matches(in: lines, range: NSRange(location: 0, length: ns.length))
        guard (2...12).contains(matches.count) else { return [] }
        let labels = matches.map { ns.substring(with: $0.range(at: 1)).lowercased() }
        let numbers = (1...matches.count).map(String.init)
        let letters = (0..<matches.count).map { String(UnicodeScalar(97 + $0)!) }
        guard labels == numbers || labels == letters else { return [] }
        return matches.map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
