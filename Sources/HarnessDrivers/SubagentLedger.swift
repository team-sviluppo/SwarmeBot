import Foundation
import HarnessCore

/// One ledger per provider run. Task IDs are provider-local, not SwarmeBot
/// threads. All mutations happen on the driver's main actor.
@MainActor
final class SubagentLedger {
    private(set) var tasks: [String: SubagentState] = [:]
    var onChange: ((SubagentState, Bool) -> Void)?

    var pending: [SubagentState] {
        tasks.values.filter { $0.isRunning && $0.waitsForCompletion }.sorted { $0.id < $1.id }
    }

    func update(_ proposed: SubagentState) {
        var state = proposed
        state.title = String(state.title.prefix(200))
        state.result = state.result.map { String($0.prefix(16_000)) }
        guard tasks[state.id] != state else { return }
        let isNew = tasks[state.id] == nil
        tasks[state.id] = state
        onChange?(state, isNew)
    }

    func finishRunning(_ status: String, reason: String) {
        for var task in tasks.values where task.isRunning {
            task.status = status
            task.result = [task.result, reason].compactMap { $0 }.joined(separator: "\n")
            update(task)
        }
    }

    static func status(_ raw: String) -> String {
        switch raw {
        case "completed": return "completed"
        case "failed", "errored", "notFound": return "failed"
        case "stopped", "killed", "interrupted", "shutdown": return "interrupted"
        default: return "running"
        }
    }

    /// Shells/monitors and permanent teammates do not hold the run open.
    /// Both terminal vocabularies matter: task_updated can be the only end.
    @discardableResult
    func claude(_ message: JSON, parentId: String) -> Bool {
        guard message["type"]?.string == "system",
              let subtype = message["subtype"]?.string, subtype.hasPrefix("task_"),
              let id = message["task_id"]?.string else { return false }
        let patch = message["patch"] ?? message
        var task = tasks[id] ?? SubagentState(id: id, parentId: parentId, title: message["description"]?.string ?? id)
        if let title = patch["description"]?.string { task.title = title }
        if let type = message["task_type"]?.string {
            task.waitsForCompletion = ["local_agent", "local_workflow"].contains(type)
        }
        if let tool = message["tool_use_id"]?.string { task.toolUseId = tool }
        if let status = patch["status"]?.string { task.status = Self.status(status) }
        if let summary = patch["summary"]?.string, !summary.isEmpty { task.result = String(summary.prefix(16_000)) }
        if let path = patch["output_file"]?.string ?? patch["outputFile"]?.string { task.outputFile = path }
        // Ignore an unrecognised patch for a task we have never seen.
        guard subtype != "task_updated" || tasks[id] != nil else { return true }
        update(task)
        return true
    }

    func claudeText(_ message: JSON) -> Bool {
        guard let parent = message["parent_tool_use_id"]?.string, !parent.isEmpty else { return false }
        if let id = tasks.values.first(where: { $0.toolUseId == parent || $0.id == parent })?.id,
           var task = tasks[id], message["type"]?.string == "assistant" {
            let text = ClaudeInstance.firstText(message["message"]?["content"])
            if !text.isEmpty { task.result = String(text.prefix(16_000)); update(task) }
        }
        return true
    }
}
