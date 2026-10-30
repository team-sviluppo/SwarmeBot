// Routines, webhooks, the Local VM and the rest of what only the desktop
// manages. Shapes from `server/routines.ts`, `server/webhooks.ts` and
// `server/container-computer.ts`; see docs/contract/http-sse.md §2.7–2.11.
//
// Same tolerance rule as Models.swift: optional unless the server always
// sends it, so a new field never breaks a decode.
import Foundation

// MARK: - Routines

public struct RoutineSchedule: Codable, Hashable, Sendable {
    /// "once", "daily" or "interval".
    public var type: String
    /// once: epoch ms.
    public var at: Double?
    /// daily: "HH:MM", local time.
    public var time: String?
    /// daily: 0 = Sunday … 6 = Saturday, like JavaScript's getDay().
    public var weekdays: [Int]?
    /// interval: how many `unit`s between runs.
    public var every: Int?
    /// interval: "minutes", "hours" or "days".
    public var unit: String?

    public init(type: String, at: Double? = nil, time: String? = nil, weekdays: [Int]? = nil, every: Int? = nil, unit: String? = nil) {
        self.type = type
        self.at = at
        self.time = time
        self.weekdays = weekdays
        self.every = every
        self.unit = unit
    }

    public static func once(_ date: Date) -> RoutineSchedule {
        RoutineSchedule(type: "once", at: date.timeIntervalSince1970 * 1000)
    }

    public static func daily(_ time: String, weekdays: [Int]) -> RoutineSchedule {
        RoutineSchedule(type: "daily", time: time, weekdays: weekdays)
    }

    public static func interval(every: Int, unit: String) -> RoutineSchedule {
        RoutineSchedule(type: "interval", every: every, unit: unit)
    }

    var json: [String: Any] {
        var out: [String: Any] = ["type": type]
        if let at { out["at"] = at }
        if let time { out["time"] = time }
        if let weekdays { out["weekdays"] = weekdays }
        if let every { out["every"] = every }
        if let unit { out["unit"] = unit }
        return out
    }
}

public struct Routine: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String
    public var botId: String
    /// "maus" (this Mac) or "cloud".
    public var runOn: String?
    public var enabled: Bool
    public var schedule: RoutineSchedule
    public var durationMinutes: Int?
    public var nextRunAt: Double?
    public var createdAt: Double?
    public var updatedAt: Double?
}

public struct RoutineRun: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var routineId: String?
    public var routineName: String?
    public var botId: String
    public var scheduledFor: Double?
    /// queued · running · waiting · completed · failed · cancelled · missed
    public var status: String
    public var manual: Bool?
    public var triggerSource: String?
    public var webhookId: String?
    public var threadId: String?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var output: String?
    public var error: String?
    public var cost: Double?
    public var createdAt: Double?
    public var seenAt: Double?

    public var isActive: Bool { ["queued", "running", "waiting"].contains(status) }
}

/// What `POST/PATCH /api/routines` take.
public struct RoutineInput: Sendable {
    public var name: String
    public var prompt: String
    public var botId: String
    public var enabled: Bool
    public var schedule: RoutineSchedule
    public var durationMinutes: Int?
    /// "maus" (the engine itself) or "cloud".
    public var runOn = "maus"

    public init(name: String, prompt: String, botId: String, enabled: Bool, schedule: RoutineSchedule, durationMinutes: Int? = nil) {
        self.name = name
        self.prompt = prompt
        self.botId = botId
        self.enabled = enabled
        self.schedule = schedule
        self.durationMinutes = durationMinutes
    }

    public static func interval(every: Int, unit: String) -> RoutineSchedule {
        RoutineSchedule(type: "interval", every: every, unit: unit)
    }

    var json: [String: Any] {
        var out: [String: Any] = [
            "name": name, "prompt": prompt, "botId": botId, "enabled": enabled,
            "runOn": runOn, "schedule": schedule.json,
        ]
        if let durationMinutes { out["durationMinutes"] = durationMinutes }
        return out
    }
}

public struct RoutineList: Codable, Sendable {
    public var routines: [Routine]
    public var runs: [RoutineRun]
}

// MARK: - Webhooks

public struct WebhookSample: Codable, Hashable, Sendable {
    public var receivedAt: Double?
    public var eventName: String?
    public var contentType: String?
    public var preview: String?
}

public struct WebhookTrigger: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var endpointId: String
    public var name: String
    public var prompt: String
    public var botId: String
    public var runOn: String?
    public var enabled: Bool
    public var createdAt: Double?
    public var updatedAt: Double?
    public var lastReceivedAt: Double?
    public var lastRunId: String?
    public var deliveryCount: Int?
    public var verificationPending: Bool?
    public var verifiedAt: Double?
    public var verificationSample: WebhookSample?
    public var eventTypes: [String]?
}

public struct WebhookAttempt: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var webhookId: String
    public var receivedAt: Double
    /// accepted · captured · duplicate · ignored · rejected
    public var outcome: String
    public var statusCode: Int?
    public var eventName: String?
    public var preview: String?
    public var runId: String?
    public var reason: String?
}

public struct WebhookIngress: Codable, Hashable, Sendable {
    public var available: Bool
    public var baseUrl: String?
    public var error: String?
}

