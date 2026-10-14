import AppKit

/// Rasterizes the bundled provider SVGs. `NSImage` does not decode SVG, and
/// these files are one viewBox plus filled paths (Lobe Icons).
enum SVGMark {
    static func render(_ svg: String, side: CGFloat) -> NSImage? {
        let viewBox = viewBox(of: svg) ?? CGRect(x: 0, y: 0, width: 24, height: 24)
        guard viewBox.width > 0, viewBox.height > 0 else { return nil }
        let paths = paths(in: svg)
        guard !paths.isEmpty else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            let sx = rect.width / viewBox.width
            let sy = rect.height / viewBox.height
            ctx.scaleBy(x: sx, y: sy)
            ctx.translateBy(x: -viewBox.minX, y: viewBox.maxY)
            ctx.scaleBy(x: 1, y: -1)
            for path in paths {
                ctx.addPath(path.0)
                ctx.setFillColor(path.1)
                if path.2 { ctx.drawPath(using: .eoFill) } else { ctx.drawPath(using: .fill) }
            }
            ctx.restoreGState()
            return true
        }
        return image
    }

    private static func viewBox(of svg: String) -> CGRect? {
        guard let range = svg.range(of: #"viewBox="([^"]+)""#, options: .regularExpression) else { return nil }
        let raw = svg[range].dropFirst("viewBox=\"".count).dropLast()
        let n = raw.split { $0 == " " || $0 == "," }.compactMap { Double($0) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    private static func paths(in svg: String) -> [(CGPath, CGColor, Bool)] {
        var out: [(CGPath, CGColor, Bool)] = []
        let rootFill = color(named: attribute("fill", in: svg.prefix { $0 != ">" }.description), svg: svg) ?? NSColor.black.cgColor
        let rootEvenOdd = svg.contains("fill-rule=\"evenodd\"") || svg.contains("fill-rule='evenodd'")
        var rest = Substring(svg)
        while let start = rest.range(of: "<path") {
            rest = rest[start.upperBound...]
            guard let end = rest.range(of: ">") else { break }
            let tag = String(rest[..<end.lowerBound])
            rest = rest[end.upperBound...]
            guard let d = attribute("d", in: tag), let path = MarkPath(d).cgPath, !path.isEmpty else { continue }
            let fill = color(named: attribute("fill", in: tag), svg: svg) ?? rootFill
            let evenOdd = tag.contains("evenodd") || rootEvenOdd
            out.append((path, fill, evenOdd))
        }
        return out
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"") ?? tag.range(of: "\(name)='") else { return nil }
        let quote = tag[range].last!
        let value = tag[range.upperBound...]
        guard let close = value.firstIndex(of: quote) else { return nil }
        return String(value[..<close])
    }

    /// A hex colour, or `url(#id)`: a gradient drawn as its first stop, which
    /// at 14–18 pt is indistinguishable from the real thing.
    private static func color(named value: String?, svg: String = "") -> CGColor? {
        guard let value, value != "currentColor", value != "none" else { return nil }
        if value.hasPrefix("url(#") {
            let id = value.dropFirst(5).prefix { $0 != ")" }
            guard let start = svg.range(of: "id=\"\(id)\""),
                  let stop = svg[start.upperBound...].range(of: "stop-color=\"") else { return nil }
            return color(named: String(svg[stop.upperBound...].prefix { $0 != "\"" }))
        }
        var hex = value
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let rgb = Int(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1).cgColor
    }
}

/// SVG path data: M L H V C S Q T A Z, absolute and relative.
private struct MarkPath {
    var cgPath: CGPath?

    init(_ d: String) {
        var s = Scanner(d)
        let path = CGMutablePath()
        var cursor = CGPoint.zero
        var start = CGPoint.zero
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?
        var command: Character = "M"
        while let next = s.peekCommand() ?? (s.hasNumber ? command : nil) {
            command = next
            if s.peekCommand() != nil { s.advance() }
            let relative = command.isLowercase
            switch command.lowercased().first! {
            case "m":
                guard let p = s.point(cursor, relative) else { return }
                path.move(to: p)
                cursor = p
                start = p
                command = relative ? "l" : "L"
            case "l":
                guard let p = s.point(cursor, relative) else { return }
                path.addLine(to: p)
                cursor = p
            case "h":
                guard let x = s.number() else { return }
                cursor.x = relative ? cursor.x + x : x
                path.addLine(to: cursor)
            case "v":
                guard let y = s.number() else { return }
                cursor.y = relative ? cursor.y + y : y
                path.addLine(to: cursor)
            case "c":
                guard let c1 = s.point(cursor, relative), let c2 = s.point(cursor, relative), let p = s.point(cursor, relative) else { return }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastCubic = c2
                cursor = p
            case "s":
                guard let c2 = s.point(cursor, relative), let p = s.point(cursor, relative) else { return }
                let c1 = lastCubic.map { CGPoint(x: 2 * cursor.x - $0.x, y: 2 * cursor.y - $0.y) } ?? cursor
                path.addCurve(to: p, control1: c1, control2: c2)
                lastCubic = c2
                cursor = p
            case "q":
                guard let c = s.point(cursor, relative), let p = s.point(cursor, relative) else { return }
                path.addQuadCurve(to: p, control: c)
                lastQuad = c
                cursor = p
            case "t":
                guard let p = s.point(cursor, relative) else { return }
                let c = lastQuad.map { CGPoint(x: 2 * cursor.x - $0.x, y: 2 * cursor.y - $0.y) } ?? cursor
                path.addQuadCurve(to: p, control: c)
                lastQuad = c
                cursor = p
            case "a":
                guard let rx = s.number(), let ry = s.number(), let angle = s.number(), let large = s.flag(), let sweep = s.flag(),
                      let p = s.point(cursor, relative) else { return }
                Self.arc(path, from: cursor, to: p, rx: abs(rx), ry: abs(ry), rotation: angle, large: large, sweep: sweep)
                cursor = p
            case "z":
                path.closeSubpath()
                cursor = start
            default:
                return
            }
            if !"csqt".contains(command.lowercased()) { lastCubic = nil; lastQuad = nil }
            if !"cs".contains(command.lowercased()) { lastCubic = nil }
            if !"qt".contains(command.lowercased()) { lastQuad = nil }
        }
        cgPath = path
    }

    /// Endpoint-to-center conversion from the SVG spec, then one cubic per quadrant.
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        var rx = rx, ry = ry
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { let scale = sqrt(lambda); rx *= scale; ry *= scale }
        let sign: CGFloat = (large == sweep) ? -1 : 1
        let sq = max(0, (rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1) / (rx * rx * y1 * y1 + ry * ry * x1 * x1))
        let coef = sign * sqrt(sq)
        let cx1 = coef * rx * y1 / ry
        let cy1 = coef * -ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        var theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let steps = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(steps)
        var t = theta
        for _ in 0..<steps {
            let t2 = t + step
            let alpha = sin(step) * (sqrt(4 + 3 * pow(tan(step / 2), 2)) - 1) / 3
            let pA = CGPoint(x: cos(t), y: sin(t))
            let pB = CGPoint(x: cos(t2), y: sin(t2))
            let c1 = CGPoint(x: pA.x - alpha * sin(t), y: pA.y + alpha * cos(t))
            let c2 = CGPoint(x: pB.x + alpha * sin(t2), y: pB.y - alpha * cos(t2))
            func map(_ p: CGPoint) -> CGPoint {
                let x = p.x * rx, y = p.y * ry
                return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
            }
            path.addCurve(to: map(pB), control1: map(c1), control2: map(c2))
            t = t2
        }
    }
}

