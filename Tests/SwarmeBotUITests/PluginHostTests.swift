import CompanionCore
@testable import SwarmeBotUI
@testable import SwarmeKit
import SwiftUI
import XCTest

/// Where a plugin shows: linked into the app, carried and switched on by the engine, active for the chat.
@MainActor
final class PluginHostTests: XCTestCase {
    final class Fake: AppPlugin {
        let id: String
        let name: String
        var active = true
        var footer: PluginView?
        var navigation: PluginView?
        var groups: [PluginSkillGroup] = []

        init(_ id: String) {
            self.id = id
            name = id
        }

        func isActive(for chat: ChatContext) -> Bool { active }
        func composerAccessories(_ chat: ChatContext) -> [PluginView] { [PluginView(Text(verbatim: id))] }
        func replyFooter(_ message: Message, _ chat: ChatContext, _ position: TurnPosition) -> PluginView? { footer }
        func chatNavigation(_ chat: ChatContext) -> PluginView? { navigation }
        func settingsSections(_ scope: SettingsScope) -> [PluginView] { [PluginView(Text(verbatim: id))] }
        func skillGroups(on model: AppModel) -> [PluginSkillGroup] { groups }
    }

    private func chat(_ model: AppModel) -> ChatContext {
        ChatContext(model: model, bot: nil, room: nil, threadId: "t", isBusy: false)
    }

    private func message() throws -> Message {
        try JSONDecoder().decode(Message.self, from: Data(#"{"id":"m","role":"bot","kind":"text","text":"hi","at":1}"#.utf8))
    }

    func testAPluginTheEngineLacksShowsNowhere() {
        let host = PluginHost()
        host.install([Fake("code")])
        let model = AppModel()
        XCTAssertTrue(host.available(on: model).isEmpty)
        XCTAssertTrue(host.composerAccessories(chat(model)).isEmpty)
        XCTAssertTrue(host.settingsSections(.global, on: model).isEmpty)
        XCTAssertFalse(host.hasActive(for: chat(model)))
    }

    func testSkillGroupsFollowPluginAvailabilityWithoutRequiringAnActiveChat() {
        let host = PluginHost()
        let plugin = Fake("suite")
        plugin.active = false
        plugin.groups = [PluginSkillGroup(id: "suite", title: "Suite", description: "", skillIDs: ["one", "two"])]
        host.install([plugin])
        let model = AppModel()
        XCTAssertTrue(host.skillGroups(on: model).isEmpty)
        model.enginePlugins = [EnginePluginInfo(id: "suite", name: "Suite", version: "1", enabled: true)]
        XCTAssertEqual(host.skillGroups(on: model).map(\.skillIDs), [["one", "two"]])
        model.enginePlugins[0].enabled = false
        XCTAssertTrue(host.skillGroups(on: model).isEmpty)
    }

    func testAPluginTheEngineSwitchedOffShowsNowhere() {
        let host = PluginHost()
        host.install([Fake("code")])
        let model = AppModel()
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1", enabled: false)]
        XCTAssertTrue(host.available(on: model).isEmpty)
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1", enabled: true)]
        XCTAssertEqual(host.available(on: model).map(\.id), ["code"])
        XCTAssertEqual(host.composerAccessories(chat(model)).count, 1)
    }

    private func profileClient(allowed: Bool) -> CompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PluginProfileStub.self]
        return CompanionClient(connection: Connection(name: "Profile test", host: allowed ? "allowed.invalid" : "denied.invalid", port: 80),
                               token: nil, session: URLSession(configuration: configuration))
    }

