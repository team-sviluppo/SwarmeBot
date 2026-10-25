@testable import CompanionCore
@testable import SwarmeKit
import CryptoKit
import XCTest

/// The app's side of the vault (docs/plans/2026-10-25-vault.md): what it
/// reads from the engine, the local file it copies from, the ssh scripts.
final class VaultClientTests: XCTestCase {
    func testTheEngineAnswerDecodes() throws {
        let json = """
        {"locked":false,"encrypted":true,"secrets":[{"name":"GITHUB_TOKEN","preset":"github","description":"Org","hint":"",
         "createdAt":1,"updatedAt":2,"set":true}],"grants":{"b1":{"secrets":[{"name":"GITHUB_TOKEN","mode":"env"}],"note":"x"}},
         "support":{"safe":["claude"],"env":["claude","piAgent"]}}
        """
        let state = try JSONDecoder().decode(VaultState.self, from: Data(json.utf8))
        XCTAssertEqual(state.secrets.first?.name, "GITHUB_TOKEN")
        XCTAssertEqual(state.grants(botId: "b1").secrets, [VaultGrant(name: "GITHUB_TOKEN", mode: "env")])
        XCTAssertEqual(state.grants(botId: "nobody"), VaultBotGrants())
        XCTAssertEqual(state.support?.env, ["claude", "piAgent"])
        XCTAssertNil(VaultSecretInput(name: "A", preset: "generic", description: "", hint: "", value: nil).body(includingName: false)["value"],
                     "no value: the stored one stays")
    }

    func testTheLocalFileOpensWithTheKeyOnly() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        // the engine's format: AES-GCM, the name as authenticated data
        let sealed = try AES.GCM.seal(Data("ghp_value".utf8), using: SymmetricKey(data: key), authenticating: Data("GH".utf8))
        let object: [String: Any] = ["v": 1, "alg": "AES-GCM", "values": ["GH": sealed.combined!.base64EncodedString()]]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        XCTAssertEqual(LocalVault.value("GH", key: key, file: file), "ghp_value")
        XCTAssertNil(LocalVault.value("GH", key: Data(repeating: 1, count: 32), file: file))
        XCTAssertNil(LocalVault.value("OTHER", key: key, file: file))

        try JSONSerialization.data(withJSONObject: ["v": 1, "values": ["GH": "plain"]]).write(to: file)
        XCTAssertEqual(LocalVault.value("GH", key: nil, file: file), "plain")
    }

    func testTheScriptsTakeTheNameAsAnArgument() {
        let command = RemoteScripts.command(RemoteScripts.vaultSet, ["GITHUB_TOKEN"])
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertTrue(command.hasSuffix(" sh 'GITHUB_TOKEN'"))
        XCTAssertTrue(RemoteScripts.vaultSet.contains(#"swarme-harness" vault set "$1""#))
        XCTAssertTrue(RemoteScripts.vaultGrant.contains(#"vault grant "$1""#))
        XCTAssertTrue(RemoteScripts.vaultUnset.contains(#"vault unset "$1""#))
    }
}
