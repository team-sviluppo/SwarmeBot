// Where the harness keeps things — `server/config.ts` DATA_DIR and friends.
import Foundation

public struct DataPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `OMB_DATA_DIR`, else `~/.swarmebot`, exactly like the Node engine.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> DataPaths {
        if let dir = env["OMB_DATA_DIR"], !dir.isEmpty {
            return DataPaths(root: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true))
        }
        return DataPaths(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".swarmebot", isDirectory: true))
    }

    public var bots: URL { root.appendingPathComponent("bots.json") }
    public var groups: URL { root.appendingPathComponent("groups.json") }
    public var config: URL { root.appendingPathComponent("config.json") }
    public var messagesDB: URL { root.appendingPathComponent("messages.db") }
    public var events: URL { root.appendingPathComponent("events", isDirectory: true) }
    public var native: URL { root.appendingPathComponent("native", isDirectory: true) }
    public var attachments: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    public var workspaces: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    public var decisions: URL { root.appendingPathComponent("decisions.ndjson") }
    /// Which plugins the user switched off (Plugins.swift).
    public var plugins: URL { root.appendingPathComponent("plugins.json") }

    public func legacyMessages(_ threadId: String) -> URL {
        root.appendingPathComponent("messages-\(threadId).json")
    }

    public func workspace(_ botId: String) -> URL {
        workspaces.appendingPathComponent(botId, isDirectory: true)
    }

    public func ensure() {
        let fm = FileManager.default
        for dir in [root, events, native, attachments, workspaces] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

public enum FileIO {
    /// Write-then-rename, like `writeFileAtomic`: a crash mid-write leaves the
    /// old file, never half a new one.
    public static func writeAtomic(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
        if rename(temp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Append one line, creating the file 0600. Logging never throws.
    public static func appendLine(_ line: String, to url: URL) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    public static func readJSON(_ url: URL) -> JSON? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSON.parse(data)
    }
}

/// The native (un-normalized) protocol tee, `drivers/native.ts`.
public enum NativeLog {
    nonisolated(unsafe) public static var directory: URL?

    public static func append(threadId: String, dir: String, source: String, msg: JSON) {
        guard let directory else { return }
        let entry: JSON = ["at": .string(isoNow()), "dir": .string(dir), "source": .string(source), "msg": Redact.json(msg)]
        FileIO.appendLine(entry.serialized(), to: directory.appendingPathComponent("\(threadId).ndjson"))
    }
}
