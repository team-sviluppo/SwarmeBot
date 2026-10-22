// The phone's private chats, in SQLite (plan §4.1): bots, servers, messages and
// connectors as JSON rows, in Application Support, so they are part of the
// device backup — for D5 the only copy there is. Images attached to a chat
// are files next to the database.
import Foundation
import SQLite3

final class LocalStore {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var db: OpaquePointer?
    let folder: URL
    var attachments: URL { folder.appendingPathComponent("attachments", isDirectory: true) }

    init(folder: URL? = nil) throws {
        let base = try folder ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Local", isDirectory: true)
        self.folder = base
        try FileManager.default.createDirectory(at: base.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        guard sqlite3_open(base.appendingPathComponent("chats.sqlite").path, &db) == SQLITE_OK else {
            throw Failure(message: "SQLite: \(String(cString: sqlite3_errmsg(db)))")
        }
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS bots (id TEXT PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS connectors (id TEXT PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS servers (id TEXT PRIMARY KEY, json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, bot TEXT NOT NULL, at REAL NOT NULL, json TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS messages_bot ON messages (bot, at);
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Rows

    func bots() -> [LocalBot] { rows("SELECT json FROM bots").sorted { $0.createdAt < $1.createdAt } }
    func save(_ bot: LocalBot) { upsert("bots", bot.id, bot) }
    func connectors() -> [LocalConnector] { rows("SELECT json FROM connectors").sorted { $0.createdAt < $1.createdAt } }
    func save(_ connector: LocalConnector) { upsert("connectors", connector.id, connector) }
    func servers() -> [LocalServer] { rows("SELECT json FROM servers").sorted { $0.createdAt < $1.createdAt } }
    func save(_ server: LocalServer) { upsert("servers", server.id, server) }

    func messages(bot: String) -> [LocalMessage] {
        rows("SELECT json FROM messages WHERE bot = ? ORDER BY at, rowid", [bot])
    }

    func save(_ message: LocalMessage) {
        guard let json = encode(message) else { return }
        run("INSERT INTO messages (id, bot, at, json) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
            [message.id, message.botId, message.at.timeIntervalSince1970, json])
    }

    func delete(bot id: String) {
        for message in messages(bot: id) {
            for image in message.images { try? FileManager.default.removeItem(at: attachments.appendingPathComponent(image)) }
        }
        run("DELETE FROM messages WHERE bot = ?", [id])
        run("DELETE FROM bots WHERE id = ?", [id])
    }

    func clear(bot id: String) {
        run("DELETE FROM messages WHERE bot = ?", [id])
    }

    func delete(connector id: String) {
        run("DELETE FROM connectors WHERE id = ?", [id])
    }

    func delete(server id: String) {
        run("DELETE FROM servers WHERE id = ?", [id])
    }

    /// Keep an attached image; the name is what messages refer to.
    func saveImage(_ data: Data, ext: String) throws -> String {
        let name = "\(UUID().uuidString.lowercased()).\(ext)"
        try data.write(to: attachments.appendingPathComponent(name), options: .completeFileProtectionUntilFirstUserAuthentication)
        return name
    }

    func image(_ name: String) -> Data? { try? Data(contentsOf: attachments.appendingPathComponent(name)) }

    // MARK: SQLite

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure(message: "SQLite: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func upsert<T: Encodable>(_ table: String, _ id: String, _ value: T) {
        guard let json = encode(value) else { return }
        run("INSERT INTO \(table) (id, json) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json", [id, json])
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ bindings: [Any]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Double: sqlite3_bind_double(statement, position, number)
            default: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ bindings: [Any] = []) {
        guard let statement = prepare(sql, bindings) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func rows<T: Decodable>(_ sql: String, _ bindings: [Any] = []) -> [T] {
        guard let statement = prepare(sql, bindings) else { return [] }
        defer { sqlite3_finalize(statement) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            if let value = try? decoder.decode(T.self, from: Data(String(cString: text).utf8)) { out.append(value) }
        }
        return out
    }
}