private struct Scanner {
    var scalars: [Character]
    var index = 0

    init(_ text: String) { scalars = Array(text) }

    var hasNumber: Bool {
        var i = index
        skip(&i)
        guard i < scalars.count else { return false }
        return scalars[i].isNumber || scalars[i] == "-" || scalars[i] == "+" || scalars[i] == "."
    }

    func peekCommand() -> Character? {
        var i = index
        skip(&i)
        guard i < scalars.count else { return nil }
        let c = scalars[i]
        return "MmLlHhVvCcSsQqTtAaZz".contains(c) ? c : nil
    }

    mutating func advance() { index += 1 }

    mutating func number() -> CGFloat? {
        skip(&index)
        guard index < scalars.count else { return nil }
        let start = index
        if scalars[index] == "+" || scalars[index] == "-" { index += 1 }
        var dot = false
        var exp = false
        while index < scalars.count {
            let c = scalars[index]
            if c.isNumber { index += 1; continue }
            if c == ".", !dot, !exp { dot = true; index += 1; continue }
            if (c == "e" || c == "E"), !exp { exp = true; index += 1; if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }; continue }
            break
        }
        guard index > start, let value = Double(String(scalars[start..<index])) else { return nil }
        return CGFloat(value)
    }

    /// Arc flags are one digit and need no separator: `a1 1 0 01.5.5` is
    /// large=0, sweep=1, then x=.5.
    mutating func flag() -> Bool? {
        skip(&index)
        guard index < scalars.count, scalars[index] == "0" || scalars[index] == "1" else { return nil }
        defer { index += 1 }
        return scalars[index] == "1"
    }

    mutating func point(_ cursor: CGPoint, _ relative: Bool) -> CGPoint? {
        guard let x = number(), let y = number() else { return nil }
        return relative ? CGPoint(x: cursor.x + x, y: cursor.y + y) : CGPoint(x: x, y: y)
    }

    private func skip(_ i: inout Int) {
        while i < scalars.count, scalars[i] == " " || scalars[i] == "," || scalars[i] == "\n" || scalars[i] == "\t" { i += 1 }
    }
}
