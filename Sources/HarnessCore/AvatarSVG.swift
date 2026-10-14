// A bot's own picture: an SVG validated against an allowlist, or a raster
// stored as an attachment (`server/avatar-svg.ts`, the avatar half of
// `server/attachments.ts`).
//
// The markup is painted inline by every client, so it is *validated, not
// cleaned*: anything we would not put in a page is refused outright.
//
// The rules are the Node engine's regular expressions, and they must accept
// and refuse exactly the same strings. ICU is not JavaScript: its `/i` folds
// Unicode (`ſcript` would match `script`), its `\s` lacks `\v` and U+FEFF, and
// its `\b` treats `é` as a word character. So the input is folded to ASCII
// lower case by hand, the patterns spell out JavaScript's `\s` and `\b`, and
// matching stays case-sensitive.
import Foundation

public enum AvatarSVG {
    /// Small on purpose: the picture rides along in every bot frame and has to
    /// fit inside a shared team file.
    public static let maxBytes = 64_000
    /// A raster is decoded at many sizes in many places at once.
    public static let imageMaxBytes = 2 * 1024 * 1024

    /// A picture is cleared with an explicit null: a bot frame is merged into what a
    /// client holds, so an absent key would leave the old picture standing.
    static let fields: Set<String> = ["mascotAvatarSvg", "mascotAvatarImage", "mascotAvatarSheetRow"]

    /// JavaScript's `\s` (WhiteSpace + LineTerminator).
    static let space = #"[\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]"#
    /// JavaScript's `\b` next to an ASCII word character.
    static let wordEnd = "(?![a-z0-9_])"
    static let wordStart = "(?<![a-z0-9_])"

