// The harness's wire types, in Swift.
//
// These mirror `server/store.ts` and the payloads in `server/index.ts`.
// There is no shared type system across the two languages, so the contract
// is pinned by fixtures instead: `Tests/CompanionCoreTests/Fixtures` holds
// real responses captured from a running server, and the decoding tests
// read them. When the server changes a payload, a test here fails.
//
// Everything the server may omit is optional, and nothing is decoded more
// strictly than it has to be — a phone that refuses to show a conversation
// because one message gained a field is worse than one that ignores it.
import Foundation

// MARK: - Messages

public struct OptionCard: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var options: [String]
    public var answered: String?
    public var dismissed: Bool?
    /// Present when this card is a live provider ask — the thing that makes
    /// it answerable rather than historical.
    public var requestId: String?
    public var tool: String?
    /// Why auto mode stopped to ask anyway.
    public var held: String?
    /// The narrow grant "always allow" would remember, e.g. `Bash:git`.
    public var allowKey: String?
    /// Desktop: a question that accepts several options at once.
    public var multiSelect: Bool?
    /// Desktop: "local-computer" when the ask is about driving this Mac.
    public var approvalScope: String?

    /// A card is actionable while it is unanswered and still has a request
    /// behind it. Everything else is transcript.
    public var isPending: Bool {
        requestId != nil && answered == nil && dismissed != true
    }

    /// Permission cards carry a tool; questions do not.
    public var isPermission: Bool { tool != nil }
}

public struct ToolActivity: Codable, Hashable, Sendable {
    public var name: String
    public var ok: Bool?
    /// The same chip as a phrase a voice can read.
    public var spoken: String?
    /// Marks an error fixed by installing something, not by retrying.
    public var setup: Bool?
    /// What the tool was called with and what it answered, shortened and
    /// scrubbed by the harness. Absent on calls older than these fields.
    public var input: String?
    public var output: String?
}

extension Message {
    /// Ordinary tool activity can be hidden; setup failures and engine errors
    /// must remain visible alongside questions, replies and activity notes.
    public var isToolCall: Bool {
        guard kind == .activity, let tool, tool.setup != true else { return false }
        let name = tool.name.lowercased()
        return !name.hasPrefix("error") && !name.hasPrefix("connettore non raggiungibile")
    }
}

public struct Sender: Codable, Hashable, Sendable {
    public var botId: String
    public var name: String
    public var color: String
}

public struct Reaction: Codable, Hashable, Sendable {
    public var emoji: String
    public var by: String
}

public struct CommChip: Codable, Hashable, Sendable {
    public var groupId: String
    public var withBotId: String
    public var withName: String
    public var withColor: String
}

public struct Message: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, options, activity, screen
        /// A kind this build has never heard of.
        ///
        /// Not decorative. `kind` is not optional, so without this a single
        /// unrecognised message fails the decode of the whole response it
        /// arrived in — the thread does not render one message oddly, it
        /// does not render. The harness gains message kinds on its own
        /// schedule and the phone is updated on the App Store's, so "newer
        /// computer than phone" is the normal state of things, not an edge
        /// case. Degrading to the text a message carries is worth more than
        /// being right about its shape.
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public enum Role: String, Codable, Sendable {
        case bot, user

        /// Same reasoning, and `bot` rather than a third case: an unplaceable
        /// message drawn as yours would be the phone claiming you said
        /// something you did not.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Role(rawValue: raw) ?? .bot
        }
    }

    public var id: String
    public var role: Role
    public var kind: Kind
    public var at: Double
    public var text: String?
    public var card: OptionCard?
    public var tool: ToolActivity?
    /// The message this one follows; nil at the thread root. Two messages
    /// sharing a parent are a fork.
    public var parentId: String?
    /// Rooms: which member said this.
    public var from: Sender?
    public var reactions: [Reaction]?
    public var comm: CommChip?
    /// Screen messages in the paged shape: the pixels live behind
    /// `/api/threads/:threadId/messages/:id/image` rather than inline.
    public var hasImage: Bool?
    /// Screen messages in the full shape: base64 pixels, inline.
    public var png: String?
    public var mime: String?
    /// Desktop: sent while the bot was busy; goes out when the turn settles.
    public var queued: Bool?
    /// Desktop: the reply a stopped turn left behind.
    public var interrupted: Bool?

    public var date: Date { Date(timeIntervalSince1970: at / 1000) }
}

// MARK: - Bots and rooms

