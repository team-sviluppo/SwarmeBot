// Per-bot workspaces — `server/workspace.ts`.
//
// The workspace is where a bot's CLI engine works when its chat has no
// project folder, and where its library lives (`Library.swift`). The
// MEMORY.md it used to seed is gone: older workspaces keep theirs on disk,
// but no turn reads it any more.
import Foundation

public enum Workspace {
    @discardableResult
    public static func ensure(_ paths: DataPaths, botId: String) -> URL {
        let dir = paths.workspace(botId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}
