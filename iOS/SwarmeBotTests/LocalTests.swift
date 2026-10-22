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
        defer { notifier.onScreen = nil; notifier.active = false }

        // on screen, in front: read as it arrives
        notifier.active = true
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
}
