@testable import HarnessCore
import XCTest

@MainActor
final class RoutineScheduleTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    func millis(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Double {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.timeIntervalSince1970 * 1000
    }

    func testDailyPicksTheNextAllowedWeekdayStrictlyAfter() {
        // Wednesday 2026-10-14 08:00; weekdays Mon(1) and Fri(5)
        let schedule: JSON = ["type": "daily", "time": "07:30", "weekdays": [1, 5]]
        XCTAssertEqual(RoutineManager.nextOccurrence(schedule, after: millis(2026, 10, 14, 8, 0), calendar: calendar), millis(2026, 10, 16, 7, 30))
        // exactly at the time is not "after"
        let atTime = millis(2026, 10, 16, 7, 30)
        XCTAssertEqual(RoutineManager.nextOccurrence(schedule, after: atTime, calendar: calendar), millis(2026, 10, 19, 7, 30))
    }

    func testIntervalCountsFromTheReferenceInstant() {
        let schedule: JSON = ["type": "interval", "every": 90, "unit": "minutes"]
        XCTAssertEqual(RoutineManager.nextOccurrence(schedule, after: 1_000), 1_000 + 90 * 60_000)
        XCTAssertEqual(RoutineManager.nextOccurrence(["type": "interval", "every": 2, "unit": "hours"], after: 0), 2 * 3_600_000)
    }

    func testIntervalValidation() throws {
        XCTAssertEqual(try RoutineManager.cleanSchedule(["type": "interval", "every": 15, "unit": "minutes"]),
                       ["type": "interval", "every": 15, "unit": "minutes"])
        XCTAssertEqual(try RoutineManager.cleanSchedule(["type": "interval", "every": 30])["unit"]?.string, "minutes", "unit defaults to minutes")
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "interval", "every": 4, "unit": "minutes"]))
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "interval", "every": 169, "unit": "hours"]))
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "interval", "every": 1.5, "unit": "hours"]))
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "interval", "every": 0, "unit": "hours"]))
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "interval", "every": 10, "unit": "days"]))
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "interval"]))
        XCTAssertNoThrow(try RoutineManager.cleanSchedule(["type": "interval", "every": 168, "unit": "hours"]))
    }

    func testOnceAndDaysCleaning() {
        XCTAssertNil(RoutineManager.nextOccurrence(["type": "once", "at": 10], after: 10))
        XCTAssertEqual(RoutineManager.nextOccurrence(["type": "once", "at": 11], after: 10), 11)
        XCTAssertEqual(RoutineManager.cleanDays([5, 1, 1, 9, 2.5]), [1, 5])
        XCTAssertEqual(RoutineManager.cleanDays([9]), RoutineManager.allDays)
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "daily", "time": "7:30"]))
        XCTAssertThrowsError(try RoutineManager.cleanSchedule(["type": "weekly"]))
    }
}

@MainActor
final class WebhookTests: XCTestCase {
    func testSecretsAreComparedByDigest() {
        let hash = WebhookManager.hash("whsec_abc")
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(WebhookManager.secretMatches("whsec_abc", hash))
        XCTAssertFalse(WebhookManager.secretMatches("whsec_abd", hash))
        XCTAssertFalse(WebhookManager.secretMatches("", hash))
    }

    func testPayloadIsCappedAndPreviewedOnOneLine() {
        let long = JSON.string(String(repeating: "a", count: 50_000))
        XCTAssertTrue(WebhookManager.serialize(long).hasSuffix("\n\n[Payload truncated by SwarmeBot]"))
        XCTAssertEqual(WebhookManager.preview(["a": [1, 2]]), "{ \"a\": [ 1, 2 ] }")
        XCTAssertEqual(WebhookManager.task(from: ["task": "  fai  "]), "fai")
        XCTAssertEqual(WebhookManager.task(from: ["task": 3, "message": "x"]), "", "a non-string task invalidates the whole object, as zod")
    }

    func testPromptPutsThePayloadBehindTheUntrustedBoundary() {
        let prompt = WebhookManager.prompt(["prompt": ""], .init(payload: ["task": "fai il punto"], eventName: "push"), receivedAt: 0, deliveryId: "d-1")
        XCTAssertTrue(prompt.hasPrefix("[AUTHENTICATED WEBHOOK TASK]\nfai il punto\n"))
        XCTAssertTrue(prompt.contains("[UNTRUSTED WEBHOOK EVENT DATA]\nReceived: 1970-01-01T00:00:00.000Z\nDelivery ID: d-1\nEvent: push\n"))
    }

