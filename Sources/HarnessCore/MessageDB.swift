// SQLite persistence for transcripts — `server/message-db.ts`, same schema,
// same file, same pragmas, so the two engines read each other's database.
//
// One row per message, the message itself as JSON in `json` (the columns
// beside it exist for search). WAL, owner-only permissions.
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class MessageDB {
    private var db: OpaquePointer?
    private let file: URL

    public init(file: URL) throws {
        self.file = file
        // private conversations: create 0600 and repair a permissive umask
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard sqlite3_open(file.path, &db) == SQLITE_OK else {
            throw DBError.open(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS messages (
              thread_id TEXT NOT NULL,
              id TEXT NOT NULL,
              at INTEGER NOT NULL,
              role TEXT NOT NULL,
              kind TEXT NOT NULL,
              text TEXT,
              json TEXT NOT NULL,
              PRIMARY KEY (thread_id, id)
            );
            CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread_id);
            CREATE TABLE IF NOT EXISTS thread_state (
              thread_id TEXT PRIMARY KEY,
              active_leaf_id TEXT
            );
            """)
    }

    deinit { sqlite3_close(db) }

    public enum DBError: LocalizedError {
        case open(String)
        case sql(String)
        public var errorDescription: String? {
            switch self {
            case let .open(message): return "messages.db: \(message)"
            case let .sql(message): return "messages.db: \(message)"
            }
        }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw DBError.sql(message)
        }
    }

    /// Prepare, bind (String, Double, nil), step through rows, finalize.
    private func query(_ sql: String, _ bindings: [Any?], row: ((OpaquePointer) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let string as String: sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case let number as Double: sqlite3_bind_int64(statement, index, sqlite3_int64(number))
            case let number as Int: sqlite3_bind_int64(statement, index, sqlite3_int64(number))
            default: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { row?(statement); continue }
            if step == SQLITE_DONE { return }
            throw DBError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    // MARK: Threads

    /// One thread, importing its legacy `messages-<id>.json` on first touch.
    public func readThread(_ threadId: String, legacyFile: URL) -> (messages: [JSONObject], activeLeafId: String?) {
        var messages: [JSONObject] = []
        try? query("SELECT json FROM messages WHERE thread_id = ? ORDER BY rowid", [threadId]) { statement in
            if let raw = Self.text(statement, 0), let object = try? JSON.parse(raw).object { messages.append(object) }
        }
        if !messages.isEmpty {
            var leaf: String?
            try? query("SELECT active_leaf_id FROM thread_state WHERE thread_id = ?", [threadId]) { leaf = Self.text($0, 0) }
            return (messages, leaf)
        }
        return importLegacy(threadId, legacyFile)
    }

    private func importLegacy(_ threadId: String, _ legacyFile: URL) -> (messages: [JSONObject], activeLeafId: String?) {
        guard let raw = FileIO.readJSON(legacyFile) else { return ([], nil) }
        var messages: [JSONObject] = []
        var leaf: String?
        if let array = raw.array {
            messages = array.compactMap(\.object)
        } else {
            messages = raw["messages"]?.array?.compactMap(\.object) ?? []
            leaf = raw["activeLeafId"]?.string
        }
        try? exec("BEGIN")
        for message in messages { insert(threadId, message) }
        setActiveLeaf(threadId, leaf)
        try? exec("COMMIT")
        let imported = legacyFile.appendingPathExtension("imported")
        try? FileManager.default.moveItem(at: legacyFile, to: imported)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imported.path)
        return (messages, leaf)
    }

    private func insert(_ threadId: String, _ message: JSONObject) {
        try? query(
            "INSERT OR REPLACE INTO messages (thread_id, id, at, role, kind, text, json) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [threadId, message["id"]?.string ?? "", message["at"]?.double ?? 0, message["role"]?.string ?? "bot",
             message["kind"]?.string ?? "text", message["text"]?.string, JSON.object(message).serialized()]
        )
    }

    /// A new message and the branch head, as one crash-safe write.
    public func append(_ threadId: String, _ message: JSONObject) {
        try? exec("BEGIN IMMEDIATE")
        insert(threadId, message)
        setActiveLeaf(threadId, message["id"]?.string)
        try? exec("COMMIT")
    }

    public func update(_ threadId: String, _ message: JSONObject) {
        try? query(
            "UPDATE messages SET at = ?, role = ?, kind = ?, text = ?, json = ? WHERE thread_id = ? AND id = ?",
            [message["at"]?.double ?? 0, message["role"]?.string ?? "bot", message["kind"]?.string ?? "text",
             message["text"]?.string, JSON.object(message).serialized(), threadId, message["id"]?.string ?? ""]
        )
    }

    public func setActiveLeaf(_ threadId: String, _ leaf: String?) {
        try? query(
            "INSERT INTO thread_state (thread_id, active_leaf_id) VALUES (?, ?) ON CONFLICT(thread_id) DO UPDATE SET active_leaf_id = excluded.active_leaf_id",
            [threadId, leaf]
        )
    }

    public func deleteThread(_ threadId: String) {
        try? query("DELETE FROM messages WHERE thread_id = ?", [threadId])
        try? query("DELETE FROM thread_state WHERE thread_id = ?", [threadId])
    }

    // MARK: Search

    /// Case-insensitive substring search over text and tool chips, newest first.
    public func search(_ raw: String, limit: Int) -> [JSONObject] {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        var hits: [JSONObject] = []
        let sql = """
            SELECT thread_id, id, at, role, kind, text, json_extract(json, '$.tool.name') AS tool_name, json_extract(json, '$.from.name') AS from_name FROM messages
            WHERE (kind = 'text' AND text IS NOT NULL AND lower(text) LIKE ? ESCAPE '\\')
               OR (kind = 'activity' AND tool_name IS NOT NULL AND lower(tool_name) LIKE ? ESCAPE '\\')
            ORDER BY at DESC LIMIT ?
            """
        try? query(sql, [pattern, pattern, limit]) { statement in
            let kind = Self.text(statement, 4) ?? "text"
            let haystack = (kind == "activity" ? Self.text(statement, 6) : Self.text(statement, 5)) ?? ""
            let chars = Array(haystack)
            let lowered = Array(haystack.lowercased())
            let needleChars = Array(needle)
            var hitAt = 0
            if needleChars.count <= lowered.count {
                for start in 0...(lowered.count - needleChars.count) where Array(lowered[start..<start + needleChars.count]) == needleChars {
                    hitAt = start
                    break
                }
            }
            let start = max(0, hitAt - 60)
            let end = min(chars.count, hitAt + needleChars.count + 90)
            let head = start > 0 ? "…" : ""
            let body = String(chars[start..<end]).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let snippet = head + body + (end < chars.count ? "…" : "")
            let folded = needle.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let match = snippet.lowercased().range(of: folded)
            var hit = JSONObject()
            hit["threadId"] = .string(Self.text(statement, 0) ?? "")
            hit["messageId"] = .string(Self.text(statement, 1) ?? "")
            hit["at"] = .number(Double(sqlite3_column_int64(statement, 2)))
            hit["role"] = .string(Self.text(statement, 3) ?? "bot")
            hit["kind"] = .string(kind)
            hit["snippet"] = .string(snippet)
            hit["matchStart"] = .number(Double(match.map { snippet.lowercased().distance(from: snippet.lowercased().startIndex, to: $0.lowerBound) } ?? head.count))
            hit["matchLength"] = .number(Double(match == nil ? 0 : folded.count))
            if let from = Self.text(statement, 7) { hit["from"] = .string(from) }
            hits.append(hit)
        }
        return hits
    }

    /// A consistent copy of the database, for the Swift engine's preview
    /// snapshot: safe while another process has it open in WAL mode.
    public static func snapshot(from source: URL, to destination: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw DBError.open(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_close(handle) }
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, "VACUUM INTO '\(escaped)'", nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw DBError.sql(message)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
