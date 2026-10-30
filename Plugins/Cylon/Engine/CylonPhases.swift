// The phases of a Cylon task and how they are told apart (docs/plans/2026-10-28-code-mode-t3.md §10).
//
// Cylon's skills hand a task from one to the next: /cylon-spec turns a seed into a ClickUp ticket,
// /cylon-plan interviews and writes `cylon-features/<slug>/plan.md`, /cylon-run carries it out,
// /cylon-review judges it, /cylon-pull opens the pull request. Each ends by naming the next command, and
// leaves its work on disk, so that is what tells a phase is over: a turn that ended is not enough (an
// interview ends a turn at every question).
import Foundation
import HarnessCore

enum CylonPhase: String, CaseIterable {
    case spec, plan, run, review, pull

    var skill: String { "cylon-\(rawValue)" }
    static let tags = ["cylon-spec", "cylon-plan"]
}

enum CylonState: String {
    case pending, running, done, skipped, failed

    /// Over, one way or the other: the next phase may go.
    var resolved: Bool { self == .done || self == .skipped }
}

struct CylonPipeline {
    struct Entry {
        var state: CylonState = .pending
        var botId: String?
        var startedAt: Double?
        var finishedAt: Double?
        /// How many messages the channel had when the phase was sent: what the bot says after is its answer.
        var fromCount: Int?
        var note: String?
    }

    var ticketId: String
    /// The tag the ticket had when it came in: where the flow starts.
    var tag: String
    /// The seed, when /cylon-spec made a new ticket from it.
    var specTicketId: String?
    var title: String?
    var slug: String?
    var prUrl: String?
    var startedAt: Double
    var phases: [CylonPhase: Entry]

    init(ticketId: String, tag: String, title: String?) {
        self.ticketId = ticketId
        self.tag = tag
        self.title = title
        startedAt = nowMillis()
        phases = Dictionary(uniqueKeysWithValues: CylonPhase.allCases.map { ($0, Entry()) })
        // a ticket tagged for planning is already a specification
        if tag == "cylon-plan" { phases[.spec]?.state = .skipped }
    }

    init?(json: JSON?) {
        guard let object = json?.object, let id = object["ticketId"]?.string, let tag = object["tag"]?.string else { return nil }
        ticketId = id
        self.tag = tag
        specTicketId = object["specTicketId"]?.string
        title = object["title"]?.string
        slug = object["slug"]?.string
        prUrl = object["prUrl"]?.string
        startedAt = object["startedAt"]?.double ?? 0
        phases = [:]
        for phase in CylonPhase.allCases {
            let raw = object["phases"]?[phase.rawValue]
            var entry = Entry()
            entry.state = raw?["state"]?.string.flatMap(CylonState.init(rawValue:)) ?? .pending
            entry.botId = raw?["botId"]?.string
            entry.startedAt = raw?["startedAt"]?.double
            entry.finishedAt = raw?["finishedAt"]?.double
            entry.fromCount = raw?["fromCount"]?.int
            entry.note = raw?["note"]?.string
            phases[phase] = entry
        }
    }

    var json: JSON {
        var object = JSONObject([("ticketId", .string(ticketId)), ("tag", .string(tag)), ("startedAt", .number(startedAt))])
        if let specTicketId { object["specTicketId"] = .string(specTicketId) }
        if let title { object["title"] = .string(title) }
        if let slug { object["slug"] = .string(slug) }
        if let prUrl { object["prUrl"] = .string(prUrl) }
        var list = JSONObject()
        for phase in CylonPhase.allCases {
            guard let entry = phases[phase] else { continue }
            var item = JSONObject([("state", .string(entry.state.rawValue))])
            if let botId = entry.botId { item["botId"] = .string(botId) }
            if let at = entry.startedAt { item["startedAt"] = .number(at) }
            if let at = entry.finishedAt { item["finishedAt"] = .number(at) }
            if let count = entry.fromCount { item["fromCount"] = .number(Double(count)) }
            if let note = entry.note { item["note"] = .string(note) }
            list[phase.rawValue] = .object(item)
        }
        object["phases"] = .object(list)
        return .object(object)
    }

    func state(_ phase: CylonPhase) -> CylonState { phases[phase]?.state ?? .pending }

    /// Every phase before this one is over: it may be sent. (A running phase is not the next to send.)
    func earlierResolved(_ phase: CylonPhase) -> Bool {
        CylonPhase.allCases.prefix { $0 != phase }.allSatisfy { state($0).resolved }
    }

    /// The one that comes next: the first not over.
    var next: CylonPhase? { CylonPhase.allCases.first { !state($0).resolved } }

    var running: CylonPhase? { CylonPhase.allCases.first { state($0) == .running } }
}

