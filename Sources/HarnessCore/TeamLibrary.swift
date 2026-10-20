// The team library and team files over HTTP (`server/team-library.ts` and the
// `/api/teams*`, `/api/team-library/*` routes of `server/index.ts`).
//
// The catalog and the GitHub links are fetched with URLSession from the same
// fixed URLs as the Node engine — it has no override for them, so neither
// does this one. Only public GitHub JSON files are ever fetched: any other
// host is refused before a request is made.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TeamLibrary {
    public static let repository = "https://github.com/milind-soni/swarmebot-teams"
    public static let rawRoot = "https://raw.githubusercontent.com/milind-soni/swarmebot-teams/main"
    public static var catalogURL: String { "\(rawRoot)/catalog.json" }
    static let maxCatalogBytes = 256_000
    static let maxManifestBytes = 1_000_000

    /// A message for the user, with the HTTP status the remote answered when there was one.
    public struct Failure: Error {
        public let message: String
        public var status: Int?
    }

    static func text(_ value: JSON?, _ field: String, max: Int) throws -> String {
        guard let raw = value?.string, !JSText.trim(raw).isEmpty else { throw Failure(message: "\(field) is required") }
        let trimmed = JSText.trim(raw)
        if JSText.length(trimmed) > max { throw Failure(message: "\(field) is too long") }
        return trimmed
    }

    static func relativeFile(_ value: JSON?, _ field: String, suffix: String, prefix: String) throws -> String {
        let path = try text(value, field, max: 300)
        let parts = path.components(separatedBy: "/")
        if path.hasPrefix("/") || path.contains("\\") || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            || !path.hasPrefix(prefix) || !path.hasSuffix(suffix) {
            throw Failure(message: "\(field) is not a safe catalog path")
        }
        return path
    }

    static func isSlug(_ value: String) -> Bool { value.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil }

    /// `parseTeamCatalog`: the remotely maintained index, validated before any of it reaches a client.
    public static func parseCatalog(_ value: JSON) throws -> JSONObject {
        guard let root = value.object, ["swarme.catalog", "openmaus.catalog"].contains(root["format"]?.string ?? ""),
              root["version"]?.double == 1 else {
            throw Failure(message: "The team library catalog is not supported")
        }
        guard let rawTeams = root["teams"]?.array, rawTeams.count <= 100 else { throw Failure(message: "The team library catalog is invalid") }
        var slugs = Set<String>()
        let teams: [JSON] = try rawTeams.enumerated().map { index, raw in
            let field = "teams[\(index)]"
            guard let entry = raw.object else { throw Failure(message: "\(field) is invalid") }
            let slug = try text(entry["slug"], "\(field).slug", max: 80)
            if !isSlug(slug) || slugs.contains(slug) { throw Failure(message: "\(field).slug is invalid") }
            slugs.insert(slug)
            let prefix = "teams/\(slug)/"
            let requires = entry["requires"]?.object ?? JSONObject()
            let name = try text(entry["name"], "\(field).name", max: 100)
            let summary = try text(entry["summary"], "\(field).summary", max: 300)
            let category = try text(entry["category"], "\(field).category", max: 80)
            let manifest = try relativeFile(entry["manifest"], "\(field).manifest", suffix: ".mausteam.json", prefix: prefix)
            let readme = try relativeFile(entry["readme"], "\(field).readme", suffix: "README.md", prefix: prefix)
            guard let members = entry["members"]?.double, members == members.rounded(), abs(members) <= 9_007_199_254_740_991,
                  members > 0, members <= 200 else {
                throw Failure(message: "\(field).members is invalid")
            }
            guard let rawSkills = entry["skills"]?.array else { throw Failure(message: "\(field).skills is invalid") }
            let skills = try rawSkills.enumerated().map {
                JSON.string(try relativeFile($1, "\(field).skills[\($0)]", suffix: "SKILL.md", prefix: "\(prefix)skills/"))
            }
            // `requires.apps ?? []`: only absent and null mean "none"
            let rawApps = requires["apps"].flatMap { $0.isNull ? Optional<JSON>.none : $0 } ?? .array([])
            guard let apps = rawApps.array, apps.count <= 30 else { throw Failure(message: "\(field).requires.apps is invalid") }
            let appNames = try apps.enumerated().map { JSON.string(try text($1, "\(field).requires.apps[\($0)]", max: 100)) }
            return .object(JSONObject([
                ("slug", .string(slug)), ("name", .string(name)), ("summary", .string(summary)), ("category", .string(category)),
                ("manifest", .string(manifest)), ("readme", .string(readme)), ("members", .number(members)),
                ("skills", .array(skills)), ("requires", ["apps": .array(appNames)]),
            ]))
        }
        return JSONObject([
            ("format", "swarme.catalog"), ("version", 1), ("repositoryUrl", .string(repository)), ("teams", .array(teams)),
        ])
    }

    static func safeSegment(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil && value != "." && value != ".."
    }

    /// `githubManifestUrls`: public GitHub JSON files only; other hosts never reach a fetch.
    public static func githubManifestURLs(_ input: String) throws -> [String] {
        // WHATWG parsing: invalid characters are escaped, not fatal, and the
        // scheme and host compare case-insensitively
        guard let url = URL(string: JSText.trim(input), encodingInvalidCharacters: true),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme,
              let host = parts.host, !host.isEmpty else {
            throw Failure(message: "Enter a valid GitHub URL")
        }
        let port = parts.port.flatMap { $0 == 443 && scheme.lowercased() == "https" ? nil : $0 }
        if scheme.lowercased() != "https" || !(parts.user ?? "").isEmpty || !(parts.password ?? "").isEmpty || port != nil {
            throw Failure(message: "Only public HTTPS GitHub links are supported")
        }
        var segments: [String] = []
        for raw in parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            switch raw.lowercased() {
            case ".", "%2e": continue
            case "..", ".%2e", "%2e.", "%2e%2e": if !segments.isEmpty { segments.removeLast() }
            default: segments.append(String(raw))
            }
        }
        let path = try segments.filter { !$0.isEmpty }.map { segment -> String in
            guard let decoded = segment.removingPercentEncoding else { throw Failure(message: "URI malformed") }
            return decoded
        }
        if !path.allSatisfy(safeSegment) { throw Failure(message: "That GitHub path is not supported") }

        let hostname = host.lowercased()
        if hostname == "github.com" || hostname == "www.github.com" {
            if path.count == 2 {
                return ["main", "master"].map { "https://raw.githubusercontent.com/\(path[0])/\(path[1])/\($0)/team.mausteam.json" }
            }
            if path.count >= 5, path[2] == "blob" || path[2] == "raw" {
                guard path.last?.hasSuffix(".json") == true else { throw Failure(message: "The GitHub link must point to a JSON team file") }
                return ["https://raw.githubusercontent.com/\(path[0])/\(path[1])/\(path[3])/\(path[4...].joined(separator: "/"))"]
            }
        }
        if hostname == "raw.githubusercontent.com", path.count >= 4 {
            guard path.last?.hasSuffix(".json") == true else { throw Failure(message: "The GitHub link must point to a JSON team file") }
            return ["https://raw.githubusercontent.com/\(path.joined(separator: "/"))"]
        }
        throw Failure(message: "Paste a GitHub repository or JSON file link")
    }

    /// Redirects are refused, like `redirect: "error"`: a fetch stays on the URL that was checked.
    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    static func fetchJSON(_ address: String, maxBytes: Int) async throws -> JSON {
        guard let url = URL(string: address) else { throw Failure(message: "fetch failed") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        } catch let error as URLError where error.code == .timedOut {
            throw Failure(message: "The operation was aborted due to timeout")
        } catch {
            throw Failure(message: "fetch failed")
        }
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "fetch failed") }
        // a refused redirect surfaces as the 3xx itself; Node's fetch fails outright
        if (300..<400).contains(http.statusCode) { throw Failure(message: "fetch failed") }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(message: "GitHub returned HTTP \(http.statusCode)", status: http.statusCode)
        }
        if Int(http.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0 > maxBytes || data.count > maxBytes {
            throw Failure(message: "The remote team file is too large")
        }
        guard let value = try? JSON.parse(String(decoding: data, as: UTF8.self)) else { throw Failure(message: "GitHub did not return valid JSON") }
        return value
    }

    /// Swapped by the tests, like the `fetcher` parameter of the Node functions.
    nonisolated(unsafe) static var fetch: (String, Int) async throws -> JSON = fetchJSON

    static func manifest(_ value: JSON) throws -> JSONObject {
        do { return try TeamManifest.parse(value) } catch let invalid as TeamManifest.Invalid { throw Failure(message: invalid.message) }
    }

    public static func fetchCatalog() async throws -> JSONObject {
        try parseCatalog(try await fetch(catalogURL, maxCatalogBytes))
    }

    public static func fetchLibraryTeam(_ slug: String) async throws -> JSONObject {
        guard isSlug(slug) else { throw Failure(message: "That team name is invalid") }
        let catalog = try await fetchCatalog()
        guard let entry = catalog["teams"]?.array?.first(where: { $0["slug"]?.string == slug }) else {
            throw Failure(message: "That library team was not found", status: 404)
        }
        return try manifest(try await fetch("\(rawRoot)/\(entry["manifest"]?.string ?? "")", maxManifestBytes))
    }

    /// A repository link tries `main`, then `master`; only a 404 moves on.
    public static func fetchGithubTeam(_ input: String) async throws -> JSONObject {
        var last: Error?
        for url in try githubManifestURLs(input) {
            do {
                return try manifest(try await fetch(url, maxManifestBytes))
            } catch let failure as Failure where failure.status == 404 {
                last = failure
            }
        }
        throw last ?? Failure(message: "No team.mausteam.json file was found in that repository")
    }

    /// `validateBotCwd` for a project's folder: `~` expanded, normalised like `path.resolve`.
    static func validateCwd(_ input: String) -> (cwd: String?, error: String?) {
        let trimmed = JSText.trim(input)
        if trimmed.isEmpty { return (nil, nil) }
        let expanded = trimmed == "~" || trimmed.hasPrefix("~/") ? NSHomeDirectory() + trimmed.dropFirst() : trimmed
        guard expanded.hasPrefix("/") else { return (nil, "working folder must be an absolute path") }
        var parts: [Substring] = []
        for part in expanded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        let cwd = "/" + parts.joined(separator: "/")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) else { return (nil, "that folder doesn't exist: \(cwd)") }
        guard isDirectory.boolValue else { return (nil, "that path is not a folder: \(cwd)") }
        return (cwd, nil)
    }
}

