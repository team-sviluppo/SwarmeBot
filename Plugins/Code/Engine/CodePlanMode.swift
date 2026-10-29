// Plan / Execute switch of a chat (docs/plans/2026-10-28-code-mode-t3.md, Parte 2 §3).
//
// In Plan mode the agent explores and proposes a plan and touches nothing; the person approves it
// or corrects it, and only then switches to Execute. The mode belongs to the chat (a bot's task, or
// a channel), is kept in `<data>/plugins/code/modes.json` and read by `beforeTurn`, so it works for
// every driver the same way: a line in the system prompt, and the chat's folder linked read-only
// (the guard of project folders: `--add-dir` and a rule for Claude, a refused permission for the
// engines that ask before writing). Like that guard it is not a sandbox: a command that writes
// without ever asking is what it cannot stop.
import Foundation
import HarnessCore

enum CodeMode: String {
    case plan, execute
}

@MainActor
struct CodeModes {
    private let file: URL

    init(harness: Harness) {
        file = harness.plugins.directory(for: "code").appendingPathComponent("modes.json")
    }

    private var stored: JSONObject {
        guard let data = try? Data(contentsOf: file), let object = try? JSON.parse(data).object else { return JSONObject() }
        return object
    }

    func mode(of threadId: String) -> CodeMode {
        stored[threadId]?.string == CodeMode.plan.rawValue ? .plan : .execute
    }

    /// Execute is the absence of an entry: a chat that never chose has nothing written.
    func set(_ mode: CodeMode, for threadId: String) throws {
        var next = stored
        next[threadId] = mode == .plan ? .string(mode.rawValue) : Optional<JSON>.none
        try FileIO.writeAtomic(JSON.object(next).data, to: file)
    }

    static let prompt = """
        PLAN MODE is on for this chat. Explore the code as much as you need: read files, search, and run \
        commands that only read. Do not create, edit, move or delete anything, and do not run a command \
        that changes the repository or the machine (no git add, commit, checkout or reset, no installs, no \
        redirects into files). Reply with a plan the person can approve: what you understood of the request, \
        the files you would change and how, the steps in order, how you would check each one, and any risk or \
        open question. Do not start the work: the person approves the plan, or corrects it, and then switches \
        you to Execute mode.
        """
}