enum CylonDetect {
    enum Outcome: Equatable {
        /// The phase is over; what it told us on the way.
        case done(ticketId: String? = nil, slug: String? = nil, prUrl: String? = nil)
        case failed(String)
        /// The turn ended and the phase did not: the bot asked something, or has more to do.
        case waiting
    }

    private static func lastMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// The ticket of the next command: `/cylon-plan <id>`, with the ticket's address allowed in its place.
    static func nextTicket(in text: String) -> String? {
        lastMatch(#"/cylon-plan\s+`?(?:https://app\.clickup\.com/t/(?:[A-Za-z0-9_-]+/)?)?([A-Za-z0-9][A-Za-z0-9_-]*)"#, in: text)?[1]
    }

    static func slug(afterCommand command: String, in text: String) -> String? {
        lastMatch("/" + command + #"\s+`?(?:\./)?cylon-features/([A-Za-z0-9][A-Za-z0-9._-]*)"#, in: text)?[1]
    }

    static func pullRequest(in text: String) -> String? {
        lastMatch(#"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+"#, in: text)?[0]
    }

    /// `REVIEW PASSED` / `REVIEW FAILED` on the report's last line, which is where /cylon-review puts it.
    static func verdict(in text: String) -> Bool? {
        guard let last = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        if last.contains("REVIEW PASSED") { return true }
        if last.contains("REVIEW FAILED") { return false }
        return nil
    }

    /// What a phase's answer says about whether it is over. `onDisk` is what the task's folder says (a plan
    /// approved in `plan.md`), which is better evidence than what the bot printed.
    static func outcome(_ phase: CylonPhase, text: String, onDisk: (slug: String, approved: Bool)?) -> Outcome {
        switch phase {
        case .spec:
            guard let ticket = nextTicket(in: text) else { return .waiting }
            return .done(ticketId: ticket)
        case .plan:
            if let onDisk {
                return onDisk.approved ? .done(slug: onDisk.slug) : .waiting
            }
            if let slug = slug(afterCommand: "cylon-run", in: text) { return .done(slug: slug) }
            return .waiting
        case .run:
            if let slug = slug(afterCommand: "cylon-pull", in: text) { return .done(slug: slug) }
            return .waiting
        case .review:
            switch verdict(in: text) {
            case true?: return .done()
            case false?: return .failed("the review failed: fix what it found and run it again")
            case nil: return .waiting
            }
        case .pull:
            if let url = pullRequest(in: text) { return .done(prUrl: url) }
            return .waiting
        }
    }

    // MARK: on disk

    /// The task folder of a ticket: the one already known, else the one whose `.data.json` names the ticket;
    /// and whether its plan is approved.
    static func onDisk(folder: String?, ticketId: String, slug known: String?) -> (slug: String, approved: Bool)? {
        guard let folder else { return nil }
        let root = (folder as NSString).appendingPathComponent("cylon-features")
        let fm = FileManager.default
        func found(_ name: String) -> (slug: String, approved: Bool) {
            (name, planApproved(at: ((root as NSString).appendingPathComponent(name) as NSString).appendingPathComponent("plan.md")))
        }
        if let known, fm.fileExists(atPath: (root as NSString).appendingPathComponent(known)) { return found(known) }
        for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.hasPrefix(".") {
            let data = (((root as NSString).appendingPathComponent(name)) as NSString).appendingPathComponent(".data.json")
            if let contents = fm.contents(atPath: data), let json = try? JSON.parse(contents), json["clickup_task_id"]?.string == ticketId { return found(name) }
        }
        return nil
    }

    /// `status: approved` in the front matter of `plan.md`, which is what /cylon-run checks too.
    static func planApproved(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return planApproved(text: String(decoding: data.prefix(4_000), as: UTF8.self))
    }

    static func planApproved(text: String) -> Bool {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return false }
        return lines[1..<end].contains { $0.trimmingCharacters(in: .whitespaces) == "status: approved" }
    }

    // MARK: what is sent

    /// A ClickUp ticket as the skills take it: its id, or the id at the end of its address.
    static func ticketId(_ input: String) -> String? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("http") {
            guard let url = URL(string: raw), url.host?.hasSuffix("clickup.com") == true else { return nil }
            raw = url.pathComponents.last(where: { $0 != "/" && !$0.isEmpty }) ?? ""
        }
        return raw.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil ? raw : nil
    }

    /// The command of a phase, with its argument: the ticket for the first two, the task's folder after.
    /// Nil when the folder is not known yet.
    static func command(_ phase: CylonPhase, ticketId: String, slug: String?) -> String? {
        switch phase {
        case .spec: return "/cylon-spec \(ticketId)"
        case .plan: return slug.map { "/cylon-plan cylon-features/\($0)" } ?? "/cylon-plan \(ticketId)"
        case .run, .review, .pull: return slug.map { "/\(phase.skill) cylon-features/\($0)" }
        }
    }
}
