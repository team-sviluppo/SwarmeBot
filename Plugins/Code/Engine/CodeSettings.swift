// The plugin's settings on this engine, in `<data>/plugins/code/settings.json`
// (`GET`/`PUT /api/code/settings`). One model writes the commit messages of every bot.
import Foundation
import HarnessCore

@MainActor
struct CodeSettings {
    private let file: URL

    init(harness: Harness) {
        file = harness.plugins.directory(for: "code").appendingPathComponent("settings.json")
    }

    private var stored: JSONObject {
        guard let data = try? Data(contentsOf: file), let object = try? JSON.parse(data).object else { return JSONObject() }
        return object
    }

    /// The model that writes commit messages; nil leaves it to the chat's own bot.
    var commitModel: ModelSelection? {
        guard let json = stored["commitModel"], json.object != nil else { return nil }
        let selection = ModelSelection(json: json)
        return selection.instanceId.isEmpty || selection.model.isEmpty ? nil : selection
    }

    var wire: JSON {
        ["commitModel": commitModel.map(\.json) ?? .null]
    }

    func update(_ body: JSONObject, harness: Harness) throws {
        var next = stored
        if let value = body["commitModel"] {
            if value.isNull {
                next["commitModel"] = nil
            } else {
                let selection = ModelSelection(json: value)
                guard !selection.model.isEmpty, harness.fleet.get(selection.instanceId) != nil else {
                    throw HTTPError(400, "commitModel must name a model of an engine this server has")
                }
                next["commitModel"] = .object(JSONObject([("instanceId", .string(selection.instanceId)), ("model", .string(selection.model))]))
            }
        }
        try FileIO.writeAtomic(JSON.object(next).data, to: file)
    }
}