/// The routes. Nil when the path is not theirs.
@MainActor
enum TeamRoutes {
    static func respond(_ status: Int, _ value: JSON) -> RouteResult { .response(.json(status, value)) }
    static func fail(_ status: Int, _ message: String) -> RouteResult { .response(.error(status, message)) }

    /// `readBody`: any JSON value, `{}` when empty, Node's own errors.
    static func body(_ r: HTTPRequest) -> Result<JSON, HTTPError> {
        if r.body.count > 1_000_000 { return .failure(HTTPError(413, "body too large")) }
        if r.body.isEmpty { return .success(.object(JSONObject())) }
        guard let value = try? JSON.parse(r.body) else { return .failure(HTTPError(400, "invalid JSON body")) }
        return .success(value)
    }

    static func handle(_ r: HTTPRequest, harness: Harness) async -> RouteResult? {
        let path = r.path
        let method = r.method
        if method == "POST", path == "/api/teams/export" { return export(r, harness) }
        if method == "GET", path == "/api/team-library/catalog" {
            do { return respond(200, .object(try await TeamLibrary.fetchCatalog())) } catch {
                return fail(502, (error as? TeamLibrary.Failure)?.message ?? "The team library is unavailable")
            }
        }
        if method == "GET", path.hasPrefix("/api/team-library/teams/") {
            let slug = String(path.dropFirst("/api/team-library/teams/".count))
            if TeamLibrary.isSlug(slug) {
                do { return respond(200, .object(try await TeamLibrary.fetchLibraryTeam(slug))) } catch {
                    let failure = error as? TeamLibrary.Failure
                    return fail(failure?.status == 404 ? 404 : 502, failure?.message ?? "The team could not be loaded")
                }
            }
        }
        if method == "POST", path == "/api/team-library/github" {
            let body: JSON
            switch Self.body(r) { case let .success(value): body = value; case let .failure(error): return fail(error.status, error.message) }
            guard let url = body["url"]?.string, !JSText.trim(url).isEmpty else { return fail(400, "A GitHub URL is required") }
            do { return respond(200, .object(try await TeamLibrary.fetchGithubTeam(url))) } catch {
                let failure = error as? TeamLibrary.Failure
                return fail(failure?.status == 404 ? 404 : 400, failure?.message ?? "The GitHub team could not be loaded")
            }
        }
        if method == "POST", path == "/api/teams/import" { return await importTeam(r, harness) }
        return nil
    }

