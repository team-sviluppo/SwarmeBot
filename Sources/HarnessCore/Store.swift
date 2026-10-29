// Bots, rooms and transcripts — `server/store.ts`.
//
// Records are JSON objects, never structs: a field this engine does not know
// (written by the Node engine or a newer build) must survive every write.
// Every mutation persists, then emits a `StoreChange`; the server turns those
// into SSE frames in one place, so no path can write without the app hearing.
import Foundation

public enum StoreChange {
    case message(threadId: String, message: JSONObject)
    case messagePatch(threadId: String, message: JSONObject)
    case thread(threadId: String, activeLeafId: String)
    case bot(botId: String)
    case botDeleted(botId: String)
    case group(groupId: String)
    case groupDeleted(groupId: String)
}

public let untitledTask = "Nuova chat"
let legacyUntitledTask = "New task"
public let busyActivities: Set<String> = ["working", "waiting-on-you", "no-signal"]

public func titleFromMessage(_ text: String) -> String {
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?
        .trimmingCharacters(in: .whitespaces) ?? ""
    if line.count > 48 { return String(line.prefix(47)) + "…" }
    return line.isEmpty ? untitledTask : line
}

@MainActor
public final class Store {
    public private(set) var bots: [JSONObject] = []
    public private(set) var groups: [JSONObject] = []
    private var threads: [String: (messages: [JSONObject], activeLeafId: String?)] = [:]
    private var listeners: [(StoreChange) -> Void] = []
    private let paths: DataPaths
    private let db: MessageDB
    public var defaultSelection: () -> ModelSelection = { ModelSelection(instanceId: "", model: "") }
    /// Known secret values out of every stored message (the vault's masking).
    public var maskSecrets: ((JSONObject) -> JSONObject)?

    static let colors = ["green", "blue", "red", "orange", "purple", "cyan", "pink", "yellow", "teal", "coral"]
    static let names = [
        "Scout", "Pixel", "Atlas", "Nova", "Juno", "Koda", "Miso", "Mochi", "Biscuit", "Pepper", "Clover", "Ember",
        "Willow", "Comet", "Orbit", "Echo", "Indigo", "Sage", "Zephyr", "Poppy", "Maple", "Cosmo", "Luna", "Otto",
        "Ivy", "Finch", "Wren", "Basil", "Hazel", "Nimbus", "Onyx", "Pearl", "Quill", "Rocket", "Sunny", "Tango",
        "Vega", "Waffle", "Ziggy", "Noodle", "Pickle", "Churro", "Panko", "Dumpling", "Pesto", "Olive", "Cocoa", "Taffy",
        "Bramble", "Fig", "Juniper", "Moss", "Pebble", "Rio", "Skye", "Tuli", "Ursa", "Yuki", "Zuko", "Momo",
        "Kiwi", "Plum", "Sprout", "Turnip",
    ]

    public init(paths: DataPaths) throws {
        self.paths = paths
        paths.ensure()
        db = try MessageDB(file: paths.messagesDB)
        bots = FileIO.readJSON(paths.bots)?.array?.compactMap(\.object) ?? []
        groups = FileIO.readJSON(paths.groups)?.array?.compactMap(\.object) ?? []

        // transient state never survives a restart
        var botsMigrated = false
        for index in bots.indices {
            let activity = bots[index]["activity"]?.string
            if bots[index]["busy"]?.truthy == true || (activity != nil && activity != "idle") { botsMigrated = true }
            bots[index]["busy"] = false
            bots[index]["activity"] = "idle"
            if var tasks = bots[index]["tasks"]?.array, tasks.contains(where: { $0["title"]?.string == legacyUntitledTask }) {
                for t in tasks.indices where tasks[t]["title"]?.string == legacyUntitledTask {
                    tasks[t]["title"] = .string(untitledTask)
                }
                bots[index]["tasks"] = .array(tasks)
                botsMigrated = true
            }
            if let backend = bots[index]["cloudBackend"]?.string, backend != "box", backend != "vps" {
                bots[index]["cloudBackend"] = nil
                botsMigrated = true
            }
            let computer = bots[index]["computer"]?.string
            if computer != "vm", computer != "off" {
                bots[index]["computer"] = "off"
                botsMigrated = true
            }
        }
        var chiefSeen = false
        for index in bots.indices where bots[index]["chiefOfStaff"]?.truthy == true {
            if !chiefSeen {
                chiefSeen = true
                if bots[index]["hidden"]?.truthy == true { bots[index]["hidden"] = false; botsMigrated = true }
            } else {
                bots[index]["chiefOfStaff"] = false
                botsMigrated = true
            }
        }
        for index in groups.indices {
            groups[index]["busyBotId"] = nil
            let members = Self.responderIds(groups[index])
            groups[index]["defaultResponder"] = Self.normalizeResponder(
                groups[index]["defaultResponder"], members: members, dm: groups[index]["dm"]?.truthy == true
            )
        }
        if botsMigrated { saveBots() }
        // bots from before tasks existed adopt their one thread as a task
        for index in bots.indices where (bots[index]["tasks"]?.array ?? []).isEmpty {
            let threadId = bots[index]["threadId"]?.string ?? newId()
            bots[index]["tasks"] = .array([[
                "threadId": .string(threadId),
                "title": .string(firstUserLine(threadId) ?? untitledTask),
                "createdAt": bots[index]["createdAt"] ?? .number(nowMillis()),
                "resumeCursors": bots[index]["resumeCursors"] ?? [:],
            ]])
        }
    }