    func testCredentialAndFormBodies() {
        let credential = WebhookIngress.credential(baseUrl: "http://127.0.0.1:8800/", endpointId: "wh_x", secret: "a b")
        XCTAssertEqual(credential["url"]?.string, "http://127.0.0.1:8800/hooks/wh_x/a%20b")
        XCTAssertEqual(WebhookIngress.form("a=1&b=x+y&a=2")["a"]?.string, "2")
        XCTAssertEqual(WebhookIngress.form("b=x+y%21")["b"]?.string, "x y!")
    }
}

@MainActor
final class RoutineRunChatTests: XCTestCase {
    func testEveryRunOpensAnAutomationChatAndMakesItLive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var created: [(title: String, activate: Bool)] = []
        let manager = RoutineManager(file: dir.appendingPathComponent("routines.json"), host: .init(
            emit: { _ in },
            botState: { _ in "ready" },
            createTask: { _, title, activate in created.append((title, activate)); return "thread-\(created.count)" },
            startTurn: { _, _, _, _, _, _ in },
            interruptTurn: { _, _, _ in }
        ))
        let routine = try manager.create(["name": "Report", "prompt": "Write it", "botId": "bot",
                                          "schedule": ["type": "once", "at": .number(nowMillis() + 3_600_000)]])
        _ = manager.runNow(routine["id"]!.string!)
        manager.tick()
        _ = try manager.enqueueWebhook(webhookId: "w", webhookName: "Inbox", prompt: "Read it", botId: "bot2",
                                       runOn: "maus", deliveryId: "d", receivedAt: nowMillis())
        manager.tick()
        XCTAssertEqual(created.map(\.title), ["[AUTOMAZIONE] Report", "[AUTOMAZIONE] Inbox"])
        XCTAssertEqual(created.map(\.activate), [true, true])
    }
}

@MainActor
final class IntervalRoutineTickTests: XCTestCase {
    /// A manager over a routines.json whose only routine is due `lateMillis` ago.
    private func manager(lateMillis: Double, every: Int, existingRun: String? = nil, in dir: URL) throws -> RoutineManager {
        let due = nowMillis() - lateMillis
        let runs = existingRun.map { """
            {"id":"r0","routineId":"rt","routineName":"Poll","botId":"bot","runOn":"maus","scheduledFor":\(due - 1),"status":"\($0)","manual":false}
            """ } ?? ""
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"version":1,"routines":[{"id":"rt","name":"Poll","prompt":"Check","botId":"bot","runOn":"maus","enabled":true,
        "schedule":{"type":"interval","every":\(every),"unit":"minutes"},"durationMinutes":30,"nextRunAt":\(due),"createdAt":0,"updatedAt":0}],
        "runs":[\(runs)]}
        """.write(to: dir.appendingPathComponent("routines.json"), atomically: true, encoding: .utf8)
        return RoutineManager(file: dir.appendingPathComponent("routines.json"), host: .init(
            emit: { _ in }, botState: { _ in "ready" }, createTask: { _, _, _ in "t" }, startTurn: { _, _, _, _, _, _ in }, interruptTurn: { _, _, _ in }))
    }

    func testDueIntervalRunsOnceAndKeepsItsGrid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 7 minutes late on a 5-minute grid: one run, and the next one on the grid after now
        let manager = try manager(lateMillis: 7 * 60_000, every: 5, in: dir)
        let routine = try XCTUnwrap(manager.routines.first)
        XCTAssertTrue(manager.runs.isEmpty)
        manager.tick()
        XCTAssertEqual(manager.runs.count, 1)
        let next = try XCTUnwrap(manager.routines.first?["nextRunAt"]?.double)
        let due = try XCTUnwrap(routine["nextRunAt"]?.double)
        XCTAssertEqual((next - due).truncatingRemainder(dividingBy: 300_000), 0, "stays on the 5-minute grid")
        XCTAssertGreaterThan(next, nowMillis())
    }

    func testIntervalDoesNotPileUpBehindAnUnfinishedRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = try manager(lateMillis: 1_000, every: 5, existingRun: "queued", in: dir)
        manager.tick()
        XCTAssertEqual(manager.runs.count, 1, "no second run while the first is still going")
        XCTAssertGreaterThan(try XCTUnwrap(manager.routines.first?["nextRunAt"]?.double), nowMillis(), "but the clock still moves on")
    }
}
