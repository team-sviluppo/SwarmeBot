// Projects (docs/plans/2026-10-28-code-mode-t3.md §7): a name, a ClickUp list and the folders of a
// piece of work with their roles, kept on the engine because the folders are on its machine. A bot or
// a channel belongs to at most one, and says which of its folders it works on; the others are linked
// to it read-only, for context.
//
// The records are kept as JSON objects, so a field a newer version adds survives an older one's write.
import Foundation
import HarnessCore

enum ProjectRole {
    /// The folders a project can name, in the order they are shown.
    static let all = ["backend", "backoffice", "app", "bruno"]
}

@MainActor
struct ProjectStore {
    private let harness: Harness
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("projects.json") }
    /// What the agents read: one file per project (`SWARME_PROJECT_JSON`).
    private var agentFolder: URL { directory.appendingPathComponent("projects", isDirectory: true) }

    init(harness: Harness) {
        self.harness = harness
        directory = harness.plugins.directory(for: "code")
    }

    var all: [JSONObject] {
        guard let data = try? Data(contentsOf: file), let array = try? JSON.parse(data).array else { return [] }
        return array.compactMap(\.object)
    }

    func project(_ id: String) -> JSONObject? { all.first { $0["id"]?.string == id } }

    func agentFile(_ id: String) -> URL { agentFolder.appendingPathComponent("\(id).json") }

    // MARK: validation

    /// The fields of a project from a request, checked. `partial` leaves out what the request does not carry.
    static func clean(_ body: JSONObject, partial: Bool) throws -> JSONObject {
        var out = JSONObject()
        if let name = body["name"] {
            guard let text = name.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 100 else {
                throw HTTPError(400, "name must be 1 to 100 characters")
            }
            out["name"] = .string(text)
        } else if !partial {
            throw HTTPError(400, "name is required")
        }
        if let list = body["clickupListId"] {
            if list.isNull {
                out["clickupListId"] = .null
            } else {
                guard let text = list.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 64,
                      text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                    throw HTTPError(400, "clickupListId must be a list id")
                }
                out["clickupListId"] = text.isEmpty ? .null : .string(text)
            }
        }
        if let repos = body["repos"] {
            guard let array = repos.array else { throw HTTPError(400, "repos must be a list") }
            var seen = Set<String>()
            var clean: [JSON] = []
            for entry in array {
                guard let role = entry["role"]?.string, ProjectRole.all.contains(role) else {
                    throw HTTPError(400, "a repo's role must be one of \(ProjectRole.all.joined(separator: ", "))")
                }
                guard seen.insert(role).inserted else { throw HTTPError(400, "the \(role) folder is listed twice") }
                guard let path = entry["path"]?.string?.trimmingCharacters(in: .whitespaces), path.hasPrefix("/") else {
                    throw HTTPError(400, "the \(role) path must be an absolute folder")
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw HTTPError(400, "the \(role) folder does not exist on this machine: \(path)")
                }
                var repo: JSONObject = JSONObject([("role", .string(role)), ("path", .string(path))])
                if let scripts = entry["scripts"] {
                    guard let list = scripts.array, list.count <= 20, list.allSatisfy({ $0["name"]?.string?.isEmpty == false && $0["command"]?.string?.isEmpty == false }) else {
                        throw HTTPError(400, "scripts must be a list of at most 20 {name, command}")
                    }
                    repo["scripts"] = .array(list.map { .object(JSONObject([("name", $0["name"]!), ("command", $0["command"]!)])) })
                }
                clean.append(.object(repo))
            }
            // in the order the roles are shown, not the order they were sent
            out["repos"] = .array(clean.sorted { (ProjectRole.all.firstIndex(of: $0["role"]?.string ?? "") ?? 99) < (ProjectRole.all.firstIndex(of: $1["role"]?.string ?? "") ?? 99) })
        } else if !partial {
            out["repos"] = .array([])
        }
        return out
    }

    // MARK: writing

    func create(_ body: JSONObject) throws -> JSONObject {
        var project = try Self.clean(body, partial: false)
        project["id"] = .string(UUID().uuidString.lowercased())
        project["createdAt"] = .number((Date().timeIntervalSince1970 * 1000).rounded())
        try save(all + [project])
        return project
    }

    func update(_ id: String, _ body: JSONObject) throws -> JSONObject {
        var projects = all
        guard let index = projects.firstIndex(where: { $0["id"]?.string == id }) else { throw HTTPError(404, "no such project") }
        let changes = try Self.clean(body, partial: true)
        let before = projects[index]
        for (key, value) in changes { projects[index][key] = value }
        try save(projects)
        // a bot that works in a folder that moved follows it
        moveWorkingFolders(project: projects[index], from: before)
        return projects[index]
    }

    func delete(_ id: String) throws {
        let projects = all
        guard projects.contains(where: { $0["id"]?.string == id }) else { throw HTTPError(404, "no such project") }
        try save(projects.filter { $0["id"]?.string != id })
        try? FileManager.default.removeItem(at: agentFile(id))
        // whoever belonged to it, belongs to none
        for bot in harness.store.bots where bot["plugins"]?["code"]?["projectId"]?.string == id {
            clearData(.bot(bot["id"]?.string ?? ""))
        }
        for group in harness.store.groups where group["plugins"]?["code"]?["projectId"]?.string == id {
            clearData(.group(group["id"]?.string ?? ""))
        }
    }

    private func clearData(_ owner: PluginDataOwner) {
        func cleared(_ plugins: JSON?) -> JSON {
            var all = plugins?.object ?? JSONObject()
            var own = all["code"]?.object ?? JSONObject()
            own["projectId"] = nil
            own["role"] = nil
            all["code"] = .object(own)
            return .object(all)
        }
        switch owner {
        case let .bot(id): harness.store.patchBot(id, ["plugins": cleared(harness.store.bot(id)?["plugins"])])
        case let .group(id): harness.store.patchGroup(id, ["plugins": cleared(harness.store.group(id)?["plugins"])])
        }
    }

    /// `projects.json`, and the file each project has for the agents: only what an agent needs.
    func save(_ projects: [JSONObject]) throws {
        try FileIO.writeAtomic(JSON.array(projects.map(JSON.object)).data, to: file)
        try? FileManager.default.createDirectory(at: agentFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for project in projects {
            guard let id = project["id"]?.string else { continue }
            var forAgents = JSONObject()
            for key in ["id", "name", "clickupListId", "repos"] { forAgents[key] = project[key] ?? .null }
            try FileIO.writeAtomic(JSON.object(forAgents).data, to: agentFile(id))
        }
    }

    /// Bots and channels that work on a role whose folder changed move their default folder with it.
    private func moveWorkingFolders(project: JSONObject, from before: JSONObject) {
        guard let id = project["id"]?.string else { return }
        func path(_ project: JSONObject, _ role: String) -> String? {
            project["repos"]?.array?.first { $0["role"]?.string == role }?["path"]?.string
        }
        for bot in harness.store.bots {
            guard bot["plugins"]?["code"]?["projectId"]?.string == id, let role = bot["plugins"]?["code"]?["role"]?.string,
                  let old = path(before, role), let new = path(project, role), old != new, bot["cwd"]?.string == old,
                  let botId = bot["id"]?.string else { continue }
            harness.store.patchBot(botId, ["cwd": .string(new)])
        }
        for group in harness.store.groups {
            guard group["plugins"]?["code"]?["projectId"]?.string == id, let role = group["plugins"]?["code"]?["role"]?.string,
                  let old = path(before, role), let new = path(project, role), old != new, group["cwd"]?.string == old,
                  group["pinnedCwd"] == nil, let groupId = group["id"]?.string else { continue }
            harness.store.patchGroup(groupId, ["cwd": .string(new)])
        }
    }
}