public struct ModelSelection: Codable, Hashable, Sendable {
    public var instanceId: String
    public var model: String
    /// Reasoning effort, when the engine offers levels. Desktop only.
    public var effort: String?

    public init(instanceId: String, model: String, effort: String? = nil) {
        self.instanceId = instanceId
        self.model = model
        self.effort = effort
    }
}

public struct TaskUsage: Codable, Hashable, Sendable {
    public var input: Double?
    public var output: Double?
    public var costUsd: Double?
    public var costEstimated: Bool?
    public var turns: Int?
    /// Output tokens whose reply time was measured, and that time in seconds.
    /// Older turns have tokens and no clock, so the speed uses only these.
    /// `estimatedOutput` is the part of `timedOutput` guessed from the text
    /// when the provider sent no token count.
    public var timedOutput: Double?
    public var estimatedOutput: Double?
    public var generationSeconds: Double?

    /// Average reply speed: measured output tokens over the time spent writing them.
    public var tokensPerSecond: Double? {
        guard let timedOutput, let generationSeconds, generationSeconds >= 0.2, timedOutput > 0 else { return nil }
        let rate = timedOutput / generationSeconds
        return rate.isFinite && rate > 0 ? rate : nil
    }
}

public struct BotTask: Codable, Hashable, Sendable {
    public var threadId: String
    public var title: String
    public var createdAt: Double
    /// Desktop fields.
    public var pinned: Bool?
    public var usage: TaskUsage?
    public var cwd: String?
    /// Library documents switched off in this chat.
    public var libraryOff: [String]?
    /// Connector switches that differ from the bot's defaults, id → on.
    public var connectors: [String: Bool]?
    /// Skill switches that differ from the bot's defaults, name → on.
    public var skills: [String: Bool]?
}

/// A connector handed to a bot, and whether new chats start with it on.
public struct BotConnector: Codable, Hashable, Sendable {
    public var id: String
    public var defaultOn: Bool

    public init(id: String, defaultOn: Bool) {
        self.id = id
        self.defaultOn = defaultOn
    }
}

public struct Bot: Codable, Hashable, Identifiable, Sendable {
    public var sharedSource: SharedSource?
    public var id: String
    public var threadId: String
    public var name: String
    public var title: String
    public var description: String
    public var notifications: Bool
    public var color: String
    public var unread: Bool
    public var modelSelection: ModelSelection
    public var createdAt: Double
    public var busy: Bool?
    public var pinned: Bool?
    public var hidden: Bool?
    public var chiefOfStaff: Bool?
    public var autoApprove: Bool?
    /// Desktop: show the folder's git branch under the chat, and fold the
    /// files a turn changed into one badge.
    public var codeMode: Bool?
    /// Absent on existing bots: tool calls remain visible by default.
    public var showToolCalls: Bool?
    public var showsToolCalls: Bool { showToolCalls ?? true }
    public var alwaysAllow: [String]?
    /// Desktop: the connectors this bot may use.
    public var connectors: [BotConnector]?
    /// Desktop: the skills this bot may use.
    public var skills: [BotSkill]?
    public var computer: String?
    /// Which cloud computer backs `computer == "cloud"`. Absent (older
    /// harnesses included) means the hosted Box; "vps" means the user's own
    /// server, which has no interactive desktop to offer a phone.
    public var cloudBackend: String?
    public var speakReplies: Bool?
    public var voice: String?
    public var mascotExpression: String?
    public var tasks: [BotTask]?
    public var messages: [Message]?
    public var activeLeafId: String?
    /// Paged responses only: there is more transcript above what you got.
    public var hasMore: Bool?
    /// Desktop: the labeled sidebar divider this bot sits under.
    public var section: String?
    /// Desktop: working / waiting-on-you / idle / no-signal / dead.
    public var activity: String?
    public var pinnedMessageId: String?
    public var cwd: String?
    /// What each plugin of the engine keeps on this bot (`plugins.<id>`); a plugin's own client reads its part.
    public var plugins: [String: JSONValue]?
    /// Desktop appearance: body shape id (`SwarmeSilhouetteData`); unknown or
    /// absent renders the default.
    public var mascotSilhouette: String?
    /// Desktop appearance: uploaded SVG markup that replaces the mascot.
    public var mascotAvatarSvg: String?
    /// Desktop appearance: a picture of its own, an attachment filename
    /// (`GET /api/attachments/<name>`).
    public var mascotAvatarImage: String?
    /// Desktop appearance: row 0…8 of a 9×8 sprite sheet in
    /// `mascotAvatarImage`. A number, not `Int`, so a stray non-integer
    /// cannot fail the whole bot's decoding; the app validates it.
    public var mascotAvatarSheetRow: Double?
}

