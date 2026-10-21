// Skills: folders of instructions the user adds once and hands to bots, for
// every engine (docs/plans/2026-10-21-skill.md).
//
// A skill is an Agent Skills folder: `SKILL.md` (YAML front matter with
// `name` and `description`, then the instructions) and whatever else it
// ships — `scripts/`, `references/`, `assets/`. They live on the engine, in
// `<data>/skills/<name>/`, so a remote engine has its own and its bots run
// the scripts there. The folder is the truth: there is no index to drift.
//
// A turn gets them two ways:
//
// - an index in the system prompt of the skills switched on in the chat —
//   name, description and where `SKILL.md` is; the model opens it when the
//   request matches. Engines without a filesystem get the text instead;
// - `/name` in the message: the whole `SKILL.md` goes into that turn, so
//   the model does not get to decide whether to read it.
import Foundation

public struct Skill: Equatable, Sendable {
    public var id: String
    public var description: String
    /// Every file, relative to the skill's folder, sorted.
    public var files: [String]
    public var bytes: Int
    /// What `SKILL.md` costs a prompt.
    public var tokens: Int
    /// Ships something a bot could run, not only text to read.
    public var hasScripts: Bool
    public var updatedAt: Double

    var json: JSON {
        JSON.object(JSONObject([
            ("id", .string(id)), ("name", .string(id)), ("description", .string(description)), ("files", .strings(files)),
            ("bytes", .number(Double(bytes))), ("tokens", .number(Double(tokens))), ("hasScripts", .bool(hasScripts)),
            ("updatedAt", .number(updatedAt)),
        ]))
    }
}

public struct SkillInvalid: LocalizedError {
    public let status: Int
    public let message: String
    init(_ message: String, status: Int = 400) {
        self.message = message
        self.status = status
    }
    public var errorDescription: String? { message }
}

