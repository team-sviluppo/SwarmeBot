import CompanionCore
import Foundation
import XCTest

/// Every desktop route against a real harness — but never yours. Runs only
/// when `SWARMEBOT_IT_PORT` points at a harness started on a throwaway data
/// dir (scripts/integration-test.sh does exactly that). No message is sent:
/// a turn would run a real engine.
final class HarnessIntegrationTests: XCTestCase {
    private var client: CompanionClient!

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["SWARMEBOT_IT_PORT"], let port = Int(raw) else {
            throw XCTSkip("set SWARMEBOT_IT_PORT (see scripts/integration-test.sh)")
        }
        client = CompanionClient(connection: Connection(name: "it", host: "127.0.0.1", port: port), token: nil)
    }

    func testBotsRoomsAndTasks() async throws {
        let health = try await client.health()
        XCTAssertEqual(health.app, "swarmebot")

        let bot = try await client.createBot()
        let patched = try await client.patchBot(bot.id, BotPatch(name: "IT Bot", pinned: true, section: "Prove"))
        XCTAssertEqual(patched.name, "IT Bot")
        XCTAssertEqual(patched.section, "Prove")
        let cleared = try await client.patchBot(bot.id, BotPatch(section: ""))
        XCTAssertNil(cleared.section, "an empty section clears the label")

        let other = try await client.createBot()
        let room = try await client.createRoom(name: "it-room", memberIds: [bot.id, other.id])
        let renamed = try await client.patchRoom(room.id, RoomPatch(name: "it-room-2", responder: "member", responderBotId: other.id))
        XCTAssertEqual(renamed.name, "it-room-2")
        XCTAssertEqual(renamed.defaultResponder.botId, other.id)

        let withTask = try await client.createTask(botId: bot.id, title: "Secondo")
        XCTAssertEqual(withTask.tasks?.count, 2)
        if let task = withTask.tasks?.first(where: { $0.title == "Secondo" }) {
            try await client.setTaskPinned(botId: bot.id, threadId: task.threadId, pinned: true)
        }

        let fleet = try await client.fleet(messages: 10)
        XCTAssertTrue(fleet.bots.contains { $0.id == bot.id })

        try await client.deleteRoom(room.id)
        try await client.deleteBot(other.id)
    }

    func testRoutinesAndWebhooks() async throws {
        let bot = try await client.createBot()
        let input = RoutineInput(name: "IT", prompt: "ping", botId: bot.id, enabled: false,
                                 schedule: .daily("09:30", weekdays: [1, 3, 5]), durationMinutes: 15)
        let routine = try await client.createRoutine(input)
        XCTAssertEqual(routine.schedule.time, "09:30")
        try await client.setRoutineEnabled(routine.id, true)
        let listed = try await client.routines()
        XCTAssertEqual(listed.routines.first { $0.id == routine.id }?.enabled, true)
        try await client.deleteRoutine(routine.id)

        let created = try await client.createWebhook(WebhookInput(name: "IT hook", prompt: "do", botId: bot.id, enabled: false))
        XCTAssertNotNil(created.credential?.secret, "the secret is shown on create")
        let rotated = try await client.rotateWebhook(created.webhook.id)
        XCTAssertNotEqual(rotated.credential?.secret, created.credential?.secret)
        _ = try await client.updateWebhook(created.webhook.id, ["name": "IT hook 2"])
        let hooks = try await client.webhooks()
        XCTAssertEqual(hooks.webhooks.first { $0.id == created.webhook.id }?.name, "IT hook 2")
        try await client.deleteWebhook(created.webhook.id)
    }

    func testAttachmentsLibraryConfigAndReads() async throws {
        let bot = try await client.createBot()
        // 1×1 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let saved = try await client.uploadAttachment(png, mime: "image/png")
        XCTAssertTrue(saved.path.hasSuffix(".png"))
        let back = try await client.attachment(named: (saved.path as NSString).lastPathComponent)
        XCTAssertEqual(back, png)

        let library = try await client.library(botId: bot.id)
        XCTAssertEqual(library, [])

        let status = try await client.saveConfig(["profile": ["name": "Tester", "email": "t@example.com"]], externalSecrets: false)
        XCTAssertEqual(status.profile?.name, "Tester")
        _ = try await client.saveConfig(["rooms": ["turnTimeoutMinutes": 12]], externalSecrets: false)
        let config = try await client.config()
        XCTAssertEqual(config.rooms?.turnTimeoutMinutes, 12)

        let instances = try await client.instances()
        XCTAssertFalse(instances.isEmpty)
        if let first = instances.first {
            let updated = try await client.patchInstance(first.instanceId, pickerVisible: .some(false))
            XCTAssertEqual(updated.first { $0.instanceId == first.instanceId }?.pickerVisible, false)
            _ = try await client.patchInstance(first.instanceId, pickerVisible: .some(nil))
        }

        _ = try await client.events(threadId: bot.threadId)
        _ = try await client.decisions()
        _ = try await client.search("ricorda")
        _ = try await client.localComputer()
        let team = try await client.exportTeam(name: "IT team")
        XCTAssertTrue(String(decoding: team, as: UTF8.self).contains("IT team"))
        let test = try await client.testCLI("/bin/echo", driver: nil)
        XCTAssertNotNil(test.ok as Bool?)
    }
}