    func testSavingTheProfileRemovesAndRestoresAllPluginUI() async {
        let host = PluginHost()
        host.install([Fake("cylon")])
        let model = AppModel()
        model.enginePlugins = [EnginePluginInfo(id: "cylon", name: "Cylon", version: "1", enabled: true)]
        model.client = profileClient(allowed: false)
        await model.saveConfig(["profile": ["email": "user@example.com"]])
        XCTAssertEqual(model.config?.profile?.email, "user@example.com")
        XCTAssertEqual(model.enginePlugins.map(\.id), ["code"])
        XCTAssertTrue(host.available(on: model).isEmpty)
        XCTAssertTrue(host.settingsSections(.global, on: model).isEmpty)
        XCTAssertTrue(host.composerAccessories(chat(model)).isEmpty)
        model.client = profileClient(allowed: true)
        await model.saveConfig(["profile": ["email": "user@hextra.it"]])
        XCTAssertEqual(host.available(on: model).map(\.id), ["cylon"])
        XCTAssertEqual(host.settingsSections(.global, on: model).count, 1)
    }

    func testAProfileEventRefreshesPluginVisibilityInSettings() async throws {
        let model = AppModel()
        model.enginePlugins = [EnginePluginInfo(id: "cylon", name: "Cylon", version: "1", enabled: true)]
        model.client = profileClient(allowed: false)
        model.settingsFrame(.config)
        for _ in 0..<100 where model.engineHasPlugin("cylon") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.config?.profile?.email, "user@example.com")
        XCTAssertEqual(model.enginePlugins.map(\.id), ["code"])
        model.client = profileClient(allowed: true)
        await model.refreshConfig()
        XCTAssertTrue(model.engineHasPlugin("cylon"))
    }

    func testAPluginInTheEngineButNotInThisAppShowsNothing() {
        let host = PluginHost()
        host.install([])
        let model = AppModel()
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1", enabled: true)]
        XCTAssertTrue(host.available(on: model).isEmpty)
    }

    func testActiveDependsOnTheChat() {
        let host = PluginHost()
        let fake = Fake("code")
        host.install([fake])
        let model = AppModel()
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1", enabled: true)]
        XCTAssertTrue(host.hasActive(for: chat(model)))
        fake.active = false
        XCTAssertFalse(host.hasActive(for: chat(model)))
        XCTAssertTrue(host.composerAccessories(chat(model)).isEmpty, "off for this chat: no chips")
        XCTAssertEqual(host.settingsSections(.global, on: model).count, 1, "settings show wherever the engine has it")
    }

    func testTheFirstFooterThatTakesOverWins() throws {
        let host = PluginHost()
        let quiet = Fake("a")
        let loud = Fake("b")
        loud.footer = PluginView(Text(verbatim: "footer"))
        host.install([quiet, loud])
        let model = AppModel()
        model.enginePlugins = [EnginePluginInfo(id: "a", name: "A", version: "1", enabled: true), EnginePluginInfo(id: "b", name: "B", version: "1", enabled: true)]
        let position = TurnPosition(isTurnEnd: true, isLatest: true)
        XCTAssertNotNil(host.replyFooter(try message(), chat(model), position))
        loud.footer = nil
        XCTAssertNil(host.replyFooter(try message(), chat(model), position), "nobody takes over: the file cards stay")
    }

    func testTwoPluginsCannotShareAnId() {
        let host = PluginHost()
        host.install([Fake("code"), Fake("code")])
        XCTAssertEqual(host.plugins.count, 1)
    }

    func testHeaderNavigationOnlyReplacesTheCoreControlsForAnAvailableActivePlugin() {
        let host = PluginHost()
        let plugin = Fake("code")
        plugin.navigation = PluginView(Text(verbatim: "chats"))
        host.install([plugin])
        let model = AppModel()
        XCTAssertNil(host.chatNavigation(chat(model)), "the engine lacks the plugin: keep core navigation")
        model.enginePlugins = [EnginePluginInfo(id: "code", name: "Code", version: "1.6.0", enabled: true)]
        XCTAssertNotNil(host.chatNavigation(chat(model)))
        plugin.active = false
        XCTAssertNil(host.chatNavigation(chat(model)), "ordinary chats keep core navigation")
        plugin.active = true
        model.enginePlugins[0].enabled = false
        XCTAssertNil(host.chatNavigation(chat(model)), "a disabled plugin cannot hide core navigation")
    }

    func testTurnEndsAreTheLastBotTextBeforeTheNextUserMessage() throws {
        func message(_ id: String, _ role: String) throws -> Message {
            try JSONDecoder().decode(Message.self, from: Data(#"{"id":"\#(id)","role":"\#(role)","kind":"text","text":"x","at":1}"#.utf8))
        }
        let ends = TurnEnds(try [message("u1", "user"), message("b1", "bot"), message("b2", "bot"), message("u2", "user"), message("b3", "bot")])
        XCTAssertEqual(ends.ids, ["b2", "b3"])
        XCTAssertEqual(ends.latest, "b3")
        XCTAssertNil(TurnEnds(try [message("u1", "user")]).latest)
    }

    func testAReviewByAnotherBotIsNotPartOfTheTurnsItCommentsOn() throws {
        func message(_ id: String, _ role: String, review: Bool = false) throws -> Message {
            let mark = review ? #","from":{"botId":"rev","name":"Revisore","color":"blue"},"review":{"applied":false}"# : ""
            return try JSONDecoder().decode(Message.self, from: Data(#"{"id":"\#(id)","role":"\#(role)","kind":"text","text":"x","at":1\#(mark)}"#.utf8))
        }
        let ends = TurnEnds(try [message("u1", "user"), message("b1", "bot"), message("r1", "bot", review: true), message("u2", "user")])
        XCTAssertEqual(ends.ids, ["b1"], "the reply keeps its footer: the review neither takes it nor ends a turn of its own")
        XCTAssertEqual(ends.latest, nil)
        let after = TurnEnds(try [message("u1", "user"), message("b1", "bot"), message("r1", "bot", review: true)])
        XCTAssertEqual(after.ids, ["b1"])
        XCTAssertEqual(after.latest, "b1", "the newest turn is still the bot's, whatever was said about it")
    }
}

/// Profile and plugin responses from the same engine, without touching a user's engine or settings.
private final class PluginProfileStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let allowed = request.url?.host == "allowed.invalid"
        let body: String
        if request.url?.path == "/api/config" {
            body = #"{"profile":{"name":"Tester","email":"user@\#(allowed ? "hextra.it" : "example.com")"}}"#
        } else if request.url?.path == "/api/plugins" {
            let cylon = allowed ? #",{"id":"cylon","enabled":true}"# : ""
            body = #"{"plugins":[{"id":"code","enabled":true}\#(cylon)]}"#
        } else {
            body = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class TurnEndsInChannelsTests: XCTestCase {
    private func message(_ id: String, _ role: String, from: String? = nil) throws -> Message {
        let sender = from.map { #","from":{"botId":"\#($0)","name":"\#($0)","color":"blue"}"# } ?? ""
        return try JSONDecoder().decode(Message.self, from: Data(#"{"id":"\#(id)","role":"\#(role)","kind":"text","text":"x","at":1\#(sender)}"#.utf8))
    }

    func testEachMembersAnswerIsItsOwnTurnEnd() throws {
        let ends = TurnEnds(try [message("u1", "user"), message("a1", "bot", from: "claude"), message("a2", "bot", from: "claude"),
                                 message("c1", "bot", from: "codex"), message("u2", "user"), message("c2", "bot", from: "codex")])
        XCTAssertEqual(ends.ids, ["a2", "c1", "c2"], "a new speaker closes the last one's turn")
        XCTAssertEqual(ends.latest, "c2")
    }

    func testOneBotsRepliesAreStillOneTurn() throws {
        let ends = TurnEnds(try [message("u1", "user"), message("b1", "bot"), message("b2", "bot"), message("b3", "bot")])
        XCTAssertEqual(ends.ids, ["b3"])
    }

    func testTheSpeakerIsForgottenAtTheNextQuestion() throws {
        let ends = TurnEnds(try [message("a1", "bot", from: "claude"), message("u1", "user"), message("a2", "bot", from: "claude")])
        XCTAssertEqual(ends.ids, ["a1", "a2"])
    }
}
