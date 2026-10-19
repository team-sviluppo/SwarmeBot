// The mascot's types: what `SwarmeFaceData.swift` fills in, the silhouette
// registry, the palette rules, and an SVG path parser for the "!" and "?"
// glyphs.
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct SwarmeBodyMotion {
    var bob: (CGFloat, CGFloat)? = nil
    var sway: (CGFloat, CGFloat)? = nil
    var pulse: (CGFloat, CGFloat)? = nil
    var circle: (CGFloat, CGFloat)? = nil
    var jitter: (CGFloat, CGFloat)? = nil
    var tilt: CGFloat? = nil
    var squash: CGFloat? = nil
    var enter: (CGFloat, CGFloat)? = nil
    var settle: CGFloat? = nil
}

struct SwarmeConfettiSpec { let count: Int; let period: CGFloat; let life: CGFloat; let origin: CGFloat; let spread: CGFloat }
struct SwarmeTrailSpec { let count: Int; let period: CGFloat; let radius: CGFloat }
struct SwarmeGlyphSpec {
    enum Kind { case bang, query }
    let kind: Kind
    let period: CGFloat
    let hold: CGFloat
}
struct SwarmeEffects {
    var confetti: SwarmeConfettiSpec? = nil
    var trails: SwarmeTrailSpec? = nil
    var glyph: SwarmeGlyphSpec? = nil
}

struct SwarmeSilhouetteSpec {
    let id: String
    /// The outline in face-box units, and where the face sits on it.
    let build: () -> (path: Path, anchor: (x: CGFloat, y: CGFloat, scale: CGFloat))
}

/// A body shape, built once in the face box.
final class SwarmeSilhouette {
    let id: String
    /// The silhouette in face-box units (fit already applied).
    let path: Path
    let bounds: CGRect
    let anchor: (x: CGFloat, y: CGFloat, scale: CGFloat)

    private init(_ spec: SwarmeSilhouetteSpec) {
        id = spec.id
        let built = spec.build()
        path = built.path
        bounds = built.path.boundingRect
        anchor = built.anchor
    }

    /// Built lazily, each at most once: a sidebar is hundreds of avatars.
    private static let registry: [String: SwarmeSilhouette] = {
        var out: [String: SwarmeSilhouette] = [:]
        for spec in SwarmeSilhouetteData.all { out[spec.id] = SwarmeSilhouette(spec) }
        return out
    }()

    static let ids: [String] = SwarmeSilhouetteData.all.map(\.id)

    /// Retired ids resolve to their replacement, unknown or absent ones to the default (`circle`).
    static func named(_ id: String?) -> SwarmeSilhouette {
        let id = id.map { SwarmeSilhouetteData.aliases[$0] ?? $0 }
        if let id, let known = registry[id] { return known }
        return registry[SwarmeSilhouetteData.defaultId]!
    }

    /// A 15-unit margin around the face box: room for the body to bob and sway.
    static let margin: CGFloat = 15

    /// The transform that puts the margined face box into `rect`.
    static func fit(_ rect: CGRect) -> CGAffineTransform {
        let side = SwarmeFaceData.faceBox + margin * 2
        let k = min(rect.width, rect.height) / side
        return CGAffineTransform(translationX: margin, y: margin)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(
                translationX: rect.minX + (rect.width - side * k) / 2,
                y: rect.minY + (rect.height - side * k) / 2
            ))
    }
}

enum SwarmePalette {
    static func hex(_ name: String) -> String {
        SwarmePaletteData.hex[name] ?? SwarmePaletteData.hex["green"]!
    }

    /// Unknown colours fall back to green.
    static func color(_ name: String) -> Color { Color(hex: hex(name)) }

    /// Dark eyes on every body, white only on a very dark one.
    static func eyeInk(_ name: String) -> Color {
        let v = rgb(hex(name))
        let luma = (0.2126 * v.r + 0.7152 * v.g + 0.0722 * v.b) / 255
        return luma < 0.3 ? .white : Color(hex: "#17171C")
    }

    private static func rgb(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        return (CGFloat((value >> 16) & 0xFF), CGFloat((value >> 8) & 0xFF), CGFloat(value & 0xFF))
    }
}

