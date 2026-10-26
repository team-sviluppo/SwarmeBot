// Routines — `server/routines.ts`, ported.
//
// Persisted definitions (once, daily at HH:MM on chosen weekdays, or every N
// minutes / hours) become detached bot tasks. The manager owns timing and receipts; the harness stays
// the only owner of provider sessions, approvals and messages. Webhook
// deliveries join the same queue (`enqueueWebhook`), so busy-bot ordering,
// task creation and runner choice are identical for every unattended job.
//
// Records are ordered JSON objects written in the Node engine's key order, so
// routines.json and the `routine` / `routine.run` frames read the same.
import Foundation

@MainActor
public final class RoutineManager {
    static let catchUpMillis = 12.0 * 60 * 60_000
    static let maxRuns = 2_000
    static let allDays = [0, 1, 2, 3, 4, 5, 6]
    /// An interval shorter than this would open a chat and spend a turn every few seconds.
    static let minIntervalMinutes = 5
    static let maxIntervalMinutes = 7 * 24 * 60
    /// Stored in the task title, like the untitled "Nuova chat": engine titles are not translated.
    public static let automationTitlePrefix = "[AUTOMAZIONE] "

    public struct Host {
        public var emit: (JSONObject) -> Void
        public var botState: (String) -> String // ready · busy · missing
        public var createTask: (_ botId: String, _ title: String, _ activate: Bool) -> String?
        /// throws what the dispatch refuses synchronously; later failures come back via onDispatchError
        public var startTurn: (_ botId: String, _ threadId: String, _ prompt: String, _ runOn: String, _ trigger: String,
                               _ onDispatchError: @escaping (String) -> Void) throws -> Void
        public var interruptTurn: (_ botId: String, _ threadId: String, _ runOn: String) -> Void
    }

    private let file: URL
    private let host: Host
    /// Why a run more than 12 h late was skipped; the remote engine says "engine", not "computer".
    public var missedReason = "This computer was offline for more than 12 hours after the scheduled time"
    private(set) var routines: [JSONObject] = []
    private(set) var runs: [JSONObject] = []
    private var timer: Task<Void, Never>?
    private var ticking = false

    public init(file: URL, host: Host) {
        self.file = file
        self.host = host
        if let disk = FileIO.readJSON(file) {
            routines = (disk["routines"]?.array ?? []).compactMap(\.object).map { var r = $0; if r["runOn"] == nil { r["runOn"] = "maus" }; return r }
            runs = (disk["runs"]?.array ?? []).compactMap(\.object).map { var r = $0; if r["runOn"] == nil { r["runOn"] = "maus" }; return r }
        }
        // a fresh process cannot still own these turns
        var recovered = false
        for index in runs.indices where ["running", "waiting"].contains(runs[index]["status"]?.string ?? "") {
            runs[index]["status"] = "failed"
            runs[index]["error"] = "SwarmeBot restarted while this routine was running"
            runs[index]["finishedAt"] = .number(nowMillis())
            recovered = true
        }
        if recovered { save() }
    }

    // MARK: Schedules

    static func cleanDays(_ value: JSON?) -> [Int] {
        guard let list = value?.array else { return allDays }
        let days = Array(Set(list.compactMap { $0.double.flatMap { $0.rounded() == $0 && $0 >= 0 && $0 <= 6 ? Int($0) : nil } })).sorted()
        return days.isEmpty ? allDays : days
    }

