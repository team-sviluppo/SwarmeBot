// The board of a job that touches several repositories (docs/plans/2026-10-30-tabellone-multirepo.md).
//
// A person splits the job by hand into independent ClickUp tickets, one per repository, and links them there. The board
// groups those tickets: each one names the channel of its repository, in the order of priority the person gave (the order
// of the list, and nothing more: a priority blocks nothing). It shows where each ticket stands and starts it in its
// channel. It keeps no state of its own about a ticket's progress: that is read from the channel's pipeline, so a channel
// is still the one owner of its flow, and removing an item or the board stops nothing.
import Foundation
import HarnessCore

struct CylonBoardItem: Equatable {
    var id: String
    /// The project's role of the repository (`backend`, `app`…): what the channel "works on".
    var role: String
    var groupId: String
    var ticketId: String
    var tag: String
    var title: String?

    init(id: String = newId(), role: String, groupId: String, ticketId: String, tag: String, title: String?) {
        self.id = id
        self.role = role
        self.groupId = groupId
        self.ticketId = ticketId
        self.tag = tag
        self.title = title
    }

    init?(json: JSON) {
        guard let id = json["id"]?.string, let role = json["role"]?.string, let groupId = json["groupId"]?.string,
              let ticketId = json["ticketId"]?.string, let tag = json["tag"]?.string else { return nil }
        self.init(id: id, role: role, groupId: groupId, ticketId: ticketId, tag: tag, title: json["title"]?.string)
    }

    var json: JSON {
        var object = JSONObject([("id", .string(id)), ("role", .string(role)), ("groupId", .string(groupId)), ("ticketId", .string(ticketId)), ("tag", .string(tag))])
        if let title { object["title"] = .string(title) }
        return .object(object)
    }
}

struct CylonBoard {
    var id: String
    var projectId: String
    var title: String
    var parentUrl: String?
    var createdAt: Double
    /// In order of priority: the first counts most.
    var items: [CylonBoardItem]

    init(id: String = newId(), projectId: String, title: String, parentUrl: String?) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.parentUrl = parentUrl
        createdAt = nowMillis()
        items = []
    }

    init?(json: JSON) {
        guard let id = json["id"]?.string, let projectId = json["projectId"]?.string, let title = json["title"]?.string else { return nil }
        self.id = id
        self.projectId = projectId
        self.title = title
        parentUrl = json["parentUrl"]?.string
        createdAt = json["createdAt"]?.double ?? 0
        items = (json["items"]?.array ?? []).compactMap(CylonBoardItem.init(json:))
    }

    var json: JSON {
        var object = JSONObject([("id", .string(id)), ("projectId", .string(projectId)), ("title", .string(title)), ("createdAt", .number(createdAt))])
        if let parentUrl { object["parentUrl"] = .string(parentUrl) }
        object["items"] = .array(items.map(\.json))
        return .object(object)
    }
}

enum CylonBoards {
    static let maxBoards = 100
    static let maxItems = 30

    /// Where a ticket stands, read from its channel's pipeline: `channel-missing`, `not-started`, `other-ticket` (the channel
    /// works on a ticket that is not this one), `done` (the pull request phase is over), `failed`, `running` (a phase is
    /// being worked on), `waiting` (one is, and the channel is idle: the bot asked something) and `ready` (between two phases).
    static func state(ticketId: String, pipeline: CylonPipeline?, channelExists: Bool, channelBusy: Bool) -> String {
        guard channelExists else { return "channel-missing" }
        guard let pipeline else { return "not-started" }
        // a spec makes a new ticket: the one the board was given is the seed, which the pipeline keeps
        guard pipeline.ticketId == ticketId || pipeline.specTicketId == ticketId else { return "other-ticket" }
        if pipeline.next == nil { return "done" }
        if CylonPhase.allCases.contains(where: { pipeline.state($0) == .failed }) { return "failed" }
        if pipeline.running != nil { return channelBusy ? "running" : "waiting" }
        return "ready"
    }

