import Foundation
import HarnessCore

@MainActor
struct CodeChats {
    let harness: Harness
    private var file: URL { harness.plugins.directory(for: "code").appendingPathComponent("chats.json") }
    private var metadata: JSONObject { (try? JSON.parse(Data(contentsOf: file)).object) ?? JSONObject() }

    func recent() -> JSON {
        let saved = metadata
        var rows: [JSONObject] = []
        for bot in harness.store.bots where bot["codeMode"] == true && bot["hidden"] != true {
            guard let botId = bot["id"]?.string else { continue }
            for task in harness.store.tasks(botId) {
                guard let thread = task["threadId"]?.string, saved[thread]?["archived"] != true else { continue }
                rows.append(["botId": .string(botId), "name": bot["name"] ?? "", "threadId": .string(thread), "title": task["title"] ?? "",
                             "updatedAt": harness.store.messages(thread).last?["at"] ?? task["createdAt"] ?? 0])
            }
        }
        rows.sort { ($0["updatedAt"]?.double ?? 0) > ($1["updatedAt"]?.double ?? 0) }
        return ["chats": .array(rows.prefix(20).map(JSON.object))]
    }

    func patch(thread: String, body: JSONObject) throws -> JSON {
        guard harness.store.botByThread(thread) != nil else { throw HTTPError(404, "no such task") }
        var all = metadata, record = all[thread]?.object ?? JSONObject()
        if let archived = body["archived"] {
            guard archived.bool != nil else { throw HTTPError(400, "archived must be true or false") }
            record["archived"] = archived
        }
        if body["read"]?.bool == true {
            record["lastReadReply"] = harness.store.messages(thread).last { $0["role"] == "bot" && $0["kind"] == "text" }?["id"] ?? .null
        }
        all[thread] = .object(record)
        try FileIO.writeAtomic(JSON.object(all).data, to: file)
        return .object(record)
    }

    func list(botId: String) async throws -> JSON {
        guard let bot = harness.store.bot(botId) else { throw HTTPError(404, "no such bot") }
        let saved = metadata
        var folders: [String: JSON] = [:], chats: [JSON] = []
        for task in harness.store.tasks(botId) {
            guard let thread = task["threadId"]?.string else { continue }
            let messages = harness.store.messages(thread)
            let lastReply = messages.last { $0["role"] == "bot" && $0["kind"] == "text" }?["id"]
            let busy = Store.isBusy(bot) && bot["threadId"]?.string == thread
                && !harness.store.groups.contains { $0["busyBotId"]?.string == botId }
            let waiting = messages.contains { $0["kind"] == "options" && $0["card"]?["requestId"] != nil && $0["card"]?["answered"] == nil && $0["card"]?["dismissed"] != true }
            let failed = messages.last.map { $0["kind"] == "activity" && $0["tool"]?["ok"] == false } ?? false
            let unread = lastReply != nil && lastReply != saved[thread]?["lastReadReply"]
            var row: JSONObject = ["threadId": .string(thread), "title": task["title"] ?? "", "createdAt": task["createdAt"] ?? 0,
                "updatedAt": messages.last?["at"] ?? task["createdAt"] ?? 0, "pinned": task["pinned"] ?? false,
                "archived": saved[thread]?["archived"] ?? false, "unread": .bool(unread),
                "status": .string(waiting && busy ? "waiting" : busy ? "working" : failed ? "error" : unread ? "unread" : "done")]
            if let folder = ThreadFiles.roots(harness.store, harness.paths, threadId: thread)?.first {
                let key = ThreadGit.canonical(folder)
                if folders[key] == nil { folders[key] = await ThreadGit.wire(folder: folder) }
                row["git"] = folders[key]
            }
            chats.append(.object(row))
        }
        return ["chats": .array(chats)]
    }

    func search(botId: String, query: String) throws -> JSON {
        guard let bot = harness.store.bot(botId) else { throw HTTPError(404, "no such bot") }
        let threads = harness.store.tasks(botId).compactMap { $0["threadId"]?.string }
        for thread in threads { _ = harness.store.messages(thread) }
        let hits = harness.store.search(query, limit: 50, threads: threads).map { hit -> JSON in
            var hit = hit
            hit["name"] = bot["name"]
            hit["botId"] = .string(botId)
            hit["task"] = harness.store.taskByThread(botId, hit["threadId"]?.string ?? "")?["title"]
            hit["onActivePath"] = .bool(harness.store.activePath(hit["threadId"]?.string ?? "").contains { $0["id"] == hit["messageId"] })
            return .object(hit)
        }
        return ["hits": .array(hits)]
    }
}
