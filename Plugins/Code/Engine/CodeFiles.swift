// The files of a chat's folder, for the composer's file search (⌘P): what git lists, so that
// `.gitignore` is respected (`GET /api/threads/:tid/files?q=`).
import Foundation
import HarnessCore

enum CodeFiles {
    static let limit = 50
    private static let maxListed = 20_000
    private static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".venv", "venv", "__pycache__", "dist", "target"]

    /// A listing is reused for a few seconds: typing in the search asks once per key.
    @MainActor private static var cache: [String: (at: Date, files: [String])] = [:]

    /// Paths relative to `folder`. In a repository: tracked files plus untracked ones that are not
    /// ignored. Elsewhere: a walk that leaves out the usual heavy folders.
    @MainActor
    static func list(folder: String, root: String?) async -> [String] {
        let key = folder
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 5 { return hit.files }
        var files: [String]
        if root != nil, let output = await GitRun.text(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."], in: folder, timeout: 20) {
            files = output.split(separator: "\0").map(String.init)
        } else {
            files = walk(folder)
        }
        files = Array(files.prefix(maxListed))
        cache[key] = (Date(), files)
        return files
    }

    static func walk(_ folder: String) -> [String] {
        var out: [String] = []
        // paths come back relative to the folder, so a symlinked folder (/tmp, /var) needs no prefix arithmetic
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return [] }
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            let attributes = walker.fileAttributes
            if skipped.contains(name) || name.hasPrefix(".") {
                if attributes?[.type] as? FileAttributeType == .typeDirectory { walker.skipDescendants() }
                continue
            }
            guard attributes?[.type] as? FileAttributeType != .typeDirectory else { continue }
            out.append(relative)
            if out.count >= maxListed { break }
        }
        return out
    }

    /// The best matches for `query`, best first; with no query, the files changed lately lead.
    static func rank(_ files: [String], query: String, preferred: [String] = [], limit: Int = CodeFiles.limit) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            let first = preferred.filter { files.contains($0) }
            let rest = files.filter { !first.contains($0) }.sorted()
            return Array((first + rest).prefix(limit))
        }
        let scored: [(path: String, score: Int)] = files.compactMap { path in
            score(path, needle).map { (path, $0) }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : ($0.path.count, $0.path) < ($1.path.count, $1.path) }
            .prefix(limit).map(\.path)
    }

    /// Fuzzy: the query's letters must appear in order. Higher is better: the name beats the folders
    /// above it, a run of letters beats scattered ones, a match after a separator beats one inside a word.
    static func score(_ path: String, _ needle: String) -> Int? {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        var total = 0
        if name == needle || stem == needle { total += 1000 }
        else if name.hasPrefix(needle) { total += 600 }
        else if name.contains(needle) { total += 400 }
        else if lower.contains(needle) { total += 200 }

        let characters = Array(lower)
        var position = 0
        var previous = -2
        for letter in needle {
            guard let found = characters[position...].firstIndex(of: letter) else { return nil }
            if found == previous + 1 { total += 15 }
            if found == 0 || "/._-".contains(characters[found - 1]) { total += 10 }
            previous = found
            position = found + 1
        }
        // a short path is nearer to what was meant than a long one
        return total - min(path.count, 100) / 4
    }
}