    static func title(_ value: JSON?, field: String, required: Bool) throws -> String? {
        guard let value, !value.isNull else {
            if required { throw HTTPError(400, "\(field) is required") }
            return nil
        }
        guard let raw = value.string else { throw HTTPError(400, "\(field) must be text") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { if required { throw HTTPError(400, "\(field) is required") }; return nil }
        guard text.count <= 120 else { throw HTTPError(400, "\(field) is too long") }
        return text
    }

    /// An address to show, never to fetch: `http(s)` only.
    static func link(_ value: JSON?) throws -> String? {
        guard let value, !value.isNull else { return nil }
        guard let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard raw.count <= 500, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            throw HTTPError(400, "parentUrl must be an http(s) address")
        }
        return raw
    }

    /// The new order, if `order` names every item once and nothing else.
    static func reordered(_ items: [CylonBoardItem], by order: [String]) throws -> [CylonBoardItem] {
        guard order.count == items.count, Set(order).count == order.count else { throw HTTPError(400, "order must name every ticket of the board once") }
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return try order.map { id in
            guard let item = byId[id] else { throw HTTPError(400, "order names a ticket that is not on the board") }
            return item
        }
    }
}

extension CylonStore {
    var boards: [CylonBoard] { (read("boards.json")["boards"]?.array ?? []).compactMap(CylonBoard.init(json:)) }

    func save(boards: [CylonBoard]) throws {
        try write("boards.json", ["boards": .array(boards.map(\.json))])
    }

    func board(_ id: String) -> CylonBoard? { boards.first { $0.id == id } }

    /// Changes one board and saves them all; a board that is not there is 404.
    func update(board id: String, _ change: (inout CylonBoard) throws -> Void) throws -> CylonBoard {
        var all = boards
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw HTTPError(404, "no such board") }
        try change(&all[index])
        try save(boards: all)
        return all[index]
    }
}

extension CylonEnginePlugin {
    // MARK: the channel of a ticket

    /// The channels of a project that work on a role of it: where a ticket of that repository goes.
    private func channels(project: String, role: String, harness: Harness) -> [JSONObject] {
        harness.store.groups.filter { $0["plugins"]?["code"]?["projectId"]?.string == project && $0["plugins"]?["code"]?["role"]?.string == role }
    }

    private func pick(channelFor role: String, groupId: String?, project: String, harness: Harness) throws -> JSONObject {
        let candidates = channels(project: project, role: role, harness: harness)
        let chosen: JSONObject
        if let groupId {
            guard let found = candidates.first(where: { $0["id"]?.string == groupId }) else {
                throw HTTPError(400, "that channel does not work on \(role) in this project")
            }
            chosen = found
        } else if candidates.count == 1 {
            chosen = candidates[0]
        } else if candidates.isEmpty {
            throw HTTPError(409, "no channel works on \(role) in this project: make one, and choose the project and \"Works on\" in its settings")
        } else {
            throw HTTPError(400, "several channels work on \(role): send groupId (\(candidates.compactMap { $0["name"]?.string }.joined(separator: ", ")))")
        }
        guard chosen["plugins"]?["cylon"]?["follow"]?.bool == true else {
            throw HTTPError(409, "the channel \(chosen["name"]?.string ?? "") does not follow the Cylon flow: switch it on in its settings")
        }
        return chosen
    }

    // MARK: what the app shows

    func boardWire(_ board: CylonBoard, harness: Harness) async -> JSON {
        let store = CylonStore(harness: harness)
        var items: [JSON] = []
        var counts = (done: 0, prOpen: 0, running: 0, notStarted: 0, problems: 0)
        for item in board.items {
            let group = harness.store.group(item.groupId)
            let pipeline = store.pipeline(of: item.groupId)
            let busy = group?["busyBotId"]?.string?.isEmpty == false
            let state = CylonBoards.state(ticketId: item.ticketId, pipeline: pipeline, channelExists: group != nil, channelBusy: busy)
            var out = item.json.object ?? JSONObject()
            out["state"] = .string(state)
            if let group {
                out["channel"] = ["name": group["name"] ?? .null, "follows": .bool(group["plugins"]?["cylon"]?["follow"]?.bool == true)]
                // the channel's own status, as its bar reads it: phases, who plays them, what is missing
                out["flow"] = await status(of: item.groupId, harness: harness)
            } else {
                out["channel"] = .null
            }
            if let url = pipeline?.prUrl, state == "done" || state == "ready" || state == "running" || state == "waiting" { out["prUrl"] = .string(url) }
            items.append(.object(out))
            switch state {
            case "done": counts.done += 1
            case "running", "waiting", "ready": counts.running += 1
            case "not-started": counts.notStarted += 1
            case "failed", "channel-missing": counts.problems += 1
            default: break
            }
            if pipeline?.prUrl != nil, state != "other-ticket", state != "channel-missing" { counts.prOpen += 1 }
        }

        // the bots of a project play the same part in all its channels, so a bot that is busy holds back the others
        var busyBots: [JSON] = []
        var seen = Set<String>()
        for botId in CylonPhase.allCases.compactMap({ store.roles(of: board.projectId)[$0] }) where seen.insert(botId).inserted {
            guard let bot = harness.store.bot(botId), Store.isBusy(bot) else { continue }
            let where_ = harness.store.groups.first { $0["busyBotId"]?.string == botId }?["name"]
            busyBots.append(["botId": .string(botId), "name": bot["name"] ?? .null, "channel": where_ ?? .null])
        }

        var object = board.json.object ?? JSONObject()
        object["items"] = .array(items)
        object["summary"] = ["total": .number(Double(board.items.count)), "done": .number(Double(counts.done)), "prOpen": .number(Double(counts.prOpen)),
                             "running": .number(Double(counts.running)), "notStarted": .number(Double(counts.notStarted)), "problems": .number(Double(counts.problems))]
        object["busyBots"] = .array(busyBots)
        return .object(object)
    }

