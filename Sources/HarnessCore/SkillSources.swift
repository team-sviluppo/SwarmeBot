// Skill sources from GitHub (docs/plans/2026-10-28-code-mode-t3.md §11).
//
// A source is a folder of skills in a GitHub repository (private ones too, with a fine-grained token
// kept in the vault) that the engine keeps installed in its skills folder: at start, every six hours
// and on request. It lives on the engine, not on the Mac, so a remote engine updates itself.
//
// An update is safe: the repository's tarball is unpacked in a scratch folder, every skill is
// validated, and only then are they all swapped in together. If any is not valid nothing changes and
// the reason is kept; the version replaced stays on disk so that "go back" is one call. Skills that
// come from a source are *managed*: the app does not edit them (the next update would overwrite
// the edit), and a skill the user made with the same name is never touched.
//
// Whoever can write to the repository runs code on every engine that follows it: scripts in a skill
// are run by bots. The update says which skills changed, and the branch should be protected.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct SkillSourceError: LocalizedError {
    public let status: Int
    public let message: String
    public init(_ message: String, status: Int = 400) {
        self.message = message
        self.status = status
    }
    public var errorDescription: String? { message }
}

/// What the engine asks GitHub: swapped by the tests, like `TeamLibrary.fetch`.
public struct GitHubSkillFetcher: Sendable {
    /// The commit `ref` points at now.
    public var head: @Sendable (_ repo: String, _ ref: String, _ token: String?) async throws -> String
    /// The repository's files at `ref`, as the `.tar.gz` GitHub makes.
    public var tarball: @Sendable (_ repo: String, _ ref: String, _ token: String?) async throws -> Data

    public init(head: @escaping @Sendable (String, String, String?) async throws -> String,
                tarball: @escaping @Sendable (String, String, String?) async throws -> Data) {
        self.head = head
        self.tarball = tarball
    }

    static let maxTarball = 60 * 1024 * 1024

    /// A redirect to another host (GitHub's tarball goes to codeload) must not carry the token along.
    final class DropTokenAcrossHosts: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            var next = request
            if next.url?.host != task.originalRequest?.url?.host { next.setValue(nil, forHTTPHeaderField: "Authorization") }
            return next
        }
    }

    static func failure(_ status: Int, repo: String, ref: String, limited: Bool) -> SkillSourceError {
        switch status {
        case 401: return SkillSourceError("GitHub refused the token: it is wrong, expired or revoked", status: 502)
        case 403 where limited: return SkillSourceError("GitHub's rate limit is reached: it will be tried again later", status: 502)
        case 403: return SkillSourceError("GitHub refused the token for \(repo): it needs read access to Contents on that repository", status: 502)
        case 404: return SkillSourceError("\(repo) at \(ref) was not found, or the token cannot see it", status: 502)
        default: return SkillSourceError("GitHub answered HTTP \(status)", status: 502)
        }
    }

    static func get(_ address: String, token: String?, accept: String, repo: String, ref: String, timeout: TimeInterval) async throws -> Data {
        guard let url = URL(string: address) else { throw SkillSourceError("not a valid address") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SwarmeBot", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request, delegate: DropTokenAcrossHosts()) }
        catch let error as URLError where error.code == .timedOut { throw SkillSourceError("GitHub did not answer in time", status: 504) }
        catch { throw SkillSourceError("could not reach GitHub", status: 502) }
        guard let http = response as? HTTPURLResponse else { throw SkillSourceError("could not reach GitHub", status: 502) }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(http.statusCode, repo: repo, ref: ref, limited: http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0")
        }
        return data
    }

    public static let live = GitHubSkillFetcher(
        head: { repo, ref, token in
            let data = try await get("https://api.github.com/repos/\(repo)/commits/\(ref)", token: token, accept: "application/vnd.github.sha",
                                     repo: repo, ref: ref, timeout: 20)
            let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { throw SkillSourceError("GitHub did not answer with a commit", status: 502) }
            return sha
        },
        tarball: { repo, ref, token in
            let data = try await get("https://api.github.com/repos/\(repo)/tarball/\(ref)", token: token, accept: "application/vnd.github+json",
                                     repo: repo, ref: ref, timeout: 120)
            guard data.count <= maxTarball else { throw SkillSourceError("the repository is larger than \(maxTarball / 1024 / 1024) MB: point the source at a smaller one", status: 413) }
            return data
        })
}

