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
        bot.endpoint = EndpointConfig(baseUrl: "http://127.0.0.1:1/v1", model: "m", headers: ["X-A": "1"], images: true)
        store.save(bot)
        store.save(LocalMessage(id: "m1", botId: "b1", role: .user, text: "ciao", at: Date(timeIntervalSince1970: 1)))
        store.save(LocalMessage(id: "m2", botId: "b1", role: .bot, text: "salve", at: Date(timeIntervalSince1970: 2)))
        store.save(LocalConnector(id: "c1", name: "MCP", url: "https://x/mcp", auth: .oauth, createdAt: Date()))

        let reopened = try LocalStore(folder: store.folder)
        XCTAssertEqual(reopened.bots(), [bot])
        XCTAssertEqual(reopened.messages(bot: "b1").map(\.text), ["ciao", "salve"])
        XCTAssertEqual(reopened.connectors().map(\.auth), [.oauth])
        reopened.delete(bot: "b1")
        XCTAssertTrue(reopened.bots().isEmpty)
        XCTAssertTrue(reopened.messages(bot: "b1").isEmpty)
    }

    func testImportFromTheMacMakesBotsAndConnectors() async throws {
        let local = LocalBots(store: try temporaryStore())
        let config = PhoneConfig(endpoints: [.init(name: "Endpoint dal Mac", baseUrl: "http://10.0.0.2:4000/v1", model: "m1", apiKey: "sk-1")],
                                 connectors: [.init(name: "MCP", url: "https://x/mcp", auth: "headers", headers: ["X-Key": "v"]),
                                              .init(name: "Notion", url: "https://n/mcp", auth: "oauth", oauthClientId: "c1")])
        await local.importConfig(config)
        let bot = try XCTUnwrap(local.bots.first)
        XCTAssertEqual(bot.endpoint?.model, "m1")
        XCTAssertEqual(Keychain.get(bot.apiKeyAccount), "sk-1")
        XCTAssertEqual(local.connectors.map(\.auth), [.headers, .oauth])
        XCTAssertEqual(ConnectorSecrets.headers(local.connectors[0]), ["X-Key": "v"])
        XCTAssertEqual(local.connectors[1].oauthClientId, "c1")
        for connector in local.connectors { local.delete(connector) }
        local.delete(bot)
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