public struct GroupResponder: Codable, Hashable, Sendable {
    public var kind: String
    public var botId: String?
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// One plugin's part of `plugins`, for a plugin's own client to read.
    func pluginData(_ id: String) -> [String: JSONValue] {
        if case let .object(data)? = self[id] { return data }
        return [:]
    }
}

public extension JSONValue {
    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

public struct Room: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var threadId: String
    public var name: String
    public var memberIds: [String]
    public var defaultResponder: GroupResponder
    public var bulletin: String
    public var unread: Bool
    public var createdAt: Double
    public var dm: Bool?
    public var busyBotId: String?
    public var messages: [Message]?
    public var hasMore: Bool?
    /// Desktop fields.
    public var cwd: String?
    public var pinnedCwd: String?
    public var pinnedMessageId: String?
    /// What each plugin of the engine keeps on this channel (`plugins.<id>`).
    public var plugins: [String: JSONValue]?
    /// Desktop: Code mode for the whole channel (the Code plugin's flag), as it is for a bot.
    public var codeMode: Bool?
    /// Members from other engines (a mixed channel hosted here).
    public var guests: [RoomGuest]?
    /// Set on a mirror: a mixed channel hosted elsewhere, written only there.
    public var guest: GuestOf?
}

// MARK: - Responses

private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

public struct Fleet: Decodable, Sendable {
    public var bots: [Bot]
    public var groups: [Room]

    private enum CodingKeys: String, CodingKey { case bots, groups }

    public init(bots: [Bot], groups: [Room]) {
        self.bots = bots
        self.groups = groups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bots = try container.decodeIfPresent([Lossy<Bot>].self, forKey: .bots)?.compactMap(\.value) ?? []
        groups = try container.decodeIfPresent([Lossy<Room>].self, forKey: .groups)?.compactMap(\.value) ?? []
    }
}

public struct ThreadPage: Codable, Sendable {
    public var messages: [Message]
    public var hasMore: Bool?
}

public struct SearchHit: Codable, Hashable, Identifiable, Sendable {
    public var threadId: String
    public var messageId: String
    public var at: Double
    public var role: Message.Role
    public var kind: Message.Kind
    public var snippet: String
    public var matchStart: Int
    public var matchLength: Int
    public var botId: String?
    public var groupId: String?
    public var name: String
    public var task: String?
    public var onActivePath: Bool

    public var id: String { "\(threadId):\(messageId)" }
}

public struct TranscriptExport: Sendable {
    public var data: Data
    public var filename: String
    public var contentType: String

    public init(data: Data, filename: String, contentType: String) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }
}

public struct PairedDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Double
    public var lastSeenAt: Double
}

public struct PairResponse: Codable, Sendable {
    public var token: String
    public var device: PairedDevice
    /// What the computer calls itself — worth showing so someone with two
    /// paired machines can tell them apart.
    public var serverName: String
    /// Every address the computer answers on, best first. Stored with the
    /// connection so the app can walk to the next one when the address it
    /// paired on stops resolving. Absent from older sidecars.
    public var hosts: [String]?
}

/// A freshly minted provider viewer. It is deliberately not Codable for
/// persistence: the URL is a short-lived bearer credential and belongs only
/// in memory for the browser session that requested it.
public struct CloudDesktopSession: Decodable, Sendable {
    public let url: URL

    private enum CodingKeys: String, CodingKey { case joinUrl }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .joinUrl)
        guard let parsed = URL(string: raw),
              parsed.scheme?.lowercased() == "https",
              parsed.host != nil
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .joinUrl,
                in: container,
                debugDescription: "Cloud desktop URL must be HTTPS"
            )
        }
        url = parsed
    }
}

public struct ProviderSnapshot: Codable, Hashable, Sendable {
    public var state: String
    public var reason: String?
    public var authenticated: Bool?
    public var version: String?

    public var isAvailable: Bool { state == "available" }
}

public struct ModelOption: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    /// Effort levels this model accepts, when it narrows the engine's list.
    public var effortLevels: [String]?
    /// false: the model runs its own tools and ignores ours (a Hermes profile).
    public var clientTools: Bool?
}

public struct ModelCatalog: Codable, Hashable, Sendable {
    public var `default`: String
    public var options: [ModelOption]
}

