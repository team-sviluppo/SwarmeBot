// What the Cylon plugin keeps on the engine, in `<data>/plugins/cylon/`: which bot plays each phase for a
// project (`roles.json`), the skill source it uses (`settings.json`), and the pipeline of each channel
// (`pipelines.json`). The channel's own switch, "follow the Cylon flow", is plain plugin data on the channel.
import Foundation
import HarnessCore

@MainActor
struct CylonStore {
    private let directory: URL

    init(harness: Harness) {
        directory = harness.plugins.directory(for: "cylon")
    }

    private func read(_ name: String) -> JSONObject {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)), let object = try? JSON.parse(data).object else { return JSONObject() }
        return object
    }

    private func write(_ name: String, _ object: JSONObject) throws {
        try FileIO.writeAtomic(JSON.object(object).data, to: directory.appendingPathComponent(name))
    }

    // MARK: roles

    /// Project id → phase → bot id.
    var roles: JSONObject { read("roles.json") }

    func roles(of projectId: String) -> [CylonPhase: String] {
        var out: [CylonPhase: String] = [:]
        for phase in CylonPhase.allCases { if let id = roles[projectId]?[phase.rawValue]?.string, !id.isEmpty { out[phase] = id } }
        return out
    }

    /// A phase with `null` loses its bot; one that is not sent keeps it. A bot must exist.
    func setRoles(_ body: JSONObject, project: String, harness: Harness) throws {
        guard project.range(of: #"^[\w-]{1,80}$"#, options: .regularExpression) != nil else { throw HTTPError(400, "not a valid project id") }
        if let unknown = body.keys.first(where: { CylonPhase(rawValue: $0) == nil }) { throw HTTPError(400, "\(unknown) is not a phase: use \(CylonPhase.allCases.map(\.rawValue).joined(separator: ", "))") }
        var all = roles
        var mine = all[project]?.object ?? JSONObject()
        for (key, value) in body {
            if value.isNull { mine[key] = nil; continue }
            guard let id = value.string, harness.store.bot(id) != nil else { throw HTTPError(400, "\(key): no such bot") }
            mine[key] = .string(id)
        }
        all[project] = mine.isEmpty ? Optional<JSON>.none : .object(mine)
        try write("roles.json", all)
    }

    func forgetBot(_ botId: String) {
        var all = roles
        var changed = false
        for (project, value) in all {
            guard var mine = value.object else { continue }
            for (phase, bot) in mine where bot.string == botId { mine[phase] = nil; changed = true }
            all[project] = mine.isEmpty ? Optional<JSON>.none : .object(mine)
        }
        if changed { try? write("roles.json", all) }
    }

    // MARK: settings

    var sourceId: String? { read("settings.json")["sourceId"]?.string }

    func setSource(_ id: String?) throws {
        var settings = read("settings.json")
        settings["sourceId"] = id.map { .string($0) } ?? Optional<JSON>.none
        try write("settings.json", settings)
    }

    // MARK: pipelines

    func pipeline(of groupId: String) -> CylonPipeline? { CylonPipeline(json: read("pipelines.json")[groupId]) }

    func save(_ pipeline: CylonPipeline?, of groupId: String) throws {
        var all = read("pipelines.json")
        all[groupId] = pipeline.map(\.json) ?? Optional<JSON>.none
        try write("pipelines.json", all)
    }

    /// Every channel's pipeline that has a phase waiting on a turn, for the plugin to follow.
    func pipelines() -> [(groupId: String, pipeline: CylonPipeline)] {
        read("pipelines.json").compactMap { key, value in CylonPipeline(json: value).map { (key, $0) } }
    }
}
