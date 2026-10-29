@testable import CodePluginApp
import CompanionCore
import SwarmeBotUI
@testable import SwarmeKit
import XCTest

@MainActor
final class CodeAppPluginTests: XCTestCase {
    private func bot(codeMode: Bool?) throws -> Bot {
        let flag = codeMode.map { #","codeMode":\#($0)"# } ?? ""
        return try JSONDecoder().decode(Bot.self, from: Data(#"{"id":"b","threadId":"t","name":"N","title":"","description":"","notifications":true,"color":"blue","unread":false,"modelSelection":{"instanceId":"i","model":"m"},"createdAt":1\#(flag)}"#.utf8))
    }

    private func chat(_ bot: Bot?, busy: Bool = false) -> ChatContext {
        ChatContext(model: AppModel(), bot: bot, room: nil, threadId: "t", isBusy: busy)
    }

    private func message() throws -> Message {
        try JSONDecoder().decode(Message.self, from: Data(#"{"id":"m","role":"bot","kind":"text","text":"hi","at":1}"#.utf8))
    }

    func testIsOnForABotWithTheFlag() throws {
        let plugin = CodeAppPlugin()
        XCTAssertEqual(plugin.id, "code", "the id the engine's plugin carries")
        XCTAssertTrue(plugin.isActive(for: chat(try bot(codeMode: true))))
        XCTAssertFalse(plugin.isActive(for: chat(try bot(codeMode: false))))
        XCTAssertFalse(plugin.isActive(for: chat(try bot(codeMode: nil))))
        XCTAssertFalse(plugin.isActive(for: chat(nil)), "a channel has no Code mode yet")
    }

    func testTheBranchTheTerminalAndOpenInSitUnderTheComposer() throws {
        let plugin = CodeAppPlugin()
        XCTAssertEqual(plugin.composerAccessories(chat(try bot(codeMode: true))).count, 3)
        XCTAssertTrue(plugin.composerAccessories(chat(nil)).isEmpty)
    }

    func testTheFooterIsAlwaysOursInACodeChat() throws {
        // in a Code chat the file cards never show: mid-turn replies get an empty footer, a turn's end the badge
        let plugin = CodeAppPlugin()
        let mid = TurnPosition(isTurnEnd: false, isLatest: false)
        let end = TurnPosition(isTurnEnd: true, isLatest: false)
        let busyLatest = TurnPosition(isTurnEnd: true, isLatest: true)
        XCTAssertNotNil(plugin.replyFooter(try message(), chat(try bot(codeMode: true)), mid))
        XCTAssertNotNil(plugin.replyFooter(try message(), chat(try bot(codeMode: true)), end))
        XCTAssertNotNil(plugin.replyFooter(try message(), chat(try bot(codeMode: true), busy: true), busyLatest))
    }

    func testOnlyABotHasASwitch() throws {
        let plugin = CodeAppPlugin()
        XCTAssertEqual(plugin.settingsSections(.bot(try bot(codeMode: false))).count, 1)
        XCTAssertTrue(plugin.settingsSections(.global).isEmpty)
    }
}
