// The Cylon plugin, engine side (docs/plans/2026-10-28-code-mode-t3.md §10): the phases of a Cylon task in a
// channel. The flow is imposed by the engine, not left to a bot: the channel has a pipeline for its ticket
// (Spec → Plan → Run → Review → Pull request), each phase is sent as its skill to the one bot that plays that
// role for the project, and the next stays blocked until the one before is over or skipped. A phase is over
// when its skill says so (`CylonDetect`), or when the person marks it so.
//
// The roles belong to the project, the pipeline to the channel (`<data>/plugins/cylon/`); the switch "follow the
// Cylon flow" is plain data on the channel (`plugins.cylon.follow`), so a channel without it is an ordinary
// one. A ticket with another tag (`cylon-investigate`) is not part of this: it is worked on its own.
import Foundation
import HarnessCore

@MainActor
public final class CylonEnginePlugin: EnginePlugin {
    private weak var harness: Harness?

    public nonisolated init() {}

    public nonisolated var id: String { "cylon" }
    public nonisolated var name: String { "Cylon" }
    public nonisolated var version: String { "1.0.0" }
    /// The channels are Code channels with a project: the roles are the project's.
    public nonisolated var requires: [String] { ["code"] }

    // MARK: data on a channel

    public func validateData(_ data: JSONObject, for owner: PluginDataOwner, harness: Harness) throws {
        guard case .group = owner else { throw HTTPError(400, "Cylon works on channels, not on a single bot") }
        if let unknown = data.keys.first(where: { $0 != "follow" }) { throw HTTPError(400, "plugins.cylon has no field \(unknown)") }
        if let follow = data["follow"], !follow.isNull, follow.bool == nil { throw HTTPError(400, "follow must be true or false") }
    }

    // MARK: following a phase

    public func start(_ harness: Harness) async { self.harness = harness }

    /// A turn of a channel ended: if it was the bot of the running phase, see whether the phase is over.
    public func afterTurn(_ result: TurnResult) async {
        guard let harness, let groupId = result.groupId, let botId = result.botId else { return }
        let store = CylonStore(harness: harness)
        guard var pipeline = store.pipeline(of: groupId), let phase = pipeline.running, var entry = pipeline.phases[phase],
              entry.botId == botId, let group = harness.store.group(groupId) else { return }
        let thread = group["threadId"]?.string ?? ""
        let said = harness.store.messages(thread).dropFirst(entry.fromCount ?? 0).filter {
            $0["role"]?.string == "bot" && $0["kind"]?.string == "text" && $0["from"]?["botId"]?.string == botId
        }.compactMap { $0["text"]?.string }.joined(separator: "\n\n")
        let folder = group["pinnedCwd"]?.string ?? group["cwd"]?.string
        let onDisk = CylonDetect.onDisk(folder: folder, ticketId: pipeline.ticketId, slug: pipeline.slug)
        if let onDisk { pipeline.slug = onDisk.slug }

        if !result.ok {
            entry.state = .failed
            entry.note = "the turn did not finish"
            entry.finishedAt = nowMillis()
        } else {
            switch CylonDetect.outcome(phase, text: said, onDisk: onDisk) {
            case let .done(ticketId, slug, prUrl):
                entry.state = .done
                entry.note = nil
                entry.finishedAt = nowMillis()
                if let ticketId, ticketId != pipeline.ticketId {
                    pipeline.specTicketId = pipeline.specTicketId ?? pipeline.ticketId
                    pipeline.ticketId = ticketId
                }
                if let slug { pipeline.slug = slug }
                if let prUrl { pipeline.prUrl = prUrl }
            case let .failed(note):
                entry.state = .failed
                entry.note = note
                entry.finishedAt = nowMillis()
            case .waiting:
                break
            }
        }
        pipeline.phases[phase] = entry
        try? store.save(pipeline, of: groupId)
    }

    // MARK: routes