@MainActor
public final class SkillSources {
    public struct Installed: Equatable {
        public var sha: String
        public var at: Double
        /// Skill name → hash of its files, to tell what an update changed.
        public var skills: [String: String]

        var json: JSON {
            .object(JSONObject([("sha", .string(sha)), ("at", .number(at)),
                                ("skills", .object(JSONObject(skills.sorted { $0.key < $1.key }.map { ($0.key, JSON.string($0.value)) })))]))
        }

        init(sha: String, at: Double, skills: [String: String]) {
            self.sha = sha
            self.at = at
            self.skills = skills
        }

        init?(_ json: JSON?) {
            guard let object = json?.object, let sha = object["sha"]?.string else { return nil }
            self.init(sha: sha, at: object["at"]?.double ?? 0,
                      skills: Dictionary(uniqueKeysWithValues: (object["skills"]?.object ?? JSONObject()).compactMap { key, value in value.string.map { (key, $0) } }))
        }
    }

    struct Source {
        var id: String
        var name: String
        var repo: String
        var path: String
        var ref: String
        var secret: String?
        var enabled = true
        var assignAll = false
        var assignBots: [String] = []
        var commands: [String] = []
        var connectors: [String] = []
        var installed: Installed?
        var previous: Installed?
        /// A commit that was gone back from: not installed again until the repository moves on.
        var hold: String?
        var last: JSONObject?
        /// What the engine did not make of it, kept so that a field this version does not know survives a write.
        var extra = JSONObject()

        init(json: JSONObject) {
            id = json["id"]?.string ?? ""
            name = json["name"]?.string ?? ""
            repo = json["repo"]?.string ?? ""
            path = json["path"]?.string ?? "skills"
            ref = json["ref"]?.string ?? "main"
            secret = json["secret"]?.string
            enabled = json["enabled"]?.bool ?? true
            assignAll = json["assign"]?["all"]?.bool ?? false
            assignBots = json["assign"]?["botIds"]?.array?.compactMap(\.string) ?? []
            commands = json["requires"]?["commands"]?.array?.compactMap(\.string) ?? []
            connectors = json["requires"]?["connectors"]?.array?.compactMap(\.string) ?? []
            installed = Installed(json["installed"])
            previous = Installed(json["previous"])
            hold = json["hold"]?.string
            last = json["last"]?.object
            let known: Set<String> = ["id", "name", "repo", "path", "ref", "secret", "enabled", "assign", "requires", "installed", "previous", "hold", "last"]
            for (key, value) in json where !known.contains(key) { extra[key] = value }
        }

        init(id: String, name: String, repo: String, path: String, ref: String) {
            self.id = id
            self.name = name
            self.repo = repo
            self.path = path
            self.ref = ref
        }

        var json: JSON {
            var object = JSONObject([("id", .string(id)), ("name", .string(name)), ("repo", .string(repo)), ("path", .string(path)), ("ref", .string(ref))])
            if let secret { object["secret"] = .string(secret) }
            object["enabled"] = .bool(enabled)
            object["assign"] = .object(JSONObject([("all", .bool(assignAll)), ("botIds", .strings(assignBots))]))
            object["requires"] = .object(JSONObject([("commands", .strings(commands)), ("connectors", .strings(connectors))]))
            if let installed { object["installed"] = installed.json }
            if let previous { object["previous"] = previous.json }
            if let hold { object["hold"] = .string(hold) }
            if let last { object["last"] = .object(last) }
            for (key, value) in extra { object[key] = value }
            return .object(object)
        }
    }

    public static let maxSources = 10
    static let interval: TimeInterval = 6 * 3600
    /// Tests swap it.
    nonisolated(unsafe) public static var fetcher = GitHubSkillFetcher.live

