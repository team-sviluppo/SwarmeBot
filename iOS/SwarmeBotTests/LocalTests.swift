@testable import SwarmeBot
import AgentCore
import CompanionCore
import XCTest

@MainActor
final class LocalTests: XCTestCase {
    private func temporaryStore() throws -> LocalStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try LocalStore(folder: folder)
    }

    func testStoreKeepsBotsMessagesAndConnectors() throws {
        let store = try temporaryStore()
        var bot = LocalBot(id: "b1", name: "Prova", kind: .endpoint, createdAt: Date(timeIntervalSince1970: 1_000))
        bot.endpoint = EndpointConfig(serverId: "s1", model: "m", images: true)
        store.save(bot)
        let server = LocalServer(id: "s1", name: "LiteLLM", baseUrl: "http://127.0.0.1:1/v1", headers: ["X-A": "1"], createdAt: Date(timeIntervalSince1970: 5))
        store.save(server)
        store.save(LocalMessage(id: "m1", botId: "b1", role: .user, text: "ciao", at: Date(timeIntervalSince1970: 1)))
        store.save(LocalMessage(id: "m2", botId: "b1", role: .bot, text: "salve", at: Date(timeIntervalSince1970: 2)))
        store.save(LocalConnector(id: "c1", name: "MCP", url: "https://x/mcp", auth: .oauth, createdAt: Date()))

        let reopened = try LocalStore(folder: store.folder)
        XCTAssertEqual(reopened.bots(), [bot])
        XCTAssertEqual(reopened.messages(bot: "b1").map(\.text), ["ciao", "salve"])
        XCTAssertEqual(reopened.connectors().map(\.auth), [.oauth])
        XCTAssertEqual(reopened.servers(), [server])
        reopened.delete(bot: "b1")
        XCTAssertTrue(reopened.bots().isEmpty)
        XCTAssertTrue(reopened.messages(bot: "b1").isEmpty)
    }

    func testAReplyOffScreenIsUnreadUntilItsChatIsOpen() throws {
        let store = try temporaryStore()
        let local = LocalBots(store: store)
        local.save(LocalBot(id: "b1", name: "Prova", kind: .apple, createdAt: Date()))
        let notifier = Notifier.shared
        defer { notifier.onScreen = nil }

        // on screen (the test host is not in the background): read as it arrives
        notifier.onScreen = Notifier.key(phoneBot: "b1")
        local.replied("b1", text: "fatto")
        XCTAssertEqual(local.unreadCount, 0)

        // another chat on screen: unread, and kept
        notifier.onScreen = nil
        local.replied("b1", text: "fatto")
        XCTAssertEqual(local.unreadCount, 1)
        XCTAssertEqual(LocalBots(store: try LocalStore(folder: store.folder)).unreadCount, 1)

        local.markRead("b1")
        XCTAssertEqual(local.unreadCount, 0)
        XCTAssertNil(local.bot("b1")?.unread)
    }

    func testAChannelAnswersAsTheEngineRoomsDo() throws {
        let ada = LocalBot(id: "a", name: "Ada", kind: .apple, createdAt: Date())
        let ada2 = LocalBot(id: "a2", name: "Ada Due", kind: .apple, createdAt: Date())
        let bob = LocalBot(id: "b", name: "Bob", kind: .apple, createdAt: Date())
        // a guest from a paired server: a mixed channel
        let cleo = RoomGuest(peerId: "srv", botId: "c", name: "Cleo", color: "green")
        let members: [RoomMember] = [.phone(ada), .phone(ada2), .phone(bob), .guest(cleo)]
        var room = LocalRoom(id: "r", name: "Team", memberIds: ["a", "a2", "b"], guests: [cleo], createdAt: Date())
        let ids = { (text: String) in LocalRoomChat.responders(text, members: members, room: room).map(\.id) }

        // untagged: the first member, the engine's default
        XCTAssertEqual(ids("ciao"), ["a"])
        // tags win, longest name first; an address is no tag
        XCTAssertEqual(ids("@Ada Due e @bob, guardate"), ["a2", "b"])
        XCTAssertEqual(ids("scrivi a me@Bob.it"), ["a"])
        XCTAssertEqual(ids("@Cleo tocca a te"), ["peer:srv:c"])
        XCTAssertEqual(ids("@everyone"), ["a", "a2", "b", "peer:srv:c"])
        room.responder = "member"
        room.responderBotId = "peer:srv:c"
        XCTAssertEqual(ids("ciao"), ["peer:srv:c"])
        room.responder = "everyone"
        XCTAssertEqual(ids("ciao"), ["a", "a2", "b", "peer:srv:c"])
        room.responder = "mentions"
        XCTAssertEqual(ids("ciao"), [])
        let system = LocalRoomChat.system(for: bob, in: room, roster: members.map { "@\($0.name)" })
        XCTAssertTrue(system.contains("Room members: @Ada, @Ada Due, @Bob, @Cleo"))
    }

    func testChannelsAreKeptAndLoseDeletedBots() throws {
        let store = try temporaryStore()
        let local = LocalBots(store: store)
        local.save(LocalBot(id: "a", name: "Ada", kind: .apple, createdAt: Date()))
        local.save(LocalBot(id: "b", name: "Bob", kind: .apple, createdAt: Date()))
        let room = local.addRoom(name: " ", memberIds: ["a", "b"])
        XCTAssertEqual(room.name, "Ada, Bob")
        XCTAssertEqual(LocalBots(store: try LocalStore(folder: store.folder)).rooms.map { [$0.id, $0.name] + $0.memberIds }, [[room.id, "Ada, Bob", "a", "b"]])

        local.delete(try XCTUnwrap(local.bot("a")))
        XCTAssertEqual(local.room(room.id)?.memberIds, ["b"])
        local.delete(try XCTUnwrap(local.bot("b")))
        XCTAssertNil(local.room(room.id))
        XCTAssertTrue(LocalBots(store: try LocalStore(folder: store.folder)).rooms.isEmpty)

        // a channel with a guest outlives its last phone bot
        local.save(LocalBot(id: "c", name: "Cleo", kind: .apple, createdAt: Date()))
        let mixed = local.addRoom(name: "", memberIds: ["c"], guests: [RoomGuest(peerId: "srv", botId: "x", name: "Xeno", color: "red")])
        XCTAssertEqual(mixed.name, "Cleo, Xeno")
        local.delete(try XCTUnwrap(local.bot("c")))
        XCTAssertEqual(local.room(mixed.id)?.allMemberIds, ["peer:srv:x"])
    }

    func testImportFromTheMacMakesBotsAndConnectors() async throws {
        let local = LocalBots(store: try temporaryStore())
        let config = PhoneConfig(endpoints: [.init(name: "Endpoint dal Mac", baseUrl: "http://10.0.0.2:4000/v1", model: "m1", apiKey: "sk-1")],
                                 connectors: [.init(name: "MCP", url: "https://x/mcp", auth: "headers", headers: ["X-Key": "v"]),
                                              .init(name: "Notion", url: "https://n/mcp", auth: "oauth", oauthClientId: "c1")])
        await local.importConfig(config)
        let bot = try XCTUnwrap(local.bots.first)
        XCTAssertEqual(bot.endpoint?.model, "m1")
        let server = try XCTUnwrap(local.server(for: bot))
        XCTAssertEqual(server.baseUrl, "http://10.0.0.2:4000/v1")
        XCTAssertEqual(Keychain.get(server.apiKeyAccount), "sk-1")
        // the same endpoint again: a second bot on the same server
        await local.importConfig(PhoneConfig(endpoints: config.endpoints, connectors: []))
        XCTAssertEqual(local.servers.count, 1)
        XCTAssertEqual(local.bots(on: server).count, 2)
        XCTAssertEqual(local.connectors.map(\.auth), [.headers, .oauth])
        XCTAssertEqual(ConnectorSecrets.headers(local.connectors[0]), ["X-Key": "v"])
        XCTAssertEqual(local.connectors[1].oauthClientId, "c1")
        for connector in local.connectors { local.delete(connector) }
        for bot in local.bots { local.delete(bot) }
        local.delete(server)
    }

    func testBotsFromBeforeServersMoveToShared() throws {
        let store = try temporaryStore()
        for (id, key) in [("old1", "sk-a"), ("old2", "sk-a"), ("old3", "sk-b")] {
            var bot = LocalBot(id: id, name: id, kind: .endpoint, createdAt: Date())
            bot.endpoint = EndpointConfig(model: "m", baseUrl: "https://llm.example/v1", headers: ["X-A": "1"])
            store.save(bot)
            try Keychain.set(key, for: bot.apiKeyAccount)
        }
        let local = LocalBots(store: store)
        // same address, headers and key: one server; another key: another
        XCTAssertEqual(local.servers.count, 2)
        let first = try XCTUnwrap(local.server(for: try XCTUnwrap(local.bot("old1"))))
        XCTAssertEqual(local.bots(on: first).map(\.id).sorted(), ["old1", "old2"])
        XCTAssertEqual(first.headers, ["X-A": "1"])
        XCTAssertEqual(Keychain.get(first.apiKeyAccount), "sk-a")
        XCTAssertNil(Keychain.get(local.bot("old1")!.apiKeyAccount))
        XCTAssertNil(local.bot("old1")?.endpoint?.baseUrl)
        // kept on reopening, nothing moved twice
        XCTAssertEqual(LocalBots(store: try LocalStore(folder: store.folder)).servers.count, 2)
        for server in local.servers { local.delete(server) }
    }

    func testAppleInstructionsKeepTheNewestHistory() {
        let bot = LocalBot(id: "b", name: "A", kind: .apple, createdAt: Date())
        let long = String(repeating: "x", count: 4_000)
        let history = [
            LocalMessage(id: "1", botId: "b", role: .user, text: "vecchio " + long, at: Date()),
            LocalMessage(id: "2", botId: "b", role: .bot, text: "recente", at: Date()),
            LocalMessage(id: "3", botId: "b", role: .user, text: long, at: Date()),
        ]
        let text = AppleDriver.instructions(bot, history: history)
        XCTAssertFalse(text.contains("vecchio"), "the oldest message goes first")
        XCTAssertTrue(text.contains("Assistant: recente"))
        XCTAssertTrue(text.contains("older messages left out"))
    }

    func testToolSpecsBecomeSendableTrees() throws {
        let spec: JSON = ["type": "function", "function": ["name": "c__echo", "parameters": ["type": "object", "required": ["text"]]]]
        let tree = try XCTUnwrap(GemmaModel.sendable(spec) as? [String: any Sendable])
        let function = try XCTUnwrap(tree["function"] as? [String: any Sendable])
        XCTAssertEqual(function["name"] as? String, "c__echo")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: any Sendable])
        XCTAssertEqual((parameters["required"] as? [any Sendable])?.first as? String, "text")
    }

    // MARK: Phone tools

    func testPhoneToolsReadLocalDatesAndTimes() throws {
        let morning = try XCTUnwrap(PhoneTools.parseDate("2026-10-24T09:05"))
        XCTAssertTrue(morning.time)
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: morning.date),
                       DateComponents(year: 2026, month: 10, day: 24, hour: 9, minute: 5))
        // a zone or seconds after the minutes are ignored: the user's own time
        XCTAssertEqual(PhoneTools.parseDate("2026-10-24 09:05:00Z")?.date, morning.date)
        let day = try XCTUnwrap(PhoneTools.parseDate("2026-10-24"))
        XCTAssertFalse(day.time)
        XCTAssertNil(PhoneTools.parseDate("domani"))
        XCTAssertNil(PhoneTools.parseDate("2026-10-24T25:00"))
        XCTAssertEqual(PhoneTools.parseClock("7:30")?.hour, 7)
        XCTAssertEqual(PhoneTools.parseClock("19.05")?.minute, 5)
        XCTAssertNil(PhoneTools.parseClock("7"))
    }

    func testPhoneToolSchemasListTheRequiredParameters() throws {
        let add = try XCTUnwrap(PhoneTool.all.first { $0.name == "calendar_add" })
        XCTAssertEqual(add.inputSchema["required"], ["title", "start"])
        XCTAssertEqual(add.inputSchema["properties"]?["minutes"]?["type"], "integer")
        XCTAssertEqual(Set(PhoneTool.all.map(\.group)), Set(PhoneToolGroup.allCases), "every group has tools")
        XCTAssertEqual(PhoneTool.tools([.contacts]).map(\.name), ["contacts_search"])
    }

    func testABotGetsOnlyThePhoneToolsItTurnedOn() async throws {
        let local = LocalBots(store: try temporaryStore())
        var bot = LocalBot(id: "b1", name: "Prova", kind: .apple, createdAt: Date())
        XCTAssertNil(local.toolBox(for: bot))
        bot.phoneTools = [.reminders]
        let box = try XCTUnwrap(local.toolBox(for: bot))
        let listed = await box.tools()
        XCTAssertEqual(listed.tools.map(\.name), ["reminders_list", "reminder_add"])
        XCTAssertEqual(Set(listed.tools.map(\.connectorId)), [PhoneTools.connectorId])
        // a tool of a group left off is refused without touching the phone
        let refused = await box.callPhone("contacts_search", arguments: ["query": "Rossi"])
        XCTAssertFalse(refused.ok)
        // Apple's model gets them as Foundation Models tools
        let sink = TurnSink(delta: { _ in }, toolStarted: { _, _ in "" }, toolDone: { _, _, _ in }, note: { _ in })
        XCTAssertEqual(AppleDriver.tools(box, sink: sink).map(\.name), ["reminders_list", "reminder_add"])
        XCTAssertTrue(AppleDriver.instructions(bot, history: [], tools: true).contains("Now is "))
    }

    func testAWriteWaitsForTheUserAndStopsAtNo() async throws {
        let phone = PhoneTools()
        // a bad argument fails before asking
        let invalid = await phone.call("timer_set", arguments: ["minutes": 0])
        XCTAssertFalse(invalid.ok)
        XCTAssertNil(phone.pending)
        let call = Task { await phone.call("timer_set", arguments: ["minutes": 5, "label": "pasta"]) }
        while phone.pending == nil { await Task.yield() }
        XCTAssertEqual(phone.pending?.detail.contains("pasta"), true)
        phone.answer(try XCTUnwrap(phone.pending?.id), false)
        let result = await call.value
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.text.contains("declined"))
        XCTAssertNil(phone.pending)
        // a stopped turn answers no by itself
        let stopped = Task { await phone.confirm("t", "d") }
        while phone.pending == nil { await Task.yield() }
        stopped.cancel()
        let answer = await stopped.value
        XCTAssertFalse(answer)
    }
}
