// A unified diff, read into lines a view can number and comment on.
import Foundation

struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case hunk, context, added, removed, note }

    var id: Int
    var kind: Kind
    /// The line's number in the old and in the new file; nil where it has none.
    var oldNumber: Int?
    var newNumber: Int?
    /// Without the leading `+`, `-` or space; the whole `@@` line for a hunk header.
    var text: String

    /// The number a comment on this line points at: the new file's, the old one's for a removed line.
    var anchor: Int? { kind == .removed ? oldNumber : newNumber }
}

enum DiffParser {
    /// `git diff` output for one file. The `diff --git`, `index`, `---` and `+++` header is dropped: the
    /// panel already names the file. A line git marks `\ No newline…` is kept as a note.
    static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldNumber = 0
        var newNumber = 0
        var inHunk = false
        for raw in diff.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                inHunk = true
                if let numbers = hunkStart(raw) { (oldNumber, newNumber) = numbers }
                lines.append(DiffLine(id: lines.count, kind: .hunk, text: raw))
                continue
            }
            guard inHunk else { continue }
            if raw.hasPrefix("+") {
                lines.append(DiffLine(id: lines.count, kind: .added, newNumber: newNumber, text: String(raw.dropFirst())))
                newNumber += 1
            } else if raw.hasPrefix("-") {
                lines.append(DiffLine(id: lines.count, kind: .removed, oldNumber: oldNumber, text: String(raw.dropFirst())))
                oldNumber += 1
            } else if raw.hasPrefix("\\") {
                lines.append(DiffLine(id: lines.count, kind: .note, text: raw))
            } else if raw.hasPrefix(" ") {
                lines.append(DiffLine(id: lines.count, kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: String(raw.dropFirst())))
                oldNumber += 1
                newNumber += 1
            }
            // anything else (the blank line the output ends with) is not part of the diff
        }
        return lines
    }

    /// `@@ -12,5 +14,7 @@ func name` → (12, 14).
    static func hunkStart(_ header: String) -> (old: Int, new: Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[0] == "@@" else { return nil }
        func start(_ part: Substring) -> Int? { Int(part.dropFirst().split(separator: ",").first ?? "") }
        guard let old = start(parts[1]), let new = start(parts[2]) else { return nil }
        return (old, new)
    }
}

/// A comment on a line of a changed file, to go to the agent with the others as one review.
struct DiffComment: Identifiable, Equatable {
    let id = UUID()
    /// Relative to the repository's root.
    var path: String
    var line: Int
    var removed: Bool
    /// The line itself, for the agent to find it by.
    var excerpt: String
    var body: String
}

enum Review {
    /// The message of "Invia revisione": every comment with its file and line, for the agent to act on.
    /// Engine-side text, so English like the rest of what the agent reads.
    static func message(_ comments: [DiffComment]) -> String {
        var out = "Review of my uncommitted changes. Please address each comment:\n"
        for (path, group) in Dictionary(grouping: comments, by: \.path).sorted(by: { $0.key < $1.key }) {
            for comment in group.sorted(by: { $0.line < $1.line }) {
                let side = comment.removed ? " (the removed line, in the old version)" : ""
                out += "\n\(path):\(comment.line)\(side)\n    \(comment.removed ? "-" : "+") \(comment.excerpt)\n\(comment.body)\n"
            }
        }
        return out
    }
}