public struct WebhookList: Codable, Sendable {
    public var webhooks: [WebhookTrigger]
    public var attempts: [WebhookAttempt]
    public var ingress: WebhookIngress?
}

/// The private URL and secret. Shown once, on create and rotate.
public struct WebhookCredential: Codable, Hashable, Sendable {
    public var endpointUrl: String?
    public var secret: String?
    public var url: String?
}

public struct WebhookCreated: Codable, Sendable {
    public var webhook: WebhookTrigger
    public var credential: WebhookCredential?
}

public struct WebhookInput: Sendable {
    public var name: String
    public var prompt: String
    public var botId: String
    public var enabled: Bool
    public var eventTypes: [String]
    /// "maus" (the engine itself) or "cloud".
    public var runOn = "maus"
    /// Disabled while it captures a first delivery to look at.
    public var verificationPending: Bool?

    public init(name: String, prompt: String, botId: String, enabled: Bool, eventTypes: [String] = []) {
        self.name = name
        self.prompt = prompt
        self.botId = botId
        self.enabled = enabled
        self.eventTypes = eventTypes
    }

    public static func interval(every: Int, unit: String) -> RoutineSchedule {
        RoutineSchedule(type: "interval", every: every, unit: unit)
    }

    var json: [String: Any] {
        var out: [String: Any] = ["name": name, "prompt": prompt, "botId": botId, "enabled": enabled, "runOn": runOn, "eventTypes": eventTypes]
        if let verificationPending { out["verificationPending"] = verificationPending }
        return out
    }
}

// MARK: - Computers

/// `GET /api/local-computer`. Only the fields the panel shows are named;
/// the rest of a large status object is ignored.
public struct LocalComputerStatus: Codable, Hashable, Sendable {
    public var runtime: String?
    public var available: [String]?
    public var daemonUp: Bool?
    public var imageMatches: Bool?
    /// running · stopped · missing
    public var container: String?
    public var desktopReady: Bool?
    public var ready: Bool?
    public var problem: String?
    public var workspace_path: String?
}

public struct BoxState: Codable, Hashable, Sendable {
    public var boxId: String?
    public var state: String?
    public var desktopAvailable: Bool?
}

/// `GET /api/bots/:id/computer`: Box or VPS, told apart by `backend`.
public struct CloudComputerStatus: Codable, Hashable, Sendable {
    public var backend: String
    public var configured: Bool?
    public var box: BoxState?
    public var state: String?
    public var sshAlias: String?
}

public struct ComputerControl: Codable, Hashable, Sendable {
    public var held: Bool
    public var helpReason: String?
}

// MARK: - Library, inspector, teams

/// A document loaded on a bot (`GET /api/bots/:id/library`).
public struct LibraryDoc: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// "pdf" or "text".
    public var kind: String
    public var bytes: Int
    public var pages: Int
    public var chars: Int
    /// An estimate, about 3.5 characters a token.
    public var tokens: Int
    public var ocrPages: Int
    /// processing, ready, failed.
    public var status: String
    public var error: String?
    public var createdAt: Double
}

/// One line of the thread inspector: a normalized runtime event or a raw
/// provider message. `data` stays as JSON text — it is shown, not used.
public struct InspectorEntry: Decodable, Identifiable, Sendable {
    public var kind: String
    public var at: Double?
    public var json: String
    public var type: String?
    public var id: String { "\(kind)-\(at ?? 0)-\(json.hashValue)" }

    private enum CodingKeys: String, CodingKey { case kind, at, data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        if let number = try? container.decode(Double.self, forKey: .at) {
            at = number
        } else if let text = try? container.decode(String.self, forKey: .at) {
            at = ISO8601DateFormatter().date(from: text).map { $0.timeIntervalSince1970 * 1000 }
        }
        let value = try container.decode(JSONValue.self, forKey: .data)
        json = value.pretty
        if case let .object(fields) = value, case let .string(name)? = fields["type"] { type = name }
    }
}

public struct InspectorPage: Decodable, Sendable {
    public var entries: [InspectorEntry]
}

public struct TeamCatalogEntry: Codable, Hashable, Identifiable, Sendable {
    public var slug: String
    public var name: String
    public var summary: String?
    public var category: String?
    public var members: [TeamCatalogMember]?
    public var id: String { slug }
}

public struct TeamCatalogMember: Codable, Hashable, Sendable {
    public var name: String?
    public var title: String?
}

public struct TeamCatalog: Codable, Sendable {
    public var teams: [TeamCatalogEntry]
}

public struct DecisionRecord: Codable, Hashable, Sendable {
    public var at: Double
    public var botName: String?
    public var tool: String?
    public var summary: String?
    public var decision: String
    public var rule: String?
}

public struct DecisionList: Codable, Sendable {
    public var decisions: [DecisionRecord]
}

// MARK: - Arbitrary JSON

/// Any JSON value, for payloads this client passes through or displays
/// without understanding: team manifests, inspector entries.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

// JSONSerialization takes Foundation values; keep the public data itself typed and Sendable.
extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(value): return value.map(\.foundationValue)
        case let .object(value): return value.mapValues(\.foundationValue)
        }
    }
}