    private let paths: DataPaths
    private unowned let skills: Skills
    private let vault: Vault
    private let botExists: (String) -> Bool
    private let connectorNames: () -> [String]
    /// Called after every change: the app reloads.
    public var onChange: (() -> Void)?

    private(set) var sources: [Source] = []
    private var syncing: Set<String> = []
    private var loop: Task<Void, Never>?

    init(paths: DataPaths, skills: Skills, vault: Vault, botExists: @escaping (String) -> Bool, connectorNames: @escaping () -> [String]) {
        self.paths = paths
        self.skills = skills
        self.vault = vault
        self.botExists = botExists
        self.connectorNames = connectorNames
        load()
    }

    private var file: URL { paths.root.appendingPathComponent("skill-sources.json") }
    private func work(_ id: String) -> URL { paths.root.appendingPathComponent("skill-sources", isDirectory: true).appendingPathComponent(id, isDirectory: true) }

    private func load() {
        sources = (FileIO.readJSON(file)?["sources"]?.array ?? []).compactMap { $0.object }.map(Source.init(json:)).filter { !$0.id.isEmpty }
    }

    private func save() {
        try? FileIO.writeAtomic(Data(JSON.object(["sources": .array(sources.map(\.json))]).pretty().utf8), to: file)
        onChange?()
    }

    private func index(_ id: String) throws -> Int {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { throw SkillSourceError("no such source", status: 404) }
        return index
    }

    // MARK: Who has what

    /// The source a skill comes from, if it comes from one.
    public func managed(_ skill: String) -> (sourceId: String, name: String, sha: String)? {
        for source in sources {
            if let installed = source.installed, installed.skills[skill] != nil { return (source.id, source.name, installed.sha) }
        }
        return nil
    }

    /// The bot, with the skills of the sources assigned to it added to its own; an entry the bot already has wins
    /// (a skill it switched off stays off).
    public func augment(_ bot: JSONObject) -> JSONObject {
        guard let botId = bot["id"]?.string else { return bot }
        var names: [String] = []
        for source in sources where source.enabled && (source.assignAll || source.assignBots.contains(botId)) {
            names += (source.installed?.skills.keys.sorted() ?? [])
        }
        guard !names.isEmpty else { return bot }
        var entries = bot["skills"]?.array ?? []
        let have = Set(entries.compactMap { $0["id"]?.string })
        var added = false
        for name in names where !have.contains(name) && !entries.contains(where: { $0["id"]?.string == name }) {
            entries.append(["id": .string(name), "defaultOn": true])
            added = true
        }
        guard added else { return bot }
        var out = bot
        out["skills"] = .array(entries)
        return out
    }

    /// Hands the source's skills to these bots as well, whatever else they have (for a plugin that
    /// knows which bots need them).
    public func assign(botIds: [String], to id: String) throws {
        let at = try index(id)
        var next = sources[at].assignBots
        for botId in botIds where botExists(botId) && !next.contains(botId) { next.append(botId) }
        guard next != sources[at].assignBots else { return }
        sources[at].assignBots = next
        save()
    }

    public func source(_ id: String) -> (name: String, skills: [String])? {
        guard let source = sources.first(where: { $0.id == id }) else { return nil }
        return (source.name, source.installed?.skills.keys.sorted() ?? [])
    }

    // MARK: Settings

