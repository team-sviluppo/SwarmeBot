@testable import HarnessCore
import XCTest

/// The Node engine's own answers (`Tests/Fixtures/team-avatar.mts`): every
/// input must be accepted or refused the same way, with the same text and,
/// when accepted, the same bytes.
private let fixtures: JSON = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/team-avatar.json")
    return try! JSON.parse(try! Data(contentsOf: url))
}()

private func cases(_ name: String) -> [JSONObject] { fixtures[name]?.array?.compactMap(\.object) ?? [] }

/// Shaped like the real thing: metadata, a mask, a fragment reference (avatar-svg.test.ts).
private let avatar = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 135 135" fill="none">
<metadata xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:RDF /></metadata>
<mask id="viewboxMask"><rect width="135" height="135" fill="#fff" /></mask>
<g mask="url(#viewboxMask)"><use xlink:href="#part" /><path id="part" d="M0 0h1v1H0z" /></g>
</svg>
"""

final class AvatarSVGTests: XCTestCase {
    func testAcceptsAPlainSelfContainedSVG() {
        // the XML declaration is dropped; the document itself is kept verbatim
        XCTAssertEqual(AvatarSVG.validate("<?xml version=\"1.0\"?>\n\(avatar)"), .ok(avatar))
    }

    func testRefusesMarkupItWouldNotPutInAPage() {
        let hostile = [
            avatar.replacingOccurrences(of: "<mask", with: "<script>fetch(\"//x\")</script><mask"),
            avatar.replacingOccurrences(of: "<svg ", with: "<svg onload=\"alert(1)\" "),
            avatar.replacingOccurrences(of: "<mask", with: "<foreignObject><b>hi</b></foreignObject><mask"),
            avatar.replacingOccurrences(of: "xlink:href=\"#part\"", with: "xlink:href=\"https://evil.com/x.svg\""),
            avatar.replacingOccurrences(of: "url(#viewboxMask)", with: "url(https://evil.com/x.svg)"),
            avatar.replacingOccurrences(of: "<metadata", with: "<image src=\"https://evil.com/x.png\" /><metadata"),
            "<!DOCTYPE svg [<!ENTITY x \"y\">]>\(avatar)",
            "<html><body>nope</body></html>",
            "",
            String(avatar.prefix(200)),
        ]
        for svg in hostile {
            guard case .refused = AvatarSVG.validate(svg) else { return XCTFail(String(svg.prefix(60))) }
        }
    }

    func testMatchesTheNodeEngineOnEveryRule() {
        let all = cases("svgs")
        XCTAssertGreaterThan(all.count, 40)
        for c in all {
            let input = c["input"]!.string!
            let expected: AvatarSVG.Verdict = c["ok"]?.string.map(AvatarSVG.Verdict.ok) ?? .refused(c["error"]!.string!)
            XCTAssertEqual(AvatarSVG.validate(input), expected, String(input.prefix(80)).debugDescription)
        }
    }

    func testSizeIsCountedInUTF16AfterTrimming() {
        let filler = String(repeating: "x", count: 64_000 - 11)
        XCTAssertEqual(AvatarSVG.validate(" <svg>\(filler)</svg> "), .ok("<svg>\(filler)</svg>"))
        XCTAssertEqual(AvatarSVG.validate("<svg>\(filler)x</svg>"), .refused("That image is too large to store"))
        // two UTF-8 bytes, one UTF-16 unit: still fits
        let accents = String(repeating: "é", count: 64_000 - 11)
        XCTAssertEqual(AvatarSVG.validate("<svg>\(accents)</svg>"), .ok("<svg>\(accents)</svg>"))
    }

    /// attachments.test.ts: a 9×8 grid of roughly square frames, read from the header.
    func testSpriteSheetsAreToldFromPhotos() {
        func png(_ width: UInt32, _ height: UInt32) -> Data {
            var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
            for value in [width, height] { bytes += withUnsafeBytes(of: value.bigEndian, Array.init) }
            return Data(bytes + [8, 6, 0, 0, 0])
        }
        XCTAssertTrue(AvatarSVG.looksLikeSpriteSheet(png(8 * 40, 9 * 40)))
        XCTAssertTrue(AvatarSVG.looksLikeSpriteSheet(png(8, 9)))
        XCTAssertTrue(AvatarSVG.looksLikeSpriteSheet(png(1536, 1872)))
        XCTAssertFalse(AvatarSVG.looksLikeSpriteSheet(png(512, 512)))
        XCTAssertFalse(AvatarSVG.looksLikeSpriteSheet(png(1200, 800)))
        XCTAssertFalse(AvatarSVG.looksLikeSpriteSheet(png(320, 359)))
        XCTAssertFalse(AvatarSVG.looksLikeSpriteSheet(png(1440, 1080)))
        XCTAssertFalse(AvatarSVG.looksLikeSpriteSheet(Data("nope".utf8)))
    }
}

final class TeamManifestTests: XCTestCase {
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><rect width="8" height="8"/></svg>"#

    func parse(_ text: String) throws -> JSONObject { try TeamManifest.parse(try JSON.parse(text)) }

    func error(_ text: String) -> String? {
        do { _ = try parse(text); return nil } catch { return (error as? TeamManifest.Invalid)?.message }
    }

    func testMatchesTheNodeEngineOnEveryInput() throws {
        let all = cases("manifests")
        XCTAssertGreaterThan(all.count, 60)
        for c in all {
            let input = c["input"]!.string!
            if let expected = c["ok"]?.string {
                XCTAssertEqual(try parse(input).asJSON.serialized(), expected, String(input.prefix(120)))
            } else {
                XCTAssertEqual(error(input), c["error"]?.string, String(input.prefix(120)))
            }
        }
    }

    func testExportsPortableMemberKeysWithoutRoomOrRuntimeState() throws {
        let bots: [JSONObject] = [
            ["id": "bot-a", "name": "Mira", "title": "Lead", "description": "Coordinates the work", "color": "purple",
             "mascotExpression": "focused", "threadId": "thread-1", "modelSelection": ["instanceId": "x"]],
            ["id": "bot-b", "name": "Mira", "title": "Researcher", "description": "Finds evidence", "color": "cyan"],
        ]
        let manifest = try TeamManifest.export(name: "Launch Crew", memberIds: ["bot-a", "bot-b"], bots: bots)
        XCTAssertEqual(manifest["format"], "swarme.team")
        XCTAssertEqual(manifest["version"], 2)
        XCTAssertEqual(manifest["team"]?["members"]?.array?.map { $0["key"] }, ["mira", "mira-2"])
        XCTAssertNil(manifest["team"]?["room"])
        XCTAssertNil(manifest.asJSON.serialized().range(of: "bot-a|bot-b|thread|model|permission|message", options: [.regularExpression, .caseInsensitive]))
    }

    func testCarriesShapeAndPictureThroughExportAndImport() throws {
        let manifest = try TeamManifest.export(name: "Shapes", memberIds: ["bot-a"], bots: [
            ["id": "bot-a", "name": "Mira", "title": "Lead", "description": "Coordinates the work", "color": "purple",
             "mascotSilhouette": "hexagon", "mascotAvatarSvg": .string(svg)],
        ])
        let member = manifest["team"]!["members"]!.array![0]
        XCTAssertEqual(member["appearance"]?["mascotSilhouette"], "hexagon")
        var taken = Set<String>()
        let profile = TeamManifest.importedProfile(try TeamManifest.parse(.object(manifest))["team"]!["members"]!.array![0].object!, taken: &taken)
        XCTAssertEqual(profile["mascotSilhouette"], "hexagon")
        XCTAssertEqual(profile["mascotAvatarSvg"]?.string, svg)
    }

    func testKeysAreFoldedSlugsNumberedWhenTaken() throws {
        let bots: [JSONObject] = [
            ["id": "1", "name": "Zoë Ñandú", "color": "purple"], ["id": "2", "name": "Zoë Ñandú", "color": "white"],
            ["id": "3", "name": "!!!", "title": nil, "color": "cyan"],
            ["id": "4", "name": .string("İstanbul Kelvin\u{212A} " + String(repeating: "x", count: 60)), "color": "red"],
        ]
        let manifest = try TeamManifest.export(name: "S", memberIds: ["1", "2", "3", "4"], bots: bots)
        XCTAssertEqual(manifest["team"]?["members"]?.array?.map { $0["key"] },
                       ["zoe-nandu", "zoe-nandu-2", "member-3", "istanbul-kelvink-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"])
    }

    func testRefusesToExportValuesTheImporterWouldReject() {
        let one: [JSONObject] = [["id": "one", "name": "One", "title": "", "description": "", "color": "blue"]]
        XCTAssertThrowsError(try TeamManifest.export(name: String(repeating: "x", count: 101), memberIds: ["one"], bots: one)) {
            XCTAssertEqual(($0 as? TeamManifest.Invalid)?.message, "team.name is too long")
        }
        let many: [JSONObject] = (0..<201).map { ["id": .string("bot-\($0)"), "name": .string("Bot \($0)"), "color": "green"] }
        XCTAssertThrowsError(try TeamManifest.export(name: "Too many", memberIds: many.map { $0["id"]!.string! }, bots: many)) {
            XCTAssertEqual(($0 as? TeamManifest.Invalid)?.message, "team.members A team can have at most 200 members")
        }
        XCTAssertThrowsError(try TeamManifest.export(name: "Gone", memberIds: ["ghost"], bots: one)) {
            XCTAssertEqual(($0 as? TeamManifest.Invalid)?.message, "Team member ghost no longer exists")
        }
    }

    func testMemberLengthsAreCheckedBeforeTheArrayLength() {
        func team(_ firstKey: String) -> String {
            let members = (0..<201).map { #"{"key":"\#($0 == 0 ? firstKey : "k\($0)")","name":"A","appearance":{"color":"red"}}"# }
            return #"{"format":"swarme.team","version":2,"team":{"name":"T","members":[\#(members.joined(separator: ","))]}}"#
        }
        XCTAssertEqual(error(team("k0")), "team.members A team can have at most 200 members")
        XCTAssertEqual(error(team("BAD")), "team.members.0.key may only contain lowercase letters, numbers, - and _")
    }

    func testImportProfilesArePersonaOnlyAndNumberCollidingNames() {
        let member: JSONObject = ["key": "mira", "name": "Mira", "title": "Lead", "description": "Coordinates",
                                  "appearance": ["color": "purple", "mascotExpression": "focused"], "autoApprove": true]
        var taken: Set<String> = ["mira"]
        XCTAssertEqual(JSON.object(TeamManifest.importedProfile(member, taken: &taken)).serialized(),
                       #"{"name":"Mira 2","title":"Lead","description":"Coordinates","color":"purple","mascotExpression":"focused"}"#)
        var upper = member
        upper["name"] = "MIRA"
        XCTAssertEqual(TeamManifest.importedProfile(upper, taken: &taken)["name"], "MIRA 3")
        var free = member
        free["name"] = "Scout"
        XCTAssertEqual(TeamManifest.importedProfile(free, taken: &taken)["name"], "Scout")
        // suffixing a max-length name trims the stem instead of busting the cap
        var long = member
        long["name"] = .string(String(repeating: "N", count: 100))
        var full: Set<String> = [String(repeating: "n", count: 100)]
        XCTAssertEqual(TeamManifest.importedProfile(long, taken: &full)["name"]?.string, String(repeating: "N", count: 98) + " 2")
    }
}

final class TeamLibraryTests: XCTestCase {
    override func tearDown() { TeamLibrary.fetch = TeamLibrary.fetchJSON }

    func testCatalogsMatchTheNodeEngine() throws {
        for c in cases("catalogs") {
            let input = try JSON.parse(c["input"]!.string!)
            do {
                let parsed = try TeamLibrary.parseCatalog(input)
                XCTAssertEqual(JSON.object(parsed).serialized(), c["ok"]?.string, c["input"]!.string!)
            } catch {
                XCTAssertEqual((error as? TeamLibrary.Failure)?.message, c["error"]?.string, c["input"]!.string!)
            }
        }
    }

    func testGithubLinksMatchTheNodeEngine() {
        for c in cases("urls") {
            let input = c["input"]!.string!
            do {
                let urls = try TeamLibrary.githubManifestURLs(input)
                XCTAssertEqual(JSON.strings(urls).serialized(), c["ok"]?.string, input)
            } catch {
                XCTAssertEqual((error as? TeamLibrary.Failure)?.message, c["error"]?.string, input)
            }
        }
    }

    let manifest: JSON = ["format": "swarme.team", "version": 2, "team": ["name": "Engineering", "members": [
        ["key": "lead", "name": "Ada", "title": "Tech Lead", "description": "Coordinates the work", "appearance": ["color": "purple"]],
    ]]]

    @MainActor
    func testLoadsOnlyTheManifestTheTrustedCatalogSelects() async throws {
        let catalog = cases("catalogs")[0]["input"]!.string!
        var calls: [String] = []
        let manifest = self.manifest
        TeamLibrary.fetch = { url, _ in
            calls.append(url)
            if url == TeamLibrary.catalogURL { return try JSON.parse(catalog) }
            if url == "\(TeamLibrary.rawRoot)/teams/engineering/team.mausteam.json" { return manifest }
            throw TeamLibrary.Failure(message: "GitHub returned HTTP 404", status: 404)
        }
        let loaded = try await TeamLibrary.fetchLibraryTeam("engineering")
        XCTAssertEqual(loaded["team"]?["name"], "Engineering")
        XCTAssertEqual(calls.count, 2)
        do { _ = try await TeamLibrary.fetchLibraryTeam("missing"); XCTFail() } catch {
            XCTAssertEqual((error as? TeamLibrary.Failure)?.status, 404)
        }
    }

    @MainActor
    func testFallsBackFromMainToMasterForARepositoryLink() async throws {
        var calls = 0
        let manifest = self.manifest
        TeamLibrary.fetch = { url, _ in
            calls += 1
            if url.contains("/main/") { throw TeamLibrary.Failure(message: "GitHub returned HTTP 404", status: 404) }
            return manifest
        }
        let loaded = try await TeamLibrary.fetchGithubTeam("https://github.com/acme/team")
        XCTAssertEqual(loaded["team"]?["members"]?.array?.first?["name"], "Ada")
        XCTAssertEqual(calls, 2)
    }
}

private extension JSONObject {
    var asJSON: JSON { .object(self) }
}
