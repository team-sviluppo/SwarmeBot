// Skills (docs/plans/2026-10-21-skill.md): the repository on the engine,
// which bot sees which, and the switches of the chat that is open.
import CompanionCore
import Foundation

extension AppModel {
    public func refreshSkills() async {
        guard let client else { return }
        if let list = try? await client.skills() { skills = list }
        if let folder = try? await client.skillsFolder() { skillsFolder = folder }
    }

    /// A skill folder, or a `.zip`/`.skill` holding one, from this Mac.
    /// With `replace` an existing skill of the same name is swapped whole.
    public func importSkill(from url: URL, replace: Bool) async -> Result<Skill, Error> {
        guard let client else { return .failure(CancellationError()) }
        do {
            let files = try SkillFolder.read(url)
            let skill = try await client.addSkill(files, replace: replace)
            upsert(skill)
            return .success(skill)
        } catch {
            return .failure(error)
        }
    }

    /// A new skill written in the editor: just its `SKILL.md`.
    public func createSkill(content: String) async -> Result<Skill, Error> {
        guard let client else { return .failure(CancellationError()) }
        do {
            let skill = try await client.addSkill([SkillFile(path: "SKILL.md", data: Data(content.utf8), executable: false)], replace: false)
            upsert(skill)
            return .success(skill)
        } catch {
            return .failure(error)
        }
    }

    public func skillContent(_ skill: Skill) async -> String? {
        try? await client?.skillContent(skill.id).content
    }

    public func updateSkill(_ skill: Skill, content: String) async -> Result<Skill, Error> {
        guard let client else { return .failure(CancellationError()) }
        do {
            let saved = try await client.updateSkill(skill.id, content: content)
            upsert(saved)
            return .success(saved)
        } catch {
            return .failure(error)
        }
    }

    public func delete(skill: Skill) async {
        await perform { client in
            try await client.deleteSkill(skill.id)
            self.skills.removeAll { $0.id == skill.id }
        }
    }

    /// Nil goes back to the engine's default folder.
    public func setSkillsFolder(_ path: String?) async {
        await perform { client in
            self.skillsFolder = try await client.setSkillsFolder(path)
            self.skills = try await client.skills()
        }
    }

    public func setSkills(_ bot: Bot, _ skills: [BotSkill]) async {
        await perform { try await $0.setBotSkills(botId: bot.id, skills) }
    }

    /// Whether a skill is on in the chat that is open: the chat's own
    /// switch, else the bot's default.
    public func skillIsOn(_ bot: Bot, _ id: String) -> Bool {
        let task = bot.tasks?.first { $0.threadId == bot.threadId }
        return task?.skills?[id] ?? bot.skills?.first { $0.id == id }?.defaultOn ?? false
    }

    /// Flip a skill for the chat that is open; a switch back to the default
    /// is dropped, so the chat follows the bot again.
    public func setSkill(_ bot: Bot, _ id: String, on: Bool) async {
        var overrides = bot.tasks?.first { $0.threadId == bot.threadId }?.skills ?? [:]
        let fallback = bot.skills?.first { $0.id == id }?.defaultOn ?? false
        overrides[id] = on == fallback ? nil : on
        await perform { try await $0.setTaskSkills(botId: bot.id, threadId: bot.threadId, overrides) }
    }

    public func resetSkills(_ bot: Bot) async {
        await perform { try await $0.setTaskSkills(botId: bot.id, threadId: bot.threadId, [:]) }
    }

    /// The bot's skills that still exist, in the bot's order.
    public func assignedSkills(_ bot: Bot) -> [Skill] {
        (bot.skills ?? []).compactMap { entry in skills.first { $0.id == entry.id } }
    }

    private func upsert(_ skill: Skill) {
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.append(skill)
            skills.sort { $0.id < $1.id }
        }
    }
}

/// Reads a skill off this Mac's disk into the files the engine takes.
public enum SkillFolder {
    public static let maxFiles = 200
    public static let maxBytes = 8 * 1024 * 1024

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// A folder with `SKILL.md` at its top, or a zip holding one (at its
    /// root or in a single folder, as Claude exports them). Hidden files
    /// (.git, .DS_Store) and links stay behind.
    public static func read(_ url: URL) throws -> [SkillFile] {
        let ext = url.pathExtension.lowercased()
        if ext == "zip" || ext == "skill" {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: temp) }
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", url.path, temp.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw Failure(message: tr("Non riesco ad aprire l'archivio %@.", url.lastPathComponent)) }
            return try read(folder: root(of: temp))
        }
        return try read(folder: url)
    }

    /// Where `SKILL.md` is in an unpacked archive.
    static func root(of dir: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) { return dir }
        let children = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if children.count == 1, FileManager.default.fileExists(atPath: children[0].appendingPathComponent("SKILL.md").path) {
            return children[0]
        }
        throw Failure(message: tr("Nell'archivio non c'è un SKILL.md, né in cima né in un'unica cartella."))
    }

    static func read(folder: URL) throws -> [SkillFile] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("SKILL.md").path) else {
            throw Failure(message: tr("Nella cartella %@ non c'è un SKILL.md: una skill è una cartella con SKILL.md in cima.", folder.lastPathComponent))
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [SkillFile] = []
        var total = 0
        while let url = walker.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1))
            total += values.fileSize ?? 0
            guard files.count < maxFiles else { throw Failure(message: tr("Una skill può avere al massimo %@ file.", String(maxFiles))) }
            guard total <= maxBytes else { throw Failure(message: tr("Una skill può pesare al massimo %@ MB.", String(maxBytes / 1024 / 1024))) }
            let data = try Data(contentsOf: url)
            files.append(SkillFile(path: path, data: data, executable: FileManager.default.isExecutableFile(atPath: url.path)))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The skeleton "Nuova skill" opens with.
    public static func template(name: String) -> String {
        """
        ---
        name: \(name)
        description: \(tr("Cosa fa questa skill e quando usarla: il bot la sceglie da qui."))
        ---

        # \(name)

        \(tr("Istruzioni passo passo per il bot."))

        """
    }
}

extension SkillFolder {
    /// Files a bot reads rather than runs, as the engine judges them.
    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "json", "yaml", "yml", "toml", "csv", "tsv", "xml", "html", "htm", "css",
        "png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "ttf", "otf", "woff", "woff2",
    ]

    /// Whether importing these would let bots run something: the warning
    /// shown before the upload, worked out the way the engine does.
    public static func hasScripts(_ files: [SkillFile]) -> Bool {
        files.contains { $0.executable || !textExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
    }
}

extension AppModel {
    /// A skill of this Mac's engine, sent to a server's engine. Refused with
    /// 409 when the server has one of that name, unless `replace`.
    public func copySkill(_ skill: Skill, to engine: RemoteEngine, replace: Bool) async throws -> Skill {
        guard let folder = skillsFolder?.folder else { throw SkillFolder.Failure(message: tr("Cartella delle skill sconosciuta.")) }
        let files = try SkillFolder.read(URL(fileURLWithPath: folder).appendingPathComponent(skill.id))
        return try await remoteClient(engine).addSkill(files, replace: replace)
    }
}
