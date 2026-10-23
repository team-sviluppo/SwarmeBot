// Routes only the desktop client calls.
//
// The phone stops at what `companion/src/routes.ts` lets a paired device do.
// The Mac app is the harness's own front end on loopback, so it reaches the
// rest: editing and deleting bots, rooms' interrupt, settings. Kept in a
// separate file so the part shared with the iOS companion stays diffable
// against its origin.
import Foundation

/// The fields `PATCH /api/bots/:id` accepts that this client sets. Every
/// field is optional; only the ones present are sent.
public struct BotPatch: Sendable {
    public var name: String?
    public var title: String?
    public var description: String?
    public var modelSelection: ModelSelection?
    public var pinned: Bool?
    public var hidden: Bool?
    public var unread: Bool?
    public var notifications: Bool?
    public var autoApprove: Bool?
    /// "" clears the label.
    public var section: String?
    public var color: String?
    /// "vm" or "off" — the only values the PATCH accepts.
    public var computer: String?
    public var cwd: String?
    /// Appearance. "" clears the field, so the bot falls back to its default.
    public var mascotSilhouette: String?
    public var mascotExpression: String?
    /// Drops the uploaded picture (still, sheet or SVG): the mascot is back.
    public var clearPicture = false
    /// Sprite sheet row 0–8; -1 shows the picture as a still image.
    public var mascotAvatarSheetRow: Int?

    public init(
        name: String? = nil, title: String? = nil, description: String? = nil,
        modelSelection: ModelSelection? = nil, pinned: Bool? = nil, hidden: Bool? = nil,
        unread: Bool? = nil, notifications: Bool? = nil, autoApprove: Bool? = nil,
        section: String? = nil, color: String? = nil, computer: String? = nil, cwd: String? = nil
    ) {
        self.computer = computer
        self.cwd = cwd
        self.name = name
        self.title = title
        self.description = description
        self.modelSelection = modelSelection
        self.pinned = pinned
        self.hidden = hidden
        self.unread = unread
        self.notifications = notifications
        self.autoApprove = autoApprove
        self.section = section
        self.color = color
    }

    var body: [String: Any] {
        var out: [String: Any] = [:]
        if let name { out["name"] = name }
        if let title { out["title"] = title }
        if let description { out["description"] = description }
        if let modelSelection {
            var selection: [String: Any] = ["instanceId": modelSelection.instanceId, "model": modelSelection.model]
            if let effort = modelSelection.effort { selection["effort"] = effort }
            out["modelSelection"] = selection
        }
        if let pinned { out["pinned"] = pinned }
        if let hidden { out["hidden"] = hidden }
        if let unread { out["unread"] = unread }
        if let notifications { out["notifications"] = notifications }
        if let autoApprove { out["autoApprove"] = autoApprove }
        if let section { out["section"] = section }
        if let color { out["color"] = color }
        if let computer { out["computer"] = computer }
        if let cwd { out["cwd"] = cwd }
        if let mascotSilhouette { out["mascotSilhouette"] = mascotSilhouette.isEmpty ? NSNull() : mascotSilhouette }
        if let mascotExpression { out["mascotExpression"] = mascotExpression.isEmpty ? NSNull() : mascotExpression }
        if clearPicture {
            out["mascotAvatarImage"] = NSNull()
            out["mascotAvatarSvg"] = NSNull()
        }
        if let mascotAvatarSheetRow { out["mascotAvatarSheetRow"] = mascotAvatarSheetRow < 0 ? NSNull() : mascotAvatarSheetRow }
        return out
    }

    public var bodyForTesting: [String: Any] { body }
}

public struct HarnessHealth: Codable, Sendable {
    public var app: String
    public var pid: Int
    public var `static`: Bool?
}

/// `PATCH /api/groups/:gid`.
public struct RoomPatch: Sendable {
    public var name: String?
    public var bulletin: String?
    public var memberIds: [String]?
    /// "everyone" · "mentions" · "member" (with `responderBotId`)
    public var responder: String?
    public var responderBotId: String?
    /// The channel's working folder; an empty string clears it. Refused (409)
    /// once the room has had its first turn.
    public var cwd: String?
    /// Members from other engines; an empty list removes them all.
    public var guests: [RoomGuest]?