    private func channel(_ request: PluginRouter.Request) throws -> (id: String, group: JSONObject) {
        harness = request.harness
        let id = request.params["gid"] ?? ""
        guard let group = request.harness.store.group(id) else { throw HTTPError(404, "no such channel") }
        return (id, group)
    }

    private func phase(_ request: PluginRouter.Request) throws -> CylonPhase {
        guard let phase = CylonPhase(rawValue: request.params["phase"] ?? "") else {
            throw HTTPError(404, "no such phase: use \(CylonPhase.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return phase
    }

    public func routes(_ router: PluginRouter) {
        router.get("/api/groups/:gid/cylon") { request in
            let (id, _) = try self.channel(request)
            return .response(.json(200, await self.status(of: id, harness: request.harness)))
        }
        router.post("/api/groups/:gid/cylon/start") { request in
            let (id, group) = try self.channel(request)
            try await self.begin(id, group: group, body: try request.http.json(), harness: request.harness)
            return .response(.json(200, await self.status(of: id, harness: request.harness)))
        }
        router.delete("/api/groups/:gid/cylon") { request in
            let (id, _) = try self.channel(request)
            try CylonStore(harness: request.harness).save(nil, of: id)
            return .response(.json(200, await self.status(of: id, harness: request.harness)))
        }
        router.post("/api/groups/:gid/cylon/phases/:phase/run") { request in
            let (id, group) = try self.channel(request)
            try self.run(try self.phase(request), in: id, group: group, body: request.http.body.isEmpty ? JSONObject() : try request.http.json(), harness: request.harness)
            return .response(.json(202, await self.status(of: id, harness: request.harness)))
        }
        router.post("/api/groups/:gid/cylon/phases/:phase/skip") { request in
            let (id, _) = try self.channel(request)
            try self.settle(try self.phase(request), in: id, as: .skipped, harness: request.harness)
            return .response(.json(200, await self.status(of: id, harness: request.harness)))
        }
        router.post("/api/groups/:gid/cylon/phases/:phase/done") { request in
            let (id, _) = try self.channel(request)
            try self.settle(try self.phase(request), in: id, as: .done, harness: request.harness)
            return .response(.json(200, await self.status(of: id, harness: request.harness)))
        }
        router.get("/api/cylon/roles") { request in
            .response(.json(200, ["roles": .object(CylonStore(harness: request.harness).roles)]))
        }
        router.put("/api/cylon/roles/:project") { request in
            let harness = request.harness
            self.harness = harness
            let project = request.params["project"] ?? ""
            let store = CylonStore(harness: harness)
            try store.setRoles(try request.http.json(), project: project, harness: harness)
            // the skills reach the bots that now have a part, without a trip to Settings
            if let source = store.sourceId { try? harness.skillSources.assign(botIds: store.roles(of: project).values.map { $0 }, to: source) }
            return .response(.json(200, ["roles": store.roles[project] ?? .object(JSONObject())]))
        }
        router.get("/api/cylon/settings") { request in
            .response(.json(200, ["sourceId": CylonStore(harness: request.harness).sourceId.map { .string($0) } ?? .null]))
        }
        router.put("/api/cylon/settings") { request in
            let harness = request.harness
            self.harness = harness
            let store = CylonStore(harness: harness)
            let body = try request.http.json()
            guard let value = body["sourceId"] else { throw HTTPError(400, "sourceId is required (null clears it)") }
            if value.isNull { try store.setSource(nil) } else {
                guard let id = value.string, harness.skillSources.source(id) != nil else { throw HTTPError(400, "no such skill source") }
                try store.setSource(id)
                var everyone: [String] = []
                for (_, roles) in store.roles { for (_, bot) in roles.object ?? JSONObject() { if let botId = bot.string { everyone.append(botId) } } }
                try? harness.skillSources.assign(botIds: everyone, to: id)
            }
            return .response(.json(200, ["sourceId": store.sourceId.map { .string($0) } ?? .null]))
        }
    }

    public func stop(_ harness: Harness) {}

    // MARK: starting

    /// A ticket comes in: a new pipeline, and a clean session for it, since the state between phases is on disk.
    private func begin(_ id: String, group: JSONObject, body: JSONObject, harness: Harness) async throws {
        guard group["plugins"]?["cylon"]?["follow"]?.bool == true else { throw HTTPError(409, "this channel does not follow the Cylon flow: switch it on in the channel's settings") }
        guard let raw = body["ticket"]?.string, let ticket = CylonDetect.ticketId(raw) else { throw HTTPError(400, "ticket must be a ClickUp ticket's id or address") }
        let tag = body["tag"]?.string ?? "cylon-plan"
        if tag == "cylon-investigate" { throw HTTPError(400, "a cylon-investigate ticket is outside the flow: run /cylon-investigate on its own") }
        guard CylonPhase.tags.contains(tag) else { throw HTTPError(400, "tag must be \(CylonPhase.tags.joined(separator: " or "))") }
        let store = CylonStore(harness: harness)
        if let existing = store.pipeline(of: id), existing.next != nil, body["replace"]?.bool != true {
            throw HTTPError(409, "this channel is in the middle of ticket \(existing.ticketId): finish it, or start over")
        }
        if let busy = group["busyBotId"]?.string, !busy.isEmpty { throw HTTPError(409, "the channel is working — stop it before starting another ticket") }
        // the bots of the phases start from a clean session: what they need is in the task's folder
        if !harness.store.messages(group["threadId"]?.string ?? "").isEmpty { _ = try await harness.newRoomSession(id, summarize: false) }
        try store.save(CylonPipeline(ticketId: ticket, tag: tag, title: body["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty), of: id)
    }

    // MARK: sending a phase

    private func run(_ phase: CylonPhase, in id: String, group: JSONObject, body: JSONObject, harness: Harness) throws {
        let store = CylonStore(harness: harness)
        guard var pipeline = store.pipeline(of: id) else { throw HTTPError(409, "no ticket is being followed in this channel: start one") }
        guard pipeline.earlierResolved(phase) else { throw HTTPError(409, "the phases before \(phase.rawValue) are not over yet: finish or skip them first") }
        guard group["busyBotId"]?.string?.isEmpty ?? true else { throw HTTPError(409, "the channel is working: wait for it, or stop it") }
        if phase != .spec, planMode(thread: group["threadId"]?.string ?? "", harness: harness) {
            throw HTTPError(409, "the channel is in Plan mode, which changes nothing: switch it to Execute to run \(phase.rawValue)")
        }

        let projectId = group["plugins"]?["code"]?["projectId"]?.string
        guard let projectId else { throw HTTPError(409, "the channel has no project: choose one in its settings, so that the phases have their bots") }
        guard let botId = store.roles(of: projectId)[phase] else {
            throw HTTPError(409, "the project has no bot for \(phase.rawValue): choose it in Settings › Plugins › Cylon")
        }
        guard let bot = harness.store.bot(botId) else { throw HTTPError(409, "the bot chosen for \(phase.rawValue) no longer exists") }
        let botName = bot["name"]?.string ?? botId
        guard group["memberIds"]?.array?.contains(.string(botId)) == true else { throw HTTPError(409, "@\(botName) plays \(phase.rawValue) but is not a member of this channel") }
        try ensureSkill(phase, for: bot, harness: harness)
        // A channel turn for a bot that cannot take it is skipped without a word and never ends: the phase would be left
        // "running" with no turn behind it, and could not be sent again. So the cases the room skips are refused here.
        guard harness.fleet.get(ModelSelection(json: bot["modelSelection"]).instanceId) != nil else {
            throw HTTPError(409, "the model of @\(botName) is not available: choose another in the bot's settings")
        }
        guard !Store.isBusy(bot) else { throw HTTPError(409, "@\(botName) is working in another conversation: wait for it to finish") }

        if let slug = body["slug"]?.string {
            guard slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$"#, options: .regularExpression) != nil else { throw HTTPError(400, "slug is not a folder name") }
            pipeline.slug = slug
        } else if pipeline.slug == nil {
            let folder = group["pinnedCwd"]?.string ?? group["cwd"]?.string
            pipeline.slug = CylonDetect.onDisk(folder: folder, ticketId: pipeline.ticketId, slug: nil)?.slug
        }
        guard let command = CylonDetect.command(phase, ticketId: pipeline.ticketId, slug: pipeline.slug) else {
            throw HTTPError(409, "the task's folder (cylon-features/<name>) is not known yet: finish the plan, or send its name as `slug`")
        }

        var entry = pipeline.phases[phase] ?? CylonPipeline.Entry()
        entry.state = .running
        entry.botId = botId
        entry.startedAt = nowMillis()
        entry.finishedAt = nil
        entry.note = nil
        entry.fromCount = harness.store.messages(group["threadId"]?.string ?? "").count
        pipeline.phases[phase] = entry
        try store.save(pipeline, of: id)
        do { try harness.startGroupTurn(groupId: id, text: "@\(botName) \(command)") } catch {
            // nothing was sent: the phase is as it was
            pipeline.phases[phase] = CylonPipeline.Entry(state: .failed, botId: botId, note: "could not be sent: \(error.localizedDescription)")
            try? store.save(pipeline, of: id)
            if let turn = error as? Harness.TurnError { throw HTTPError(turn.status, turn.message) }
            throw error
        }
    }

    /// The skill is on this engine and the bot has it; one the bot lacks is handed over by the Cylon source.
    private func ensureSkill(_ phase: CylonPhase, for bot: JSONObject, harness: Harness) throws {
        let name = bot["name"]?.string ?? ""
        guard harness.skills.skill(phase.skill) != nil else {
            throw HTTPError(409, "the skill \(phase.skill) is not on this engine: add the Cylon source in Settings › Skills and update it")
        }
        func has(_ bot: JSONObject) -> Bool {
            harness.skillSources.augment(bot)["skills"]?.array?.contains { $0["id"]?.string == phase.skill && $0["defaultOn"]?.bool != false } == true
        }
        if has(bot) { return }
        if let source = CylonStore(harness: harness).sourceId, let botId = bot["id"]?.string,
           harness.skillSources.source(source)?.skills.contains(phase.skill) == true {
            try harness.skillSources.assign(botIds: [botId], to: source)
            if let fresh = harness.store.bot(botId), has(fresh) { return }
        }
        throw HTTPError(409, "@\(name) does not have the skill \(phase.skill): give it to the bot (Settings › Skills), or pick the Cylon source in Settings › Plugins › Cylon")
    }

    /// The Code plugin's Plan mode keeps its choices in its own file: a phase that writes cannot run under it.
    private func planMode(thread: String, harness: Harness) -> Bool {
        let file = harness.plugins.directory(for: "code").appendingPathComponent("modes.json")
        guard let data = try? Data(contentsOf: file), let json = try? JSON.parse(data) else { return false }
        return json[thread]?.string == "plan"
    }

    // MARK: skipping and marking

    private func settle(_ phase: CylonPhase, in id: String, as state: CylonState, harness: Harness) throws {
        let store = CylonStore(harness: harness)
        guard var pipeline = store.pipeline(of: id) else { throw HTTPError(409, "no ticket is being followed in this channel") }
        guard pipeline.earlierResolved(phase) else { throw HTTPError(409, "the phases before \(phase.rawValue) are not over yet") }
        let current = pipeline.state(phase)
        if state == .skipped, current != .pending, current != .failed { throw HTTPError(409, "only a phase that is waiting (or that failed) is skipped") }
        if state == .done, current == .done { throw HTTPError(409, "the phase is already over") }
        var entry = pipeline.phases[phase] ?? CylonPipeline.Entry()
        entry.state = state
        entry.note = state == .skipped ? "skipped" : "marked as done"
        entry.finishedAt = nowMillis()
        pipeline.phases[phase] = entry
        try store.save(pipeline, of: id)
    }

    // MARK: what the app shows

    func status(of id: String, harness: Harness) async -> JSON {
        let store = CylonStore(harness: harness)
        let group = harness.store.group(id)
        let follow = group?["plugins"]?["cylon"]?["follow"]?.bool ?? false
        let projectId = group?["plugins"]?["code"]?["projectId"]?.string
        let roles = projectId.map { store.roles(of: $0) } ?? [:]
        let pipeline = store.pipeline(of: id)
        let busy = group?["busyBotId"]?.string?.isEmpty == false

        func player(_ phase: CylonPhase) -> JSON {
            guard let botId = roles[phase], let bot = harness.store.bot(botId) else { return .null }
            let skill = harness.skills.skill(phase.skill) != nil
            let has = harness.skillSources.augment(bot)["skills"]?.array?.contains { $0["id"]?.string == phase.skill && $0["defaultOn"]?.bool != false } == true
            return ["botId": .string(botId), "name": bot["name"] ?? .null,
                    "member": .bool(group?["memberIds"]?.array?.contains(.string(botId)) == true),
                    "skillOnEngine": .bool(skill), "skillOnBot": .bool(has),
                    // working in another conversation: the phase cannot go to it now
                    "busy": .bool(Store.isBusy(bot))]
        }

        var phases: [JSON] = []
        for phase in CylonPhase.allCases {
            var item: JSONObject = ["key": .string(phase.rawValue), "skill": .string(phase.skill), "bot": player(phase)]
            if let pipeline {
                let entry = pipeline.phases[phase] ?? CylonPipeline.Entry()
                let resolved = pipeline.earlierResolved(phase)
                item["state"] = .string(entry.state.rawValue)
                // the next to send; a phase over can be sent again
                item["current"] = .bool(pipeline.next == phase)
                let botBusy = roles[phase].map { Store.isBusy(harness.store.bot($0)) } ?? false
                item["canRun"] = .bool(resolved && !busy && !botBusy && entry.state != .running)
                item["canSkip"] = .bool(resolved && (entry.state == .pending || entry.state == .failed))
                item["canMarkDone"] = .bool(resolved && (entry.state == .pending || entry.state == .running || entry.state == .failed))
                if let command = CylonDetect.command(phase, ticketId: pipeline.ticketId, slug: pipeline.slug) { item["command"] = .string(command) }
                if let note = entry.note { item["note"] = .string(note) }
                if let at = entry.startedAt { item["startedAt"] = .number(at) }
                if let at = entry.finishedAt { item["finishedAt"] = .number(at) }
            }
            phases.append(.object(item))
        }
        var answer: JSONObject = ["follow": .bool(follow), "phases": .array(phases), "busy": .bool(busy)]
        answer["projectId"] = projectId.map { .string($0) } ?? .null
        if let pipeline {
            var info = JSONObject([("ticketId", .string(pipeline.ticketId)), ("tag", .string(pipeline.tag)), ("startedAt", .number(pipeline.startedAt))])
            if let specTicketId = pipeline.specTicketId { info["specTicketId"] = .string(specTicketId) }
            if let title = pipeline.title { info["title"] = .string(title) }
            if let slug = pipeline.slug { info["slug"] = .string(slug) }
            if let url = pipeline.prUrl { info["prUrl"] = .string(url) }
            info["finished"] = .bool(pipeline.next == nil)
            answer["pipeline"] = .object(info)
        } else {
            answer["pipeline"] = .null
        }
        if let source = store.sourceId, let wire = try? await harness.skillSources.wire(source) {
            answer["source"] = ["id": .string(source), "name": wire["name"] ?? .null, "ok": wire["last"]?["ok"] ?? .null,
                                "installed": .bool(wire["installed"] != nil), "missing": wire["missing"] ?? []]
        }
        return .object(answer)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
