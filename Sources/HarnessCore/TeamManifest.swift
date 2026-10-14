// Team files: parse an untrusted shared manifest, export the current team
// (`server/team-manifest.ts`).
//
// The Node engine validates with zod and answers with the *first* issue zod
// reports, prefixed by its path ("team.members.0.key is required"). That text
// reaches the user, so the validator below walks the manifest in the same
// order zod does — shape keys in declaration order, array elements before the
// array's own length checks, a string's checks in declaration order — and
// stops at the first problem. Lengths are UTF-16 code units and trimming is
// JavaScript's, like every other Node cap.
import Foundation

public enum TeamManifest {
    public static let format = "swarme.team"
    public static let version = 2
    public static let legacyVersion = 1
    public static let maxMembers = 200
    static let maxMemberName = 100

    static let colors: Set<String> = ["white", "green", "blue", "red", "orange", "purple", "cyan", "pink", "yellow", "teal", "coral"]

    public struct Invalid: Error, Equatable {
        public let message: String
    }

    /// One zod issue: where it is and what it says.
    struct Issue: Error {
        let path: [String]
        let message: String
        var text: String { path.isEmpty ? message : "\(path.joined(separator: ".")) \(message)" }
    }

    /// zod's name for a value it did not expect.
    static func received(_ value: JSON?) -> String {
        switch value {
        case nil: return "undefined"
        case .null?: return "null"
        case .bool?: return "boolean"
        case .number?: return "number"
        case .string?: return "string"
        case .array?: return "array"
        case .object?: return "object"
        }
    }

    static func object(_ value: JSON?, _ path: [String]) throws -> JSONObject {
        guard let object = value?.object else {
            throw Issue(path: path, message: "Invalid input: expected object, received \(received(value))")
        }
        return object
    }

    /// `requiredText(max)`: text, trimmed, non-empty, capped.
    static func required(_ value: JSON?, _ path: [String], max: Int) throws -> String {
        guard let raw = value?.string else { throw Issue(path: path, message: "must be text") }
        let text = JSText.trim(raw)
        if text.isEmpty { throw Issue(path: path, message: "is required") }
        if JSText.length(text) > max { throw Issue(path: path, message: "is too long") }
        return text
    }

    /// `optionalText(max)`: absent, null and blank all read as "not given".
    static func optional(_ value: JSON?, _ path: [String], max: Int) throws -> String? {
        switch value {
        case nil, .null?: return nil
        case let .string(raw)?:
            let text = JSText.trim(raw)
            if text.isEmpty { return nil }
            if JSText.length(text) > max { throw Issue(path: path, message: "is too long") }
            return text
        default: throw Issue(path: path, message: "Invalid input")
        }
    }

