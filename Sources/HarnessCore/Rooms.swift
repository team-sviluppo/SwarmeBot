// The room turn engine — `startGroupTurn` / `runGroupMemberTurn` of
// `server/index.ts`, with `room-cwd.ts`, `room-turn-timeout.ts` and
// `member-turn.ts`.
//
// A room message goes to the room's default responder unless the user
// @mentions members. Responders speak ONE AT A TIME (the transcript and the
// streaming bubble stay coherent), each on its own session with the recent
// room context. A member's reply may @mention teammates: those get one
// chained turn (hop 1), never deeper.
import Foundation

extension Harness {
    static let roomContextMessages = 30
    static let maxRoomHops = 1

    var userName: String {
        let name = config.json["profile"]?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "User" : name
    }

    func roomContext(_ threadId: String, userName: String? = nil) -> String {
        let human = userName ?? self.userName
        return sessionMessages(threadId).filter { $0["kind"]?.string == "text" && $0["queued"]?.bool != true && !($0["text"]?.string ?? "").isEmpty }
            .suffix(Self.roomContextMessages)
            .map { "\($0["role"]?.string == "user" ? human : ($0["from"]?["name"]?.string ?? "Bot")): \($0["text"]?.string ?? "")" }
            .joined(separator: "\n")
    }

    public func startGroupTurn(groupId: String, text: String) throws {
        guard let group = store.group(groupId), let threadId = group["threadId"]?.string else { throw TurnError(status: 404, message: "no such group") }
        guard !roomSessionResets.contains(groupId) else { throw TurnError(status: 409, message: "a new session is being prepared") }
        var message: JSONObject = ["role": "user", "kind": "text", "text": .string(text)]
        if roomIsBusy(groupId) { message["queued"] = true }
        let sent = store.appendMessage(threadId, message)
        // guests from other engines too (MixedRooms.swift)
        let members = roomMembers(group)
        var responders = PeerText.responders(text, members: members, policy: group["defaultResponder"])
        // bot⇄bot channels: chipping in untagged addresses the last speaker
        if responders.isEmpty, group["dm"]?.truthy == true {
            let lastSpeaker = store.messages(threadId).reversed().first { $0["kind"]?.string == "text" && $0["from"] != nil }?["from"]?["botId"]
            if let last = members.first(where: { $0["id"] == lastSpeaker }) ?? members.first { responders = [last] }
        }
        guard !responders.isEmpty else {
            if let id = sent["id"]?.string { _ = store.patchMessage(threadId, id, ["queued": .null]) }
            return
        }
        let ids = responders.compactMap { $0["id"]?.string }
        let previous = groupQueues[groupId]
        let queueId = UUID()
        let interruptEpoch = roomInterruptEpochs[groupId, default: 0]
        roomQueueIds[groupId] = queueId
        groupQueues[groupId] = Task { @MainActor in
            await previous?.value
            defer {
                if self.roomQueueIds[groupId] == queueId {
                    self.groupQueues[groupId] = nil
                    self.roomQueueIds[groupId] = nil
                }
            }
            if let id = sent["id"]?.string { _ = self.store.patchMessage(threadId, id, ["queued": .null]) }
            guard self.roomInterruptEpochs[groupId, default: 0] == interruptEpoch else { return }
            if let current = self.store.group(groupId), let busy = current["busyBotId"]?.string {
                let owner = self.store.bot(busy)?["name"]?.string ?? "A room member"
                self.store.appendMessage(threadId, ["role": "bot", "kind": "activity", "tool": [
                    "name": .string("\(owner) is still stopping — this message was not dispatched"), "ok": false,
                ]])
                return
            }
            var spoken = Set<String>()
            for id in ids where !spoken.contains(id) {
                guard self.roomInterruptEpochs[groupId, default: 0] == interruptEpoch else { break }
                if !(await self.runGroupMemberTurn(groupId: groupId, botId: id, hop: 0, spoken: &spoken)) { break }
            }
        }
    }