/// What a turn of a bot or a channel needs from its project: where it works, what it only reads.
struct ProjectContext: Equatable {
    var name: String
    var projectId: String
    var workingRole: String?
    var workingPath: String?
    /// Linked read-only: every other folder of the project, real paths, with their roles.
    var readOnly: [(role: String, path: String)]

    static func == (a: ProjectContext, b: ProjectContext) -> Bool {
        a.name == b.name && a.projectId == b.projectId && a.workingRole == b.workingRole && a.workingPath == b.workingPath
            && a.readOnly.map(\.path) == b.readOnly.map(\.path)
    }

    /// `role` is the folder the chat works on, when it said; else the project's folder that holds `cwd`.
    static func make(project: JSONObject, role: String?, cwd: String?) -> ProjectContext? {
        guard let id = project["id"]?.string else { return nil }
        let repos: [(role: String, path: String)] = (project["repos"]?.array ?? []).compactMap {
            guard let role = $0["role"]?.string, let path = $0["path"]?.string, FileManager.default.fileExists(atPath: path) else { return nil }
            return (role, ReadOnlyGuard.canonical(path))
        }
        let here = cwd.map(ReadOnlyGuard.canonical)
        let working = role.flatMap { wanted in repos.first { $0.role == wanted } }
            ?? here.flatMap { here in repos.first { here == $0.path || here.hasPrefix($0.path + "/") } }
        let workingPath = working?.path ?? here
        // a folder that holds the working one is not linked: the chat could not write anywhere in it
        let readOnly = repos.filter { repo in
            if repo.path == working?.path { return false }
            if let workingPath, workingPath == repo.path || workingPath.hasPrefix(repo.path + "/") { return false }
            return true
        }
        return ProjectContext(name: project["name"]?.string ?? "", projectId: id, workingRole: working?.role, workingPath: working?.path, readOnly: readOnly)
    }

    static let roleNames = ["backend": "Backend", "backoffice": "Backoffice", "app": "App", "bruno": "Bruno collection"]

    /// What the agent is told. Engine-side text, so English.
    func prompt(agentFile: String) -> String {
        var text = "This chat belongs to the project \"\(name)\"."
        if let workingRole, let workingPath {
            text += " You work on its \(Self.roleNames[workingRole] ?? workingRole) folder, \(workingPath)."
        }
        if !readOnly.isEmpty {
            text += " The project's other folders are linked read-only, for context: read them as much as you need, but never create, edit, delete or move anything in them; if a change is needed there, say so instead.\n"
            text += readOnly.map { "- \(Self.roleNames[$0.role] ?? $0.role): \($0.path)" }.joined(separator: "\n")
        }
        text += "\nThe project's details (its ClickUp list, its folders and their roles) are in the JSON file at \(agentFile), also in $SWARME_PROJECT_JSON."
        return text
    }
}
