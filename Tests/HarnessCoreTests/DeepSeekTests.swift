@testable import HarnessCore
@testable import HarnessDrivers
import XCTest

final class DeepSeekProtocolTests: XCTestCase {
    func testModelIdsRoundTripAndRejectForgeries() {
        let id = DSHProtocol.encodeModelId(provider: "deepseek", model: "chat/v3+")
        XCTAssertTrue(id.hasPrefix("dsh:"))
        XCTAssertEqual(DSHProtocol.decodeModelId(id)?.provider, "deepseek")
        XCTAssertEqual(DSHProtocol.decodeModelId(id)?.model, "chat/v3+")
        XCTAssertNil(DSHProtocol.decodeModelId("dsh:ZGVlcHNlZWs=:Y2hhdA"), "padding is not base64url")
        XCTAssertNil(DSHProtocol.decodeModelId("claude-sonnet-5"))
        XCTAssertNil(DSHProtocol.decodeModelId("dsh::Y2hhdA"))
    }

    func testEffortsMapToHarnessLevels() {
        XCTAssertEqual(DSHProtocol.mapEffortLevels(["off", "high", "bogus", "high", "max"]), ["none", "high", "max"])
    }

    func testCatalogFlattensGroupsAndKeepsDiagnostics() {
        let value: JSON = [
            "groups": [
                ["id": "deepseek", "name": "DeepSeek", "models": [
                    ["id": "chat", "name": "Chat", "contextWindow": 64000, "reasoning": ["efforts": [["id": "off", "name": "Off"]]]],
                ]],
                ["id": "bad", "name": "Bad", "models": [["id": "", "name": "x"]]],
            ],
            "failures": [["id": "f", "name": "Failing", "message": "down"]],
        ]
        let result = DSHProtocol.flattenCatalog(value)
        XCTAssertEqual(result.catalog?.options.map(\.label), ["DeepSeek: Chat"])
        XCTAssertEqual(result.catalog?.options.first?.effortLevels, ["none"])
        XCTAssertEqual(result.catalog?.options.first?.contextWindow, 64000)
        XCTAssertEqual(result.catalog?.default, result.catalog?.options.first?.id)
        let empty = DSHProtocol.flattenCatalog(["groups": [], "failures": [["id": "f", "name": "Failing", "message": "down"]]])
        XCTAssertNil(empty.catalog)
        XCTAssertEqual(empty.diagnostics, ["Failing: down"])
    }

    func testStreamFramesMustNameTheirPayload() {
        let good = #"{"type":"server-request","rpcId":"1","method":"approval/requested","payload":{"type":"approval/requested","sessionId":"s"}}"#
        XCTAssertNotNil(DSHProtocol.streamFrame(good, kind: .mux))
        XCTAssertNil(DSHProtocol.streamFrame(good, kind: .host), "a mux type on the host downlink")
        let mismatch = #"{"type":"server-request","rpcId":"1","method":"session/event","payload":{"type":"approval/requested","sessionId":"s"}}"#
        XCTAssertNil(DSHProtocol.streamFrame(mismatch, kind: .mux))
    }

    @MainActor
    func testCursorRecordsPersonaDelivery() {
        XCTAssertEqual(DeepSeekHarnessInstance.decodeCursor("plain-session")?.sessionId, "plain-session")
        XCTAssertEqual(DeepSeekHarnessInstance.decodeCursor("plain-session")?.personaDelivered, false)
        let encoded = "dsh1:" + Data(#"{"version":1,"sessionId":"s-9","personaDelivered":true}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(DeepSeekHarnessInstance.decodeCursor(.string(encoded))?.personaDelivered, true)
        XCTAssertNil(DeepSeekHarnessInstance.decodeCursor("dsh1:not-json"))
    }
}

final class DeepSeekSettingsTests: XCTestCase {
    func testConfigIsStrict() throws {
        let defaults = try DeepSeekHarnessConfig(.null)
        XCTAssertEqual(defaults.baseUrl, "http://127.0.0.1:3080")
        XCTAssertEqual(defaults.transport, "direct")
        XCTAssertEqual(try DeepSeekHarnessConfig(["baseUrl": "https://DSH.example.test:443/"]).baseUrl, "https://dsh.example.test")
        XCTAssertThrowsError(try DeepSeekHarnessConfig(["baseUrl": "https://dsh.example.test/path"]))
        XCTAssertThrowsError(try DeepSeekHarnessConfig(["baseUrl": "https://dsh.example.test?token=x"]))
        XCTAssertThrowsError(try DeepSeekHarnessConfig(["transport": "paired"]))
        XCTAssertThrowsError(try DeepSeekHarnessConfig(["baseUrl": "ftp://dsh.example.test"]))
        XCTAssertThrowsError(try DeepSeekHarnessConfig(["unexpected": true]))
    }