public struct InstallHint: Codable, Hashable, Sendable {
    public struct Command: Codable, Hashable, Sendable {
        public var darwin: String?
    }

    public var command: Command?
    public var docsUrl: String?
    public var signInCommand: String?
    public var needsNode: Bool?
}

public struct InstanceCapabilities: Codable, Hashable, Sendable {
    public var images: Bool?
    public var computerMcp: Bool?
    public var agentsMcp: Bool?
    public var localComputerMcp: Bool?
    /// "none", "mcp" or "inline": whether the engine can take connectors.
    public var connectors: String?
    /// Ascending. Absent means the driver cannot set effort at all.
    public var effortLevels: [String]?
}

public struct Instance: Codable, Hashable, Identifiable, Sendable {
    public var instanceId: String
    public var driverKind: String
    public var displayName: String?
    public var snapshot: ProviderSnapshot
    public var models: ModelCatalog
    /// Desktop: what the driver can do, which gates composer controls.
    public var capabilities: InstanceCapabilities?
    /// Desktop: the user's model-picker visibility override.
    public var pickerVisible: Bool?
    /// Desktop: "subscription" or "custom".
    public var access: String?
    public var install: InstallHint?
    /// The configured CLI override, the driver's default binary, and every
    /// copy of that binary on the augmented PATH.
    public var cli: String?
    public var cliDefault: String?
    public var cliCandidates: [String]?
    /// The subscription's session window, once a turn has reported it.
    public var usageLimit: UsageLimit?

    /// The levels a given model accepts: its own list, else the driver's.
    public func effortLevels(for model: String) -> [String] {
        models.options.first { $0.id == model }?.effortLevels ?? capabilities?.effortLevels ?? []
    }

    public var id: String { instanceId }
}

/// A subscription's rolling session window (Claude's five hours), as the
/// last turn on that account reported it.
public struct UsageLimit: Codable, Hashable, Sendable {
    public var window: String
    /// 0…1, past 1 when over the cap.
    public var utilization: Double
    /// Epoch seconds.
    public var resetsAt: Double?

    public init(window: String, utilization: Double, resetsAt: Double?) {
        self.window = window
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }

    /// Past its reset the number no longer says anything.
    public func isCurrent(at now: Date = Date()) -> Bool {
        guard let resetDate else { return true }
        return resetDate > now
    }
}

public struct InstanceList: Codable, Sendable {
    public var instances: [Instance]
}

public struct ConfigFlag: Codable, Hashable, Sendable {
    public var configured: Bool
    public var apiKeyConfigured: Bool?
    public var ready: Bool?
    public var voice: String?
    /// Desktop: `vps.sshAlias`, `localEndpoint.baseUrl`, `composio.mode`.
    public var sshAlias: String?
    public var baseUrl: String?
    public var mode: String?
}

public struct RoomsConfig: Codable, Hashable, Sendable {
    public var turnTimeoutMinutes: Int?
}

public struct Profile: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
}

public struct ConfigStatus: Codable, Sendable {
    public var composio: ConfigFlag?
    public var box: ConfigFlag?
    public var tts: ConfigFlag?
    public var profile: Profile?
    /// Desktop fields.
    public var xai: ConfigFlag?
    public var vps: ConfigFlag?
    public var opencodeGo: ConfigFlag?
    public var localEndpoint: ConfigFlag?
    public var rooms: RoomsConfig?
}

/// The harness's error body. Every non-2xx response carries one.
public struct APIErrorBody: Codable, Sendable {
    public var error: String
}

/// One frame of a bot's computer, as it arrives on the stream.
public struct ScreenFrame: Hashable, Sendable {
    public var png: String
    public var mime: String

    public init(png: String, mime: String) {
        self.png = png
        self.mime = mime
    }

    /// Decoded pixels, or nil if the base64 was not what it claimed to be.
    /// Returning nil rather than throwing keeps the caller a view.
    public var data: Data? { Data(base64Encoded: png) }
}

/// `POST /api/bots` — the harness answers with the bot it made.
public struct CreatedBot: Codable, Sendable {
    public var bot: Bot
}

/// `POST /api/groups` — the harness answers with the room it made.
public struct CreatedRoom: Codable, Sendable {
    public var group: Room
}

struct SearchResponse: Codable, Sendable {
    var hits: [SearchHit]
}

struct MessageResponse: Codable, Sendable {
    var message: Message
}

struct ActiveBranchResponse: Codable, Sendable {
    var activeLeafId: String
}

struct BotResponse: Codable, Sendable {
    var bot: Bot
}
