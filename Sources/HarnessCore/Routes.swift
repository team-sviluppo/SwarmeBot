// The HTTP API — the routes of `server/index.ts` this engine serves.
//
// Same paths, bodies, statuses and error texts as the Node engine
// (docs/contract/http-sse.md). Routes for areas not ported yet answer 501
// with a sentence that says so, rather than a 404 that reads like a bug.
import Foundation

@MainActor
public final class Routes {
    private let harness: Harness
    private var store: Store { harness.store }
    private var patterns: [String: NSRegularExpression] = [:]

    static let notPorted = "non ancora disponibile nel motore Swift — passa al motore Node in Impostazioni › Motore"

    public init(harness: Harness) {
        self.harness = harness
    }

    private func match(_ pattern: String, _ path: String) -> [String]? {
        let regex = patterns[pattern] ?? { () -> NSRegularExpression in
            let compiled = try! NSRegularExpression(pattern: pattern)
            patterns[pattern] = compiled
            return compiled
        }()
        let ns = path as NSString
        guard let found = regex.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<found.numberOfRanges).map { ns.substring(with: found.range(at: $0)) }
    }

    private func ok(_ value: JSON, _ status: Int = 200) -> RouteResult { .response(.json(status, value)) }
    private func fail(_ status: Int, _ message: String) -> RouteResult { .response(.error(status, message)) }

    public func handle(_ request: HTTPRequest) async -> RouteResult {
        do {
            return try await route(request)
        } catch let error as HTTPError {
            return fail(error.status, error.message)
        } catch let error as Harness.TurnError {
            return fail(error.status, error.message)
        } catch let error as JSONParseError {
            return fail(400, "invalid JSON: \(error.description)")
        } catch {
            return fail(500, error.localizedDescription)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func route(_ r: HTTPRequest) async throws -> RouteResult {
        let path = r.path
        let method = r.method

        // its own 415 and `{code, error}` bodies, so it goes before the JSON gate
        if let settings = await DeepSeekSettingsRoutes.handle(r, harness: harness) { return settings }
        if let team = await TeamRoutes.handle(r, harness: harness) { return team }
        if let avatar = AvatarRoutes.handle(r, harness: harness) { return avatar }

        // dangerous mutations must declare JSON (no CSRF via HTML forms)
        let jsonOnly = [#"^/api/local-computer/"#, #"^/api/cli-test$"#, #"^/api/instances/[\w.-]+"#, #"^/api/bots/[\w-]+/computer"#, #"^/api/bots/[\w-]+/library"#]
        if method != "GET", jsonOnly.contains(where: { match($0, path) != nil }), !r.isJSON {
            return fail(415, "content-type must be application/json")
        }

        if method == "GET", path == "/api/health" {
            return ok(["app": "swarmebot", "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "static": false, "engine": "swift"])
        }
        if method == "GET", path == "/api/events" { return harness.hub.route(r) }
        // peer comms for the agents MCP helper: loopback and the boot token only
        if let response = await harness.internalRoute(r) { return .response(response) }

        // MARK: bots
        if path == "/api/bots" {
            if method == "GET" {
                let limit = try pageSize(r.query["messages"])
                var bots: [JSON] = []
                for bot in store.bots {
                    var out = harness.botWithThread(bot)
                    let page = messagePage(bot["threadId"]?.string ?? "", limit: limit)
                    for (key, value) in page { out[key] = value }
                    bots.append(.object(out))
                }
                let groups: [JSON] = store.groups.map { group in
                    var out = harness.wireGroup(group)
                    for (key, value) in messagePage(group["threadId"]?.string ?? "", limit: limit) { out[key] = value }
                    return .object(out)
                }
                var control = JSONObject()
                for bot in store.bots {
                    guard let id = bot["id"]?.string else { continue }
                    let snapshot = harness.computerControl.snapshot(id)
                    control[id] = ["held": snapshot["held"] ?? false, "helpReason": snapshot["helpReason"] ?? .null]
                }
                return ok(["bots": .array(bots), "groups": .array(groups), "computerControl": .object(control)])
            }
            if method == "POST" {
                let bot = store.createBot()
                // the selection of right now, not of boot: engines come and go
                let id = bot["id"]!.string!
                store.patchBot(id, ["modelSelection": await harness.fleet.defaultSelection().json])
                return ok(["bot": .object(harness.botWithThread(store.bot(id) ?? bot))], 201)
            }
        }

        if let m = match(#"^/api/bots/([\w-]+)$"#, path) {
            guard let bot = store.bot(m[0]) else { return fail(404, "no such bot") }
            if method == "PATCH" { return try await patchBot(bot, r.json()) }
            if method == "DELETE" {
                await harness.interrupt(botId: m[0])
                harness.routines.disableForBot(m[0])
                harness.webhooks.disableForBot(m[0])
                // an approval naming this bot can never be meaningfully answered now
                harness.peerApprovals.cancelFor(botId: m[0])
                harness.discardDelegations(bot["threadId"]?.string ?? "")
                harness.stopScreenPoller(m[0])
                harness.computerControl.forget(m[0])
                _ = store.deleteBot(m[0])
                return ok(["ok": true])
            }
        }
        if let m = match(#"^/api/bots/([\w-]+)/read$"#, path), method == "POST" {
            guard let bot = store.patchBot(m[0], ["unread": false]) else { return fail(404, "no such bot") }
            return ok(["bot": .object(harness.wireBot(bot))])
        }
        if let m = match(#"^/api/bots/([\w-]+)/always-allow$"#, path), method == "POST" {
            guard let bot = store.bot(m[0]) else { return fail(404, "no such bot") }
            let key = try r.json()["allowKey"]?.string ?? ""
            let pending = store.messages(bot["threadId"]?.string ?? "").contains {
                $0["card"]?["allowKey"]?.string == key && $0["card"]?["answered"] == nil
            }
            guard !key.isEmpty, pending else { return fail(409, "that grant is not on a pending approval") }
            var allowed = bot["alwaysAllow"]?.array?.compactMap(\.string) ?? []
            if !allowed.contains(key) { allowed.append(key) }
            let updated = store.patchBot(m[0], ["alwaysAllow": .strings(Array(allowed.prefix(200)))])!
            return ok(["bot": .object(harness.wireBot(updated))])
        }
        // onboarding and ask cards keep their answered/dismissed state
        if let m = match(#"^/api/bots/([\w-]+)/cards/([\w-]+)$"#, path), method == "PATCH" {
            guard let bot = store.bot(m[0]), let threadId = bot["threadId"]?.string else { return fail(404, "no such bot") }
            guard let card = store.messages(threadId).first(where: { $0["id"]?.string == m[1] })?["card"]?.object else { return fail(404, "no such card") }
            let body = try r.json()
            var patched = card
            // a JSON null is kept as a value here, like `{ ...card, answered: null }`
            for key in ["answered", "dismissed"] { if let value = body[key] { patched[key] = value } }
            return ok(["message": store.patchMessage(threadId, m[1], ["card": .object(patched)]).map(JSON.object) ?? .null])
        }
        if let m = match(#"^/api/bots/([\w-]+)/library$"#, path) {
            guard store.bot(m[0]) != nil else { return fail(404, "no such bot") }
            if method == "GET" { return ok(["docs": .array(harness.library.docs(m[0]).map(\.json))]) }
            if method == "POST" {
                // the app and the engine share this Mac: a path, not the bytes
                guard let path = try r.json()["path"]?.string, path.hasPrefix("/") else { return fail(400, "path must be an absolute file path") }
                do {
                    let doc = try harness.library.add(m[0], from: URL(fileURLWithPath: path))
                    return ok(["doc": doc.json], 201)
                } catch let error as Library.ImportError {
                    return fail(error.status, error.message)
                }
            }
        }
        if let m = match(#"^/api/bots/([\w-]+)/library/([\w-]+)$"#, path) {
            if method == "DELETE" {
                guard harness.library.remove(m[0], m[1]) else { return fail(404, "no such document") }
                return ok(["ok": true])
            }
        }
        if let m = match(#"^/api/bots/([\w-]+)/library/([\w-]+)/text$"#, path), method == "GET" {
            guard let text = harness.library.text(m[0], m[1]) else { return fail(404, "no such document") }
            return ok(["text": .string(text)])
        }
        if let m = match(#"^/api/bots/([\w-]+)/messages$"#, path), method == "POST" {
            let text = try r.json()["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return fail(400, "text required") }
            guard let bot = store.bot(m[0]) else { return fail(404, "no such bot") }
            if Store.isBusy(bot) {
                let message = harness.queueSteeredMessage(botId: m[0], text: text)
                return ok(["ok": true, "queued": true, "messageId": message?["id"] ?? .null], 202)
            }
            try harness.startTurn(botId: m[0], text: text)
            return ok(["ok": true], 202)
        }
        if let m = match(#"^/api/bots/([\w-]+)/messages/([\w-]+)/edit$"#, path), method == "POST" {
            guard let bot = store.bot(m[0]), let threadId = bot["threadId"]?.string else { return fail(404, "no such bot") }
            let text = try r.json()["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return fail(400, "text required") }
            if Store.isBusy(bot) { return fail(409, "the bot is working — stop it before editing") }
            let source = store.messages(threadId).first { $0["id"]?.string == m[1] }
            guard source?["role"]?.string == "user", source?["kind"]?.string == "text" else { return fail(404, "only user messages can be edited") }
            let instanceId = ModelSelection(json: bot["modelSelection"]).instanceId
            guard harness.fleet.get(instanceId) != nil else {
                return fail(409, "provider instance \"\(instanceId)\" is unavailable — pick another model in settings")
            }
            guard let message = store.branchMessage(threadId, sourceId: m[1], text: text) else { return fail(404, "no such message") }
            store.patchBot(m[0], ["rewound": true])
            try harness.startTurn(botId: m[0], text: text, userMessage: message)
            return ok(["ok": true], 202)
        }
        if let m = match(#"^/api/bots/([\w-]+)/active-branch$"#, path), method == "POST" {
            guard let bot = store.bot(m[0]), let threadId = bot["threadId"]?.string else { return fail(404, "no such bot") }
            if Store.isBusy(bot) { return fail(409, "the bot is working — stop it before switching versions") }
            guard let leaf = store.setActiveLeaf(threadId, messageId: try r.json()["messageId"]?.string ?? "") else { return fail(404, "no such message") }
            store.patchBot(m[0], ["rewound": true])
            return ok(["activeLeafId": .string(leaf)])
        }
        if let m = match(#"^/api/bots/([\w-]+)/respond$"#, path), method == "POST" {
            guard let bot = store.bot(m[0]) else { return fail(404, "no such bot") }
            if let answered = try peerAnswer(r) { return answered }
            return try await respond(r, threadId: bot["threadId"]?.string ?? "", owner: bot)
        }
        if let m = match(#"^/api/threads/([\w-]+)/respond$"#, path), method == "POST" {
            if let answered = try peerAnswer(r) { return answered }
            let pending = store.messages(m[0]).first { $0["card"]?["requestId"]?.string == (try? r.json())?["requestId"]?.string }
            // a room's request belongs to the member speaking now, else to the one who raised it
            let room = store.groupByThread(m[0])
            let owner = room == nil ? store.botByThread(m[0])
                : room?["busyBotId"]?.string.flatMap { store.bot($0) } ?? pending?["from"]?["botId"]?.string.flatMap { store.bot($0) }
            if owner == nil, pending == nil { return fail(404, "nothing is waiting on an answer in this conversation") }
            return try await respond(r, threadId: m[0], owner: owner)
        }
        if let m = match(#"^/api/bots/([\w-]+)/interrupt$"#, path), method == "POST" {
            guard store.bot(m[0]) != nil else { return fail(404, "no such bot") }
            // a routine run owns the bot: stopping it cancels the run (which interrupts)
            if let run = harness.routines.activeRun(forBot: m[0]), let id = run["id"]?.string {
                _ = harness.routines.cancelRun(id)
                return ok(["ok": true])
            }
            await harness.interrupt(botId: m[0])
            return ok(["ok": true])
        }

        // MARK: tasks
        if let m = match(#"^/api/bots/([\w-]+)/tasks$"#, path), method == "POST" {
            guard let bot = store.bot(m[0]) else { return fail(404, "no such bot") }
            if Store.isBusy(bot) { return fail(409, "this bot is working — let it finish before starting a task") }
            guard let task = store.createTask(m[0], title: try r.json()["title"]?.string) else { return fail(500, "couldn't create that task") }
            let fresh = harness.botWithThread(store.bot(m[0])!)
            harness.broadcast(["kind": "bot", "bot": .object(fresh)])
            return ok(["bot": .object(fresh), "task": Harness.wireTask(task)], 201)
        }
        if let m = match(#"^/api/bots/([\w-]+)/tasks/([\w-]+)$"#, path) {
            if method == "POST" {
                guard let switched = store.switchTask(m[0], m[1]) else { return fail(404, "no such task") }
                let fresh = harness.botWithThread(switched)
                harness.broadcast(["kind": "bot", "bot": .object(fresh)])
                return ok(["bot": .object(fresh)])
            }
            if method == "PATCH" {
                let body = try r.json()
                guard var task = store.taskByThread(m[0], m[1]) else { return fail(404, "no such task") }
                if let pinned = body["pinned"]?.bool { task = store.setTaskPinned(m[0], m[1], pinned: pinned) ?? task }
                if let title = body["title"] { task = store.renameTask(m[0], m[1], title: title.string ?? "") ?? task }
                if let off = body["libraryOff"] {
                    guard let list = off.array, list.allSatisfy({ $0.string != nil }) else { return fail(400, "libraryOff must be a list of document ids") }
                    task = store.setTaskLibraryOff(m[0], m[1], Array(Set(list.compactMap(\.string))).sorted()) ?? task
                }
                if let cwd = body["cwd"] {
                    if cwd.isNull || cwd.string == "" {
                        task = store.setTaskCwd(m[0], m[1], cwd: nil) ?? task
                    } else {
                        guard let path = cwd.string, path.hasPrefix("/") else { return fail(400, "cwd must be an absolute path") }
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                            return fail(400, "cwd must be an existing folder")
                        }
                        task = store.setTaskCwd(m[0], m[1], cwd: path) ?? task
                    }
                }
                let fresh = harness.botWithThread(store.bot(m[0])!)
                harness.broadcast(["kind": "bot", "bot": .object(fresh)])
                return ok(["bot": .object(fresh), "task": Harness.wireTask(task)])
            }
            if method == "DELETE" {
                let bot = store.bot(m[0])
                if Store.isBusy(bot), bot?["threadId"]?.string == m[1] || harness.routines.isActiveThread(m[1]) { return fail(409, "this task is running — stop it first") }
                if store.taskByThread(m[0], m[1])?["pinned"]?.truthy == true { return fail(409, "unpin this task before deleting it") }
                guard let updated = store.deleteTask(m[0], m[1]) else { return fail(400, "a bot keeps at least one task") }
                let fresh = harness.botWithThread(updated)
                harness.broadcast(["kind": "bot", "bot": .object(fresh)])
                return ok(["bot": .object(fresh)])
            }
        }

        // MARK: threads
        if let m = match(#"^/api/threads/([\w-]+)/messages$"#, path), method == "GET" {
            guard store.botByThread(m[0]) != nil || store.groupByThread(m[0]) != nil else { return fail(404, "no such conversation") }
            let limit = try pageSize(r.query["limit"]) ?? 50
            let before = r.query["before"]
            let around = r.query["around"]
            if before != nil, around != nil { return fail(400, "before and around cannot be combined") }
            let all = store.messages(m[0])
            if let around {
                guard let index = all.firstIndex(where: { $0["id"]?.string == around }) else { return fail(404, "no such message") }
                let start = max(0, index - limit / 2)
                let end = min(all.count, start + limit)
                return ok(["messages": .array(all[start..<end].map { .object(Self.slim($0)) }), "hasMore": .bool(start > 0)])
            }
            if let before, !all.contains(where: { $0["id"]?.string == before }) { return fail(404, "no such message") }
            return ok(.object(messagePage(m[0], limit: limit, before: before)))
        }
        if let m = match(#"^/api/threads/([\w-]+)/messages/([\w-]+)/image$"#, path), method == "GET" {
            guard store.botByThread(m[0]) != nil || store.groupByThread(m[0]) != nil else { return fail(404, "no such conversation") }
            guard let message = store.messages(m[0]).first(where: { $0["id"]?.string == m[1] }),
                  let png = message["png"]?.string, let data = Data(base64Encoded: png) else { return fail(404, "no such image") }
            return .response(HTTPResponse(status: 200, headers: [
                ("Content-Type", message["mime"]?.string ?? "image/png"), ("Cache-Control", "private, max-age=31536000, immutable"),
            ], body: data))
        }
        if let m = match(#"^/api/threads/([\w-]+)/messages/([\w-]+)/reactions$"#, path), method == "POST" {
            let body = try r.json()
            let emoji = body["emoji"]?.string ?? ""
            guard !emoji.isEmpty, emoji.count <= 8 else { return fail(400, "emoji required") }
            guard let message = store.toggleReaction(m[0], m[1], emoji: emoji, by: body["by"]?.string ?? "user") else { return fail(404, "no such message") }
            return ok(["message": .object(message)])
        }
        if let m = match(#"^/api/threads/([\w-]+)/export$"#, path), method == "GET" {
            return export(threadId: m[0], format: r.query["format"] ?? "markdown")
        }
        if let m = match(#"^/api/threads/([\w-]+)/events$"#, path), method == "GET" {
            return ok(threadEvents(m[0], limit: min(2000, max(1, Int(r.query["limit"] ?? "") ?? 300))))
        }

        // MARK: rooms (management only — room turns are not ported yet)
        if path == "/api/groups", method == "POST" {
            let body = try r.json()
            let members = (body["memberIds"]?.array ?? []).compactMap(\.string).filter { store.bot($0) != nil }
            guard !members.isEmpty else { return fail(400, "memberIds must name at least one bot") }
            let name = body["name"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            let group = store.createGroup(name: name.isEmpty ? (store.bot(members[0])?["name"]?.string ?? "Room") : name, memberIds: members)
            var out = harness.wireGroup(group)
            out["messages"] = .array([])
            return ok(["group": .object(out)], 201)
        }
        if let m = match(#"^/api/groups/([\w-]+)$"#, path) {
            guard let existing = store.group(m[0]) else { return fail(404, "no such room") }
            if method == "DELETE" {
                _ = store.deleteGroup(m[0])
                return ok(["ok": true])
            }
            if method == "PATCH" {
                let body = try r.json()
                var patch = JSONObject()
                for key in ["name", "bulletin", "unread"] { if let value = body[key] { patch[key] = value } }
                if let ids = body["memberIds"]?.array?.compactMap(\.string).filter({ store.bot($0) != nil }), !ids.isEmpty {
                    patch["memberIds"] = .strings(ids)
                }
                if let responder = body["defaultResponder"] {
                    let members = patch["memberIds"]?.array?.compactMap(\.string) ?? existing["memberIds"]?.array?.compactMap(\.string) ?? []
                    switch responder["kind"]?.string {
                    case "everyone", "mentions": patch["defaultResponder"] = ["kind": responder["kind"]!]
                    case "member" where members.contains(responder["botId"]?.string ?? ""):
                        patch["defaultResponder"] = ["kind": "member", "botId": responder["botId"]!]
                    default: return fail(400, "invalid default responder")
                    }
                }
                guard let group = store.patchGroup(m[0], patch) else { return fail(404, "no such room") }
                return ok(["group": .object(harness.wireGroup(group))])
            }
        }
        if let m = match(#"^/api/groups/([\w-]+)/read$"#, path), method == "POST" {
            guard let group = store.patchGroup(m[0], ["unread": false]) else { return fail(404, "no such room") }
            return ok(["group": .object(harness.wireGroup(group))])
        }
        if let m = match(#"^/api/groups/([\w-]+)/messages$"#, path), method == "POST" {
            let text = (try r.json()["text"].flatMap(Harness.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return fail(400, "text required") }
            try harness.startGroupTurn(groupId: m[0], text: text)
            return ok(["ok": true], 202)
        }
        if let m = match(#"^/api/groups/([\w-]+)/interrupt$"#, path), method == "POST" {
            guard await harness.interruptGroup(m[0]) else { return fail(404, "no such room") }
            return ok(["ok": true])
        }

        // MARK: engines and config
        if method == "GET", path == "/api/instances" {
            EnvPath.reset()
            return ok(["instances": .array(await harness.fleet.describe(pickerVisibility: harness.config.pickerVisibility))])
        }
        if let m = match(#"^/api/instances/([\w.-]+)$"#, path), method == "PATCH" {
            let body = try r.json()
            guard body["cli"] != nil || body["pickerVisible"] != nil else { return fail(400, "cli or pickerVisible is required") }
            if let visible = body["pickerVisible"] {
                guard try harness.config.setPickerVisibility(m[0], visible.bool) else { return fail(404, "no such instance") }
            }
            let visibilityOnly = body["cli"] == nil
            if let cli = body["cli"]?.string {
                guard try harness.config.setInstanceCli(m[0], cli) else { return fail(404, "no such instance") }
                await harness.reloadProviders()
            }
            return ok(["instances": .array(await harness.fleet.describe(pickerVisibility: harness.config.pickerVisibility, refresh: !visibilityOnly))])
        }
        if method == "GET", path == "/api/cli-candidates" {
            EnvPath.reset()
            return ok(["candidates": .strings(EnvPath.candidates(r.query["name"] ?? ""))])
        }
        if method == "POST", path == "/api/cli-test" {
            return ok(await cliTest(try r.json()))
        }
        if path == "/api/config" {
            if method == "GET" { return ok(harness.config.status()) }
            if method == "PUT" || method == "PATCH" {
                let external = r.query["secretStorage"] == "external"
                do {
                    let reload = try harness.config.save(patch: try r.json(), externalSecrets: external)
                    if reload { await harness.reloadProviders() } else {
                        harness.broadcast(JSONObject([("kind", "config")]).merging(harness.config.status().object!))
                    }
                } catch let error as AppConfig.SaveError {
                    return fail(400, error.localizedDescription)
                }
                return ok(harness.config.status())
            }
        }

        // MARK: search, attachments, decisions
        if method == "GET", path == "/api/search" {
            let limit = min(100, max(1, Int(r.query["limit"] ?? "") ?? 40))
            let hits: [JSON] = store.search(r.query["q"] ?? "", limit: limit).compactMap { hit in
                var out = hit
                let threadId = hit["threadId"]?.string ?? ""
                if let bot = store.botByThread(threadId) {
                    out["botId"] = bot["id"]
                    out["name"] = bot["name"]
                    if let task = store.taskByThread(bot["id"]?.string ?? "", threadId) { out["task"] = task["title"] }
                } else if let group = store.groupByThread(threadId) {
                    out["groupId"] = group["id"]
                    out["name"] = group["name"]
                } else {
                    return nil
                }
                out["onActivePath"] = .bool(store.activePath(threadId).contains { $0["id"]?.string == hit["messageId"]?.string })
                return .object(out)
            }
            return ok(["hits": .array(hits)])
        }
        if method == "POST", path == "/api/attachments" {
            let extensions = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"]
            guard let ext = extensions[r.contentType] else { return fail(400, "content-type must be an image type") }
            guard !r.body.isEmpty else { return fail(400, "empty image") }
            guard r.body.count <= 10 * 1024 * 1024 else { return fail(413, "image exceeds 10485760 bytes") }
            let file = harness.paths.attachments.appendingPathComponent("\(UUID().uuidString.lowercased()).\(ext)")
            try FileIO.writeAtomic(r.body, to: file)
            return ok(["path": .string(file.path), "mime": .string(r.contentType), "bytes": .number(Double(r.body.count))], 201)
        }
        if let m = match(#"^/api/attachments/([\w.-]+)$"#, path), method == "GET" {
            let name = m[0]
            guard name.range(of: #"^[A-Za-z0-9-]+\.(png|jpg|gif|webp)$"#, options: .regularExpression) != nil,
                  let data = try? Data(contentsOf: harness.paths.attachments.appendingPathComponent(name)) else {
                return fail(404, "no such attachment")
            }
            let mime = ["png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][(name as NSString).pathExtension] ?? "application/octet-stream"
            return .response(HTTPResponse(status: 200, headers: [
                ("Content-Type", mime), ("Cache-Control", "private, max-age=31536000, immutable"), ("X-Content-Type-Options", "nosniff"),
            ], body: data))
        }
        if method == "GET", path == "/api/decisions" {
            return ok(["decisions": .array(DecisionLog.read(harness.paths, limit: Int(r.query["limit"] ?? "") ?? 200))])
        }

        if let routed = try await automationRoute(r) { return routed }

        // MARK: not ported yet — read routes answer empty, writes say so
        if path == "/api/local-computer" || path.hasPrefix("/api/local-computer/") {
            if let response = await harness.localComputerRoute(r, path: path) { return .response(response) }
        }
        if match(#"^/api/bots/([\w-]+)/computer"#, path) != nil {
            if let response = try await harness.computerRoute(r, path: path) { return .response(response) }
            return fail(501, "Questa funzione è \(Self.notPorted)")
        }
        // voice and Composio were left out of the native app on purpose (piano §2.1)
        if ["/api/tts", "/api/connectors"].contains(where: path.hasPrefix) || match(#"^/api/bots/([\w-]+)/connector-cards"#, path) != nil {
            return fail(501, "Questa funzione non fa parte dell'app nativa: voce e connettori Composio sono stati esclusi")
        }
        return fail(404, "no route: \(method) \(path)")
    }

    // MARK: - Helpers

    private func pageSize(_ raw: String?) throws -> Int? {
        guard let raw else { return nil }
        guard let size = Int(raw), size >= 0 else { throw HTTPError(400, "messages must be a non-negative whole number") }
        return min(size, 200)
    }

    static func slim(_ message: JSONObject) -> JSONObject {
        guard message["kind"]?.string == "screen", message["png"] != nil else { return message }
        var out = message.removing("png", "mime")
        out["hasImage"] = true
        return out
    }

    /// `messagePage`: nil limit is the unpaginated shape.
    private func messagePage(_ threadId: String, limit: Int?, before: String? = nil) -> JSONObject {
        let all = store.messages(threadId)
        guard let limit else { return ["messages": .array(all.map(JSON.object))] }
        let stop = before.flatMap { id in all.firstIndex { $0["id"]?.string == id } } ?? all.count
        let start = max(0, stop - limit)
        return ["messages": .array(all[start..<stop].map { .object(Self.slim($0)) }), "hasMore": .bool(start > 0)]
    }

    private func patchBot(_ bot: JSONObject, _ body: JSONObject) async throws -> RouteResult {
        let id = bot["id"]?.string ?? ""
        if let selection = body["modelSelection"], let effort = selection["effort"]?.string {
            guard isEffortLevel(effort) else { return fail(400, "effort \"\(effort)\" is not recognized") }
            let current = ModelSelection(json: bot["modelSelection"])
            if let target = harness.fleet.get(selection["instanceId"]?.string ?? current.instanceId) {
                let allowed = effortLevelsForModel(target.models.options, model: selection["model"]?.string ?? current.model,
                                                   driverLevels: target.adapter.capabilities.effortLevels) ?? []
                if !allowed.contains(effort) { return fail(400, "effort \"\(effort)\" is not offered by this bot's engine") }
            }
        }
        for (field, max) in [("name", 100), ("title", 200), ("description", 8000)] {
            guard let value = body[field] else { continue }
            guard let string = value.string else { return fail(400, "\(field) must be a string") }
            if string.count > max { return fail(400, "\(field) must be at most \(max) characters") }
            if field == "name", string.trimmingCharacters(in: .whitespaces).isEmpty { return fail(400, "name must not be empty") }
        }
        var patch = JSONObject()
        for key in ["name", "title", "description", "notifications", "modelSelection", "unread", "color", "mascotExpression",
                    "mascotSilhouette", "pinned", "hidden", "speakReplies", "voice"] {
            if let value = body[key] { patch[key] = value }
        }
        if let section = body["section"] {
            if section.isNull { patch["section"] = .null } else {
                guard let text = section.string else { return fail(400, "section must be a string") }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 60 { return fail(400, "section must be at most 60 characters") }
                patch["section"] = trimmed.isEmpty ? .null : .string(trimmed)
            }
        }
        if let computer = body["computer"] {
            guard ["local", "vm", "off"].contains(computer.string ?? "") else { return fail(400, "computer must be local, vm, or off") }
            patch["computer"] = computer
        }
        for flag in ["autoApprove", "approvePeerComms", "chiefOfStaff", "composio"] {
            guard let value = body[flag] else { continue }
            guard value.bool != nil else { return fail(400, "\(flag) must be true or false") }
            patch[flag] = value
        }
        if body["hidden"]?.bool == true, bot["chiefOfStaff"]?.truthy == true, body["chiefOfStaff"]?.bool != false {
            return fail(400, "choose another Chief of Staff before hiding this bot")
        }
        if let allowed = body["alwaysAllow"] {
            guard let list = allowed.array, list.allSatisfy({ $0.string != nil }) else { return fail(400, "alwaysAllow must be a list of tool keys") }
            patch["alwaysAllow"] = .strings(Array(Set(list.compactMap(\.string))).sorted().prefix(200).map { $0 })
        }
        if let pinned = body["pinnedMessageId"] {
            if pinned.isNull || pinned.string == "" { patch["pinnedMessageId"] = .null }
            else if let id = pinned.string, id.range(of: #"^[\w-]+$"#, options: .regularExpression) != nil { patch["pinnedMessageId"] = .string(id) }
            else { return fail(400, "pinnedMessageId must be a message id") }
        }
        if let cwd = body["cwd"] {
            if cwd.isNull || cwd.string == "" { patch["cwd"] = .null } else {
                guard let path = cwd.string, path.hasPrefix("/") else { return fail(400, "cwd must be an absolute path") }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return fail(400, "cwd must be an existing folder")
                }
                patch["cwd"] = .string(path)
            }
        }
        // pictures come from the upload route; a PATCH may only clear them, or pick a sheet row
        for field in ["mascotAvatarSvg", "mascotAvatarImage"] {
            guard let value = body[field] else { continue }
            guard value.isNull || value.string == "" else { return fail(400, "\(field) can only be cleared") }
            patch[field] = .null
            if field == "mascotAvatarImage" { patch["mascotAvatarSheetRow"] = .null }
        }
        if let row = body["mascotAvatarSheetRow"] {
            if row.isNull { patch["mascotAvatarSheetRow"] = .null } else {
                guard let value = row.double, value == value.rounded(), (0...8).contains(value) else {
                    return fail(400, "mascotAvatarSheetRow must be an integer 0–8")
                }
                patch["mascotAvatarSheetRow"] = row
            }
        }
        let leavingLocal = bot["computer"]?.string == "local" && patch["computer"] != nil && patch["computer"]?.string != "local"
        if leavingLocal {
            let selection = ModelSelection(json: bot["modelSelection"])
            await harness.fleet.get(selection.instanceId)?.adapter.interruptTurn(threadId: bot["threadId"]?.string ?? "")
        }
        guard let updated = store.patchBot(id, patch, keepingNulls: AvatarSVG.fields) else { return fail(404, "no such bot") }
        return ok(["bot": .object(harness.wireBot(updated))])
    }

    /// A harness-native peer card: resolved here, the provider never sees it.
    private func peerAnswer(_ r: HTTPRequest) throws -> RouteResult? {
        let body = try r.json()
        guard let behavior = body["behavior"]?.string, ["allow", "deny", "answer"].contains(behavior) else { return nil }
        let requestId = body["requestId"].flatMap(Harness.text) ?? "undefined"
        guard harness.peerApprovals.resolve(requestId, behavior: behavior) else { return nil }
        return ok(["ok": true, "outcome": .string(behavior == "allow" ? "allowed-once" : "rejected")])
    }

    /// `/api/routines*`, `/api/routine-runs*`, `/api/webhooks*`.
    private func automationRoute(_ r: HTTPRequest) async throws -> RouteResult? {
        let path = r.path, method = r.method
        let routines = harness.routines!, webhooks = harness.webhooks!
        // the managers' own validation errors carry no status: 500, as in Node
        func run<T>(_ body: () throws -> T) throws -> T {
            do { return try body() } catch let error as RoutineManager.InputError { throw HTTPError(500, error.message) }
        }
        if path == "/api/routines", method == "GET" {
            let from = r.query["from"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            let to = r.query["to"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            return ok(["routines": .array(routines.routines.map(JSON.object)), "runs": .array(routines.listRuns(from: from, to: to).map(JSON.object))])
        }
        if path == "/api/routines", method == "POST" {
            let body = try r.json()
            return ok(["routine": .object(try run { try routines.create(body) })], 201)
        }
        if let m = match(#"^/api/routines/([\w-]+)/run$"#, path), method == "POST" {
            guard let started = routines.runNow(m[0]) else { return fail(404, "no such routine") }
            return ok(["run": .object(started)], 201)
        }
        if let m = match(#"^/api/routines/([\w-]+)$"#, path) {
            if method == "PATCH" {
                let body = try r.json()
                guard let routine = try run({ try routines.update(m[0], body) }) else { return fail(404, "no such routine") }
                return ok(["routine": .object(routine)])
            }
            if method == "DELETE" { return routines.remove(m[0]) ? ok(["ok": true]) : fail(404, "no such routine") }
        }
        if let m = match(#"^/api/routine-runs/([\w-]+)/(cancel|seen)$"#, path), method == "POST" {
            guard let result = m[1] == "cancel" ? routines.cancelRun(m[0]) : routines.markSeen(m[0]) else { return fail(404, "no such active run") }
            return ok(["run": .object(result)])
        }
        // management here; deliveries only on the webhook-only listener
        if path == "/api/webhooks", method == "GET" {
            return ok(["webhooks": .array(webhooks.list().map(JSON.object)), "attempts": .array(webhooks.attempts.map(JSON.object)),
                       "ingress": harness.webhookIngressStatus])
        }
        let credential = { (webhook: JSONObject, secret: String) -> JSON in
            WebhookIngress.credential(baseUrl: self.harness.webhookIngressBaseUrl, endpointId: webhook["endpointId"]?.string ?? "", secret: secret)
        }
        if path == "/api/webhooks", method == "POST" {
            let created = try webhooks.create(try r.json())
            return ok(["webhook": .object(created.webhook), "ingress": harness.webhookIngressStatus, "credential": credential(created.webhook, created.secret)], 201)
        }
        if let m = match(#"^/api/webhooks/([\w-]+)/(rotate|test)$"#, path), method == "POST" {
            if m[1] == "test" {
                let payload: JSON? = r.body.isEmpty ? nil : try JSON.parse(r.body)
                guard let result = try webhooks.test(m[0], payload: payload) else { return fail(404, "no such webhook") }
                return ok(.object(result), 202)
            }
            guard let rotated = webhooks.rotateSecret(m[0]) else { return fail(404, "no such webhook") }
            return ok(["webhook": .object(rotated.webhook), "ingress": harness.webhookIngressStatus, "credential": credential(rotated.webhook, rotated.secret)])
        }
        if let m = match(#"^/api/webhooks/([\w-]+)$"#, path) {
            if method == "PATCH" {
                guard let webhook = try webhooks.update(m[0], try r.json()) else { return fail(404, "no such webhook") }
                return ok(["webhook": .object(webhook)])
            }
            if method == "DELETE" { return webhooks.remove(m[0]) ? ok(["ok": true]) : fail(404, "no such webhook") }
        }
        return nil
    }

    private func respond(_ r: HTTPRequest, threadId: String, owner: JSONObject?) async throws -> RouteResult {
        let body = try r.json()
        guard let behavior = body["behavior"]?.string, ["allow", "deny", "answer"].contains(behavior) else {
            return fail(400, "behavior must be allow, deny, or answer")
        }
        let decision = RequestDecision(
            behavior: behavior, message: body["message"]?.string,
            selected: body["selected"]?.array?.compactMap(\.string), custom: body["custom"]?.string
        )
        let instanceId = ModelSelection(json: owner?["modelSelection"]).instanceId
        let outcome = await harness.answerRequest(threadId: threadId, instanceId: instanceId,
                                                  requestId: body["requestId"]?.string ?? "", decision: decision, decidedFor: owner)
        if outcome == .retryable {
            return fail(409, "the host did not acknowledge the answer; retry it")
        }
        return ok(["ok": true, "outcome": .string(outcome.rawValue)])
    }

    private func export(threadId: String, format: String) -> RouteResult {
        let bot = store.botByThread(threadId)
        let group = bot == nil ? store.groupByThread(threadId) : nil
        guard bot != nil || group != nil else { return fail(404, "no such conversation") }
        guard format == "markdown" || format == "json" else { return fail(400, "format must be markdown or json") }
        let title = bot.flatMap { store.taskByThread($0["id"]?.string ?? "", threadId)?["title"]?.string }
            ?? bot?["name"]?.string ?? group?["name"]?.string ?? "conversation"
        let cleaned = title.replacingOccurrences(of: #"[^\w\- ]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let filename = cleaned.isEmpty ? "conversation" : String(cleaned.prefix(60))
        let messages = store.activePath(threadId)
        if format == "json" {
            let slim = messages.map { JSON.object($0.removing("png", "mime")) }
            let body: JSON = ["name": .string(title), "threadId": .string(threadId), "messages": .array(slim)]
            return .response(HTTPResponse(status: 200, headers: [
                ("Content-Type", "application/json"), ("Content-Disposition", "attachment; filename=\"\(filename).json\""),
            ], body: Data(body.pretty().utf8)))
        }
        let userName = harness.config.string("profile", "name")?.trimmingCharacters(in: .whitespaces)
        var lines = ["# \(title)", ""]
        for message in messages where message["kind"]?.string == "text" {
            guard let text = message["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let who = message["role"]?.string == "user"
                ? (userName?.isEmpty == false ? userName! : "User")
                : (message["from"]?["name"]?.string ?? bot?["name"]?.string ?? "Bot")
            lines += ["**\(who):**", "", text, ""]
        }
        var markdown = lines.joined(separator: "\n")
        while markdown.hasSuffix("\n") || markdown.hasSuffix(" ") { markdown.removeLast() }
        return .response(HTTPResponse(status: 200, headers: [
            ("Content-Type", "text/markdown; charset=utf-8"), ("Content-Disposition", "attachment; filename=\"\(filename).md\""),
        ], body: Data((markdown + "\n").utf8)))
    }

    private func threadEvents(_ threadId: String, limit: Int) -> JSON {
        func read(_ dir: URL, kind: String) -> [JSON] {
            guard let text = try? String(contentsOf: dir.appendingPathComponent("\(threadId).ndjson"), encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line -> JSON? in
                guard let data = try? JSON.parse(String(line)) else { return nil }
                let at = data["createdAt"] ?? data["at"] ?? .null
                return ["kind": .string(kind), "at": at, "data": data]
            }
        }
        let runtime = read(harness.paths.events, kind: "runtime")
        let native = read(harness.paths.native, kind: "native")
        let merged = (runtime + native).sorted { ($0["at"]?.string ?? "") < ($1["at"]?.string ?? "") }
        return ["entries": .array(Array(merged.suffix(limit))),
                "total": ["runtime": .number(Double(runtime.count)), "native": .number(Double(native.count))]]
    }

    private func cliTest(_ body: JSONObject) async -> JSON {
        let parts = EnvPath.split(body["cli"]?.string ?? "")
        guard let first = parts.first else { return ["ok": false, "message": "no command"] }
        guard let executable = first.contains("/") ? first : EnvPath.which(first) else {
            return ["ok": false, "message": .string("\(first) was not found on PATH")]
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = Array(parts.dropFirst()) + ["--version"]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = EnvPath.augmented()
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ["ok": false, "message": .string(error.localizedDescription)])
                    return
                }
                let deadline = Date().addingTimeInterval(15)
                while process.isRunning, Date() < deadline { usleep(50_000) }
                if process.isRunning { process.terminate() }
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
                continuation.resume(returning: process.terminationStatus == 0
                    ? ["ok": true, "version": .string(firstLine)]
                    : ["ok": false, "message": .string(firstLine.isEmpty ? "exited with \(process.terminationStatus)" : firstLine)])
            }
        }
    }
}
