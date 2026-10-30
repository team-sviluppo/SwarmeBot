// `/api/skill-sources*` — skills kept from GitHub folders (SkillSources.swift).
// Every change is broadcast as `{"kind": "skill-sources"}` (and `skills` when the installed skills moved).
// No route returns a token: a source names a secret of the vault, and the vault never gives values out.
import Foundation

@MainActor
enum SkillSourceRoutes {
    static func respond(_ status: Int, _ value: JSON) -> RouteResult { .response(.json(status, value)) }
    static func fail(_ status: Int, _ message: String) -> RouteResult { .response(.error(status, message)) }

    static func handle(_ r: HTTPRequest, harness: Harness) async throws -> RouteResult? {
        let path = r.path, method = r.method
        guard path == "/api/skill-sources" || path.hasPrefix("/api/skill-sources/") else { return nil }
        if method != "GET", !r.isJSON, !(method == "DELETE" && r.body.isEmpty) { return fail(415, "content-type must be application/json") }
        let sources = harness.skillSources
        do {
            if path == "/api/skill-sources" {
                switch method {
                case "GET": return respond(200, await sources.wire())
                case "POST":
                    let created = try sources.create(try r.json())
                    guard let id = created["id"]?.string else { return fail(500, "the source could not be read back") }
                    return respond(201, ["source": try await sources.wire(id)])
                default: return nil
                }
            }
            let rest = String(path.dropFirst("/api/skill-sources/".count)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let id = rest.first, !id.isEmpty, id.range(of: #"^[\w-]+$"#, options: .regularExpression) != nil else { return nil }
            switch (method, rest.count == 2 ? rest[1] : "") {
            case ("PATCH", ""):
                _ = try sources.update(id, try r.json())
                return respond(200, ["source": try await sources.wire(id)])
            case ("DELETE", ""):
                try sources.remove(id)
                return respond(200, ["ok": true])
            case ("POST", "update"):
                let force = r.body.isEmpty ? false : (try r.json())["force"]?.bool ?? false
                return respond(200, ["source": try await sources.sync(id, force: force)])
            case ("POST", "rollback"):
                return respond(200, ["source": try await sources.rollback(id)])
            default: return nil
            }
        } catch let error as SkillSourceError {
            return fail(error.status, error.message)
        }
    }
}
