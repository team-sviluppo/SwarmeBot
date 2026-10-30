@testable import SwarmeKit
import XCTest

@MainActor
final class TerminalAppTests: XCTestCase {
    func testEachTerminalIsLaunchedItsOwnWay() {
        let script = "/tmp/swarmebot-x.command"
        XCTAssertEqual(TerminalApp.terminal.launch(script: script), .openFile)
        XCTAssertEqual(TerminalApp.iterm.launch(script: script), .openFile)
        XCTAssertEqual(TerminalApp.warp.launch(script: script), .openFile)
        XCTAssertEqual(TerminalApp.ghostty.launch(script: script), .newInstance(arguments: ["-e", script]))
        XCTAssertEqual(TerminalApp.wezterm.launch(script: script), .newInstance(arguments: ["start", "--", script]))
        XCTAssertEqual(TerminalApp.kitty.launch(script: script), .newInstance(arguments: [script]))
    }

    func testTheSixTerminalsHaveDistinctNamesAndBundles() {
        XCTAssertEqual(TerminalApp.allCases.count, 6)
        XCTAssertEqual(Set(TerminalApp.allCases.map(\.bundleId)).count, 6)
        XCTAssertEqual(Set(TerminalApp.allCases.map(\.name)).count, 6)
        XCTAssertEqual(TerminalApp.terminal.bundleId, "com.apple.Terminal")
    }

    func testTheChoiceIsKeptAndTerminalIsTheDefault() {
        let before = AppPaths.defaults.string(forKey: TerminalApp.defaultsKey)
        defer { AppPaths.defaults.set(before, forKey: TerminalApp.defaultsKey) }
        AppPaths.defaults.removeObject(forKey: TerminalApp.defaultsKey)
        XCTAssertEqual(TerminalApp.selected, .terminal)
        TerminalApp.selected = .iterm
        XCTAssertEqual(TerminalApp.selected, .iterm)
        AppPaths.defaults.set("not-a-terminal", forKey: TerminalApp.defaultsKey)
        XCTAssertEqual(TerminalApp.selected, .terminal, "a value nobody knows falls back")
    }

    func testAServerShellRunsInTheChosenTerminalWhenTheAppHasOne() throws {
        let model = AppModel()
        let identity = SSHIdentity(id: "i", host: "srv.example.it", port: 22, user: "bot", hostKey: nil, keyInstalledAt: nil, createdAt: Date())
        var ran: [String] = []
        model.terminalRunner = { ran.append($0) }
        try model.openTerminal(identity, command: "uptime")
        XCTAssertEqual(ran.count, 1)
        XCTAssertTrue(ran[0].hasPrefix("'/usr/bin/ssh' '-t'"), ran[0])
        XCTAssertTrue(ran[0].hasSuffix("'--' 'srv.example.it' 'uptime'"), ran[0])
    }
}