    // MARK: Persistence and changes

    private func saveBots() {
        try? FileIO.writeAtomic(Data(JSON.array(bots.map(JSON.object)).pretty().utf8), to: paths.bots)
    }

    private func saveGroups() {
        let persisted = groups.map { JSON.object($0.removing("busyBotId")) }
        try? FileIO.writeAtomic(Data(JSON.array(persisted).pretty().utf8), to: paths.groups)
    }

    public func onChange(_ listener: @escaping (StoreChange) -> Void) {
        listeners.append(listener)
    }

    private func emit(_ change: StoreChange) {
        for listener in listeners { listener(change) }
    }

    // MARK: Lookups

    public func bot(_ id: String) -> JSONObject? { bots.first { $0["id"]?.string == id } }

    public func botByThread(_ threadId: String) -> JSONObject? {
        bots.first { bot in
            bot["threadId"]?.string == threadId || (bot["tasks"]?.array ?? []).contains { $0["threadId"]?.string == threadId }
        }
    }

    public func group(_ id: String) -> JSONObject? { groups.first { $0["id"]?.string == id } }

    public func groupByThread(_ threadId: String) -> JSONObject? { groups.first { $0["threadId"]?.string == threadId } }

    private func botIndex(_ id: String) -> Int? { bots.firstIndex { $0["id"]?.string == id } }
    private func groupIndex(_ id: String) -> Int? { groups.firstIndex { $0["id"]?.string == id } }

    nonisolated public static func isBusy(_ bot: JSONObject?) -> Bool { bot?["busy"]?.truthy == true }

    // MARK: Threads

    private func thread(_ threadId: String) -> (messages: [JSONObject], activeLeafId: String?) {
        if let cached = threads[threadId] { return cached }
        var (messages, leaf) = db.readThread(threadId, legacyFile: paths.legacyMessages(threadId))
        // legacy rows carry no parentId: chain them in order
        var previous: String?
        for index in messages.indices {
            if messages[index]["parentId"] == nil { messages[index]["parentId"] = JSON.from(previous) }
            previous = messages[index]["id"]?.string
        }
        if leaf == nil { leaf = messages.last?["id"]?.string }
        threads[threadId] = (messages, leaf)
        return (messages, leaf)
    }

    public func messages(_ threadId: String) -> [JSONObject] { thread(threadId).messages }

    public func activeLeaf(_ threadId: String) -> String? { thread(threadId).activeLeafId }

    /// The visible conversation: root → active leaf.
    public func activePath(_ threadId: String) -> [JSONObject] {
        let t = thread(threadId)
        var byId: [String: JSONObject] = [:]
        for message in t.messages { if let id = message["id"]?.string { byId[id] = message } }
        var path: [JSONObject] = []
        var visited = Set<String>()
        var current = t.activeLeafId.flatMap { byId[$0] }
        while let message = current, let id = message["id"]?.string, visited.insert(id).inserted {
            path.append(message)
            current = message["parentId"]?.string.flatMap { byId[$0] }
        }
        return path.reversed()
    }