    struct InputError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func cleanSchedule(_ schedule: JSON?) throws -> JSON {
        switch schedule?["type"]?.string {
        case "once":
            let at = schedule?["at"].flatMap { $0.double ?? $0.string.flatMap(Double.init) }
            guard let at, at.isFinite else { throw InputError(message: "Choose a valid date and time") }
            return ["type": "once", "at": .number(at)]
        case "daily":
            let time = schedule?["time"].flatMap(Harness.text) ?? ""
            guard time.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { throw InputError(message: "Time must use HH:MM") }
            var daily: JSONObject = ["type": "daily", "time": .string(time), "weekdays": .array(cleanDays(schedule?["weekdays"]).map { .number(Double($0)) })]
            // the client's zone: a server's clock is often UTC (bot-remoto §8.1)
            if let zone = schedule?["timeZone"]?.string, !zone.isEmpty {
                guard TimeZone(identifier: zone) != nil else { throw InputError(message: "Unknown time zone \(zone)") }
                daily["timeZone"] = .string(zone)
            }
            return .object(daily)
        case "interval":
            let unit = schedule?["unit"]?.string ?? "minutes"
            guard ["minutes", "hours", "days"].contains(unit) else { throw InputError(message: "Interval unit must be minutes, hours or days") }
            guard let every = schedule?["every"]?.double, every.isFinite, every.rounded() == every, every >= 1,
                  let minutes = intervalMinutes(every: Int(every), unit: unit),
                  (minIntervalMinutes...maxIntervalMinutes).contains(minutes) else {
                throw InputError(message: "The interval must be a whole number, from \(minIntervalMinutes) minutes to 7 days")
            }
            return ["type": "interval", "every": .number(every), "unit": .string(unit)]
        default:
            throw InputError(message: "Choose a supported schedule")
        }
    }

    /// The period of an interval schedule in minutes; nil when it is not a valid one.
    static func intervalMinutes(every: Int, unit: String) -> Int? {
        switch unit {
        case "minutes": return every
        case "hours": return every.multipliedReportingOverflow(by: 60).overflow ? nil : every * 60
        case "days": return every.multipliedReportingOverflow(by: 24 * 60).overflow ? nil : every * 24 * 60
        default: return nil
        }
    }

    static func intervalMillis(_ schedule: JSON) -> Double? {
        guard let every = schedule["every"]?.double, every >= 1, every <= Double(Int.max / 120),
              let minutes = intervalMinutes(every: Int(every), unit: schedule["unit"]?.string ?? "minutes") else { return nil }
        return Double(minutes) * 60_000
    }