/// SVG path data → `Path`. All commands, absolute and relative:
/// M L H V C S Q T A Z.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var scanner = Tokens(Array(d.utf8))
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0
        var command: UInt8 = 0

        while let next = scanner.nextCommandOrNumber() {
            switch next {
            case let .command(c):
                command = c
                if c == UInt8(ascii: "Z") || c == UInt8(ascii: "z") {
                    path.closeSubpath()
                    current = start
                    lastControl = nil
                    lastCommand = c
                    continue
                }
            case .number:
                scanner.rewind()
                if command == 0 { return path }
            }
            let relative = command >= UInt8(ascii: "a")
            let upper = relative ? command - 32 : command
            func pt() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch upper {
            case UInt8(ascii: "M"):
                guard let p = pt() else { return path }
                path.move(to: p); current = p; start = p; lastControl = nil
                // implicit lineto after the first pair
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "L"):
                guard let p = pt() else { return path }
                path.addLine(to: p); current = p; lastControl = nil
            case UInt8(ascii: "H"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "V"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "C"):
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2
            case UInt8(ascii: "S"):
                let wasCubic = [UInt8(ascii: "C"), UInt8(ascii: "S")].contains(lastCommand & ~0x20)
                let c1 = wasCubic && lastControl != nil ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                guard let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; lastControl = c2
            case UInt8(ascii: "Q"):
                guard let c = pt(), let p = pt() else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p; lastControl = c
            case UInt8(ascii: "T"):
                let wasQuad = [UInt8(ascii: "Q"), UInt8(ascii: "T")].contains(lastCommand & ~0x20)
                let c = wasQuad && lastControl != nil ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                guard let p = pt() else { return path }
                path.addQuadCurve(to: p, control: c)
                current = p; lastControl = c
            case UInt8(ascii: "A"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = pt() else { return path }
                addArc(to: &path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = p; lastControl = nil
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    /// SVG endpoint arc → centre parameterisation → cubic segments (F.6).
    static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                       rotation: CGFloat, large: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry
        let cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosP - ry * sin(t) * sinP, y: cy + rx * cos(t) * sinP + ry * sin(t) * cosP)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosP - ry * cos(t) * sinP, y: -rx * sin(t) * sinP + ry * cos(t) * cosP)
        }
        var t = theta1
        for i in 0..<segments {
            let t2 = t + step
            let a = point(t), b = i == segments - 1 ? p1 : point(t2)
            let da = derivative(t), db = derivative(t2)
            path.addCurve(
                to: b,
                control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y)
            )
            t = t2
        }
    }

    private enum Token { case command(UInt8), number }

    private struct Tokens {
        let bytes: [UInt8]
        var i = 0
        var mark = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skip() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 10 || bytes[i] == 9 || bytes[i] == 13 { i += 1 }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skip()
            mark = i
            guard i < bytes.count else { return nil }
            let c = bytes[i]
            if (c >= 65 && c <= 90 || c >= 97 && c <= 122) && c != UInt8(ascii: "e") && c != UInt8(ascii: "E") {
                i += 1
                return .command(c)
            }
            return .number
        }

        mutating func rewind() { i = mark }

        /// Arc flags may be written without separators ("a1 1 0 011 1").
        mutating func flag() -> Bool? {
            skip()
            guard i < bytes.count else { return nil }
            let c = bytes[i]
            guard c == 48 || c == 49 else { return number().map { $0 != 0 } }
            i += 1
            return c == 49
        }

        mutating func number() -> CGFloat? {
            skip()
            let begin = i
            if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
            var seenDot = false, digits = false
            while i < bytes.count {
                let c = bytes[i]
                if c >= 48 && c <= 57 { digits = true; i += 1 }
                else if c == 46 && !seenDot { seenDot = true; i += 1 }
                else if (c == 101 || c == 69) && digits {
                    i += 1
                    if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
                } else { break }
            }
            guard digits, let s = String(bytes: bytes[begin..<i], encoding: .ascii), let v = Double(s) else {
                i = begin
                return nil
            }
            return CGFloat(v)
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