@MainActor
public final class Skills {
    static let idPattern = #"^[a-z0-9]+(-[a-z0-9]+)*$"#
    static let maxIdLength = 64
    static let maxDescription = 1024
    static let maxFiles = 200
    // base64 grows it by a third, and a request stops at 12 MB
    static let maxBytes = 8 * 1024 * 1024
    static let maxSkills = 200
    /// Past this, an engine without a filesystem gets the index alone.
    static let inlineBudget = 60_000
    /// Files a bot reads rather than runs.
    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "json", "yaml", "yml", "toml", "csv", "tsv", "xml", "html", "htm", "css",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "ttf", "otf", "woff", "woff2",
    ]

    let paths: DataPaths
    /// Called after every change to the repository.
    public var onChange: (() -> Void)?
    /// The folder the user chose in Settings, if any (`config.json` skills.folder).
    public var chosenFolder: () -> String? = { nil }

    public init(paths: DataPaths) { self.paths = paths }

    public var defaultFolder: URL { paths.root.appendingPathComponent("skills", isDirectory: true) }
    /// Read on every use: a shared folder can change under the engine, and
    /// the setting can move it.
    public var folder: URL { chosenFolder().map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder }
    public func directory(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }
    public func manifest(_ id: String) -> URL { directory(id).appendingPathComponent("SKILL.md") }

    static func isValidId(_ id: String) -> Bool {
        id.count <= maxIdLength && id.range(of: idPattern, options: .regularExpression) != nil
    }

    // MARK: Reading

    public func list() -> [Skill] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(Self.isValidId).sorted().compactMap(skill)
    }

    /// Nil for a folder that is not a valid skill (any more): it is not offered.
    public func skill(_ id: String) -> Skill? {
        guard Self.isValidId(id), let text = content(id),
              let parsed = try? Self.parse(text), parsed.name == id else { return nil }
        let base = directory(id)
        var files: [String] = []
        var bytes = 0
        var scripts = false
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        var updated = 0.0
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
            files.append(relative)
            bytes += values?.fileSize ?? 0
            updated = max(updated, (values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            if !Self.textExtensions.contains((relative as NSString).pathExtension.lowercased())
                || FileManager.default.isExecutableFile(atPath: url.path) {
                scripts = true
            }
        }
        return Skill(id: id, description: parsed.description, files: files.sorted(), bytes: bytes,
                     tokens: LibraryConversion.tokens(text), hasScripts: scripts, updatedAt: updated.rounded())
    }

    public func content(_ id: String) -> String? {
        guard Self.isValidId(id), let data = try? Data(contentsOf: manifest(id)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Front matter

    struct Parsed: Equatable {
        var name: String
        var description: String
        /// The instructions after the front matter.
        var body: String
    }

    /// The `---` block at the top of `SKILL.md`: `name` and `description`
    /// are required, and that is all this reads. Plain, quoted and block
    /// (`|`, `>`) scalars, which is what skill authors write.
    static func parse(_ text: String) throws -> Parsed {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw SkillInvalid("SKILL.md must start with a --- front matter block holding name and description")
        }
        var fields: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            // only top-level keys; nested maps (metadata:) are skipped whole
            guard let first = line.first, !first.isWhitespace, first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                while index < end, lines[index].isEmpty || lines[index].first?.isWhitespace == true {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = block.joined(separator: folded ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if !value.isEmpty, value.first != "\"", value.first != "'" {
                // a plain scalar carries on over indented lines, joined with spaces
                while index < end, lines[index].first?.isWhitespace == true, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    value += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
            } else if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
                value = quote == "'" ? value.replacingOccurrences(of: "''", with: "'")
                    : value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
            }
            fields[key] = value
        }
        guard let name = fields["name"], !name.isEmpty else { throw SkillInvalid("SKILL.md front matter needs a name") }
        guard isValidId(name) else {
            throw SkillInvalid("the skill name must be lowercase letters, digits and single hyphens, at most \(maxIdLength) characters")
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw SkillInvalid("SKILL.md front matter needs a description: it is how a bot knows when to use the skill")
        }
        guard description.count <= maxDescription else { throw SkillInvalid("the description must be at most \(maxDescription) characters") }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(name: name, description: description, body: body)
    }

    // MARK: Writing

    public struct UploadFile {
        public var path: String
        public var data: Data
        public var executable: Bool
    }

    /// `{files: [{path, content (base64), executable?}]}` from the API.
    static func uploadFiles(_ body: JSONObject) throws -> [UploadFile] {
        guard let list = body["files"]?.array, !list.isEmpty else { throw SkillInvalid("files must be a non-empty list") }
        guard list.count <= maxFiles else { throw SkillInvalid("a skill has at most \(maxFiles) files") }
        return try list.map { entry in
            guard let path = entry["path"]?.string, let encoded = entry["content"]?.string,
                  let data = Data(base64Encoded: encoded) else {
                throw SkillInvalid("each file needs a path and its content in base64")
            }
            if let flag = entry["executable"], flag.bool == nil { throw SkillInvalid("executable must be true or false") }
            return UploadFile(path: path, data: data, executable: entry["executable"]?.bool ?? false)
        }
    }

    /// A relative path inside the skill, or nil: no absolute paths, no `..`,
    /// no hidden files, nothing a folder could be tricked into writing elsewhere.
    static func cleanPath(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !path.hasPrefix("/"), !parts.isEmpty, parts.count <= 8,
              parts.allSatisfy({ !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains("\0") && $0.count <= 128 }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// Creates the skill, or replaces it whole with `replace`. The name comes
    /// from `SKILL.md`; the files land in a fresh folder that takes the old
    /// one's place only once all of them are written.
    @discardableResult
    public func add(_ files: [UploadFile], replace: Bool) throws -> Skill {
        var seen = Set<String>()
        var total = 0
        var clean: [(path: String, file: UploadFile)] = []
        for file in files {
            guard let path = Self.cleanPath(file.path) else { throw SkillInvalid("not a valid file path in a skill: \(file.path)") }
            guard seen.insert(path.lowercased()).inserted else { throw SkillInvalid("\(path) is listed twice") }
            total += file.data.count
            clean.append((path, file))
        }
        guard total <= Self.maxBytes else { throw SkillInvalid("a skill can be at most \(Self.maxBytes / 1024 / 1024) MB", status: 413) }
        guard let manifest = clean.first(where: { $0.path == "SKILL.md" }) else { throw SkillInvalid("a skill needs a SKILL.md at the top of its folder") }
        let parsed = try Self.parse(String(decoding: manifest.file.data, as: UTF8.self))
        let id = parsed.name
        let exists = FileManager.default.fileExists(atPath: directory(id).path)
        if exists, !replace { throw SkillInvalid("a skill named \(id) already exists", status: 409) }
        if !exists, list().count >= Self.maxSkills { throw SkillInvalid("at most \(Self.maxSkills) skills") }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = folder.appendingPathComponent(".incoming-\(newId().prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (path, file) in clean {
            let target = staging.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try file.data.write(to: target)
            try fm.setAttributes([.posixPermissions: file.executable ? 0o700 : 0o600], ofItemAtPath: target.path)
        }
        if exists { try fm.removeItem(at: directory(id)) }
        try fm.moveItem(at: staging, to: directory(id))
        onChange?()
        guard let skill = skill(id) else { throw SkillInvalid("the skill could not be read back", status: 500) }
        return skill
    }

    /// The editor's save: a new `SKILL.md`, the rest of the folder untouched.
    /// The name is the folder, so it cannot change here.
    public func update(_ id: String, content: String) throws -> Skill {
        guard FileManager.default.fileExists(atPath: manifest(id).path) else { throw SkillInvalid("no such skill", status: 404) }
        let parsed = try Self.parse(content)
        guard parsed.name == id else { throw SkillInvalid("the name cannot change: it is the skill's id (\(id))") }
        guard content.utf8.count <= Self.maxBytes else { throw SkillInvalid("SKILL.md is too large", status: 413) }
        try FileIO.writeAtomic(Data(content.utf8), to: manifest(id))
        onChange?()
        guard let skill = skill(id) else { throw SkillInvalid("the skill could not be read back", status: 500) }
        return skill
    }

    public func remove(_ id: String) -> Bool {
        guard Self.isValidId(id), FileManager.default.fileExists(atPath: directory(id).path) else { return false }
        try? FileManager.default.removeItem(at: directory(id))
        onChange?()
        return true
    }

    // MARK: Turns

    /// The skills this bot has switched on for this chat (`task` nil in a
    /// room: the defaults), in the bot's order.
    static func active(bot: JSONObject, task: JSONObject?, exists: (String) -> Bool) -> [String] {
        let overrides = task?["skills"]?.object
        var seen = Set<String>()
        return (bot["skills"]?.array ?? []).compactMap { entry in
            guard let id = entry["id"]?.string, seen.insert(id).inserted, exists(id) else { return nil }
            return (overrides?[id]?.bool ?? entry["defaultOn"]?.bool ?? true) ? id : nil
        }
    }

    /// The skills named as `/name` in the message, among the ones the bot
    /// has — on or off in this chat: naming one is the switch.
    static func invoked(_ text: String, bot: JSONObject) -> [String] {
        let assigned = Set((bot["skills"]?.array ?? []).compactMap { $0["id"]?.string })
        guard !assigned.isEmpty, text.contains("/") else { return [] }
        var found: [String] = []
        var previous: Character = " "
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "/", previous.isWhitespace || previous == "(" {
                let start = text.index(after: index)
                let end = text[start...].firstIndex { !($0.isLetter && $0.isASCII && $0.isLowercase) && !$0.isNumber && $0 != "-" } ?? text.endIndex
                let name = String(text[start..<end])
                // "/report." and "/report," still name it; "/path/to" does not
                let next = end < text.endIndex ? text[end] : " "
                if assigned.contains(name), next != "/", !found.contains(name) { found.append(name) }
            }
            previous = char
            index = text.index(after: index)
        }
        return found
    }

    /// The system prompt block for a turn; empty with nothing switched on.
    /// `invoked` skills are left out: their whole text is in the turn.
    func prompt(_ ids: [String], mode: LibraryMode) -> String {
        let skills = ids.compactMap(skill)
        guard !skills.isEmpty else { return "" }
        switch mode {
        case .paths:
            let list = skills.map { "- \($0.id): \(Self.oneLine($0.description)) — \(JSON.string(manifest($0.id).path).serialized())" }
            return "Skills available in this chat. Each is a folder of instructions, with scripts and references beside them." +
                " When a request matches a skill's description, read its SKILL.md before starting and follow it;" +
                " the paths it mentions are relative to its folder. Run its scripts through their interpreter (python3, bash, node…)," +
                " since a synced folder may not keep them executable:\n" + list.joined(separator: "\n")
        case .inline:
            let total = skills.reduce(0) { $0 + $1.tokens }
            guard total <= Self.inlineBudget else {
                let list = skills.map { "- \($0.id): \(Self.oneLine($0.description))" }
                return "Skills the user set up for this chat (too long to include here; the user can call one by writing /name):\n" +
                    list.joined(separator: "\n")
            }
            let blocks = skills.compactMap { skill in
                content(skill.id).map { "<skill name=\(JSON.string(skill.id).serialized())>\n\($0)\n</skill>" }
            }
            return "Skills available in this chat. When a request matches a skill's description, follow its instructions." +
                " Files they mention are not available here.\n\n" + blocks.joined(separator: "\n\n")
        }
    }

    /// What goes before the message when the user named skills with `/name`.
    func invocation(_ ids: [String], mode: LibraryMode) -> String {
        let blocks = ids.compactMap { id -> String? in
            guard let text = content(id) else { return nil }
            let place = mode == .paths ? " folder=\(JSON.string(directory(id).path).serialized())" : ""
            return "<skill name=\(JSON.string(id).serialized())\(place)>\n\(text)\n</skill>"
        }
        guard !blocks.isEmpty else { return "" }
        let names = ids.map { "/\($0)" }.joined(separator: ", ")
        return "[The user called \(names) for this message. Follow the skill's instructions below" +
            (mode == .paths ? "; the paths it mentions are relative to its folder" : "") + ".]\n\n" +
            blocks.joined(separator: "\n\n") + "\n\n[The user's message:]\n\n"
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