    /// One member speaks. False = the room is still owned by a turn that is
    /// stopping (timed out or stalled): nobody else may start on its thread.
    func runGroupMemberTurn(groupId: String, botId: String, hop: Int, spoken: inout Set<String>) async -> Bool {
        if GuestId.parse(botId) != nil { return await runPeerMemberTurn(groupId: groupId, memberId: botId, hop: hop, spoken: &spoken) }
        guard let group = store.group(groupId), let bot = store.bot(botId), let threadId = group["threadId"]?.string else { return false }
        let interruptEpoch = roomInterruptEpochs[groupId, default: 0]
        spoken.insert(botId)
        let name = bot["name"]?.string ?? ""
        let from = PeerText.from(bot)
        let chip = { (text: String) -> Void in
            _ = self.store.appendMessage(threadId, ["role": "bot", "kind": "activity", "from": from, "tool": ["name": .string(text), "ok": false]])
        }
        let selection = ModelSelection(json: bot["modelSelection"])
        guard let instance = fleet.get(selection.instanceId) else {
            chip("error: \(name)'s model is unavailable")
            return true
        }
        // one turn per bot at a time, across 1:1 and rooms
        if Store.isBusy(bot) {
            chip("\(name) is busy in another conversation — skipped this round")
            return true
        }
        if instance.driverKind == "deepseekHarness", !instance.models.options.contains(where: { $0.id == selection.model }) {
            chip("error: \(name)'s selected DeepSeek Harness model is no longer available. Refresh the catalog or choose another model")
            return true
        }
        if let effort = selection.effort,
           !(effortLevelsForModel(instance.models.options, model: selection.model, driverLevels: instance.adapter.capabilities.effortLevels) ?? []).contains(effort) {
            chip("error: effort \"\(effort)\" is not offered by this bot's engine — choose another level in settings")
            return true
        }
        store.setActivity(botId, "working")
        store.patchGroup(groupId, ["busyBotId": .string(botId)])
        groupSpeakers[threadId] = from.object

        let roster = roomRoster(group).joined(separator: ", ")
        let human = roomUserName(group)
        let about = (bot["description"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bulletin = (group["bulletin"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let system = [
            "You are \(name), a bot in the room \"\(group["name"]?.string ?? "")\" in SwarmeBot.",
            about.isEmpty ? nil : "About: \(about)",
            "Room members: \(roster), and \(human) (the human).",
            bulletin.isEmpty ? nil : "Room bulletin (shared instructions for everyone):\n\(bulletin)",
            "Reply as yourself, briefly and conversationally. To bring a teammate in, mention them like @Name — they'll see the conversation and respond.",
        ].compactMap { $0 }.joined(separator: "\n")
        var text = "\(roomContext(threadId, userName: human))\n\n(Reply to the conversation above as \(name).)"

        // same workspace and library as a 1:1 turn: a different conversation, not a
        // different bot. A room has no per-chat switches, so every ready document goes.
        let worksInWorkspace = instance.driverKind != "grok" && instance.driverKind != "boxAgent"
        var cwd: String?
        var roomSystem = system
        if worksInWorkspace {
            Workspace.ensure(paths, botId: botId)
            // the room's own folder is a shared desk, pinned on the first turn that
            // dispatches; an off-host member never decides that pin
            cwd = store.pinGroupCwd(groupId) ?? paths.workspace(botId).path
        }
        let library = self.library.prompt(botId, off: [], mode: Library.mode(instance.driverKind), message: roomContext(threadId, userName: human))
        if !library.isEmpty { roomSystem = "\(system)\n\n\(library)" }
        // skills, as in a 1:1 turn: the ones switched on by default, and a `/name` in the last message of the person,
        // for the member it was written to (not for one a teammate brings in)
        let skillful = skillSources.augment(bot)
        let said = sessionMessages(threadId).last { $0["role"]?.string == "user" && $0["kind"]?.string == "text" && $0["queued"]?.bool != true }?["text"]?.string ?? ""
        let invoked = hop == 0 ? Skills.invoked(said, bot: skillful) : []
        let available = Skills.active(bot: skillful, task: nil) { self.skills.skill($0) != nil }.filter { !invoked.contains($0) }
        let skillsPrompt = skills.prompt(available, mode: Library.mode(instance.driverKind))
        if !skillsPrompt.isEmpty { roomSystem += "\n\n\(skillsPrompt)" }
        text = skills.invocation(invoked, mode: Library.mode(instance.driverKind)) + text
        // each member brings its own secrets, as it brings its own connectors
        let secrets = turnSecrets(botId: botId, threadId: threadId, instance: instance, cwd: cwd, computerKind: nil)
        if !secrets.prompt.isEmpty { roomSystem += "\n\n\(secrets.prompt)" }

        let minutes = config.roomTurnTimeoutMinutes
        var replyText = ""
        enum Outcome { case settled, dispatchFailed, stalled, timedOut }
        let outcome: Outcome = await withCheckedContinuation { continuation in
            var done = false
            var unsubscribe: () -> Void = {}
            var timer: Task<Void, Never>?
            let finish: (Outcome) -> Void = { value in
                guard !done else { return }
                done = true
                timer?.cancel()
                unsubscribe()
                self.roomStallHandlers[threadId] = nil
                continuation.resume(returning: value)
            }
            unsubscribe = bus.subscribe { event in
                guard event.threadId == threadId else { return }
                if case let .textCompleted(reply) = event.body { replyText += "\n\(reply)" }
                if case .turnCompleted = event.body { finish(.settled) }
            }
            timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                Task { await instance.adapter.interruptTurn(threadId: threadId) }
                chip("\(name)'s room turn exceeded \(minutes) \(minutes == 1 ? "minute" : "minutes") and was stopped")
                finish(.timedOut)
            }
            roomStallHandlers[threadId] = { finish(.stalled) }
            watchdog.watch(threadId, botId: botId)
            var input = SendTurnInput(
                threadId: threadId, text: text,
                // a room copies the picker selection: without `model` Hermes hits
                // OpenRouter and Grok silently runs its cloud default
                model: selection.model, effort: selection.effort,
                resumeCursor: store.groupResumeCursor(groupId, botId: botId, instanceId: instance.instanceId),
                system: roomSystem, cwd: cwd, sessionKey: "\(threadId):\(botId)" + (group["sessionEpoch"]?.string.map { ":\($0)" } ?? "")
            )
            // a room has no per-chat switches: each member brings its own defaults
            input.connectors = mountConnectors(bot: bot, task: nil, threadId: threadId, mount: instance.adapter.capabilities.connectors)
            input.connectorGateway = connectorGateway(bot: bot, task: nil, instance: instance, model: selection.model)
            input.secrets = secrets.server
            input.secretEnvironment = secrets.environment
            var setup = TurnSetup(botId: botId, threadId: threadId, groupId: groupId, driverKind: instance.driverKind, bot: bot, group: group, cwd: cwd)
            plugins.beforeTurn(&setup)
            setup.apply(to: &input)
            readOnlyFolders[threadId] = setup.readOnlyFolders.isEmpty ? nil : setup.readOnlyFolders
            Task { @MainActor in
                do {
                    _ = try await instance.adapter.sendTurn(input)
                } catch {
                    chip("error: \(String(error.localizedDescription.prefix(140)))")
                    self.watchdog.settle(threadId)
                    finish(.dispatchFailed)
                }
            }
        }
        // a stopping provider still owns the room thread until it settles
        if outcome == .stalled || outcome == .timedOut { return false }
        // turn.completed normally cleans up; only when this turn still owns the room
        if store.group(groupId)?["busyBotId"]?.string == botId {
            groupSpeakers[threadId] = nil
            // a mirror room is read on its host, not here
            store.patchGroup(groupId, group["guest"] == nil ? ["busyBotId": .null, "unread": true] : ["busyBotId": .null])
            if Store.isBusy(store.bot(botId)) { store.setActivity(botId, "idle") }
        }

        // chained mentions: a member's reply can summon teammates, one hop only
        // (in a mirror room the host does that)
        guard roomInterruptEpochs[groupId, default: 0] == interruptEpoch else { return true }
        return await chainMentions(groupId: groupId, speakerId: botId, reply: replyText, hop: hop, spoken: &spoken)
    }

    public func interruptGroup(_ groupId: String) async -> Bool {
        guard let group = store.group(groupId), let threadId = group["threadId"]?.string else { return false }
        roomInterruptEpochs[groupId, default: 0] += 1
        await interruptPeerTurn(groupId)
        if let busy = group["busyBotId"]?.string, let bot = store.bot(busy) {
            await fleet.get(ModelSelection(json: bot["modelSelection"]).instanceId)?.adapter.interruptTurn(threadId: threadId)
        }
        closeOpenApprovals(threadId)
        return true
    }
}
