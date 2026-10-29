import Foundation

/// A provider task belongs to the enclosing SwarmeBot turn, even when its
/// parent has already answered. Kept in ordinary activity messages so old
/// desktop and phone clients can still inspect its request and result.
public struct SubagentState: Equatable, Sendable {
    public var id: String
    public var parentId: String
    public var title: String
    public var status: String = "running"
    public var result: String?
    public var outputFile: String?
    public var toolUseId: String?
    public var waitsForCompletion = true

    public init(id: String, parentId: String, title: String) {
        self.id = id
        self.parentId = parentId
        self.title = title
    }

    public var isRunning: Bool { status == "running" }

    public var json: JSON {
        var value: JSONObject = ["id": .string(id), "parentId": .string(parentId), "title": .string(title), "status": .string(status)]
        if let result { value["result"] = .string(result) }
        if let outputFile { value["outputFile"] = .string(outputFile) }
        if let toolUseId { value["toolUseId"] = .string(toolUseId) }
        return .object(value)
    }
}
