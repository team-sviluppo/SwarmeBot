// `/api/skills*` and `/api/skills-folder` — the skills' settings API
// (docs/plans/2026-10-21-skill.md). Every change is broadcast as
// `{"kind": "skills"}`; the app reloads the list.
import Foundation

@MainActor
enum SkillRoutes {
    static func respond(_ status: Int, _ value: JSON) -> RouteResult { .response(.json(status, value)) }
    static func fail(_ status: Int, _ message: String) -> RouteResult { .response(.error(status, message)) }

    static func handle(_ r: HTTPRequest, harness: Harness) throws -> RouteResult? {
        let path = r.path, method = r.method
        guard path == "/api/skills" || path.hasPrefix("/api/skills/") || path == "/api/skills-folder" else { return nil }
        if method != "GET", !r.isJSON, !(method == "DELETE" && r.body.isEmpty) {
            return fail(415, "content-type must be application/json")
        }
        let skills = harness.skills

        if path == "/api/skills-folder" {
            if method == "GET" { return respond(200, folder(harness)) }
            guard method == "PUT" else { return nil }
            let value = try r.json()["folder"]
            if value == nil || value?.isNull == true || value?.string == "" {
                try harness.config.setSkillsFolder(nil)
            } else {
                guard let raw = value?.string, raw.hasPrefix("/") else { return fail(400, "folder must be an absolute path") }
                let path = URL(fileURLWithPath: raw).standardizedFileURL.path
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                    // a new folder inside an existing one, like a fresh shared drive
                    guard (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)) != nil else {
                        return fail(400, "folder must be an existing folder, or a new one inside an existing folder")
                    }
                } else if !isDirectory.boolValue {
                    return fail(400, "folder must be a folder, not a file")
                }
                guard FileManager.default.isWritableFile(atPath: path) else { return fail(400, "this folder is not writable by the engine") }
                try harness.config.setSkillsFolder(path)
            }
            harness.broadcast(["kind": "skills"])
            return respond(200, folder(harness))
        }

        if path == "/api/skills" {
            if method == "GET" { return respond(200, ["skills": .array(skills.list().map { withSource($0, harness) })]) }
            guard method == "POST" else { return nil }
            let body = try r.json()
            if let replace = body["replace"], replace.bool == nil { return fail(400, "replace must be true or false") }
            do {
                let files = try Skills.uploadFiles(body)
                // a skill a GitHub source keeps is not replaced by hand: the next update would take it back
                if let manifest = files.first(where: { $0.path == "SKILL.md" }),
                   let name = (try? Skills.parse(String(decoding: manifest.data, as: UTF8.self)))?.name, let source = harness.skillSources.managed(name) {
                    return fail(409, managedMessage(source.name))
                }
                let skill = try skills.add(files, replace: body["replace"]?.bool ?? false)
                return respond(201, ["skill": skill.json])
            } catch let error as SkillInvalid {
                return fail(error.status, error.message)
            }
        }

        let id = String(path.dropFirst("/api/skills/".count))
        guard Skills.isValidId(id) else { return nil }
        switch method {
        case "GET":
            guard let skill = skills.skill(id), let content = skills.content(id) else { return fail(404, "no such skill") }
            return respond(200, ["skill": withSource(skill, harness), "content": .string(content)])
        case "PUT":
            if let source = harness.skillSources.managed(id) { return fail(409, managedMessage(source.name)) }
            guard let content = try r.json()["content"]?.string else { return fail(400, "content must be the text of SKILL.md") }
            do {
                return respond(200, ["skill": try skills.update(id, content: content).json])
            } catch let error as SkillInvalid {
                return fail(error.status, error.message)
            }
        case "DELETE":
            if let source = harness.skillSources.managed(id) { return fail(409, managedMessage(source.name)) }
            guard skills.remove(id) else { return fail(404, "no such skill") }
            harness.store.forgetSkill(id)
            return respond(200, ["ok": true])
        default:
            return nil
        }
    }

    static func managedMessage(_ source: String) -> String {
        "this skill comes from the GitHub source \(source): change it there, or make a copy under another name"
    }

    /// A skill's wire form; one that a GitHub source keeps says which and at what commit.
    static func withSource(_ skill: Skill, _ harness: Harness) -> JSON {
        var object = skill.json.object ?? JSONObject()
        if let source = harness.skillSources.managed(skill.id) {
            object["source"] = .object(JSONObject([("id", .string(source.sourceId)), ("name", .string(source.name)), ("sha", .string(String(source.sha.prefix(7))))]))
        }
        return .object(object)
    }

    /// The folder in use, and the default, so Settings can offer to go back.
    static func folder(_ harness: Harness) -> JSON {
        JSON.object(JSONObject([
            ("folder", .string(harness.skills.folder.path)), ("defaultFolder", .string(harness.skills.defaultFolder.path)),
            ("custom", .bool(harness.config.skillsFolder != nil)),
        ]))
    }
}
