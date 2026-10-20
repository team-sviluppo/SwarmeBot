// Files a bot's reply points at, for the file cards under it
// (`POST /api/threads/:tid/files`, `GET /api/threads/:tid/files/content`).
//
// The client finds the candidates in the reply's text; the engine resolves
// them, because the files live where the engine runs — on a server they are
// not on the Mac that shows the chat. A relative path resolves against the
// chat's folder. A remote client only reaches files inside the chat's
// folders or ones a tool of that chat named (what the bot wrote); on this
// machine the app could open any file anyway, so nothing is held back.
import Foundation

enum ThreadFiles {
    static let maxPaths = 20
    static let maxBytes = 50 * 1024 * 1024

    struct Resolved {
        var path: String
        var bytes: Int
    }

    /// The folders a chat's turns run in, the first one for relative paths;
    /// nil for a thread that is neither a bot's nor a room's.
    @MainActor
    static func roots(_ store: Store, _ paths: DataPaths, threadId: String) -> [String]? {
        if let bot = store.botByThread(threadId), let botId = bot["id"]?.string {
            let task = store.taskByThread(botId, threadId)
            return unique([task?["cwd"]?.string, bot["cwd"]?.string, paths.workspace(botId).path])
        }
        if let group = store.groupByThread(threadId) {
            let members = group["memberIds"]?.array?.compactMap(\.string) ?? []
            return unique([group["pinnedCwd"]?.string, group["cwd"]?.string] + members.map { paths.workspace($0).path })
        }
        return nil
    }

    /// The text of the chat's tool calls, where a written file is named.
    @MainActor
    static func toolText(_ store: Store, threadId: String) -> String {
        store.messages(threadId).compactMap { message -> String? in
            guard message["kind"]?.string == "activity", let tool = message["tool"] else { return nil }
            return tool["input"]?.string
        }.joined(separator: "\n")
    }

    /// A regular file the reference names, or nil.
    static func resolve(_ reference: String, roots: [String], toolText: String, remote: Bool) -> Resolved? {
        var raw = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("file://") {
            guard let url = URL(string: raw), url.isFileURL else { return nil }
            raw = url.path
        }
        guard !raw.isEmpty, !raw.contains("\0") else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if raw == "~" || raw.hasPrefix("~/") { raw = home + raw.dropFirst() }
        let absolute: String
        if raw.hasPrefix("/") {
            absolute = raw
        } else {
            guard let base = roots.first else { return nil }
            absolute = (base as NSString).appendingPathComponent(raw)
        }
        let real = URL(fileURLWithPath: absolute).standardizedFileURL.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: real),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        if remote {
            let inside = roots.contains { root in
                let folder = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
                return real.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
            }
            let named = [absolute, real].contains { toolText.contains($0) || toolText.contains($0.replacingOccurrences(of: "/", with: "\\/")) }
            guard inside || named else { return nil }
        }
        return Resolved(path: real, bytes: (attributes[.size] as? NSNumber)?.intValue ?? 0)
    }

    private static func unique(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
