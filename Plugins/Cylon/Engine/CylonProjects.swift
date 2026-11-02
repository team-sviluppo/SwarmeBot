import Foundation
import HarnessCore

/// ClickUp belongs to Cylon. Read the old Code field until this project's setting is saved here.
@MainActor
struct CylonProjects {
    let harness: Harness

    private var store: CylonStore { CylonStore(harness: harness) }

    var projects: [JSONObject] {
        let file = harness.plugins.directory(for: "code").appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: file), let list = try? JSON.parse(data).array else { return [] }
        return list.compactMap(\.object)
    }

    func settings(_ id: String) throws -> JSONObject {
        guard let project = projects.first(where: { $0["id"]?.string == id }) else { throw HTTPError(404, "no such project") }
        let mine = store.read("projects.json")[id]?.object
        let value = mine?["clickupListId"] ?? project["clickupListId"] ?? .null
        return ["clickupListId": value]
    }

    func update(_ id: String, _ body: JSONObject) throws -> JSONObject {
        _ = try settings(id)
        if let key = body.keys.first(where: { $0 != "clickupListId" }) { throw HTTPError(400, "unknown Cylon project setting: \(key)") }
        var all = store.read("projects.json")
        var mine = all[id]?.object ?? JSONObject()
        if let value = body["clickupListId"] {
            if value.isNull { mine["clickupListId"] = .null }
            else {
                guard let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 64,
                      text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                    throw HTTPError(400, "clickupListId must be a list id")
                }
                mine["clickupListId"] = text.isEmpty ? .null : .string(text)
            }
        }
        all[id] = .object(mine)
        try store.write("projects.json", all)
        return try settings(id)
    }

    func prepare(_ turn: inout TurnSetup) {
        let owner = turn.group ?? turn.bot
        guard let id = owner["plugins"]?["code"]?["projectId"]?.string,
              id.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil,
              let project = projects.first(where: { $0["id"]?.string == id }), let settings = try? settings(id) else { return }
        var data = JSONObject()
        for key in ["id", "name", "repos"] { data[key] = project[key] ?? .null }
        data["clickupListId"] = settings["clickupListId"] ?? .null
        let folder = harness.plugins.directory(for: "cylon").appendingPathComponent("projects", isDirectory: true)
        let file = folder.appendingPathComponent(id + ".json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileIO.writeAtomic(JSON.object(data).data, to: file)
        } catch { return }
        turn.environment["SWARME_PROJECT_JSON"] = file.path
        if let list = settings["clickupListId"]?.string, !list.isEmpty {
            turn.system += "\nCylon uses ClickUp list \(list) for this project. Its configuration is in \(file.path), also in $SWARME_PROJECT_JSON."
        }
    }
}