    static func export(_ r: HTTPRequest, _ harness: Harness) -> RouteResult {
        let body: JSON
        switch Self.body(r) { case let .success(value): body = value; case let .failure(error): return fail(error.status, error.message) }
        let profileName = JSText.trim(harness.config.string("profile", "name") ?? "")
        let requested = JSText.trim(body["name"]?.string ?? "")
        let name = !requested.isEmpty ? requested : !profileName.isEmpty ? "\(profileName)'s Team" : "My SwarmeBot Team"
        let bots = harness.store.bots
        let memberIds = bots.filter { $0["hidden"]?.truthy != true }.compactMap { $0["id"]?.string }
        if memberIds.isEmpty { return fail(400, "Create a bot before exporting your team") }
        do { return respond(200, .object(try TeamManifest.export(name: name, memberIds: memberIds, bots: bots))) } catch {
            return fail(400, (error as? TeamManifest.Invalid)?.message ?? "Team could not be exported")
        }
    }

    /// Additive only: a manifest is untrusted, so every member becomes a NEW bot
    /// and nothing in the file can name, merge into or archive the user's own
    /// records. Replace mode hides the current team because the *caller* asked;
    /// project mode's room is likewise described by the caller, never the file.
    static func importTeam(_ r: HTTPRequest, _ harness: Harness) async -> RouteResult {
        let store = harness.store
        let mode = r.query["mode"] ?? "add"
        guard ["add", "replace", "project"].contains(mode) else { return fail(400, "Team import mode must be add, replace, or project") }
        var projectCwd: String?
        if mode == "project", let requested = r.query["cwd"] {
            let checked = TeamLibrary.validateCwd(requested)
            if let error = checked.error { return fail(400, error) }
            projectCwd = checked.cwd
        }
        let manifest: JSONObject
        switch body(r) {
        case let .failure(error): return fail(error.status, error.message)
        case let .success(value):
            do { manifest = try TeamManifest.parse(value) } catch {
                return fail(400, (error as? TeamManifest.Invalid)?.message ?? "Invalid team file")
            }
        }
        // snapshot first, so replace never archives the newcomers
        let archived: [JSON] = mode != "replace" ? [] : store.bots.filter { $0["hidden"]?.truthy != true }.map {
            ["id": $0["id"] ?? .null, "chiefOfStaff": .bool($0["chiefOfStaff"]?.truthy == true)]
        }
        // hidden bots count too: an archived one can come back, and Undo must never show two of a name
        var taken = Set(store.bots.map { JSText.trim($0["name"]?.string ?? "").lowercased() })
        let selection = await harness.fleet.defaultSelection().json
        var imported: [String] = []
        for member in manifest["team"]?["members"]?.array?.compactMap(\.object) ?? [] {
            var profile = TeamManifest.importedProfile(member, taken: &taken)
            profile["modelSelection"] = selection
            // no greeting from a bot the user did not just create; and a shared
            // persona never starts with reach into connected apps (absence means allowed)
            let id = store.createBot(profile: profile, seedMessages: false)["id"]!.string!
            store.patchBot(id, ["composio": false])
            imported.append(id)
        }
        let archivedBots: [JSON] = archived.compactMap { entry in
            store.patchBot(entry["id"]?.string ?? "", ["hidden": true, "chiefOfStaff": false]).map { .object(harness.botWithThread($0)) }
        }
        let publicBots: [JSON] = imported.compactMap { store.bot($0).map { .object(harness.botWithThread($0)) } }
        for bot in archivedBots + publicBots { harness.broadcast(["kind": "bot", "bot": bot]) }
        var group: JSONObject?
        if mode == "project", !imported.isEmpty {
            let requested = JSText.trim(r.query["room"] ?? "")
            var room = store.createGroup(name: requested.isEmpty ? manifest["team"]?["name"]?.string ?? "" : requested, memberIds: imported)
            // the folder the room wants; the store pins it on the first turn
            if let projectCwd { room = store.patchGroup(room["id"]!.string!, ["cwd": .string(projectCwd)]) ?? room }
            harness.broadcast(["kind": "group", "group": .object(harness.wireGroup(room))])
            group = room
        }
        var out: JSONObject = ["bots": .array(publicBots)]
        out["archivedBots"] = .array(archivedBots)
        out["archived"] = .array(archived)
        if let group { out["group"] = .object(harness.wireGroup(group)) }
        return respond(201, .object(out))
    }
}
