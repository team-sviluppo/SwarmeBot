import Foundation

/// Presentation-only shortcuts for a final reply that asks the user to choose.
/// Fenced examples and ordinary numbered instructions never become answers.
public enum SuggestedChoices {
    public static func parse(_ text: String) -> [String] {
        // Keep a boundary where code was, so a prompt cannot reach across an example.
        let prose = text.replacingOccurrences(of: #"(?s)```.*?```|~~~.*?~~~"#, with: "\n[code block]\n", options: .regularExpression)
        let pattern = #"(?m)^[ \t]*(?:[-*][ \t]+)?(?:\*\*)?([A-Za-z]|[1-9][0-9]?)[.)](?:\*\*)?[ \t]+(.+?)[ \t]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let lines = prose.replacingOccurrences(of: #"(?<!\S)([A-Za-z]|[1-9][0-9]?)[.)]\s+"#,
                                               with: "\n$1) ", options: .regularExpression)
        let ns = lines as NSString
        let matches = regex.matches(in: lines, range: NSRange(location: 0, length: ns.length))
        // Separate lists interrupted by prose, tables or code instead of collecting
        // every numbered row in the reply as a single set of answers.
        var lists: [[NSTextCheckingResult]] = []
        for match in matches {
            if let previous = lists.last?.last,
               ns.substring(with: NSRange(location: NSMaxRange(previous.range),
                                          length: match.range.location - NSMaxRange(previous.range)))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lists[lists.count - 1].append(match)
            } else {
                lists.append([match])
            }
        }
        // Prefer the final alternatives when a reply also includes a recap.
        for list in lists.reversed() {
            guard (2...12).contains(list.count) else { continue }
            let labels = list.map { ns.substring(with: $0.range(at: 1)).lowercased() }
            let numbers = (1...list.count).map(String.init)
            let letters = (0..<list.count).map { String(UnicodeScalar(97 + $0)!) }
            guard labels == numbers || labels == letters else { continue }
            let before = ns.substring(to: list[0].range.location).split(separator: "\n")
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
            let after = ns.substring(from: NSMaxRange(list[list.count - 1].range)).split(separator: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
            guard asksToChoose(before) || asksToChoose(after) else { continue }
            return list.map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return []
    }

    private static func asksToChoose(_ line: String) -> Bool {
        // Only inspect the adjacent prompt, never the options themselves or URL
        // query strings. Generic follow-ups ("Want me to commit?") are not choices.
        let prompt = line
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)|`[^`]*`|https?://\S+"#,
                                  with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[*_#]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let start = #"(?i)(?:^|[.!?]\s+)(?:(?:per favore|please)[, ]+)?"#
        let command = #"(?:scegli(?:ete)?|seleziona(?:te)?|dimmi quale|ditemi quale|choose|select|pick|tell me which)\b[^.!?]*\??$"#
        let question = [
            #"(?:quale|quali)\b[^.!?]*\b(?:preferisci|preferite|scegli|scegliete|vuoi|volete)\b"#,
            #"(?:quale|quali)\s+(?:opzion[ei]|alternativ[ae]|soluzion[ei])\b"#,
            #"(?:which|what)\b[^.!?]*\b(?:do you|would you|you)\s+(?:prefer|choose|select|pick|want|like)\b"#,
            #"which\s+(?:option|one|alternative|solution)\b"#,
            #"(?:preferisci|preferite|do you prefer|would you prefer)\b"#,
        ].joined(separator: "|")
        return prompt.range(of: start + command, options: .regularExpression) != nil
            || prompt.range(of: start + "(?:" + question + #")[^.!?]*\?$"#, options: .regularExpression) != nil
    }
}
