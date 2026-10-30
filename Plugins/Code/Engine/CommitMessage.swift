// The commit message, written from the diff by a model in a call of its own
// (`POST /api/threads/:tid/git/commit-message`): not a turn of the chat, so the chat stays clean.
//
// The model runs in an empty folder, not in the repository, and is told to use no tool; if it
// asks for a permission anyway, the answer is no. The diff comes in the prompt.
import Foundation
import HarnessCore

@MainActor
enum CommitMessage {
    static let promptLimit = 24_000
    static let timeout: TimeInterval = 90

    static let system = """
        You write git commit messages. Reply with the message only: a subject line of at most 72 \
        characters in the imperative mood, a blank line, then a short body, wrapped at 72 characters, that \
        says what changed and why. No quotes, no code fences, no preamble, no sign-off. Never use a tool.
        """

    static func prompt(diff: String, files: [String], recent: [String]) -> String {
        var text = "Write the commit message for these changes.\n\nChanged files:\n" + files.map { "- \($0)" }.joined(separator: "\n")
        if !recent.isEmpty {
            text += "\n\nRecent commit subjects in this repository, to match their style:\n" + recent.map { "- \($0)" }.joined(separator: "\n")
        }
        let shown = diff.count > promptLimit ? String(diff.prefix(promptLimit)) + "\n[diff cut here: it is longer than this]" : diff
        return text + "\n\nDiff:\n" + shown
    }

    /// What a model wraps around a message in spite of the instructions.
    static func clean(_ reply: String) -> String {
        var lines = reply.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, let first = text.first, let last = text.last, first == last, "\"'`".contains(first) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// The model to ask: the one set for commit messages, else the chat's own bot's.
    static func selection(harness: Harness, threadId: String) -> ModelSelection? {
        if let chosen = CodeSettings(harness: harness).commitModel, harness.fleet.get(chosen.instanceId) != nil { return chosen }
        let group = harness.store.groupByThread(threadId)
        let defaultMember = group?["defaultResponder"]?["kind"] == "member" ? group?["defaultResponder"]?["botId"]?.string : nil
        let member = defaultMember ?? group?["memberIds"]?.array?.first?.string
        guard let bot = harness.store.botByThread(threadId) ?? member.flatMap({ harness.store.bot($0) }) else { return nil }
        let own = ModelSelection(json: bot["modelSelection"])
        return harness.fleet.get(own.instanceId) != nil ? own : nil
    }

    static func generate(harness: Harness, threadId: String, root: String) async throws -> String {
        let diff = try await GitDiff.diff(root: root, path: nil)
        guard !diff.diff.isEmpty || diff.binary else { throw HTTPError(400, "nothing to commit") }
        let state = await ThreadGit.inspect(folder: root)
        let files = (state?.changes ?? []).map(\.path)
        let recent = (await GitRun.text(["log", "-8", "--format=%s"], in: root) ?? "").split(separator: "\n").map(String.init)
        guard let selection = selection(harness: harness, threadId: threadId), let instance = harness.fleet.get(selection.instanceId) else {
            throw HTTPError(409, "no model is available to write the message: pick one in Settings › Plugins")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("swarme-commit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let callThread = "code-commit-\(UUID().uuidString)"
        var input = SendTurnInput(threadId: callThread, text: prompt(diff: diff.diff, files: files, recent: recent),
                                  model: selection.model, effort: selection.effort, system: system, cwd: scratch.path)
        input.sessionKey = callThread
        let bus = harness.bus
        let adapter = instance.adapter
        let reply: String = try await withCheckedThrowingContinuation { continuation in
            var done = false
            var text = ""
            var streamed = ""
            var unsubscribe: () -> Void = {}
            var timer: Task<Void, Never>?
            let finish: (Swift.Result<String, Error>) -> Void = { result in
                guard !done else { return }
                done = true
                timer?.cancel()
                unsubscribe()
                continuation.resume(with: result)
            }
            unsubscribe = bus.subscribe { event in
                guard event.threadId == callThread else { return }
                switch event.body {
                case let .textCompleted(reply): text += (text.isEmpty ? "" : "\n") + reply
                case let .contentDelta(kind, delta) where kind == "assistant_text": streamed += delta
                case .requestOpened:
                    // no tool for this: say no
                    if let id = event.requestId {
                        Task { _ = await adapter.respond(threadId: callThread, requestId: id, decision: RequestDecision(behavior: "deny", message: "No tools here: reply with the message only.")) }
                    }
                case let .runtimeError(message, _): finish(.failure(HTTPError(502, message)))
                case let .turnCompleted(ok, _, _, _, _):
                    let said = text.isEmpty ? streamed : text
                    finish(ok && !said.isEmpty ? .success(said) : .failure(HTTPError(502, "the model did not write a message")))
                default: break
                }
            }
            timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await adapter.interruptTurn(threadId: callThread)
                finish(.failure(HTTPError(504, "the model took too long to write the message")))
            }
            Task { @MainActor in
                do { _ = try await adapter.sendTurn(input) } catch { finish(.failure(error)) }
            }
        }
        let message = clean(reply)
        guard !message.isEmpty else { throw HTTPError(502, "the model did not write a message") }
        return message
    }
}