    /// Scripting, anything that reaches the network, any non-fragment reference.
    static let forbidden: [(regex: NSRegularExpression, what: String)] = [
        (#"<\#(space)*(script|foreignobject|iframe|object|embed|audio|video|link|meta|handler)\#(wordEnd)"#, "an element we do not allow"),
        (#"\#(space)on[a-z]+\#(space)*="#, "an event handler"),
        (#"(javascript|vbscript)\#(space)*:"#, "a script URL"),
        (#"<!entity|<!doctype"#, "a document definition"),
        (#"(?:xlink:)?href\#(space)*=\#(space)*["'](?!#)"#, "a reference outside the document"),
        (#"\#(wordStart)src\#(space)*="#, "an external source"),
        (#"url\(\#(space)*["']?(?!#)"#, "a reference outside the document"),
        (#"@import"#, "a stylesheet import"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static let declaration = try! NSRegularExpression(pattern: #"^<\?xml[^>]*\?>\#(space)*"#)
    static let closing = try! NSRegularExpression(pattern: #"</svg>\#(space)*\z"#)

    public enum Verdict: Equatable {
        case ok(String)
        case refused(String)
    }

    /// `validateAvatarSvg`: a plain, self-contained SVG document and nothing else.
    public static func validate(_ input: String) -> Verdict {
        let svg = JSText.trim(input)
        if svg.isEmpty { return .refused("That image is empty") }
        if svg.utf16.count > maxBytes { return .refused("That image is too large to store") }
        // an XML declaration is fine; anything else before the root is not.
        // ASCII folding keeps UTF-16 offsets, so a match on the folded text cuts the original.
        var folded = asciiLowercased(svg) as NSString
        var body = svg as NSString
        if let found = declaration.firstMatch(in: folded as String, range: NSRange(location: 0, length: folded.length)) {
            body = body.substring(from: found.range.length) as NSString
            folded = folded.substring(from: found.range.length) as NSString
        }
        if !body.hasPrefix("<svg") { return .refused("That is not an SVG image") }
        let whole = NSRange(location: 0, length: folded.length)
        if closing.firstMatch(in: folded as String, range: whole) == nil { return .refused("That SVG image is incomplete") }
        for rule in forbidden where rule.regex.firstMatch(in: folded as String, range: whole) != nil {
            return .refused("That SVG image carries \(rule.what)")
        }
        return .ok(body as String)
    }

    /// `/i` on an all-ASCII pattern, without JavaScript's or ICU's Unicode folding.
    static func asciiLowercased(_ text: String) -> String {
        String(decoding: text.utf16.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, as: UTF16.self)
    }

    // MARK: - Raster pictures

    /// `IMAGE_MIMES`: the stored extension; the bytes are not sniffed.
    public static func imageExtension(_ mime: String) -> String? {
        ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"][mime]
    }

    /// `looksLikeSpriteSheet`: the pixels divide into the 9×8 grid and the cells
    /// are roughly portrait frames (1440×1080 divides too, but its cells are a photo's).
    public static func looksLikeSpriteSheet(_ bytes: Data) -> Bool {
        guard let (width, height) = imageDimensions(bytes), width > 0, height > 0 else { return false }
        guard width % 8 == 0, height % 9 == 0 else { return false }
        let aspect = Double(width) / 8 / (Double(height) / 9)
        return aspect >= 0.7 && aspect <= 1.4
    }

    /// `imageDimensions`: the pixel size from the header alone, nil when unrecognised.
    static func imageDimensions(_ data: Data) -> (Int, Int)? {
        let b = [UInt8](data)
        func be16(_ at: Int) -> Int { Int(b[at]) << 8 | Int(b[at + 1]) }
        func le16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func be32(_ at: Int) -> Int { be16(at) << 16 | be16(at + 2) }
        func le(_ at: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(b[at + $1]) << (8 * $1) } }
        func ascii(_ from: Int, _ to: Int) -> String { String(decoding: b[from..<to], as: UTF8.self) }
        if b.count >= 24, b[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            guard ascii(12, 16) == "IHDR" else { return nil }
            return (be32(16), be32(20))
        }
        if b.count >= 10, ascii(0, 3) == "GIF" { return (le16(6), le16(8)) }
        if b.count >= 30, ascii(0, 4) == "RIFF", ascii(8, 12) == "WEBP" {
            switch ascii(12, 16) {
            case "VP8 ": return (le16(26) & 0x3FFF, le16(28) & 0x3FFF)
            case "VP8L":
                // readUInt32LE then `>>`: JavaScript shifts a signed 32-bit value
                let bits = Int(Int32(truncatingIfNeeded: le(21, 4)))
                return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
            case "VP8X": return ((le(24, 3) & 0xFFFFFF) + 1, (le(27, 3) & 0xFFFFFF) + 1)
            default: return nil
            }
        }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 {
            var at = 2
            while at + 9 < b.count {
                if b[at] != 0xFF { at += 1; continue }
                let marker = b[at + 1]
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { at += 2; continue }
                let length = be16(at + 2)
                // SOF0..SOF15, minus DHT/JPG/DAC interleaved in that range
                if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) { return (be16(at + 7), be16(at + 5)) }
                at += 2 + length
            }
            return nil
        }
        return nil
    }
}

/// JavaScript string semantics the ported validators depend on.
enum JSText {
    /// `String.prototype.trim`: WhiteSpace and LineTerminator, U+FEFF included and U+0085 not —
    /// unlike Foundation's `.whitespacesAndNewlines`.
    static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }

    static func trim(_ text: String) -> String {
        let units = Array(text.utf16)
        guard let start = units.firstIndex(where: { !isSpace($0) }) else { return "" }
        let end = units.lastIndex(where: { !isSpace($0) })!
        if start == 0, end == units.count - 1 { return text }
        return String(decoding: units[start...end], as: UTF16.self)
    }

    /// `.length`: UTF-16 code units, which is what every Node length cap counts.
    static func length(_ text: String) -> Int { text.utf16.count }
}

/// `POST /api/bots/:id/avatar/upload`: raw bytes, stored the way the content
/// type says — markup on the bot, or a raster served by name from the
/// attachments. Setting one clears the other, so a bot never carries two
/// pictures and a guess about which wins.
@MainActor
enum AvatarRoutes {
    static func handle(_ r: HTTPRequest, harness: Harness) -> RouteResult? {
        guard r.method == "POST", let range = r.path.range(of: #"^/api/bots/[\w-]+/avatar/upload$"#, options: .regularExpression) else { return nil }
        let id = String(r.path[range].dropFirst("/api/bots/".count).dropLast("/avatar/upload".count))
        func fail(_ status: Int, _ message: String) -> RouteResult { .response(.error(status, message)) }
        let store = harness.store
        guard store.bot(id) != nil else { return fail(404, "no such bot") }
        let mime = r.contentType
        if mime == "image/svg+xml" {
            if r.body.count > AvatarSVG.maxBytes { return fail(413, "image exceeds \(AvatarSVG.maxBytes) bytes") }
            switch AvatarSVG.validate(String(decoding: r.body, as: UTF8.self)) {
            case let .refused(error): return fail(400, error)
            case let .ok(svg):
                // real nulls, as Node's Object.assign writes them
                let bot = store.patchBot(id, ["mascotAvatarSvg": .string(svg), "mascotAvatarImage": .null, "mascotAvatarSheetRow": .null], keepingNulls: AvatarSVG.fields)!
                return .response(.json(200, ["bot": .object(harness.wireBot(bot))]))
            }
        }
        guard let ext = AvatarSVG.imageExtension(mime) else { return fail(400, "content-type must be an image type") }
        if r.body.count > AvatarSVG.imageMaxBytes { return fail(413, "image exceeds \(AvatarSVG.imageMaxBytes) bytes") }
        if r.body.isEmpty { return fail(400, "empty image") }
        let name = "\(newId()).\(ext)"
        do {
            try FileManager.default.createDirectory(at: harness.paths.attachments, withIntermediateDirectories: true)
            try FileIO.writeAtomic(r.body, to: harness.paths.attachments.appendingPathComponent(name))
        } catch {
            return fail(500, error.localizedDescription)
        }
        // a still photo and a 9×8 sprite sheet share the route: the picture's shape decides
        let bot = store.patchBot(id, [
            "mascotAvatarImage": .string(name), "mascotAvatarSvg": .null,
            "mascotAvatarSheetRow": AvatarSVG.looksLikeSpriteSheet(r.body) ? 0 : .null,
        ], keepingNulls: AvatarSVG.fields)!
        return .response(.json(200, ["bot": .object(harness.wireBot(bot))]))
    }
}