    /// Next wall-clock occurrence, strictly after `after`: in the schedule's
    /// `timeZone` when it has one, else in this computer's.
    public static func nextOccurrence(_ schedule: JSON, after: Double, calendar base: Calendar = .current) -> Double? {
        if schedule["type"]?.string == "once" {
            let at = schedule["at"]?.double ?? 0
            return at > after ? at : nil
        }
        if schedule["type"]?.string == "interval" {
            return intervalMillis(schedule).map { after + $0 }
        }
        var calendar = base
        if let zone = schedule["timeZone"]?.string.flatMap(TimeZone.init(identifier:)) { calendar.timeZone = zone }
        let parts = (schedule["time"]?.string ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let weekdays = Set(cleanDays(schedule["weekdays"]))
        let start = Date(timeIntervalSince1970: after / 1000)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let at = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) else { continue }
            let millis = (at.timeIntervalSince1970 * 1000).rounded()
            // JS getDay(): 0 = Sunday, as Calendar's weekday 1
            if millis > after, weekdays.contains(calendar.component(.weekday, from: at) - 1) { return millis }
        }
        return nil
    }

    func sanitize(_ input: JSONObject) throws -> JSONObject {
        let name = String((input["name"].flatMap(Harness.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let prompt = String((input["prompt"].flatMap(Harness.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(20_000))
        let botId = (input["botId"].flatMap(Harness.text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw InputError(message: "Give the routine a name") }
        if prompt.isEmpty { throw InputError(message: "Tell the bot what to do") }
        if botId.isEmpty { throw InputError(message: "Choose a bot") }
        let runOn = input["runOn"]?.string ?? "maus"
        guard runOn == "maus" || runOn == "cloud" else { throw InputError(message: "Choose where this routine runs") }
        let minutes = (input["durationMinutes"]?.double).flatMap { $0.isFinite && $0 != 0 ? $0 : nil } ?? 30
        return JSONObject([
            ("name", .string(name)), ("prompt", .string(prompt)), ("botId", .string(botId)), ("runOn", .string(runOn)),
            ("enabled", .bool(input["enabled"]?.bool != false)), ("schedule", try Self.cleanSchedule(input["schedule"])),
            ("durationMinutes", .number(min(240, max(15, minutes.rounded(.toNearestOrAwayFromZero))))),
        ])
    }

    func initialOccurrence(_ schedule: JSON, now: Double) -> JSON {
        if schedule["type"]?.string == "once" { return .number(max(schedule["at"]?.double ?? 0, now)) }
        return .from(Self.nextOccurrence(schedule, after: now))
    }

    // MARK: Lists and edits

    public func listRuns(from: Double?, to: Double?) -> [JSONObject] {
        runs.filter { run in
            let at = run["scheduledFor"]?.double ?? 0
            return (from.map { at >= $0 } ?? true) && (to.map { at <= $0 } ?? true)
        }.enumerated().sorted { ($1.element["scheduledFor"]?.double ?? 0, $0.offset) < ($0.element["scheduledFor"]?.double ?? 0, $1.offset) }.map(\.element)
    }

    static let live: Set<String> = ["running", "waiting"]
    static let unfinished: Set<String> = ["queued", "running", "waiting"]

    public func activeRun(forBot botId: String) -> JSONObject? {
        runs.first { $0["botId"]?.string == botId && Self.live.contains($0["status"]?.string ?? "") }
    }

    public func isActiveThread(_ threadId: String) -> Bool {
        runs.contains { $0["threadId"]?.string == threadId && Self.live.contains($0["status"]?.string ?? "") }
    }

    public func create(_ input: JSONObject) throws -> JSONObject {
        let clean = try sanitize(input)
        if host.botState(clean["botId"]?.string ?? "") == "missing" { throw InputError(message: "That bot no longer exists") }
        let at = nowMillis()
        var routine = JSONObject([("id", .string(newId()))]).merging(clean)
        routine["nextRunAt"] = clean["enabled"]?.bool == true ? initialOccurrence(clean["schedule"]!, now: at) : .null
        routine["createdAt"] = .number(at)
        routine["updatedAt"] = .number(at)
        routines.insert(routine, at: 0)
        save()
        emitRoutine(routine)
        return routine
    }

    public func update(_ id: String, _ patch: JSONObject) throws -> JSONObject? {
        guard let index = routines.firstIndex(where: { $0["id"]?.string == id }) else { return nil }
        var merged = JSONObject()
        for key in ["name", "prompt", "botId", "runOn", "enabled", "schedule", "durationMinutes"] {
            let value = patch[key].flatMap { $0.isNull ? nil : $0 } ?? routines[index][key]
            if let value { merged[key] = value }
        }
        let clean = try sanitize(merged)
        if host.botState(clean["botId"]?.string ?? "") == "missing" { throw InputError(message: "That bot no longer exists") }
        for (key, value) in clean { routines[index][key] = value }
        routines[index]["nextRunAt"] = clean["enabled"]?.bool == true ? initialOccurrence(clean["schedule"]!, now: nowMillis()) : .null
        routines[index]["updatedAt"] = .number(nowMillis())
        if patch["enabled"]?.bool == false {
            for run in runs.indices where runs[run]["routineId"]?.string == id && runs[run]["status"]?.string == "queued" {
                runs[run]["status"] = "cancelled"
                runs[run]["finishedAt"] = .number(nowMillis())
                runs[run]["error"] = "The routine was paused before this run started"
                emitRun(runs[run])
            }
        }
        save()
        emitRoutine(routines[index])
        return routines[index]
    }

    public func remove(_ id: String) -> Bool {
        guard let index = routines.firstIndex(where: { $0["id"]?.string == id }) else { return false }
        routines.remove(at: index)
        for run in runs.indices where runs[run]["routineId"]?.string == id && runs[run]["status"]?.string == "queued" {
            runs[run]["status"] = "cancelled"
            runs[run]["finishedAt"] = .number(nowMillis())
            emitRun(runs[run])
        }
        save()
        host.emit(["kind": "routine.deleted", "routineId": .string(id)])
        return true
    }

    public func disableForBot(_ botId: String) {
        var changed = false
        for index in routines.indices where routines[index]["botId"]?.string == botId && routines[index]["enabled"]?.bool == true {
            routines[index]["enabled"] = false
            routines[index]["nextRunAt"] = .null
            routines[index]["updatedAt"] = .number(nowMillis())
            emitRoutine(routines[index])
            changed = true
        }
        for index in runs.indices where runs[index]["botId"]?.string == botId && Self.unfinished.contains(runs[index]["status"]?.string ?? "") {
            runs[index]["status"] = "cancelled"
            runs[index]["finishedAt"] = .number(nowMillis())
            runs[index]["error"] = "The assigned bot was deleted"
            emitRun(runs[index])
            if let thread = runs[index]["threadId"]?.string { host.interruptTurn(botId, thread, runs[index]["runOn"]?.string ?? "maus") }
            changed = true
        }
        if changed { save() }
    }

    public func runNow(_ id: String) -> JSONObject? {
        guard let routine = routines.first(where: { $0["id"]?.string == id }) else { return nil }
        let run = newRun(routine, scheduledFor: nowMillis(), manual: true)
        save()
        emitRun(run)
        scheduleTick()
        return run
    }

    /// A webhook delivery as a queued run: same queue, same receipts.
    public func enqueueWebhook(webhookId: String, webhookName: String, prompt: String, botId: String, runOn: String,
                               deliveryId: String, receivedAt: Double) throws -> JSONObject {
        if host.botState(botId) == "missing" { throw HTTPError(410, "The assigned SWARMEno longer exists") }
        let run = JSONObject([
            ("id", .string(newId())), ("routineId", .string(webhookId)), ("routineName", .string(webhookName)), ("prompt", .string(prompt)),
            ("botId", .string(botId)), ("runOn", .string(runOn)), ("scheduledFor", .number(receivedAt)), ("status", "queued"),
            ("manual", false), ("triggerSource", "webhook"), ("webhookId", .string(webhookId)), ("deliveryId", .string(deliveryId)),
            ("createdAt", .number(nowMillis())),
        ])
        appendRun(run)
        save()
        emitRun(run)
        scheduleTick()
        return run
    }

    public func activeWebhookRunCount(_ webhookId: String) -> Int {
        runs.filter { $0["webhookId"]?.string == webhookId && Self.unfinished.contains($0["status"]?.string ?? "") }.count
    }

    public func cancelQueuedWebhook(_ webhookId: String, message: String) {
        var changed = false
        for index in runs.indices where runs[index]["webhookId"]?.string == webhookId && runs[index]["status"]?.string == "queued" {
            runs[index]["status"] = "cancelled"
            runs[index]["finishedAt"] = .number(nowMillis())
            runs[index]["error"] = .string(String(message.prefix(500)))
            emitRun(runs[index])
            changed = true
        }
        if changed { save() }
    }

    public func cancelRun(_ id: String) -> JSONObject? {
        guard let index = runs.firstIndex(where: { $0["id"]?.string == id }), Self.unfinished.contains(runs[index]["status"]?.string ?? "") else { return nil }
        runs[index]["status"] = "cancelled"
        runs[index]["finishedAt"] = .number(nowMillis())
        save()
        emitRun(runs[index])
        let run = runs[index]
        if let thread = run["threadId"]?.string { host.interruptTurn(run["botId"]?.string ?? "", thread, run["runOn"]?.string ?? "maus") }
        scheduleTick()
        return run
    }

    public func markSeen(_ id: String) -> JSONObject? {
        guard let index = runs.firstIndex(where: { $0["id"]?.string == id }) else { return nil }
        if runs[index]["seenAt"]?.truthy != true {
            runs[index]["seenAt"] = .number(nowMillis())
            save()
            emitRun(runs[index])
        }
        return runs[index]
    }

    // MARK: The clock

    public func start() {
        guard timer == nil else { return }
        tick()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.tick()
            }
        }
    }

    /// Node's queueMicrotask: after the current call, never inside it.
    func scheduleTick() {
        Task { @MainActor [weak self] in self?.tick() }
    }

    func tick() {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let now = nowMillis()
        var changed = false
        for index in routines.indices {
            let routine = routines[index]
            guard routine["enabled"]?.bool == true, let scheduledFor = routine["nextRunAt"]?.double, scheduledFor <= now else { continue }
            if routine["schedule"]?["type"]?.string == "interval", hasUnfinishedRun(routine["id"]?.string) {
                // the previous run is still going: do not pile runs up behind a slow one
            } else if now - scheduledFor > Self.catchUpMillis {
                var missed = newRun(routine, scheduledFor: scheduledFor, manual: false)
                missed["status"] = "missed"
                missed["finishedAt"] = .number(now)
                missed["error"] = .string(missedReason)
                replaceRun(missed)
                emitRun(missed)
            } else {
                emitRun(newRun(routine, scheduledFor: scheduledFor, manual: false))
            }
            let once = routine["schedule"]?["type"]?.string == "once"
            routines[index]["nextRunAt"] = once ? .null : .from(nextRun(after: routine["schedule"]!, scheduledFor: scheduledFor, now: now))
            if once { routines[index]["enabled"] = false }
            routines[index]["updatedAt"] = .number(now)
            emitRoutine(routines[index])
            changed = true
        }
        if changed { save() }

        for runId in runs.reversed().compactMap({ $0["status"]?.string == "queued" ? $0["id"]?.string : nil }) {
            guard let index = runs.firstIndex(where: { $0["id"]?.string == runId }), runs[index]["status"]?.string == "queued" else { continue }
            let botId = runs[index]["botId"]?.string ?? ""
            let state = host.botState(botId)
            if state == "busy" { continue }
            if state == "missing" {
                fail(index, "The assigned bot no longer exists")
                continue
            }
            // every run opens its own chat and makes it the bot's live one, so its
            // result is what the user sees on opening the bot; the title says it is unattended
            let title = Self.automationTitlePrefix + (runs[index]["routineName"]?.string ?? "")
            guard let threadId = host.createTask(botId, title, true) else {
                fail(index, "Could not create a task for this run")
                continue
            }
            runs[index]["threadId"] = .string(threadId)
            runs[index]["startedAt"] = .number(nowMillis())
            runs[index]["status"] = "running"
            save()
            emitRun(runs[index])
            let run = runs[index]
            guard let prompt = run["prompt"]?.string ?? routines.first(where: { $0["id"] == run["routineId"] })?["prompt"]?.string else {
                failThread(threadId, "The routine was deleted before it could start")
                continue
            }
            let trigger = run["triggerSource"]?.string ?? (run["manual"]?.bool == true ? "manual" : "schedule")
            do {
                try host.startTurn(botId, threadId, prompt, run["runOn"]?.string ?? "maus", trigger) { [weak self] message in
                    self?.failThread(threadId, message)
                }
            } catch {
                failThread(threadId, (error as? Harness.TurnError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// An interval keeps its grid (`scheduledFor` + k periods) so ticks do not drift, and
    /// never lands in the past after downtime; the other schedules count from now.
    private func nextRun(after schedule: JSON, scheduledFor: Double, now: Double) -> Double? {
        guard schedule["type"]?.string == "interval" else { return Self.nextOccurrence(schedule, after: max(now, scheduledFor)) }
        guard let period = Self.intervalMillis(schedule) else { return nil }
        return scheduledFor + period * (((now - scheduledFor) / period).rounded(.down) + 1)
    }

    private func hasUnfinishedRun(_ routineId: String?) -> Bool {
        runs.contains { $0["routineId"]?.string == routineId && Self.unfinished.contains($0["status"]?.string ?? "") }
    }

    private func fail(_ index: Int, _ message: String) {
        runs[index]["status"] = "failed"
        runs[index]["error"] = .string(message)
        runs[index]["finishedAt"] = .number(nowMillis())
        save()
        emitRun(runs[index])
    }

    /// Called from the fold, before it folds: the receipt follows its turn.
    public func handleRuntimeEvent(_ event: RuntimeEvent) {
        guard let index = runs.firstIndex(where: { $0["threadId"]?.string == event.threadId && Self.live.contains($0["status"]?.string ?? "") }) else { return }
        var completed = false
        switch event.body {
        case .requestOpened: runs[index]["status"] = "waiting"
        case .requestResolved: runs[index]["status"] = "running"
        case let .textCompleted(text): runs[index]["output"] = .string(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)))
        case let .runtimeError(message, _): runs[index]["error"] = .string(String(message.prefix(500)))
        case let .turnCompleted(ok, stopReason, cost, denials, _):
            runs[index]["status"] = .string(ok ? "completed" : "failed")
            runs[index]["finishedAt"] = .number(nowMillis())
            runs[index]["error"] = ok ? Optional<JSON>.none
                : .string(stopReason ?? runs[index]["error"]?.string ?? "The bot did not complete this run")
            runs[index]["cost"] = event.costAbsent ? Optional<JSON>.none : .from(cost)
            runs[index]["denials"] = denials.map(JSON.strings)
            completed = true
        default:
            return
        }
        save()
        emitRun(runs[index])
        if completed { scheduleTick() }
    }

    public func failThread(_ threadId: String, _ message: String) {
        guard let index = runs.firstIndex(where: { $0["threadId"]?.string == threadId && Self.live.contains($0["status"]?.string ?? "") }) else { return }
        fail(index, String(message.prefix(500)))
        scheduleTick()
    }

    // MARK: Records

    @discardableResult
    private func newRun(_ routine: JSONObject, scheduledFor: Double, manual: Bool) -> JSONObject {
        let run = JSONObject([
            ("id", .string(newId())), ("routineId", routine["id"] ?? .null), ("routineName", routine["name"] ?? .null),
            ("prompt", routine["prompt"] ?? .null), ("durationMinutes", routine["durationMinutes"] ?? .null), ("botId", routine["botId"] ?? .null),
            ("runOn", routine["runOn"] ?? "maus"), ("scheduledFor", .number(scheduledFor)), ("status", "queued"), ("manual", .bool(manual)),
            ("triggerSource", .string(manual ? "manual" : "schedule")), ("createdAt", .number(nowMillis())),
        ])
        appendRun(run)
        return run
    }

    private func appendRun(_ run: JSONObject) {
        runs.append(run)
        if runs.count > Self.maxRuns { runs.removeFirst(runs.count - Self.maxRuns) }
    }

    private func replaceRun(_ run: JSONObject) {
        if let index = runs.firstIndex(where: { $0["id"] == run["id"] }) { runs[index] = run }
    }

    private func emitRoutine(_ routine: JSONObject) { host.emit(["kind": "routine", "routine": .object(routine)]) }
    private func emitRun(_ run: JSONObject) { host.emit(["kind": "routine.run", "run": .object(run)]) }

    private func save() {
        let disk: JSON = ["version": 1, "routines": .array(routines.map(JSON.object)), "runs": .array(runs.map(JSON.object))]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileIO.writeAtomic(Data(disk.pretty().utf8), to: file, mode: 0o644)
    }
}