    public init(name: String? = nil, bulletin: String? = nil, memberIds: [String]? = nil, responder: String? = nil, responderBotId: String? = nil,
                cwd: String? = nil, guests: [RoomGuest]? = nil) {
        self.cwd = cwd
        self.guests = guests
        self.name = name
        self.bulletin = bulletin
        self.memberIds = memberIds
        self.responder = responder
        self.responderBotId = responderBotId
    }

    var body: [String: Any] {
        var out: [String: Any] = [:]
        if let name { out["name"] = name }
        if let bulletin { out["bulletin"] = bulletin }
        if let memberIds { out["memberIds"] = memberIds }
        if let cwd { out["cwd"] = cwd }
        if let guests { out["guests"] = guests.map(\.body) }
        if let responder {
            var value: [String: Any] = ["kind": responder]
            if let responderBotId { value["botId"] = responderBotId }
            out["defaultResponder"] = value
        }
        return out
    }
}

public struct SavedAttachment: Codable, Sendable {
    public var path: String
    public var mime: String
    public var bytes: Int
}

public struct CLITestResult: Codable, Sendable {
    public var ok: Bool
    public var version: String?
    public var message: String?

    public init(ok: Bool, version: String?, message: String?) {
        self.ok = ok
        self.version = version
        self.message = message
    }
}

private struct RoomResponse: Codable { var group: Room }
private struct InstancesResponse: Codable { var instances: [Instance] }
private struct CandidatesResponse: Codable { var candidates: [String] }
private struct RoutineResponse: Codable { var routine: Routine }
private struct RunResponse: Codable { var run: RoutineRun }
private struct WebhookResponse: Codable { var webhook: WebhookTrigger }

