// Folders a chat may read and must not change: a project's linked repositories
// (docs/plans/2026-10-28-code-mode-t3.md §7). Said in the prompt, and enforced:
//
// - a driver that can says so to its CLI (Claude: `--add-dir` and a rule against editing there);
// - the rest ask the engine for a permission before they write, and the engine says no here.
//
// It cannot stop what never asks (an engine run with every permission open), and a shell command
// is read for the folder it names and a verb that writes: a guard, not a sandbox.
import Foundation

public enum ReadOnlyGuard {
    /// The real path, as git and the file system report it. `resolvingSymlinksInPath` is not it: it
    /// drops `/private`, so a folder under `/tmp` or `/var` would never match a path from git.
    public static func canonical(_ path: String) -> String {
        func real(_ path: String) -> String? {
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        if let found = real(path) { return found }
        // a path that is not there (yet): the real path of the part that is, and the rest as it was
        var rest: [String] = []
        var existing = URL(fileURLWithPath: path).standardizedFileURL.path
        while existing != "/", real(existing) == nil {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return (rest.isEmpty ? [real(existing) ?? existing] : [real(existing) ?? existing] + rest).reduce("") { $0.isEmpty ? $1 : ($0 == "/" ? "/" + $1 : $0 + "/" + $1) }
    }

    /// Tool names that change files, matched on pieces of the name (`Edit`, `str_replace_editor`, `apply_patch`…).
    static let writeWords = ["edit", "write", "patch", "create", "delete", "remove", "move", "rename", "notebook", "replace", "insert"]

    /// A shell command that changes things.
    static let writingCommand: NSRegularExpression = try! NSRegularExpression(
        pattern: #"(>>?\s*\S)|\b(rm|mv|cp|mkdir|rmdir|touch|tee|truncate|chmod|chown|ln|install|rsync|dd|patch)\b|\b(sed|perl)\s+(-[a-z]*i)|\bgit\b[^|;&\n]*?\s(add|commit|checkout|switch|reset|clean|apply|stash|merge|rebase|pull|push|restore|rm|mv|cherry-pick|revert|am|init)(\s|$)"#,
        options: .caseInsensitive)

    /// Why a permission request must be refused, nil when it may go on.
    public static func reason(tool: String, summary: String, folders: [String]) -> String? {
        guard !folders.isEmpty else { return nil }
        guard let folder = folders.first(where: { mentions(summary, $0) }) else { return nil }
        let bare = tool.replacingOccurrences(of: #"^mcp__[^_]+__"#, with: "", options: .regularExpression).lowercased()
        let writes: Bool
        if AutoApprove.commandTools.contains(bare) {
            writes = writingCommand.firstMatch(in: summary, range: NSRange(location: 0, length: (summary as NSString).length)) != nil
        } else {
            writes = writeWords.contains { bare.contains($0) }
        }
        guard writes else { return nil }
        return "\(folder) is linked to this project read-only: read it as much as you need, and make changes only in your working folder."
    }

    /// The folder's path in the text, as a whole path (not the start of a longer name), also under the
    /// name a client would use for a folder behind `/private`.
    static func mentions(_ text: String, _ folder: String) -> Bool {
        var names = [folder]
        for prefix in ["/private"] where folder.hasPrefix(prefix + "/") { names.append(String(folder.dropFirst(prefix.count))) }
        for name in names {
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: name, range: search) {
                let after = found.upperBound
                if after == text.endIndex || !text[after].isLetter && !text[after].isNumber && text[after] != "_" && text[after] != "-" && text[after] != "." {
                    return true
                }
                search = found.upperBound..<text.endIndex
            }
        }
        return false
    }
}
