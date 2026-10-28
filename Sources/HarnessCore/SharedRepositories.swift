// Shared definitions are read from a repository; all runtime state stays local.
import Foundation

public enum SharedRepositoryKind: String, CaseIterable, Sendable {
    case bots, connectors
    var fileName: String { self == .bots ? "bots.json" : "mcp-connectors.json" }
}

@MainActor
public final class SharedRepositories {
    private unowned let harness: Harness
    init(harness: Harness) { self.harness = harness }

    func folder(_ kind: SharedRepositoryKind) -> String? {
        harness.config.string("sharedRepositories", kind.rawValue)
    }

    func setFolder(_ kind: SharedRepositoryKind, _ raw: String?) throws {
        var path: String?
        if let raw, !raw.isEmpty {
            guard raw.hasPrefix("/") else { throw HTTPError(400, "folder must be an absolute path") }
            let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw HTTPError(400, "folder must be an existing readable directory")
            }
            guard url != harness.paths.root.standardizedFileURL.resolvingSymlinksInPath() else {
                throw HTTPError(400, "choose a shared folder separate from the local data directory")
            }
            path = url.path
        }
        try harness.config.setSharedFolder(kind.rawValue, path)
    }

    private func source(_ kind: SharedRepositoryKind, _ id: String) -> JSON {
        ["folder": .string(folder(kind) ?? ""), "id": .string(id)]
    }

    private func local(_ kind: SharedRepositoryKind) -> [JSONObject] {
        kind == .bots ? harness.store.bots : harness.mcpConnectors.connectors
    }

    private func imported(_ kind: SharedRepositoryKind, _ id: String) -> JSONObject? {
        local(kind).first { $0["sharedSource"] == source(kind, id) }
    }

    private func file(_ kind: SharedRepositoryKind) throws -> URL {
        guard let path = folder(kind) else { throw HTTPError(400, "choose a shared folder first") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            throw HTTPError(400, "shared folder is unavailable; local copies have been kept")
        }
        return URL(fileURLWithPath: path).appendingPathComponent(kind.fileName)
    }

    /// The whole catalog is validated before importing or syncing anything.
    func definitions(_ kind: SharedRepositoryKind) throws -> [JSONObject] {
        let url = try file(kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 8 * 1024 * 1024, let array = try JSON.parse(data).array, array.count <= 200 else {
            throw HTTPError(400, "shared catalog must be a JSON array of at most 200 definitions (8 MB)")
        }
        var ids = Set<String>()
        return try array.map { value in
            guard let body = value.object, let id = body["id"]?.string,
                  id.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
                  ids.insert(id).inserted else { throw HTTPError(400, "shared definitions need valid unique ids") }
            if kind == .bots {
                guard let name = body["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
                      let instructions = body["description"]?.string, instructions.count <= 8000,
                      (body["title"] == nil || body["title"]?.string != nil), (body["title"]?.string?.count ?? 0) <= 200 else {
                    throw HTTPError(400, "a shared bot needs name (100 characters), description (8000) and optional title (200)")
                }
                return ["id": .string(id), "name": .string(name), "description": .string(instructions), "title": body["title"] ?? ""]
            }
            guard id.range(of: MCPConnectors.idPattern, options: .regularExpression) != nil,
                  !MCPConnectors.reservedIds.contains(id) else { throw HTTPError(400, "invalid or reserved shared connector id") }
            do { return try Self.connectorDefinition(body) }
            catch { throw HTTPError(400, "invalid shared connector \(id): \(error.localizedDescription)") }
        }
    }

    /// Only portable configuration crosses machines. OAuth discoveries, tokens,
    /// secret values, checks and machine-local enable switches never do.
    static func connectorDefinition(_ body: JSONObject) throws -> JSONObject {
        var clean = JSONObject()
        for key in ["id", "name", "transport", "command", "args", "cwd", "url", "auth", "tools", "toolTimeoutSeconds"] {
            clean[key] = body[key]
        }
        for kind in ["env", "headers"] {
            var values = JSONObject()
            for (key, value) in body[kind]?.object ?? JSONObject() {
                let sensitive = key.range(of: "KEY|TOKEN|SECRET|PASSWORD|AUTH|COOKIE|CREDENTIAL", options: [.caseInsensitive, .regularExpression]) != nil
                values[key] = value["secret"]?.bool == true || sensitive ? ["secret": true] : value
            }
            clean[kind] = .object(values)
        }
        if let settings = body["oauth"]?.object {
            var oauth = JSONObject()
            for key in ["clientId", "scope", "redirectUri"] { oauth[key] = settings[key] }
            if settings["clientSecret"] != nil { oauth["clientSecret"] = ["secret": true] }
            clean["oauth"] = .object(oauth)
        }
        let (record, _) = try MCPConnectors.validate(clean, id: body["id"]?.string ?? "", previousSecrets: nil)
        return record.removing("enabled")
    }

    func snapshot(_ kind: SharedRepositoryKind) -> JSON {
        var entries: [JSON] = []
        var problem: String?
        if folder(kind) != nil {
            do {
                entries = try definitions(kind).map { record in
                    let id = record["id"]!.string!
                    let found = imported(kind, id)
                    let collision = kind == .connectors && found == nil && harness.mcpConnectors.connector(id) != nil
                    return ["id": .string(id), "name": record["name"] ?? .string(id),
                            "description": .string(record["description"]?.string ?? record["url"]?.string ?? record["command"]?.string ?? ""),
                            "imported": .bool(found != nil), "conflict": .bool(collision)]
                }
            } catch { problem = (error as? HTTPError)?.message ?? error.localizedDescription }
        }
        return ["folder": folder(kind).map(JSON.string) ?? .null, "fileName": .string(kind.fileName),
                "entries": .array(entries), "problem": problem.map(JSON.string) ?? .null]
    }

    func importSelected(_ kind: SharedRepositoryKind, ids: [String]) throws {
        let records = try definitions(kind)
        let selected = records.filter { ids.contains($0["id"]!.string!) }
        guard !ids.isEmpty, Set(ids).count == ids.count, selected.count == ids.count else {
            throw HTTPError(400, "select existing unique definitions to import")
        }
        // Refuse a collision before creating any local record.
        for record in selected where kind == .connectors {
            let id = record["id"]!.string!
            if harness.mcpConnectors.connector(id) != nil, imported(kind, id) == nil {
                throw HTTPError(409, "a local connector already uses id \(id); it has not been overwritten")
            }
        }
        if kind == .connectors {
            let additions = selected.filter { imported(kind, $0["id"]!.string!) == nil }.count
            guard harness.mcpConnectors.connectors.count + additions <= MCPConnectors.maxConnectors else {
                throw HTTPError(400, "too many local connectors")
            }
        }
        for record in selected {
            let id = record["id"]!.string!
            if imported(kind, id) != nil { try refresh(kind, record); continue }
            if kind == .bots {
                let bot = harness.store.createBot(profile: record, seedMessages: false)
                _ = harness.store.patchBot(bot["id"]!.string!, ["sharedSource": source(kind, id)])
            } else {
                _ = try harness.mcpConnectors.create(record)
                try harness.mcpConnectors.setSharedSource(id, source(kind, id))
            }
        }
        if kind == .connectors { harness.broadcast(["kind": "mcpConnectors"]) }
    }

    private func refresh(_ kind: SharedRepositoryKind, _ record: JSONObject) throws {
        let id = record["id"]!.string!
        guard let before = imported(kind, id), let localId = before["id"]?.string else { return }
        if kind == .bots {
            var patch = JSONObject()
            for key in ["name", "title", "description"] where before[key] != record[key] { patch[key] = record[key] }
            if !patch.isEmpty { harness.store.patchBot(localId, patch) }
        } else {
            guard try Self.connectorDefinition(before) != record else { return }
            var updated = record
            updated["enabled"] = before["enabled"] ?? true
            _ = try harness.mcpConnectors.update(localId, updated)
            harness.mcpPool.invalidate(localId)
            harness.broadcast(["kind": "mcpConnectors"])
        }
    }

    /// Called at engine boot and when a Mac client connects to an existing engine.
    @discardableResult
    public func sync() -> [String] {
        var problems: [String] = []
        for kind in SharedRepositoryKind.allCases where folder(kind) != nil {
            do { for record in try definitions(kind) { try refresh(kind, record) } }
            catch { problems.append((error as? HTTPError)?.message ?? error.localizedDescription) }
        }
        return problems
    }

    /// The profile editor writes through to the selected shared repository.
    func updateBot(_ bot: JSONObject, patch: JSONObject) throws {
        guard let id = bot["sharedSource"]?["id"]?.string,
              bot["sharedSource"] == source(.bots, id) else {
            throw HTTPError(409, "select this bot's shared folder in Settings before editing its shared profile")
        }
        var all = try definitions(.bots)
        guard let index = all.firstIndex(where: { $0["id"]?.string == id }) else {
            throw HTTPError(409, "the shared bot is missing; local instructions have been kept")
        }
        var changed = false
        for key in ["name", "title", "description"] {
            if let value = patch[key], value != all[index][key] { all[index][key] = value; changed = true }
        }
        guard changed else { return }
        let url = try file(.bots)
        guard !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else {
            throw HTTPError(400, "shared catalog must not be a symbolic link")
        }
        try FileIO.writeAtomic(JSON.array(all.map(JSON.object)).data, to: url)
        for record in all { try refresh(.bots, record) }
    }

    /// Explicitly publish a local definition. Existing shared ids are replaced
    /// only by their own imported copy, so a name collision cannot overwrite a peer.
    func publish(_ kind: SharedRepositoryKind, localId: String) throws {
        guard let record = local(kind).first(where: { $0["id"]?.string == localId }) else { throw HTTPError(404, "no such local definition") }
        var all = try definitions(kind)
        let existingSource = record["sharedSource"]
        let sharedId = existingSource?["folder"]?.string == folder(kind) ? existingSource?["id"]?.string ?? localId : localId
        var definition: JSONObject
        if kind == .bots {
            definition = ["id": .string(sharedId), "name": record["name"] ?? "", "title": record["title"] ?? "", "description": record["description"] ?? ""]
        } else {
            definition = try Self.connectorDefinition(record)
            definition["id"] = .string(sharedId)
        }
        if let index = all.firstIndex(where: { $0["id"]?.string == sharedId }) {
            guard existingSource == source(kind, sharedId) else { throw HTTPError(409, "shared id already exists") }
            all[index] = definition
        } else {
            guard all.count < 200 else { throw HTTPError(400, "shared catalog is full") }
            all.append(definition)
        }
        let url = try file(kind)
        guard !((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) else {
            throw HTTPError(400, "shared catalog must not be a symbolic link")
        }
        try FileIO.writeAtomic(JSON.array(all.map(JSON.object)).data, to: url)
        if kind == .bots { harness.store.patchBot(localId, ["sharedSource": source(kind, sharedId)]) }
        else { try harness.mcpConnectors.setSharedSource(localId, source(kind, sharedId)); harness.broadcast(["kind": "mcpConnectors"]) }
    }
}

@MainActor
enum SharedRepositoryRoutes {
    static func handle(_ r: HTTPRequest, harness: Harness) throws -> RouteResult? {
        guard r.path.hasPrefix("/api/shared-repositories/") else { return nil }
        let parts = r.path.dropFirst("/api/shared-repositories/".count).split(separator: "/").map(String.init)
        if parts == ["sync"], r.method == "POST" {
            guard r.isJSON else { return .response(.error(415, "content-type must be application/json")) }
            return .response(.json(200, ["problems": .strings(harness.sharedRepositories.sync())]))
        }
        guard let name = parts.first, let kind = SharedRepositoryKind(rawValue: name), parts.count <= 2 else { return nil }
        let repository = harness.sharedRepositories
        if r.method == "GET", parts.count == 1 { return .response(.json(200, repository.snapshot(kind))) }
        guard r.isJSON else { return .response(.error(415, "content-type must be application/json")) }
        let body = try r.json()
        if r.method == "PUT", parts.count == 1 {
            guard let folder = body["folder"], folder.isNull || folder.string != nil else { throw HTTPError(400, "folder must be a string or null") }
            try repository.setFolder(kind, body["folder"]?.string)
        } else if r.method == "POST", parts.last == "import" {
            guard let values = body["ids"]?.array, values.allSatisfy({ $0.string != nil }) else { throw HTTPError(400, "ids must be a list of strings") }
            try repository.importSelected(kind, ids: values.compactMap(\.string))
        } else if r.method == "POST", parts.last == "publish" {
            guard let id = body["id"]?.string else { throw HTTPError(400, "id is required") }
            try repository.publish(kind, localId: id)
        } else { return nil }
        return .response(.json(200, repository.snapshot(kind)))
    }
}
