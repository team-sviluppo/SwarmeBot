// "Continue in the terminal": the command that picks a chat's session up in the
// agent's own CLI, in the same folder (`GET /api/threads/:tid/resume-command`).
//
// The engine builds it because it knows the session and the folder, and because
// they are on its machine: on a server the Mac only has to run it over ssh.
import Foundation
import HarnessCore

enum ResumeCommand {
    /// The CLI of an engine whose sessions can be resumed by hand, and how. Keyed by the
    /// engine's driver kind (`claudeAgent`, `codex`), not by the CLI's name.
    static func cli(driverKind: String, session: String) -> (tool: String, arguments: [String])? {
        switch driverKind {
        case "claudeAgent": return ("claude", ["--resume", session])
        case "codex": return ("codex", ["resume", session])
        default: return nil
        }
    }

    /// Single-quoted for any POSIX shell.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where the CLIs are usually installed, for a shell that never read the user's profile.
    static let path = #"export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH""#

    static func command(folder: String, tool: String, arguments: [String]) -> String {
        "\(path); cd -- \(quote(folder)) && exec \(tool) \(arguments.map(quote).joined(separator: " "))"
    }

    /// `{supported: false, reason}`, or `{supported: true, tool, folder, command}`.
    @MainActor
    static func wire(harness: HarnessCore.Harness, threadId: String) -> JSON {
        let store = harness.store
        guard let bot = store.botByThread(threadId), let botId = bot["id"]?.string,
              let folder = ThreadFiles.roots(store, harness.paths, threadId: threadId)?.first else {
            return ["supported": false, "reason": "only a bot's chat has a session to continue"]
        }
        let instanceId = ModelSelection(json: bot["modelSelection"]).instanceId
        guard let driverKind = harness.fleet.get(instanceId)?.driverKind else {
            return ["supported": false, "reason": "the bot's engine is unavailable"]
        }
        guard let session = store.taskByThread(botId, threadId)?["resumeCursors"]?[instanceId]?.string, !session.isEmpty else {
            return ["supported": false, "reason": "this chat has no session yet: send a message first"]
        }
        guard let cli = cli(driverKind: driverKind, session: session) else {
            return ["supported": false, "reason": "this engine's sessions cannot be continued in a terminal"]
        }
        return ["supported": true, "tool": .string(cli.tool), "folder": .string(folder),
                "command": .string(command(folder: folder, tool: cli.tool, arguments: cli.arguments))]
    }
}