    // MARK: routes

    func boardRoutes(_ router: PluginRouter) {
        router.get("/api/cylon/boards") { request in
            let harness = request.harness
            self.harness = harness
            let project = request.http.query["projectId"]
            var wires: [JSON] = []
            for board in CylonStore(harness: harness).boards where project == nil || board.projectId == project { wires.append(await self.boardWire(board, harness: harness)) }
            return .response(.json(200, ["boards": .array(wires)]))
        }
        router.post("/api/cylon/boards") { request in
            let harness = request.harness
            self.harness = harness
            let store = CylonStore(harness: harness)
            let body = try request.http.json()
            guard let project = body["projectId"]?.string, project.range(of: #"^[\w-]{1,80}$"#, options: .regularExpression) != nil else { throw HTTPError(400, "projectId is required") }
            guard store.boards.count < CylonBoards.maxBoards else { throw HTTPError(409, "at most \(CylonBoards.maxBoards) boards") }
            let board = CylonBoard(projectId: project, title: try CylonBoards.title(body["title"], field: "title", required: true) ?? "", parentUrl: try CylonBoards.link(body["parentUrl"]))
            try store.save(boards: store.boards + [board])
            return .response(.json(201, ["board": await self.boardWire(board, harness: harness)]))
        }
        router.get("/api/cylon/boards/:id") { request in
            let harness = request.harness
            guard let board = CylonStore(harness: harness).board(request.params["id"] ?? "") else { throw HTTPError(404, "no such board") }
            return .response(.json(200, ["board": await self.boardWire(board, harness: harness)]))
        }
        router.patch("/api/cylon/boards/:id") { request in
            let harness = request.harness
            let body = try request.http.json()
            let board = try CylonStore(harness: harness).update(board: request.params["id"] ?? "") { board in
                if body["title"] != nil { board.title = try CylonBoards.title(body["title"], field: "title", required: true) ?? board.title }
                if body["parentUrl"] != nil { board.parentUrl = try CylonBoards.link(body["parentUrl"]) }
                if let order = body["order"] {
                    guard let ids = order.array?.compactMap(\.string), ids.count == order.array?.count else { throw HTTPError(400, "order must be a list of ticket ids") }
                    board.items = try CylonBoards.reordered(board.items, by: ids)
                }
            }
            return .response(.json(200, ["board": await self.boardWire(board, harness: harness)]))
        }
        router.delete("/api/cylon/boards/:id") { request in
            let store = CylonStore(harness: request.harness)
            let id = request.params["id"] ?? ""
            guard store.board(id) != nil else { throw HTTPError(404, "no such board") }
            try store.save(boards: store.boards.filter { $0.id != id })
            return .response(.json(200, ["ok": true]))
        }
        router.post("/api/cylon/boards/:id/items") { request in
            let harness = request.harness
            let body = try request.http.json()
            let store = CylonStore(harness: harness)
            guard let current = store.board(request.params["id"] ?? "") else { throw HTTPError(404, "no such board") }
            guard current.items.count < CylonBoards.maxItems else { throw HTTPError(409, "at most \(CylonBoards.maxItems) tickets on a board") }
            guard let role = body["role"]?.string, role.range(of: #"^[a-z][a-z0-9-]{1,30}$"#, options: .regularExpression) != nil else { throw HTTPError(400, "role is required: the repository's role in the project") }
            guard let raw = body["ticket"]?.string, let ticket = CylonDetect.ticketId(raw) else { throw HTTPError(400, "ticket must be a ClickUp ticket's id or address") }
            let tag = body["tag"]?.string ?? "cylon-plan"
            if tag == "cylon-investigate" { throw HTTPError(400, "a cylon-investigate ticket is outside the flow: it is not put on a board") }
            guard CylonPhase.tags.contains(tag) else { throw HTTPError(400, "tag must be \(CylonPhase.tags.joined(separator: " or "))") }
            guard !current.items.contains(where: { $0.ticketId == ticket }) else { throw HTTPError(409, "this ticket is already on the board") }
            let channel = try self.pick(channelFor: role, groupId: body["groupId"]?.string, project: current.projectId, harness: harness)
            let item = CylonBoardItem(role: role, groupId: channel["id"]?.string ?? "", ticketId: ticket, tag: tag, title: try CylonBoards.title(body["title"], field: "title", required: false))
            let board = try store.update(board: current.id) { $0.items.append(item) }
            return .response(.json(201, ["board": await self.boardWire(board, harness: harness)]))
        }
        router.delete("/api/cylon/boards/:id/items/:item") { request in
            let harness = request.harness
            let itemId = request.params["item"] ?? ""
            let board = try CylonStore(harness: harness).update(board: request.params["id"] ?? "") { board in
                guard board.items.contains(where: { $0.id == itemId }) else { throw HTTPError(404, "no such ticket on the board") }
                board.items.removeAll { $0.id == itemId }
            }
            return .response(.json(200, ["board": await self.boardWire(board, harness: harness)]))
        }
        router.post("/api/cylon/boards/:id/items/:item/start") { request in
            let harness = request.harness
            self.harness = harness
            guard let board = CylonStore(harness: harness).board(request.params["id"] ?? "") else { throw HTTPError(404, "no such board") }
            guard let item = board.items.first(where: { $0.id == request.params["item"] }) else { throw HTTPError(404, "no such ticket on the board") }
            let replace = (request.http.body.isEmpty ? nil : try request.http.json()["replace"]?.bool) ?? false
            try await self.start(item, harness: harness, replace: replace)
            return .response(.json(200, ["board": await self.boardWire(board, harness: harness), "started": .string(item.id)]))
        }
        router.post("/api/cylon/boards/:id/start-next") { request in
            let harness = request.harness
            self.harness = harness
            let store = CylonStore(harness: harness)
            guard let board = store.board(request.params["id"] ?? "") else { throw HTTPError(404, "no such board") }
            let replace = (request.http.body.isEmpty ? nil : try request.http.json()["replace"]?.bool) ?? false
            // the first one in the order of priority that nobody has started: a ticket whose channel is busy with another is not skipped over
            guard let next = board.items.first(where: { item in
                CylonBoards.state(ticketId: item.ticketId, pipeline: store.pipeline(of: item.groupId), channelExists: harness.store.group(item.groupId) != nil, channelBusy: false) == "not-started"
            }) else { throw HTTPError(409, "there is nothing left to start on this board") }
            try await self.start(next, harness: harness, replace: replace)
            return .response(.json(200, ["board": await self.boardWire(board, harness: harness), "started": .string(next.id)]))
        }
    }

    /// The same start as the channel's own "Start a ticket…", with the same refusals.
    private func start(_ item: CylonBoardItem, harness: Harness, replace: Bool) async throws {
        guard let group = harness.store.group(item.groupId) else { throw HTTPError(409, "the channel of this ticket no longer exists: take the ticket off the board") }
        if let pipeline = CylonStore(harness: harness).pipeline(of: item.groupId), pipeline.ticketId == item.ticketId || pipeline.specTicketId == item.ticketId {
            throw HTTPError(409, "this ticket is already being followed in its channel")
        }
        var body: JSONObject = ["ticket": .string(item.ticketId), "tag": .string(item.tag), "replace": .bool(replace)]
        if let title = item.title { body["title"] = .string(title) }
        try await begin(item.groupId, group: group, body: body, harness: harness)
    }
}