    /// Everything the bot authored is scrubbed before it is stored.
    static func redactBotAuthored(_ message: JSONObject) -> JSONObject {
        guard message["role"]?.string == "bot" else { return message }
        var out = message
        if let text = out["text"]?.string { out["text"] = .string(Redact.text(text)) }
        if var tool = out["tool"]?.object, let name = tool["name"]?.string {
            tool["name"] = .string(Redact.text(name))
            out["tool"] = .object(tool)
        }
        if var card = out["card"]?.object {
            for field in ["title", "subtitle", "summary"] {
                if let value = card[field]?.string { card[field] = .string(Redact.text(value)) }
            }
            out["card"] = .object(card)
        }
        return out
    }

    /// Append to the active branch. `message` carries role/kind and content;
    /// id, at and parentId are assigned here (in that key order, like Node).
    @discardableResult
    public func appendMessage(_ threadId: String, _ message: JSONObject) -> JSONObject {
        var t = thread(threadId)
        var full = JSONObject([
            ("id", .string(newId())),
            ("at", message["at"] ?? .number(nowMillis())),
            ("parentId", JSON.from(t.activeLeafId)),
        ])
        // the vault's names first: «secret GITHUB_TOKEN» says more than «redacted»
        let content = message.removing("at")
        full = full.merging(Self.redactBotAuthored(maskSecrets?(content) ?? content))
        t.messages.append(full)
        t.activeLeafId = full["id"]?.string
        if full["kind"]?.string == "screen" {
            // keep the pixels of the newest few frames only
            var seen = 0
            for index in t.messages.indices.reversed() where t.messages[index]["kind"]?.string == "screen" && t.messages[index]["png"] != nil {
                seen += 1
                if seen > 4 {
                    t.messages[index]["png"] = nil
                    db.update(threadId, t.messages[index])
                    emit(.messagePatch(threadId: threadId, message: t.messages[index]))
                }
            }
        }
        threads[threadId] = t
        db.append(threadId, full)
        emit(.message(threadId: threadId, message: full))
        return full
    }

    /// A new user message replacing `sourceId` (same parent): a fork.
    public func branchMessage(_ threadId: String, sourceId: String, text: String) -> JSONObject? {
        var t = thread(threadId)
        guard let source = t.messages.first(where: { $0["id"]?.string == sourceId }) else { return nil }
        let full = JSONObject([
            ("id", .string(newId())), ("at", .number(nowMillis())), ("role", "user"), ("kind", "text"),
            ("text", .string(text)), ("parentId", source["parentId"] ?? .null),
        ])
        t.messages.append(full)
        t.activeLeafId = full["id"]?.string
        threads[threadId] = t
        db.append(threadId, full)
        emit(.message(threadId: threadId, message: full))
        return full
    }

    /// Show the branch containing `messageId`, down to its newest leaf.
    public func setActiveLeaf(_ threadId: String, messageId: String) -> String? {
        var t = thread(threadId)
        guard t.messages.contains(where: { $0["id"]?.string == messageId }) else { return nil }
        var current = messageId
        while true {
            let children = t.messages.filter { $0["parentId"]?.string == current }
            guard let newest = children.max(by: { ($0["at"]?.double ?? 0) < ($1["at"]?.double ?? 0) }),
                  let id = newest["id"]?.string else { break }
            current = id
        }
        t.activeLeafId = current
        threads[threadId] = t
        db.setActiveLeaf(threadId, current)
        emit(.thread(threadId: threadId, activeLeafId: current))
        return current
    }

    @discardableResult
    public func patchMessage(_ threadId: String, _ messageId: String, _ patch: JSONObject) -> JSONObject? {
        var t = thread(threadId)
        guard let index = t.messages.firstIndex(where: { $0["id"]?.string == messageId }) else { return nil }
        var merged = t.messages[index]
        for (key, value) in maskSecrets?(patch) ?? patch {
            // `{ ...m, ...patch }`, with JSON null standing in for undefined
            if value.isNull && key != "parentId" { merged[key] = Optional<JSON>.none } else { merged[key] = value }
        }
        t.messages[index] = merged
        threads[threadId] = t
        db.update(threadId, merged)
        emit(.messagePatch(threadId: threadId, message: merged))
        return merged
    }