extension CompanionClient {
    /// A request whose body is JSON even when empty. The harness answers 415
    /// to the dangerous routes (computer, local VM, CLI test, instance
    /// writes) unless the content type says JSON — a form post from a
    /// hostile page cannot claim that without a CORS preflight.
    func jsonRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any] = [:]) throws -> URLRequest {
        try makeRequest(method, path, query: query, body: body)
    }

    public func health() async throws -> HarnessHealth {
        try await send(try makeRequest("GET", "/api/health"), as: HarnessHealth.self)
    }

    // MARK: Bots

    @discardableResult
    public func patchBot(_ botId: String, _ patch: BotPatch) async throws -> Bot {
        try await send(try makeRequest("PATCH", "/api/bots/\(botId)", body: patch.body), as: BotResponse.self).bot
    }

    public func deleteBot(_ botId: String) async throws {
        try await send(try makeRequest("DELETE", "/api/bots/\(botId)"))
    }

    public func setTaskPinned(botId: String, threadId: String, pinned: Bool) async throws {
        try await send(try makeRequest("PATCH", "/api/bots/\(botId)/tasks/\(threadId)", body: ["pinned": pinned]))
    }

    public func setTaskCwd(botId: String, threadId: String, cwd: String) async throws {
        try await send(try makeRequest("PATCH", "/api/bots/\(botId)/tasks/\(threadId)", body: ["cwd": cwd]))
    }

    public func library(botId: String) async throws -> [LibraryDoc] {
        struct Docs: Decodable { var docs: [LibraryDoc] }
        return try await send(try makeRequest("GET", "/api/bots/\(botId)/library"), as: Docs.self).docs
    }

    /// The harness copies the file from this path: both run on this Mac.
    public func addLibraryDoc(botId: String, path: String) async throws {
        try await send(try makeRequest("POST", "/api/bots/\(botId)/library", body: ["path": path]))
    }

    public func deleteLibraryDoc(botId: String, docId: String) async throws {
        try await send(try makeRequest("DELETE", "/api/bots/\(botId)/library/\(docId)"))
    }

    public func libraryText(botId: String, docId: String) async throws -> String {
        struct Text: Decodable { var text: String }
        return try await send(try makeRequest("GET", "/api/bots/\(botId)/library/\(docId)/text"), as: Text.self).text
    }

    /// The connector switches of one chat: only those that differ from the bot's defaults.
    public func setTaskConnectors(botId: String, threadId: String, _ overrides: [String: Bool]) async throws {
        try await send(try makeRequest("PATCH", "/api/bots/\(botId)/tasks/\(threadId)", body: ["connectors": overrides]))
    }

    /// Which connectors a bot may use.
    @discardableResult
    public func setBotConnectors(botId: String, _ connectors: [BotConnector]) async throws -> Bot {
        let list = connectors.map { ["id": $0.id, "defaultOn": $0.defaultOn] as [String: Any] }
        return try await send(try makeRequest("PATCH", "/api/bots/\(botId)", body: ["connectors": list]), as: BotResponse.self).bot
    }

    /// The documents this chat leaves out.
    public func setTaskLibraryOff(botId: String, threadId: String, off: [String]) async throws {
        try await send(try makeRequest("PATCH", "/api/bots/\(botId)/tasks/\(threadId)", body: ["libraryOff": off]))
    }

    /// Answer with the full shape: several picks and/or free text.
    public func respond(threadId: String, requestId: String, selected: [String], custom: String?) async throws {
        var body: [String: Any] = ["requestId": requestId, "behavior": "answer", "selected": selected]
        let message = custom ?? selected.first
        if let message { body["message"] = message }
        if let custom { body["custom"] = custom }
        try await send(try makeRequest("POST", "/api/threads/\(threadId)/respond", body: body))
    }

    // MARK: Rooms

    @discardableResult
    public func patchRoom(_ groupId: String, _ patch: RoomPatch) async throws -> Room {
        try await send(try makeRequest("PATCH", "/api/groups/\(groupId)", body: patch.body), as: RoomResponse.self).group
    }

    public func deleteRoom(_ groupId: String) async throws {
        try await send(try makeRequest("DELETE", "/api/groups/\(groupId)"))
    }

    public func interrupt(roomId: String) async throws {
        try await send(try makeRequest("POST", "/api/groups/\(roomId)/interrupt"))
    }

    // MARK: Attachments

    /// Save an image server-side; the returned path goes into the prompt as
    /// `<attached-image path="…"/>` so every engine can open it.
    public func uploadAttachment(_ data: Data, mime: String) async throws -> SavedAttachment {
        var request = try makeRequest("POST", "/api/attachments")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 60
        return try await send(request, as: SavedAttachment.self)
    }

    /// `POST /api/bots/:id/avatar/upload`: a raster or SVG that replaces the
    /// mascot. The server tells a still from a 9×8 sprite sheet by its shape.
    @discardableResult
    public func uploadAvatar(botId: String, _ data: Data, mime: String) async throws -> Bot {
        var request = try makeRequest("POST", "/api/bots/\(botId)/avatar/upload")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 60
        return try await send(request, as: BotResponse.self).bot
    }

    public func attachment(named name: String) async throws -> Data {
        let request = try makeRequest("GET", "/api/attachments/\(name)")
        let (data, response) = try await perform(request)
        try Self.check(response, data)
        return data
    }

    /// `POST /api/threads/:tid/files`: which of these references name a file
    /// the engine can hand over.
    public func replyFiles(threadId: String, references: [String]) async throws -> [ReplyFile] {
        struct Answer: Decodable { var files: [ReplyFile] }
        let request = try makeRequest("POST", "/api/threads/\(threadId)/files", body: ["paths": references])
        return try await send(request, as: Answer.self).files
    }

    /// `GET /api/threads/:tid/files/content`: the bytes of one of those files.
    public func replyFileContent(threadId: String, path: String) async throws -> Data {
        var request = try makeRequest("GET", "/api/threads/\(threadId)/files/content", query: [URLQueryItem(name: "path", value: path)])
        request.timeoutInterval = 120
        let (data, response) = try await perform(request)
        try Self.check(response, data)
        return data
    }

    // MARK: Config and engines

    /// `secretStorage=external` keeps credentials out of config.json: the app
    /// holds them in the Keychain and hands them to the harness at boot.
    @discardableResult
    public func saveConfig(_ patch: [String: Any], externalSecrets: Bool) async throws -> ConfigStatus {
        let query = externalSecrets ? [URLQueryItem(name: "secretStorage", value: "external")] : []
        return try await send(try makeRequest("PUT", "/api/config", query: query, body: patch), as: ConfigStatus.self)
    }

    @discardableResult
    public func patchInstance(_ instanceId: String, cli: String? = nil, pickerVisible: Bool?? = nil) async throws -> [Instance] {
        var body: [String: Any] = [:]
        if let cli { body["cli"] = cli }
        if let pickerVisible { body["pickerVisible"] = pickerVisible.map { $0 as Any } ?? NSNull() }
        return try await send(try jsonRequest("PATCH", "/api/instances/\(instanceId)", body: body), as: InstancesResponse.self).instances
    }

    public func cliCandidates(name: String) async throws -> [String] {
        try await send(try makeRequest("GET", "/api/cli-candidates", query: [URLQueryItem(name: "name", value: name)]), as: CandidatesResponse.self).candidates
    }

    public func testCLI(_ cli: String, driver: String?) async throws -> CLITestResult {
        var body: [String: Any] = ["cli": cli]
        if let driver { body["driver"] = driver }
        return try await send(try jsonRequest("POST", "/api/cli-test", body: body), as: CLITestResult.self)
    }

    // MARK: Routines

    public func routines() async throws -> RoutineList {
        try await send(try makeRequest("GET", "/api/routines"), as: RoutineList.self)
    }

    @discardableResult
    public func createRoutine(_ input: RoutineInput) async throws -> Routine {
        try await send(try makeRequest("POST", "/api/routines", body: input.json), as: RoutineResponse.self).routine
    }

    @discardableResult
    public func updateRoutine(_ id: String, _ input: RoutineInput) async throws -> Routine {
        try await send(try makeRequest("PATCH", "/api/routines/\(id)", body: input.json), as: RoutineResponse.self).routine
    }

    public func setRoutineEnabled(_ id: String, _ enabled: Bool) async throws {
        try await send(try makeRequest("PATCH", "/api/routines/\(id)", body: ["enabled": enabled]))
    }

    public func deleteRoutine(_ id: String) async throws {
        try await send(try makeRequest("DELETE", "/api/routines/\(id)"))
    }

    @discardableResult
    public func runRoutine(_ id: String) async throws -> RoutineRun {
        try await send(try makeRequest("POST", "/api/routines/\(id)/run"), as: RunResponse.self).run
    }

    public func cancelRun(_ runId: String) async throws {
        try await send(try makeRequest("POST", "/api/routine-runs/\(runId)/cancel"))
    }

    // MARK: Webhooks

    public func webhooks() async throws -> WebhookList {
        try await send(try makeRequest("GET", "/api/webhooks"), as: WebhookList.self)
    }

    public func createWebhook(_ input: WebhookInput) async throws -> WebhookCreated {
        try await send(try makeRequest("POST", "/api/webhooks", body: input.json), as: WebhookCreated.self)
    }

    @discardableResult
    public func updateWebhook(_ id: String, _ body: [String: Any]) async throws -> WebhookTrigger {
        try await send(try makeRequest("PATCH", "/api/webhooks/\(id)", body: body), as: WebhookResponse.self).webhook
    }

    public func deleteWebhook(_ id: String) async throws {
        try await send(try makeRequest("DELETE", "/api/webhooks/\(id)"))
    }

    public func rotateWebhook(_ id: String) async throws -> WebhookCreated {
        try await send(try makeRequest("POST", "/api/webhooks/\(id)/rotate"), as: WebhookCreated.self)
    }

    public func testWebhook(_ id: String) async throws {
        try await send(try makeRequest("POST", "/api/webhooks/\(id)/test", body: ["event": "swarme.test", "message": "Test webhook delivery"]))
    }

    // MARK: Computers

    public func localComputer() async throws -> LocalComputerStatus {
        try await send(try makeRequest("GET", "/api/local-computer"), as: LocalComputerStatus.self)
    }

    /// pull · run · start · stop · remove
    @discardableResult
    public func localComputer(_ action: String) async throws -> LocalComputerStatus {
        var request = try jsonRequest("POST", "/api/local-computer/\(action)")
        // pulling an image and building the desktop can take minutes
        request.timeoutInterval = 900
        return try await send(request, as: LocalComputerStatus.self)
    }

    public func cloudComputer(botId: String) async throws -> CloudComputerStatus {
        try await send(try makeRequest("GET", "/api/bots/\(botId)/computer"), as: CloudComputerStatus.self)
    }

    /// provision · sleep · remove (join has its own call: it mints a viewer).
    public func cloudComputer(botId: String, action: String) async throws {
        var request = try jsonRequest("POST", "/api/bots/\(botId)/computer/\(action)")
        request.timeoutInterval = 300
        try await send(request)
    }

    /// The desktop-safe `join`: JSON content type, unlike the phone's.
    public func joinCloudDesktop(botId: String) async throws -> CloudDesktopSession {
        try await send(try jsonRequest("POST", "/api/bots/\(botId)/computer/join"), as: CloudDesktopSession.self)
    }

    /// take · release · dismiss-help
    @discardableResult
    public func computerControl(botId: String, action: String) async throws -> ComputerControl {
        try await send(try jsonRequest("POST", "/api/bots/\(botId)/computer/control", body: ["action": action]), as: ComputerControl.self)
    }

    // MARK: Inspector, decisions

    public func events(threadId: String, limit: Int = 400) async throws -> [InspectorEntry] {
        try await send(
            try makeRequest("GET", "/api/threads/\(threadId)/events", query: [URLQueryItem(name: "limit", value: String(limit))]),
            as: InspectorPage.self
        ).entries
    }

    public func decisions(limit: Int = 200) async throws -> [DecisionRecord] {
        try await send(
            try makeRequest("GET", "/api/decisions", query: [URLQueryItem(name: "limit", value: String(limit))]),
            as: DecisionList.self
        ).decisions
    }

    // MARK: Teams

    public func teamCatalog() async throws -> TeamCatalog {
        var request = try makeRequest("GET", "/api/team-library/catalog")
        request.timeoutInterval = 30
        return try await send(request, as: TeamCatalog.self)
    }

    public func teamManifest(slug: String) async throws -> JSONValue {
        try await send(try makeRequest("GET", "/api/team-library/teams/\(slug)"), as: JSONValue.self)
    }

    public func teamManifest(github url: String) async throws -> JSONValue {
        try await send(try makeRequest("POST", "/api/team-library/github", body: ["url": url]), as: JSONValue.self)
    }

    public func exportTeam(name: String?) async throws -> Data {
        var body: [String: Any] = [:]
        if let name, !name.isEmpty { body["name"] = name }
        let request = try makeRequest("POST", "/api/teams/export", body: body)
        let (data, response) = try await perform(request)
        try Self.check(response, data)
        return data
    }

    /// mode: add · replace
    public func importTeam(manifest: Data, mode: String) async throws {
        var request = try makeRequest("POST", "/api/teams/import", query: [URLQueryItem(name: "mode", value: mode)])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = manifest
        try await send(request)
    }

    // MARK: DeepSeek Harness

    public func deepSeekHarness(instanceId: String) async throws -> DeepSeekHarnessSettings {
        try await send(try makeRequest("GET", "/api/instances/\(instanceId)/deepseek-harness"), as: DeepSeekHarnessSettings.self)
    }

    public func saveDeepSeekHarness(instanceId: String, baseUrl: String?, transport: String?, agentPreset: String?) async throws {
        var body: [String: Any] = [:]
        if let baseUrl { body["baseUrl"] = baseUrl }
        if let transport { body["transport"] = transport }
        if let agentPreset { body["agentPreset"] = agentPreset.isEmpty ? NSNull() : agentPreset }
        try await send(try jsonRequest("PATCH", "/api/instances/\(instanceId)/deepseek-harness", body: body))
    }

    public func pairDeepSeekHarness(instanceId: String, pairingLink: String) async throws {
        try await send(try jsonRequest("POST", "/api/instances/\(instanceId)/deepseek-harness/pair", body: ["pairingLink": pairingLink]))
    }
}

public struct DeepSeekHarnessSettings: Codable, Sendable {
    public struct Connection: Codable, Sendable {
        public var transport: String
        public var baseUrl: String
        public var paired: Bool?
        public var agentPreset: String?
    }

    public var connection: Connection
}