    func testPairingLinkNeedsExactlyOneToken() throws {
        let parsed = try DeepSeekSettings.parsePairingLink("http://100.64.0.2:3080/remote?pair=abc")
        XCTAssertEqual(parsed.baseUrl, "http://100.64.0.2:3080")
        XCTAssertEqual(parsed.token, "abc")
        XCTAssertThrowsError(try DeepSeekSettings.parsePairingLink("http://h/?pair=a&pair=b"))
        XCTAssertThrowsError(try DeepSeekSettings.parsePairingLink("http://user:pw@h/?pair=a"))
        XCTAssertThrowsError(try DeepSeekSettings.parsePairingLink("http://h/#x?pair=a"))
    }

    func testDeviceCookieIsTheOneHttpOnlyPair() throws {
        let lines = DeepSeekSettings.splitSetCookie("theme=dark; Path=/, dsh_device=abc123; Path=/; HttpOnly")
        XCTAssertEqual(try DeepSeekSettings.extractDeviceCookie(lines), "dsh_device=abc123")
        XCTAssertThrowsError(try DeepSeekSettings.extractDeviceCookie(["a=1; HttpOnly", "b=2; HttpOnly"]))
        XCTAssertThrowsError(try DeepSeekSettings.extractDeviceCookie(["a=1"]))
    }

    func testUpsertRequestRequiresCanonicalEffortOrder() throws {
        let ok = try DeepSeekSettings.parseUpsertRequest(["provider": " deepseek ", "model": ["id": "m", "reasoningEfforts": ["off", "high"]]])
        XCTAssertEqual(ok.provider, "deepseek")
        XCTAssertEqual(ok.model.reasoningEfforts, ["off", "high"])
        XCTAssertThrowsError(try DeepSeekSettings.parseUpsertRequest(["provider": "d", "model": ["id": "m", "reasoningEfforts": ["high", "off"]]]))
        XCTAssertThrowsError(try DeepSeekSettings.parseUpsertRequest(["provider": "d", "model": ["id": "m", "contextWindow": 0]]))
    }

    func testMutationPlanOverridesAnInstalledModelAndMaterializesANewOne() throws {
        let catalog: JSON = ["groups": [["id": "d", "name": "D", "models": [["id": "chat", "name": "Chat"]]]], "failures": []]
        let rename = DeepSeekSettings.ModelProfile(id: "chat", name: "Chat 2")
        let override = try DeepSeekSettings.mutationPlan(profile: ["modelOverrides": ["chat": ["maxTokens": 10]]], provider: "d", model: rename, catalog: catalog)
        XCTAssertEqual(override.first?["path"], ["providers", "d", "modelOverrides", "chat"])
        XCTAssertEqual(override.first?["value"], ["maxTokens": 10, "name": "Chat 2"])

        let fresh = DeepSeekSettings.ModelProfile(id: "new", reasoningEfforts: ["off"])
        let ops = try DeepSeekSettings.mutationPlan(profile: ["modelOverrides": ["chat": ["maxTokens": 10]]], provider: "d", model: fresh, catalog: catalog)
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops[0]["value"], [["maxTokens": 10, "id": "chat"], ["id": "new", "reasoningEfforts": ["off": nil]]])
        XCTAssertEqual(ops[1], ["op": "unset", "path": ["providers", "d", "modelOverrides"]])

        XCTAssertThrowsError(try DeepSeekSettings.mutationPlan(profile: ["models": [["id": "x"]], "modelOverrides": ["x": [:]]],
                                                              provider: "d", model: fresh, catalog: catalog))
    }

    func testPublicErrorsNeverCarryHostText() {
        let error = DeepSeekSettingsError(502, "dsh-management-failed", "secret detail from the host")
        XCTAssertEqual(error.publicBody, ["code": "host-unavailable", "error": "DeepSeek Harness is unreachable from this SwarmeBot host."])
    }
}
