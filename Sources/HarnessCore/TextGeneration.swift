import Foundation

extension Harness {
    /// An isolated text call: no transcript, workspace, connectors or tools from the bot's turn.
    func generateText(selection: ModelSelection, system: String, text: String) async throws -> String {
        guard let instance = fleet.get(selection.instanceId) else { throw HTTPError(409, "the selected model is unavailable") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sw-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let thread = "text-\(UUID().uuidString)", adapter = instance.adapter
        let input = SendTurnInput(threadId: thread, text: text, model: selection.model, effort: selection.effort,
                                  system: system, cwd: scratch.path, sessionKey: thread)
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false, completed = "", streamed = ""
            var unsubscribe: () -> Void = {}
            var timer: Task<Void, Never>?
            let finish: (Result<String, Error>) -> Void = { result in
                guard !finished else { return }
                finished = true
                timer?.cancel()
                unsubscribe()
                continuation.resume(with: result)
            }
            unsubscribe = bus.subscribe { event in
                guard event.threadId == thread else { return }
                switch event.body {
                case let .textCompleted(text): completed += text + "\n"
                case let .contentDelta(kind, delta) where kind == "assistant_text": streamed += delta
                case .requestOpened:
                    if let id = event.requestId {
                        Task { _ = await adapter.respond(threadId: thread, requestId: id, decision: RequestDecision(behavior: "deny", message: "No tools: return text only.")) }
                    }
                case let .runtimeError(message, _): finish(.failure(HTTPError(502, message)))
                case let .turnCompleted(ok, _, _, _, _):
                    let answer = (completed.isEmpty ? streamed : completed).trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(ok && !answer.isEmpty ? .success(answer) : .failure(HTTPError(502, "the model did not return text")))
                default: break
                }
            }
            timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                guard !Task.isCancelled else { return }
                finish(.failure(HTTPError(504, "the model took too long")))
                await adapter.interruptTurn(threadId: thread)
            }
            Task { @MainActor in
                do { _ = try await adapter.sendTurn(input) } catch { finish(.failure(error)) }
            }
        }
    }
}
