// A synthetic thread for measuring the transcript (risk R1 in the plan):
// thousands of messages with the mix a real computer-use thread has —
// markdown replies, fenced code, tool chips, cards. No harness involved, so
// the numbers are the UI's alone.
import CompanionCore
import Foundation

extension AppModel {
    public static let benchmarkBotId = "bench-bot"

    public func installBenchmark(messages count: Int) {
        let threadId = "bench-thread"
        var messages: [[String: Any]] = []
        var parent: String?
        let start = Date().addingTimeInterval(-Double(count) * 60).timeIntervalSince1970 * 1000
        for index in 0..<count {
            var message: [String: Any] = ["id": "m\(index)", "at": start + Double(index) * 60_000]
            if let parent { message["parentId"] = parent }
            switch index % 10 {
            case 0, 5:
                message.merge(["role": "user", "kind": "text",
                               "text": "Messaggio \(index): controlla il servizio e dimmi se il deploy ha funzionato."]) { $1 }
            case 1, 6, 8:
                message.merge(["role": "bot", "kind": "activity",
                               "tool": ["name": "Bash(kubectl get pods -n prod)", "ok": index % 3 != 0]]) { $1 }
            case 9:
                message.merge(["role": "bot", "kind": "options",
                               "card": ["title": "Eseguire il comando?", "subtitle": "git push origin main",
                                        "options": ["Allow", "Deny"], "answered": "allow", "requestId": "r\(index)",
                                        "tool": "Bash", "allowKey": "Bash:git"]]) { $1 }
            default:
                message.merge(["role": "bot", "kind": "text", "text": Self.reply(index)]) { $1 }
            }
            messages.append(message)
            parent = message["id"] as? String
        }
        let bot: [String: Any] = [
            "id": Self.benchmarkBotId, "threadId": threadId, "name": "Benchmark", "title": "R1", "description": "",
            "notifications": false, "color": "blue", "unread": false,
            "modelSelection": ["instanceId": "", "model": ""], "createdAt": start,
            "activeLeafId": parent ?? "", "messages": messages,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: ["bots": [bot], "groups": []]),
              let fleet = try? JSONDecoder().decode(Fleet.self, from: data)
        else { return }
        state.hydrate(fleet)
        stateDidChange()
        status = .live
        selection = .bot(Self.benchmarkBotId)
    }

    /// One more settled reply, as a stream would deliver it.
    public func appendBenchmarkMessage(_ index: Int) {
        let threadId = "bench-thread"
        var message: [String: Any] = [
            "id": "live\(index)", "role": "bot", "kind": "text",
            "at": Date().timeIntervalSince1970 * 1000, "text": Self.reply(index),
        ]
        if let parent = state.transcript(forThread: threadId).last?.id { message["parentId"] = parent }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let decoded = try? JSONDecoder().decode(Message.self, from: data)
        else { return }
        state.apply(.message(threadId: threadId, message: decoded))
        live.clear(threadId)
        stateDidChange()
    }

    /// Token-by-token text, as `content.delta` would grow it.
    public func streamBenchmarkDelta(_ text: String) {
        live.append(text, to: "bench-thread")
    }

    private static func reply(_ index: Int) -> String {
        """
        ## Stato del deploy \(index)

        Ho controllato i **pod** in `prod`: tutti *Running* tranne uno, che è in `CrashLoopBackOff`.

        - api-7f9c: ok
        - worker-2b1d: ok
        - scheduler-91aa: **riavvii: 14**

        ```bash
        kubectl logs scheduler-91aa -n prod --previous | tail -n 20
        kubectl describe pod scheduler-91aa -n prod
        ```

        > Il crash coincide con la rotazione dei segreti delle 03:00.

        Vuoi che riavvii il deployment? Vedi [la guida](https://example.com/runbook).
        """
    }
}