    static func member(_ value: JSON, _ path: [String]) throws -> JSONObject {
        let raw = try object(value, path)
        let key = try required(raw["key"], path + ["key"], max: 64)
        if key.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) == nil {
            throw Issue(path: path + ["key"], message: "may only contain lowercase letters, numbers, - and _")
        }
        let name = try required(raw["name"], path + ["name"], max: 100)
        let title = try optional(raw["title"], path + ["title"], max: 200)
        let description = try optional(raw["description"], path + ["description"], max: 8_000)
        let look = try object(raw["appearance"], path + ["appearance"])
        guard let color = look["color"]?.string, colors.contains(color) else {
            throw Issue(path: path + ["appearance", "color"], message: "is not supported")
        }
        var appearance: JSONObject = ["color": .string(color)]
        if let expression = try optional(look["mascotExpression"], path + ["appearance", "mascotExpression"], max: 80) {
            appearance["mascotExpression"] = .string(expression)
        }
        if let silhouette = try optional(look["mascotSilhouette"], path + ["appearance", "mascotSilhouette"], max: 40) {
            appearance["mascotSilhouette"] = .string(silhouette)
        }
        // untrusted markup: the upload route's allowlist, and a refused picture is
        // dropped rather than failing the whole team
        if let svg = try optional(look["mascotAvatarSvg"], path + ["appearance", "mascotAvatarSvg"], max: AvatarSVG.maxBytes),
           case let .ok(clean) = AvatarSVG.validate(svg) {
            appearance["mascotAvatarSvg"] = .string(clean)
        }
        return JSONObject([
            ("key", .string(key)), ("name", .string(name)), ("title", .string(title ?? "")),
            ("description", .string(description ?? "")), ("appearance", .object(appearance)),
        ])
    }

    static func responder(_ value: JSON?, _ path: [String]) throws -> JSONObject {
        let raw = try object(value, path)
        switch raw["kind"]?.string {
        case "member": return ["kind": "member", "member": .string(try required(raw["member"], path + ["member"], max: 64))]
        case "everyone": return ["kind": "everyone"]
        case "mentions": return ["kind": "mentions"]
        default:
            throw Issue(path: path + ["kind"], message: "Invalid discriminator value. Expected 'member' | 'everyone' | 'mentions'")
        }
    }

    /// `parseTeamManifest`: the small, portable subset of a shared file we keep.
    public static func parse(_ value: JSON) throws -> JSONObject {
        do {
            return try parseChecked(value)
        } catch let issue as Issue {
            throw Invalid(message: issue.text)
        }
    }

    static func parseChecked(_ value: JSON) throws -> JSONObject {
        var root = try object(value, [])
        // the format before the rename
        if root["format"]?.string == "openmaus.team" { root["format"] = .string(format) }
        // the discriminator first: a wrong version never reaches the format check
        guard let version = root["version"]?.double, version == Double(legacyVersion) || version == Double(self.version) else {
            throw Invalid(message: "Team file version is not supported")
        }
        guard root["format"]?.string == format else { throw Invalid(message: "This is not a SwarmeBot team file") }
        let rawTeam = try object(root["team"], ["team"])
        let name = try required(rawTeam["name"], ["team", "name"], max: 100)
        let description = try optional(rawTeam["description"], ["team", "description"], max: 2_000)
        guard let rawMembers = rawTeam["members"]?.array else {
            throw Issue(path: ["team", "members"], message: "Invalid input: expected array, received \(received(rawTeam["members"]))")
        }
        let parsed = try rawMembers.enumerated().map { try member($1, ["team", "members", String($0)]) }
        if parsed.isEmpty { throw Issue(path: ["team", "members"], message: "A team needs at least one member") }
        if parsed.count > maxMembers { throw Issue(path: ["team", "members"], message: "A team can have at most \(maxMembers) members") }
        var room: (name: String, bulletin: String?, responder: JSONObject)?
        if version == Double(legacyVersion) {
            let rawRoom = try object(rawTeam["room"], ["team", "room"])
            room = (try required(rawRoom["name"], ["team", "room", "name"], max: 100),
                    try optional(rawRoom["bulletin"], ["team", "room", "bulletin"], max: 12_000),
                    try responder(rawRoom["defaultResponder"], ["team", "room", "defaultResponder"]))
        }

        var seen = Set<String>()
        for member in parsed {
            let key = member["key"]!.string!
            if seen.contains(key) { throw Invalid(message: "Duplicate member key: \(key)") }
            seen.insert(key)
        }
        var team: JSONObject = ["name": .string(name), "members": .array(parsed.map(JSON.object))]
        if let description { team["description"] = .string(description) }
        if let room {
            if room.responder["kind"]?.string == "member", let target = room.responder["member"]?.string, !seen.contains(target) {
                throw Invalid(message: "Unknown default responder: \(target)")
            }
            team["room"] = ["name": .string(room.name), "bulletin": .string(room.bulletin ?? ""), "defaultResponder": .object(room.responder)]
        }
        return JSONObject([("format", .string(format)), ("version", .number(version)), ("team", .object(team))])
    }

    /// `importedMemberProfile`: persona fields only — built field by field, so no
    /// privilege a file claims can reach a bot — and a colliding name numbered
    /// ("Scout 2"), case-insensitively like @mentions. `taken` is lowercased and
    /// grows as names are claimed, so one batch stays unique against itself too.
    public static func importedProfile(_ member: JSONObject, taken: inout Set<String>) -> JSONObject {
        let base = JSText.trim(member["name"]?.string ?? "")
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            let tag = " \(n)"
            let units = Array(base.utf16.prefix(maxMemberName - tag.utf16.count))
            name = trimEnd(String(decoding: units, as: UTF16.self)) + tag
            n += 1
        }
        taken.insert(name.lowercased())
        let look = member["appearance"]?.object ?? JSONObject()
        var profile = JSONObject([
            ("name", .string(name)), ("title", member["title"] ?? ""), ("description", member["description"] ?? ""),
            ("color", look["color"] ?? .null),
        ])
        for key in ["mascotExpression", "mascotSilhouette", "mascotAvatarSvg"] where look[key]?.truthy == true { profile[key] = look[key] }
        return profile
    }

    static func trimEnd(_ text: String) -> String {
        let units = Array(text.utf16)
        guard let last = units.lastIndex(where: { !JSText.isSpace($0) }) else { return "" }
        return String(decoding: units[...last], as: UTF16.self)
    }

    /// `memberKey`: a portable slug of the name, numbered when taken.
    static func memberKey(_ name: String, index: Int, used: inout Set<String>) -> String {
        let folded = String(String.UnicodeScalarView(name.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !(0x300...0x36F).contains($0.value) })).lowercased()
        var slug = ""
        var gap = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                gap = false
            } else if !gap {
                slug += "-"
                gap = true
            }
        }
        if slug.hasPrefix("-") { slug.removeFirst() }
        if slug.hasSuffix("-") { slug.removeLast() }
        var stem = String(slug.prefix(48))
        if stem.isEmpty { stem = "member-\(index + 1)" }
        var key = stem
        var suffix = 2
        while used.contains(key) {
            key = "\(stem)-\(suffix)"
            suffix += 1
        }
        used.insert(key)
        return key
    }

    /// `createTeamManifest`: a shareable definition only — no ids, transcripts,
    /// engines or permissions — run back through `parse` so an export obeys the
    /// same limits as an untrusted file.
    public static func export(name: String, memberIds: [String], bots: [JSONObject]) throws -> JSONObject {
        var used = Set<String>()
        let members: [JSON] = try memberIds.enumerated().map { index, id in
            guard let bot = bots.first(where: { $0["id"]?.string == id }) else { throw Invalid(message: "Team member \(id) no longer exists") }
            var appearance = JSONObject()
            appearance["color"] = bot["color"]
            for key in ["mascotExpression", "mascotSilhouette", "mascotAvatarSvg"] where bot[key]?.truthy == true { appearance[key] = bot[key] }
            var member = JSONObject()
            member["key"] = .string(memberKey(bot["name"]?.string ?? "", index: index, used: &used))
            member["name"] = bot["name"]
            member["title"] = bot["title"]
            member["description"] = bot["description"]
            member["appearance"] = .object(appearance)
            return .object(member)
        }
        let manifest: JSON = ["format": .string(format), "version": .number(Double(version)), "team": ["name": .string(name), "members": .array(members)]]
        return try parse(manifest)
    }
}
