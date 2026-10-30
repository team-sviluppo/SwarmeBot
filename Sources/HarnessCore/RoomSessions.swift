import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Harness {
    static func afterSessionDivider(_ messages: [JSONObject]) -> [JSONObject] {
        guard let boundary = messages.lastIndex(where: { $0["sessionDivider"]?.bool == true }) else { return messages }
        return Array(messages.dropFirst(boundary + 1))
    }
    /// The visible history stays in the room; only messages after the divider enter a new session.
    func sessionMessages(_ threadId: String) -> [JSONObject] {
        Self.afterSessionDivider(store.messages(threadId))
    }

    func resetRoomSession(_ groupId: String, epoch: String, at: Double, summary: String? = nil) {
        guard let group = store.group(groupId), let thread = group["threadId"]?.string,
              group["sessionEpoch"]?.string != epoch else { return }
        if let previous = group["sessionStartedAt"]?.double, at <= previous { return }
        guard at.isFinite else { return }
        store.patchGroup(groupId, ["memberResumeCursors": [:], "sessionEpoch": .string(epoch), "sessionStartedAt": .number(at), "context": .null])
        store.appendMessage(thread, ["role": "bot", "kind": "activity", "text": "New session", "sessionDivider": true, "at": .number(at)])
        if let summary, !summary.isEmpty {
            store.appendMessage(thread, ["role": "bot", "kind": "text", "text": .string(summary)])
        }
    }

    /// A queued turn owns the room too, including the gaps between two members speaking.
    func roomIsBusy(_ groupId: String) -> Bool {
        store.group(groupId)?["busyBotId"]?.string != nil || groupQueues[groupId] != nil || roomSessionResets.contains(groupId)
    }

    public func newRoomSession(_ groupId: String, summarize: Bool) async throws -> JSONObject {
        guard let group = store.group(groupId) else { throw HTTPError(404, "no such room") }
        guard group["guest"] == nil else { throw HTTPError(409, "this channel is written from where it lives") }
        guard !roomIsBusy(groupId) else { throw HTTPError(409, "the channel is working — stop it before starting a new session") }
        roomSessionResets.insert(groupId)
        defer { roomSessionResets.remove(groupId) }
        var summary: String?
        if summarize {
            guard group["defaultResponder"]?["kind"]?.string == "member",
                  let botId = group["defaultResponder"]?["botId"]?.string else {
                throw HTTPError(409, "choose a default member to write the summary")
            }
            if let guest = GuestId.parse(botId) {
                guard let peer = peerEngines[guest.peer] else { throw HTTPError(409, "the default member's engine is unavailable") }
                var body = guestTurnBody(group, botId: guest.bot)
                body["summaryOnly"] = true
                switch await Self.callGuest(peer, body: body, timeout: 95, endpoint: "/api/guest-turns/summary") {
                case let .reply(text, _) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: summary = text
                case let .failed(message): throw HTTPError(502, message)
                default: throw HTTPError(502, "the default member did not return a summary")
                }
            } else {
                guard let bot = store.bot(botId) else { throw HTTPError(409, "the default member is unavailable") }
                let selection = ModelSelection(json: bot["modelSelection"])
                summary = try await generateText(selection: selection, system: Self.roomSummaryPrompt,
                    text: String(roomContext(group["threadId"]?.string ?? "").suffix(32_000)))
            }
        }
        // Nothing is changed if summary generation failed.
        guard store.group(groupId) != nil else { throw HTTPError(404, "no such room") }
        let epoch = UUID().uuidString.lowercased()
        let at = max((Date().timeIntervalSince1970 * 1000).rounded(), (group["sessionStartedAt"]?.double ?? 0) + 1)
        resetRoomSession(groupId, epoch: epoch, at: at, summary: summary)
        let peerIds = Set((group["guests"]?.array ?? []).compactMap { $0["peerId"]?.string })
        var pending: [JSON] = [], requests: [(String, URLRequest)] = []
        for peerId in peerIds {
            guard let peer = peerEngines[peerId], let url = URL(string: peer.url + "/api/guest-turns/session") else {
                pending.append(.string(peerId)); continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
            request.httpBody = JSON.object(["conversationId": .string(groupId), "sessionEpoch": .string(epoch), "startedAt": .number(at),
                                            "summary": summary.map(JSON.string) ?? .null]).data
            requests.append((peerId, request))
        }
        let failed = await withTaskGroup(of: String?.self, returning: [String].self) { tasks in
            for (id, request) in requests {
                tasks.addTask {
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        return (response as? HTTPURLResponse)?.statusCode == 200 ? nil : id
                    } catch { return id }
                }
            }
            var failed: [String] = []
            for await result in tasks { if let result { failed.append(result) } }
            return failed
        }
        pending += failed.sorted().map(JSON.string)
        // The epoch also travels with every later guest turn, so an offline peer catches up before speaking.
        return ["ok": true, "pendingPeers": .array(pending)]
    }

    static let roomSummaryPrompt = "Summarize this channel for a fresh session. Include the current work, decisions, relevant files and next steps. Be brief. Reply in the conversation's language. Do not use tools."

    func resetGuestSession(_ body: JSONObject, deviceId: String) -> HTTPResponse {
        guard let epoch = body["sessionEpoch"]?.string, !epoch.isEmpty, epoch.count <= 100 else { return .error(400, "sessionEpoch required") }
        guard let group = mirrorRoom(deviceId: deviceId, conversationId: body["conversationId"]?.string ?? ""),
              let id = group["id"]?.string else { return .json(200, ["ok": true]) }
        guard !roomIsBusy(id) else { return .error(409, "the channel is busy") }
        resetRoomSession(id, epoch: epoch, at: body["startedAt"]?.double ?? Date().timeIntervalSince1970 * 1000,
                         summary: body["summary"]?.string.map { String($0.prefix(20_000)) })
        return .json(200, ["ok": true])
    }

    func compactTask(botId: String, thread: String) async throws {
        guard let bot = store.bot(botId), store.taskByThread(botId, thread) != nil else { throw HTTPError(404, "no such task") }
        guard !Store.isBusy(bot), !taskSessionResets.contains(thread), routines?.isActiveThread(thread) != true else { throw HTTPError(409, "the bot is working") }
        taskSessionResets.insert(thread)
        defer { taskSessionResets.remove(thread) }
        let transcript = Self.afterSessionDivider(store.activePath(thread)).filter { $0["kind"] == "text" }
            .map { "\($0["role"]?.string ?? ""): \($0["text"]?.string ?? "")" }.joined(separator: "\n\n")
        guard !transcript.isEmpty else { throw HTTPError(400, "the chat is empty") }
        let summary = try await generateText(selection: ModelSelection(json: bot["modelSelection"]),
            system: "Summarize this conversation for a fresh session of the same agent. Preserve current work, decisions, relevant files and next steps. Be brief. Use the conversation's language. Do not use tools.",
            text: String(transcript.suffix(32_000)))
        guard store.taskByThread(botId, thread) != nil else { throw HTTPError(404, "no such task") }
        store.resetTaskSession(botId, thread, epoch: UUID().uuidString.lowercased())
        store.appendMessage(thread, ["role": "bot", "kind": "activity", "text": "New session", "sessionDivider": true])
        // A user history entry makes every driver load this summary when it starts without a resume cursor.
        store.appendMessage(thread, ["role": "user", "kind": "text", "text": .string("[Summary of the previous session]\n" + summary)])
    }
}