    static func clean(_ value: JSON?, _ field: String, max: Int) throws -> String? {
        guard let value, !value.isNull else { return nil }
        guard let raw = value.string else { throw SkillSourceError("\(field) must be text") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= max else { throw SkillSourceError("\(field) is too long") }
        return text
    }

    static func validRepo(_ repo: String) -> Bool {
        repo.range(of: #"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil && !repo.contains("..")
    }

    /// The folder inside the repository: relative, no `..`, no backslash; "" is the repository's root.
    static func validPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed.isEmpty || trimmed == "." { return "" }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !trimmed.contains("\\"), !trimmed.contains("\0"), trimmed.count <= 200,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return trimmed
    }

    static func validRef(_ ref: String) -> Bool {
        ref.range(of: #"^[A-Za-z0-9._/-]{1,100}$"#, options: .regularExpression) != nil && !ref.contains("..") && !ref.hasPrefix("/") && !ref.hasSuffix("/")
    }

    private func apply(_ body: JSONObject, to source: inout Source) throws {
        if let name = try Self.clean(body["name"], "name", max: 80) { source.name = name }
        if let repo = try Self.clean(body["repo"], "repo", max: 201) {
            guard Self.validRepo(repo) else { throw SkillSourceError("repo must look like owner/name") }
            source.repo = repo
        }
        if let path = try Self.clean(body["path"], "path", max: 200) {
            guard let valid = Self.validPath(path) else { throw SkillSourceError("path must be a folder inside the repository, with no .. in it") }
            source.path = valid
        }
        if let ref = try Self.clean(body["ref"], "ref", max: 100) {
            guard Self.validRef(ref) else { throw SkillSourceError("ref must be a branch, tag or commit") }
            source.ref = ref
        }
        if let value = body["secret"] {
            if value.isNull { source.secret = nil } else {
                guard let name = value.string, vault.secret(name) != nil else { throw SkillSourceError("no such secret in this engine's vault") }
                source.secret = name
            }
        }
        if let enabled = body["enabled"] {
            guard let flag = enabled.bool else { throw SkillSourceError("enabled must be true or false") }
            source.enabled = flag
        }
        if let assign = body["assign"] {
            guard let object = assign.object else { throw SkillSourceError("assign must be an object") }
            if let all = object["all"] {
                guard let flag = all.bool else { throw SkillSourceError("assign.all must be true or false") }
                source.assignAll = flag
            }
            if let bots = object["botIds"] {
                guard let list = bots.array, list.allSatisfy({ $0.string != nil }) else { throw SkillSourceError("assign.botIds must be a list of bot ids") }
                let ids = list.compactMap(\.string)
                guard ids.allSatisfy(botExists) else { throw SkillSourceError("assign.botIds names a bot that does not exist") }
                var seen = Set<String>()
                source.assignBots = ids.filter { seen.insert($0).inserted }
            }
        }
        if let requires = body["requires"] {
            guard let object = requires.object else { throw SkillSourceError("requires must be an object") }
            if let commands = object["commands"] {
                guard let list = commands.array?.compactMap(\.string), list.count == commands.array?.count,
                      list.allSatisfy({ $0.range(of: #"^[A-Za-z0-9._-]{1,40}$"#, options: .regularExpression) != nil }), list.count <= 10 else {
                    throw SkillSourceError("requires.commands must be command names")
                }
                source.commands = list
            }
            if let connectors = object["connectors"] {
                guard let list = connectors.array?.compactMap(\.string), list.count == connectors.array?.count, list.allSatisfy({ !$0.isEmpty && $0.count <= 60 }), list.count <= 10 else {
                    throw SkillSourceError("requires.connectors must be connector names")
                }
                source.connectors = list
            }
        }
    }

    public func create(_ body: JSONObject) throws -> JSON {
        guard sources.count < Self.maxSources else { throw SkillSourceError("at most \(Self.maxSources) sources") }
        guard let repo = try Self.clean(body["repo"], "repo", max: 201), !repo.isEmpty else { throw SkillSourceError("repo is required, like owner/name") }
        var source = Source(id: newId(), name: repo, repo: repo, path: "skills", ref: "main")
        try apply(body, to: &source)
        guard !sources.contains(where: { $0.repo == source.repo && $0.path == source.path && $0.ref == source.ref }) else {
            throw SkillSourceError("this folder of \(source.repo) is already a source", status: 409)
        }
        sources.append(source)
        save()
        return source.json
    }

    public func update(_ id: String, _ body: JSONObject) throws -> JSON {
        let at = try index(id)
        var next = sources[at]
        let before = (next.repo, next.path, next.ref)
        try apply(body, to: &next)
        // pointing it elsewhere is a different source: what was installed is no longer what it follows
        if before != (next.repo, next.path, next.ref) { next.hold = nil }
        sources[at] = next
        save()
        return next.json
    }

    /// Removes the source and the skills it installed.
    public func remove(_ id: String) throws {
        let at = try index(id)
        guard !syncing.contains(id) else { throw SkillSourceError("the source is updating: try again in a moment", status: 409) }
        for name in sources[at].installed?.skills.keys.sorted() ?? [] { _ = skills.remove(name) }
        try? FileManager.default.removeItem(at: work(id))
        sources.remove(at: at)
        save()
    }

    /// The bot went away: it no longer needs the skills handed to it.
    public func forgetBot(_ botId: String) {
        var changed = false
        for at in sources.indices where sources[at].assignBots.contains(botId) {
            sources[at].assignBots.removeAll { $0 == botId }
            changed = true
        }
        if changed { save() }
    }

    // MARK: Wire

    /// What the app shows, with what is missing for the skills to work on this engine.
    public func wire() async -> JSON {
        var list: [JSON] = []
        for source in sources { list.append(await wire(source)) }
        return ["sources": .array(list)]
    }

    public func wire(_ id: String) async throws -> JSON {
        await wire(sources[try index(id)])
    }

    private func wire(_ source: Source) async -> JSON {
        var object = source.json.object ?? JSONObject()
        if let installed = source.installed {
            var skillsJSON: [JSON] = []
            for name in installed.skills.keys.sorted() { skillsJSON.append(["name": .string(name), "present": .bool(skills.skill(name) != nil)]) }
            var wire = installed.json.object ?? JSONObject()
            wire["shortSha"] = .string(String(installed.sha.prefix(7)))
            wire["skills"] = .array(skillsJSON)
            object["installed"] = .object(wire)
        }
        if let previous = source.previous { object["previousSha"] = .string(String(previous.sha.prefix(7))) }
        object["previous"] = Optional<JSON>.none
        object["canRollback"] = .bool(source.previous != nil)
        object["syncing"] = .bool(syncing.contains(source.id))
        object["held"] = .bool(source.hold != nil)
        object["hold"] = Optional<JSON>.none
        var missing: [JSON] = []
        for command in source.commands where !(await Self.commandExists(command)) { missing.append(["kind": "command", "name": .string(command)]) }
        let known = connectorNames().map { $0.lowercased() }
        for connector in source.connectors where !known.contains(where: { $0.contains(connector.lowercased()) }) {
            missing.append(["kind": "connector", "name": .string(connector)])
        }
        object["missing"] = .array(missing)
        if let secret = source.secret { object["secretPresent"] = .bool(vault.secret(secret) != nil) }
        return .object(object)
    }

    static func commandExists(_ name: String) async -> Bool {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = EnvPath.augmented()
        return (await CLIProcess.run("sh", ["-c", "command -v \"$1\"", "sh", name], environment: environment, timeout: 8))?.ok == true
    }

    // MARK: Updating

    private struct Staged {
        var name: String
        var directory: URL
        var files: [(path: String, executable: Bool)]
        var hash: String
    }

    private func token(_ source: Source) throws -> String? {
        guard let name = source.secret else { return nil }
        guard let value = vault.value(name), !value.isEmpty else {
            throw SkillSourceError("the secret \(name) is not in this engine's vault: add it there (Settings › Vault), or on a server copy it from the Mac")
        }
        return value
    }

    /// Looks for a newer commit and installs it. Always answers with the source as it is afterwards: a failure
    /// is in `last`, the installed version untouched.
    @discardableResult
    public func sync(_ id: String, force: Bool = false) async throws -> JSON {
        let at = try index(id)
        guard syncing.insert(id).inserted else { throw SkillSourceError("the source is already updating", status: 409) }
        sources[at].last = nil
        onChange?()
        var last = JSONObject([("checkedAt", .number(nowMillis()))])
        do {
            let source = sources[try index(id)]
            let token = try token(source)
            let sha = try await Self.fetcher.head(source.repo, source.ref, token)
            let installedAll = source.installed?.skills.keys.allSatisfy { skills.skill($0) != nil } ?? true
            if !force, source.installed?.sha == sha, installedAll {
                last["ok"] = true
                last["unchanged"] = true
            } else if !force, source.hold == sha {
                last["ok"] = true
                last["held"] = true
            } else {
                let tarball = try await Self.fetcher.tarball(source.repo, source.ref, token)
                let outcome = try await install(tarball, sha: sha, source: source)
                last["ok"] = true
                last["sha"] = .string(sha)
                last["updated"] = .object(JSONObject([("added", .strings(outcome.added)), ("changed", .strings(outcome.changed)), ("removed", .strings(outcome.removed))]))
                if !outcome.conflicts.isEmpty { last["conflicts"] = .strings(outcome.conflicts) }
            }
        } catch let error as SkillSourceError {
            last["ok"] = false
            last["error"] = .string(error.message)
        } catch {
            last["ok"] = false
            last["error"] = .string(error.localizedDescription)
        }
        syncing.remove(id)
        if let now = try? index(id) {
            // the install wrote its own record; keep it and add what this run found
            sources[now].last = last
            save()
        }
        return try await wire(id)
    }

    /// Every enabled source, one after the other; what fails is in the source's own record.
    public func syncAll(force: Bool = false) async {
        for id in sources.filter(\.enabled).map(\.id) { _ = try? await sync(id, force: force) }
    }

    /// Updates at start (after a short wait for the engine to settle) and every six hours.
    public func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            while !Task.isCancelled {
                await self?.syncAll()
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    struct Outcome {
        var added: [String] = []
        var changed: [String] = []
        var removed: [String] = []
        var conflicts: [String] = []
    }

    private func install(_ tarball: Data, sha: String, source: Source) async throws -> Outcome {
        let fm = FileManager.default
        let scratch = work(source.id).appendingPathComponent(".work-\(newId().prefix(8))", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let staged = try await stage(tarball, source: source, in: scratch)

        let owned = Set((source.installed?.skills ?? [:]).keys)
        let others = Set(sources.filter { $0.id != source.id }.flatMap { Array(($0.installed?.skills ?? [:]).keys) })
        var outcome = Outcome()
        var toInstall: [Staged] = []
        for skill in staged {
            // a skill the user made, or another source's, is not ours to replace
            if (fm.fileExists(atPath: skills.directory(skill.name).path) && !owned.contains(skill.name)) || others.contains(skill.name) {
                outcome.conflicts.append(skill.name)
            } else { toInstall.append(skill) }
        }
        let old = source.installed?.skills ?? [:]
        let now = Dictionary(uniqueKeysWithValues: toInstall.map { ($0.name, $0.hash) })
        outcome.added = now.keys.filter { old[$0] == nil }.sorted()
        outcome.changed = now.keys.filter { old[$0] != nil && old[$0] != now[$0] }.sorted()
        outcome.removed = old.keys.filter { now[$0] == nil }.sorted()

        // the new skills are written in full beside the skills folder's own, then swapped in together
        try fm.createDirectory(at: skills.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let incoming = skills.folder.appendingPathComponent(".incoming-\(source.id.prefix(6))-\(newId().prefix(6))", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: incoming) }
        for skill in toInstall {
            let target = incoming.appendingPathComponent(skill.name, isDirectory: true)
            for file in skill.files {
                let from = skill.directory.appendingPathComponent(file.path)
                let to = target.appendingPathComponent(file.path)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.copyItem(at: from, to: to)
                try fm.setAttributes([.posixPermissions: file.executable ? 0o700 : 0o600], ofItemAtPath: to.path)
            }
        }

        let previousNew = work(source.id).appendingPathComponent("previous.new", isDirectory: true)
        try? fm.removeItem(at: previousNew)
        try fm.createDirectory(at: previousNew, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var movedAway: [String] = []
        var movedIn: [String] = []
        do {
            for name in owned.sorted() where fm.fileExists(atPath: skills.directory(name).path) {
                try fm.moveItem(at: skills.directory(name), to: previousNew.appendingPathComponent(name))
                movedAway.append(name)
            }
            for skill in toInstall {
                try fm.moveItem(at: incoming.appendingPathComponent(skill.name), to: skills.directory(skill.name))
                movedIn.append(skill.name)
            }
        } catch {
            for name in movedIn { try? fm.removeItem(at: skills.directory(name)) }
            for name in movedAway { try? fm.moveItem(at: previousNew.appendingPathComponent(name), to: skills.directory(name)) }
            try? fm.removeItem(at: previousNew)
            throw SkillSourceError("could not install the skills: \(error.localizedDescription)", status: 500)
        }

        // what was replaced is kept, so that going back is possible
        let previous = work(source.id).appendingPathComponent("previous", isDirectory: true)
        try? fm.removeItem(at: previous)
        let at = try index(source.id)
        if movedAway.isEmpty {
            try? fm.removeItem(at: previousNew)
            sources[at].previous = nil
        } else {
            try? fm.moveItem(at: previousNew, to: previous)
            sources[at].previous = source.installed
        }
        sources[at].installed = Installed(sha: sha, at: nowMillis(), skills: now)
        if sources[at].hold != sha { sources[at].hold = nil }
        skills.onChange?()
        return outcome
    }

    // MARK: Unpacking

    /// The skills of the tarball, each one checked. Nothing here touches the skills folder.
    private func stage(_ tarball: Data, source: Source, in scratch: URL) async throws -> [Staged] {
        let fm = FileManager.default
        let archive = scratch.appendingPathComponent("source.tar.gz")
        try tarball.write(to: archive)
        let extract = scratch.appendingPathComponent("extract", isDirectory: true)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = EnvPath.augmented()
        guard let unpacked = await CLIProcess.run("tar", ["-xzf", archive.path, "-C", extract.path], environment: environment, timeout: 120), unpacked.ok else {
            throw SkillSourceError("could not unpack what GitHub sent")
        }
        let tops = ((try? fm.contentsOfDirectory(atPath: extract.path)) ?? []).filter { !$0.hasPrefix(".") }
        guard tops.count == 1, Self.isDirectory(extract.appendingPathComponent(tops[0])) else { throw SkillSourceError("the download is not a repository") }
        let top = extract.appendingPathComponent(tops[0], isDirectory: true)
        let base = source.path.isEmpty ? top : top.appendingPathComponent(source.path, isDirectory: true)
        guard Self.isDirectory(base), ReadOnlyGuard.canonical(base.path).hasPrefix(ReadOnlyGuard.canonical(top.path)) else {
            throw SkillSourceError("the folder \"\(source.path)\" is not in \(source.repo) at \(source.ref)")
        }

        var staged: [Staged] = []
        var invalid: [String] = []
        for entry in ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted() where !entry.hasPrefix(".") {
            let directory = base.appendingPathComponent(entry, isDirectory: true)
            guard Self.isDirectory(directory), Self.isRegular(directory.appendingPathComponent("SKILL.md")) else { continue }
            do { staged.append(try Self.check(entry, at: directory)) } catch let error as SkillSourceError { invalid.append("\(entry): \(error.message)") }
        }
        guard invalid.isEmpty else {
            throw SkillSourceError("\(invalid.count == 1 ? "a skill is" : "\(invalid.count) skills are") not valid, so nothing was changed — " + invalid.joined(separator: "; "), status: 422)
        }
        guard !staged.isEmpty else { throw SkillSourceError("no skills in \"\(source.path)\" of \(source.repo): each one is a folder with a SKILL.md") }
        guard staged.count <= Skills.maxSkills else { throw SkillSourceError("more than \(Skills.maxSkills) skills") }
        return staged
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeDirectory
    }

    private static func isRegular(_ url: URL) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeRegular
    }

    /// One skill's folder: its files (no links, nothing hidden), its manifest, and a hash of all of it.
    private static func check(_ name: String, at directory: URL) throws -> Staged {
        let fm = FileManager.default
        guard Skills.isValidId(name) else { throw SkillSourceError("the folder name must be lowercase letters, digits and single hyphens") }
        var files: [(path: String, executable: Bool)] = []
        var bytes = 0
        func walk(_ relative: String) throws {
            let current = relative.isEmpty ? directory : directory.appendingPathComponent(relative)
            for entry in ((try? fm.contentsOfDirectory(atPath: current.path)) ?? []).sorted() where !entry.hasPrefix(".") {
                let path = relative.isEmpty ? entry : relative + "/" + entry
                let url = directory.appendingPathComponent(path)
                switch (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType {
                case .typeDirectory: try walk(path)
                case .typeRegular:
                    guard Skills.cleanPath(path) != nil else { throw SkillSourceError("\(path) is not a valid path in a skill") }
                    bytes += ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
                    files.append((path, fm.isExecutableFile(atPath: url.path)))
                default: continue   // a link, a socket: not taken
                }
                if files.count > Skills.maxFiles { throw SkillSourceError("more than \(Skills.maxFiles) files") }
                if bytes > Skills.maxBytes { throw SkillSourceError("larger than \(Skills.maxBytes / 1024 / 1024) MB") }
            }
        }
        try walk("")
        guard let manifest = try? Data(contentsOf: directory.appendingPathComponent("SKILL.md")) else { throw SkillSourceError("SKILL.md cannot be read") }
        do {
            let parsed = try Skills.parse(String(decoding: manifest, as: UTF8.self))
            guard parsed.name == name else { throw SkillSourceError("its SKILL.md names it \"\(parsed.name)\": the folder and the name must match") }
        } catch let error as SkillInvalid { throw SkillSourceError(error.message) }
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data("\(file.path)\0\(file.executable ? "x" : "-")\0".utf8))
            hasher.update(data: (try? Data(contentsOf: directory.appendingPathComponent(file.path))) ?? Data())
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Staged(name: name, directory: directory, files: files.sorted { $0.path < $1.path }, hash: hash)
    }

    // MARK: Going back

    /// The version before the last update comes back, and the one that was installed is not installed again
    /// until the repository moves on.
    @discardableResult
    public func rollback(_ id: String) async throws -> JSON {
        let at = try index(id)
        guard !syncing.contains(id) else { throw SkillSourceError("the source is updating: try again in a moment", status: 409) }
        guard let previous = sources[at].previous, let current = sources[at].installed else { throw SkillSourceError("there is no earlier version to go back to", status: 409) }
        let fm = FileManager.default
        let store = work(id).appendingPathComponent("previous", isDirectory: true)
        let aside = work(id).appendingPathComponent("replaced", isDirectory: true)
        try? fm.removeItem(at: aside)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var movedAway: [String] = []
        var movedBack: [String] = []
        do {
            for name in current.skills.keys.sorted() where fm.fileExists(atPath: skills.directory(name).path) {
                try fm.moveItem(at: skills.directory(name), to: aside.appendingPathComponent(name))
                movedAway.append(name)
            }
            for name in previous.skills.keys.sorted() {
                // a skill someone made meanwhile under the same name stays
                guard !fm.fileExists(atPath: skills.directory(name).path) else { continue }
                try fm.moveItem(at: store.appendingPathComponent(name), to: skills.directory(name))
                movedBack.append(name)
            }
        } catch {
            for name in movedBack { try? fm.removeItem(at: skills.directory(name)) }
            for name in movedAway { try? fm.moveItem(at: aside.appendingPathComponent(name), to: skills.directory(name)) }
            throw SkillSourceError("could not go back: \(error.localizedDescription)", status: 500)
        }
        try? fm.removeItem(at: aside)
        try? fm.removeItem(at: store)
        var restored = previous
        restored.skills = restored.skills.filter { movedBack.contains($0.key) }
        sources[at].installed = restored
        sources[at].previous = nil
        sources[at].hold = current.sha
        sources[at].last = JSONObject([("checkedAt", .number(nowMillis())), ("ok", true), ("rolledBack", true), ("sha", .string(restored.sha))])
        skills.onChange?()
        save()
        return try await wire(id)
    }
}
