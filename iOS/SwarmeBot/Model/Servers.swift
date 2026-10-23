// The remote engines this phone is paired with (plan §5.1). The list is a
// small JSON file in Application Support; each device token is in the
// Keychain, never in the file.
import CompanionCore
import Foundation

struct PairedServer: Codable, Hashable, Identifiable, Sendable {
    /// The device id the engine gave this phone: unique per engine.
    var id: String
    var name: String
    /// `https://…/<prefix>/`, as the pairing QR carries it.
    var chatURL: String
    var pairedAt: Date

    var tokenAccount: String { "server.\(id).token" }
    var connection: Connection? { Connection.remote(chatURL: chatURL, name: name) }
}

enum ServerStore {
    static var file: URL {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return folder.appendingPathComponent("servers.json")
    }

    static func load() -> [PairedServer] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([PairedServer].self, from: data)) ?? []
    }

    static func save(_ servers: [PairedServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The last fleet a server sent, so its chats open at once and read offline
/// (plan §5.4). Always overwritten: the engine is the source of truth.
enum FleetCache {
    struct Snapshot: Codable {
        var bots: [Bot]
        var rooms: [Room]
        var savedAt: Date
    }

    private static func file(_ serverId: String) -> URL {
        let folder = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let safe = serverId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return folder.appendingPathComponent("fleet-\(safe).json")
    }

    static func load(_ serverId: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: file(serverId)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ state: CompanionState, serverId: String) {
        // the last 50 messages of each chat are plenty for a first screen
        func trimmed(_ messages: [Message]?) -> [Message]? { messages.map { Array($0.suffix(50)) } }
        let bots = state.bots.map { bot -> Bot in
            var copy = bot
            copy.messages = trimmed(state.messages[bot.threadId])
            return copy
        }
        let rooms = state.rooms.map { room -> Room in
            var copy = room
            copy.messages = trimmed(state.messages[room.threadId])
            return copy
        }
        guard let data = try? JSONEncoder().encode(Snapshot(bots: bots, rooms: rooms, savedAt: Date())) else { return }
        try? data.write(to: file(serverId), options: .atomic)
    }

    static func remove(_ serverId: String) {
        try? FileManager.default.removeItem(at: file(serverId))
    }
}