    public func toggleReaction(_ threadId: String, _ messageId: String, emoji: String, by: String) -> JSONObject? {
        guard let existing = messages(threadId).first(where: { $0["id"]?.string == messageId }) else { return nil }
        var reactions = existing["reactions"]?.array ?? []
        if let at = reactions.firstIndex(where: { $0["emoji"]?.string == emoji && $0["by"]?.string == by }) {
            reactions.remove(at: at)
        } else {
            reactions.append(["emoji": .string(emoji), "by": .string(by)])
        }
        return patchMessage(threadId, messageId, ["reactions": reactions.isEmpty ? .null : .array(reactions)])
    }

    private func deleteThreadRecord(_ threadId: String) {
        threads[threadId] = nil
        db.deleteThread(threadId)
        let legacy = paths.legacyMessages(threadId)
        try? FileManager.default.removeItem(at: legacy)
        try? FileManager.default.removeItem(at: legacy.appendingPathExtension("imported"))
    }

    public func search(_ query: String, limit: Int) -> [JSONObject] { db.search(query, limit: limit) }

    // MARK: Bots

    private func firstUserLine(_ threadId: String) -> String? {
        let first = messages(threadId).first {
            $0["role"]?.string == "user" && $0["kind"]?.string == "text" && !($0["text"]?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        return first?["text"]?.string.map(titleFromMessage)
    }

    func pickName() -> String {
        let used = Set(bots.compactMap { $0["name"]?.string?.trimmingCharacters(in: .whitespaces).lowercased() })
        let free = Self.names.filter { !used.contains($0.lowercased()) }
        if let name = free.randomElement() { return name }
        let base = Self.names.randomElement()!
        var index = 2
        while used.contains("\(base.lowercased()) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    @discardableResult
    public func createBot(profile: JSONObject = JSONObject(), seedMessages: Bool = true) -> JSONObject {
        let trimmed = profile["name"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = trimmed.isEmpty ? pickName() : trimmed
        let threadId = newId()
        let createdAt = nowMillis()
        var bot = JSONObject([
            ("id", .string(newId())), ("threadId", .string(threadId)), ("name", .string(name)),
            ("title", profile["title"] ?? ""), ("description", profile["description"] ?? ""),
            ("notifications", true), ("color", profile["color"] ?? .string(Self.colors[bots.count % Self.colors.count])),
        ])
        for key in ["mascotExpression", "mascotSilhouette", "mascotAvatarSvg"] where profile[key]?.truthy == true {
            bot[key] = profile[key]
        }
        bot["unread"] = false
        bot["computer"] = "off"
        bot["modelSelection"] = profile["modelSelection"] ?? defaultSelection().json
        bot["resumeCursors"] = [:]
        bot["createdAt"] = .number(createdAt)
        bot["tasks"] = .array([["threadId": .string(threadId), "title": .string(untitledTask),
                                "createdAt": .number(createdAt), "resumeCursors": [:]]])
        bots.insert(bot, at: 0)
        saveBots()
        emit(.bot(botId: bot["id"]!.string!))
        if seedMessages {
            appendMessage(threadId, ["role": "bot", "kind": "text", "text": .string("Hey — I'm \(name). Nice to meet you.")])
            appendMessage(threadId, ["role": "bot", "kind": "options", "card": [
                "title": "What do you mostly want help with?",
                "subtitle": "Pick whatever's closest; we can always expand from there.",
                "options": ["Work & projects", "Writing & research", "Life admin", "A bit of everything"],
            ]])
        }
        return bot
    }

    public func deleteBot(_ id: String) -> Bool {
        guard let bot = bot(id) else { return false }
        bots.removeAll { $0["id"]?.string == id }
        var threadIds = Set([bot["threadId"]?.string].compactMap { $0 })
        for task in bot["tasks"]?.array ?? [] { if let thread = task["threadId"]?.string { threadIds.insert(thread) } }
        threadIds.forEach(deleteThreadRecord)
        try? FileManager.default.removeItem(at: paths.workspace(id))
        saveBots()
        emit(.botDeleted(botId: id))
        return true
    }

    @discardableResult
    /// `keepingNulls`: keys whose JSON null is written as a value — Node's `Object.assign`
    /// with a real `null`, which a client merging bot frames needs to clear a field.
    public func patchBot(_ id: String, _ patch: JSONObject, keepingNulls: Set<String> = []) -> JSONObject? {
        guard let index = botIndex(id) else { return nil }
        for (key, value) in patch { if value.isNull && !keepingNulls.contains(key) { bots[index][key] = Optional<JSON>.none } else { bots[index][key] = value } }
        saveBots()
        emit(.bot(botId: id))
        return bots[index]
    }

    /// The one way runtime state changes; `busy` is derived from it.
    @discardableResult
    public func setActivity(_ botId: String, _ activity: String) -> JSONObject? {
        guard let index = botIndex(botId) else { return nil }
        let busy = busyActivities.contains(activity)
        if bots[index]["activity"]?.string == activity, bots[index]["busy"]?.truthy == busy { return bots[index] }
        bots[index]["activity"] = .string(activity)
        bots[index]["busy"] = .bool(busy)
        saveBots()
        emit(.bot(botId: botId))
        return bots[index]
    }

    // MARK: Tasks

    public func tasks(_ botId: String) -> [JSONObject] { bot(botId)?["tasks"]?.array?.compactMap(\.object) ?? [] }

    public func taskByThread(_ botId: String, _ threadId: String) -> JSONObject? {
        tasks(botId).first { $0["threadId"]?.string == threadId }
    }

    private func updateTask(_ botId: String, _ threadId: String, save: Bool = true, _ change: (inout JSONObject) -> Void) -> JSONObject? {
        guard let index = botIndex(botId) else { return nil }
        var tasks = bots[index]["tasks"]?.array ?? []
        guard let at = tasks.firstIndex(where: { $0["threadId"]?.string == threadId }), var task = tasks[at].object else { return nil }
        change(&task)
        tasks[at] = .object(task)
        bots[index]["tasks"] = .array(tasks)
        if save {
            saveBots()
            emit(.bot(botId: botId))
        }
        return task
    }

    public func setResumeCursor(_ botId: String, instanceId: String, cursor: JSON, threadId: String?) {
        guard let index = botIndex(botId) else { return }
        let target = threadId ?? bots[index]["threadId"]?.string ?? ""
        _ = updateTask(botId, target, save: false) { task in
            var cursors = task["resumeCursors"]?.object ?? JSONObject()
            cursors[instanceId] = cursor
            task["resumeCursors"] = .object(cursors)
        }
        if threadId == nil || bots[index]["threadId"]?.string == threadId {
            var cursors = bots[index]["resumeCursors"]?.object ?? JSONObject()
            cursors[instanceId] = cursor
            bots[index]["resumeCursors"] = .object(cursors)
        }
        saveBots()
        emit(.bot(botId: botId))
    }

    public func markTaskDispatched(_ botId: String, _ threadId: String, instanceId: String) {
        guard taskByThread(botId, threadId)?["lastInstanceId"]?.string != instanceId else { return }
        _ = updateTask(botId, threadId, save: false) { $0["lastInstanceId"] = .string(instanceId) }
        saveBots()
    }

    /// `timedTokens` is the output used for tok/s. It matches `output` when the
    /// provider reported a count; otherwise it is a text estimate and is not
    /// added to the token total.
    public func addTaskUsage(_ botId: String, _ threadId: String, input: Double?, output: Double?, costUsd: Double?, generationSeconds: Double? = nil, timedTokens: Double? = nil, costEstimated: Bool = false) {
        _ = updateTask(botId, threadId) { task in
            let previous = task["usage"]?.object ?? JSONObject()
            func clean(_ value: Double?) -> Double { value.map { $0.isFinite ? max(0, $0.rounded(.towardZero)) : 0 } ?? 0 }
            let prevCost = previous["costUsd"]?.double
            let cost = costUsd.flatMap { $0.isFinite ? $0 : nil }
            let addedOutput = clean(output)
            let seconds = generationSeconds.flatMap { $0.isFinite && $0 >= 0.2 ? $0 : nil }
            let counted = timedTokens.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let timed = counted != nil && seconds != nil
            let fromText = timed && addedOutput <= 0
            task["usage"] = [
                "input": .number((previous["input"]?.double ?? 0) + clean(input)),
                "output": .number((previous["output"]?.double ?? 0) + addedOutput),
                "costUsd": cost == nil ? JSON.from(prevCost) : .number((prevCost ?? 0) + cost!),
                "turns": .number((previous["turns"]?.double ?? 0) + 1),
                "timedOutput": .number((previous["timedOutput"]?.double ?? 0) + (timed ? counted ?? 0 : 0)),
                "estimatedOutput": .number((previous["estimatedOutput"]?.double ?? 0) + (fromText ? counted ?? 0 : 0)),
                "generationSeconds": .number((previous["generationSeconds"]?.double ?? 0) + (timed ? seconds ?? 0 : 0)),
            ]
            if previous["costEstimated"]?.bool == true || (cost != nil && costEstimated) {
                task["usage"]?["costEstimated"] = true
            }
        }
    }

    /// The folder a task's turns run in, pinned on first use.
    ///
    /// A folder that was moved or deleted is dropped for `fallback` (the
    /// bot's workspace), on the task and as the bot's default: otherwise
    /// every turn fails to spawn and no chat of that bot can recover.
    public func pinTaskCwd(_ botId: String, _ threadId: String, fallback: String?) -> String? {
        guard let bot = bot(botId), let task = taskByThread(botId, threadId) else { return nil }
        if let path = bot["cwd"]?.string, !Self.isDirectory(path), let index = botIndex(botId) {
            bots[index]["cwd"] = nil
            saveBots()
            emit(.bot(botId: botId))
        }
        if let path = task["cwd"]?.string, !Self.isDirectory(path) {
            _ = updateTask(botId, threadId) { $0["cwd"] = JSON.from(fallback) }
            return fallback
        }
        if let pinned = task["cwd"] { return pinned.string }
        let hasSession = !(task["resumeCursors"]?.object?.isEmpty ?? true)
        let value: JSON = hasSession ? .null : (self.bot(botId)?["cwd"] ?? JSON.from(fallback))
        _ = updateTask(botId, threadId) { $0["cwd"] = value }
        return value.string
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    @discardableResult
    public func createTask(_ botId: String, title: String?, activate: Bool = true) -> JSONObject? {
        guard let index = botIndex(botId) else { return nil }
        let trimmed = title?.trimmingCharacters(in: .whitespaces) ?? ""
        let task = JSONObject([
            ("threadId", .string(newId())), ("title", .string(trimmed.isEmpty ? untitledTask : trimmed)),
            ("createdAt", .number(nowMillis())), ("resumeCursors", [:]),
        ])
        bots[index]["tasks"] = .array([.object(task)] + (bots[index]["tasks"]?.array ?? []))
        if activate {
            bots[index]["threadId"] = task["threadId"]
            bots[index]["resumeCursors"] = [:]
        }
        saveBots()
        emit(.bot(botId: botId))
        return task
    }

    public func switchTask(_ botId: String, _ threadId: String) -> JSONObject? {
        guard let index = botIndex(botId), let task = taskByThread(botId, threadId) else { return nil }
        bots[index]["threadId"] = .string(threadId)
        bots[index]["resumeCursors"] = task["resumeCursors"] ?? [:]
        saveBots()
        emit(.bot(botId: botId))
        return bots[index]
    }

    public func renameTask(_ botId: String, _ threadId: String, title: String) -> JSONObject? {
        let trimmed = String(title.trimmingCharacters(in: .whitespaces).prefix(80))
        return updateTask(botId, threadId) { $0["title"] = .string(trimmed.isEmpty ? untitledTask : trimmed) }
    }

    public func setTaskPinned(_ botId: String, _ threadId: String, pinned: Bool) -> JSONObject? {
        updateTask(botId, threadId) { $0["pinned"] = pinned ? .bool(true) : nil }
    }

    /// The folder this task's turns run in. Empty clears the pin so the next
    /// turn falls back to the bot default.
    public func setTaskCwd(_ botId: String, _ threadId: String, cwd: String?) -> JSONObject? {
        updateTask(botId, threadId) { task in
            if let cwd, !cwd.isEmpty { task["cwd"] = .string(cwd) } else { task["cwd"] = .null }
        }
    }

    /// Library documents this chat leaves out; every other ready one goes.
    public func setTaskLibraryOff(_ botId: String, _ threadId: String, _ off: [String]) -> JSONObject? {
        updateTask(botId, threadId) { $0["libraryOff"] = off.isEmpty ? nil : .strings(off) }
    }

    /// Per-conversation connector switches: only the choices that differ
    /// from the bot's defaults (docs/plans/2026-10-15-connettori-mcp.md §2.3).
    @discardableResult
    public func setTaskConnectors(_ botId: String, _ threadId: String, _ overrides: [String: Bool]) -> JSONObject? {
        updateTask(botId, threadId) { task in
            var map = JSONObject()
            for (id, on) in overrides.sorted(by: { $0.key < $1.key }) { map[id] = .bool(on) }
            // explicit Optional: a bare nil here would be JSON null, not a removal
            task["connectors"] = map.isEmpty ? Optional<JSON>.none : .object(map)
        }
    }

    /// Per-conversation skill switches, like the connectors': only the
    /// choices that differ from the bot's defaults.
    @discardableResult
    public func setTaskSkills(_ botId: String, _ threadId: String, _ overrides: [String: Bool]) -> JSONObject? {
        updateTask(botId, threadId) { task in
            var map = JSONObject()
            for (id, on) in overrides.sorted(by: { $0.key < $1.key }) { map[id] = .bool(on) }
            task["skills"] = map.isEmpty ? Optional<JSON>.none : .object(map)
        }
    }

    /// A deleted connector leaves no trace on bots or their conversations.
    public func forgetConnector(_ id: String) { forget("connectors", id) }

    /// Nor does a deleted skill.
    public func forgetSkill(_ id: String) { forget("skills", id) }

    /// `field` is a bot's `[{id, defaultOn}]` list and its tasks' `{id: on}` switches.
    private func forget(_ field: String, _ id: String) {
        var changed: [String] = []
        for index in bots.indices {
            var touched = false
            if let list = bots[index][field]?.array, list.contains(where: { $0["id"]?.string == id }) {
                bots[index][field] = .array(list.filter { $0["id"]?.string != id })
                touched = true
            }
            if var tasks = bots[index]["tasks"]?.array {
                for at in tasks.indices {
                    guard var task = tasks[at].object, var map = task[field]?.object, map[id] != nil else { continue }
                    map = map.removing(id)
                    task[field] = map.isEmpty ? Optional<JSON>.none : .object(map)
                    tasks[at] = .object(task)
                    touched = true
                }
                if touched { bots[index]["tasks"] = .array(tasks) }
            }
            if touched, let botId = bots[index]["id"]?.string { changed.append(botId) }
        }
        guard !changed.isEmpty else { return }
        saveBots()
        for botId in changed { emit(.bot(botId: botId)) }
    }

    public func titleTaskFromFirstMessage(_ botId: String, text: String, threadId: String) {
        guard taskByThread(botId, threadId)?["title"]?.string == untitledTask else { return }
        _ = updateTask(botId, threadId) { $0["title"] = .string(titleFromMessage(text)) }
    }

    public func deleteTask(_ botId: String, _ threadId: String) -> JSONObject? {
        guard let index = botIndex(botId) else { return nil }
        var tasks = bots[index]["tasks"]?.array ?? []
        guard tasks.count >= 2, let task = tasks.first(where: { $0["threadId"]?.string == threadId }),
              task["pinned"]?.truthy != true else { return nil }
        tasks.removeAll { $0["threadId"]?.string == threadId }
        bots[index]["tasks"] = .array(tasks)
        deleteThreadRecord(threadId)
        if bots[index]["threadId"]?.string == threadId {
            bots[index]["threadId"] = tasks[0]["threadId"]
            bots[index]["resumeCursors"] = tasks[0]["resumeCursors"] ?? [:]
        }
        saveBots()
        emit(.bot(botId: botId))
        return bots[index]
    }

    public func seedIfEmpty() {
        if bots.isEmpty { createBot() }
    }

    // MARK: Rooms

    /// Who may be a room's default responder: its bots, then its guests
    /// from other engines (MixedRooms.swift).
    static func responderIds(_ group: JSONObject) -> [String] {
        (group["memberIds"]?.array?.compactMap(\.string) ?? [])
            + (group["guests"]?.array ?? []).compactMap { guest in
                guard let peer = guest["peerId"]?.string, let bot = guest["botId"]?.string else { return nil }
                return GuestId.make(peer: peer, bot: bot)
            }
    }

    static func normalizeResponder(_ value: JSON?, members: [String], dm: Bool) -> JSON {
        if dm { return ["kind": "mentions"] }
        switch value?["kind"]?.string {
        case "everyone": return ["kind": "everyone"]
        case "mentions": return ["kind": "mentions"]
        case "member":
            if let botId = value?["botId"]?.string, members.contains(botId) { return ["kind": "member", "botId": .string(botId)] }
        default: break
        }
        guard let first = members.first else { return ["kind": "mentions"] }
        return ["kind": "member", "botId": .string(first)]
    }

    @discardableResult
    public func createGroup(name: String, memberIds: [String], dm: Bool = false) -> JSONObject {
        var group = JSONObject([
            ("id", .string(newId())), ("threadId", .string(newId())), ("name", .string(name)),
            ("memberIds", .strings(memberIds)),
            ("defaultResponder", dm ? ["kind": "mentions"] : ["kind": "member", "botId": .string(memberIds.first ?? "")]),
            ("bulletin", ""), ("unread", false), ("createdAt", .number(nowMillis())), ("memberResumeCursors", [:]),
        ])
        if dm { group["dm"] = true }
        group["busyBotId"] = .null
        groups.insert(group, at: 0)
        saveGroups()
        emit(.group(groupId: group["id"]!.string!))
        return group
    }

    @discardableResult
    public func patchGroup(_ id: String, _ patch: JSONObject) -> JSONObject? {
        guard let index = groupIndex(id) else { return nil }
        for (key, value) in patch { if value.isNull && key != "busyBotId" { groups[index][key] = Optional<JSON>.none } else { groups[index][key] = value } }
        let members = Self.responderIds(groups[index])
        groups[index]["defaultResponder"] = Self.normalizeResponder(groups[index]["defaultResponder"], members: members, dm: groups[index]["dm"]?.truthy == true)
        saveGroups()
        emit(.group(groupId: id))
        return groups[index]
    }

    /// The bot⇄bot channel for a pair, if it exists (order-insensitive).
    public func dmGroup(_ a: String, _ b: String) -> JSONObject? {
        groups.first { group in
            let members = group["memberIds"]?.array?.compactMap(\.string) ?? []
            return group["dm"]?.truthy == true && members.count == 2 && members.contains(a) && members.contains(b)
        }
    }

    /// The room's folder, pinned on the first turn that dispatches: a room
    /// lives on one thread forever, so its folder never moves underneath it.
    /// A path, or nil = each member's own default.
    public func pinGroupCwd(_ groupId: String) -> String? {
        guard let index = groupIndex(groupId) else { return nil }
        if groups[index]["pinnedCwd"] == nil {
            groups[index]["pinnedCwd"] = groups[index]["cwd"] ?? .null
            saveGroups()
            emit(.group(groupId: groupId))
        }
        return groups[index]["pinnedCwd"]?.string
    }

    public func groupResumeCursor(_ groupId: String, botId: String, instanceId: String) -> JSON? {
        group(groupId)?["memberResumeCursors"]?[botId]?[instanceId]
    }

    public func setGroupResumeCursor(_ groupId: String, botId: String, instanceId: String, cursor: JSON) {
        guard let index = groupIndex(groupId),
              groups[index]["memberIds"]?.array?.contains(.string(botId)) == true else { return }
        var cursors = groups[index]["memberResumeCursors"]?.object ?? JSONObject()
        var member = cursors[botId]?.object ?? JSONObject()
        member[instanceId] = cursor
        cursors[botId] = .object(member)
        groups[index]["memberResumeCursors"] = .object(cursors)
        saveGroups()
        emit(.group(groupId: groupId))
    }

    public func deleteGroup(_ id: String) -> Bool {
        guard let group = group(id) else { return false }
        groups.removeAll { $0["id"]?.string == id }
        saveGroups()
        if let thread = group["threadId"]?.string { deleteThreadRecord(thread) }
        emit(.groupDeleted(groupId: id))
        return true
    }
}
