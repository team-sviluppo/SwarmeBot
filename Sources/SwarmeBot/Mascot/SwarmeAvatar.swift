// The bot's face: two eyes on a flat body.
//
// A state picks a pool of expressions and drifts through them on its
// cadence, a critically damped spring morphs the eyes between them, it
// blinks on its own rhythm, the body bobs / sways / breathes / jitters per
// state, and states carry effects: ribbons behind the body, confetti in
// front, or a "!"/"?" glyph standing in for it. One-shot motion beats borrow
// a state for 1.4 s, blink or spin the eyes around the head's sphere; the
// eyes follow the pointer. All numbers are in `SwarmeFaceData.swift`.
import SwiftUI

/// One-shot beats the app plays on events.
enum MascotMotion: String {
    case arrive, `switch`, customize, alert, thinking, working, launch, success, celebrate, blink, surprise, failure

    /// The state, blink and spin (ms) each beat shows.
    var face: (state: SwarmeState?, blink: Bool, spin: CGFloat?) {
        switch self {
        case .arrive: return (.spawning, false, 900)
        case .switch: return (.waking, false, 620)
        case .customize: return (.proud, true, nil)
        case .alert: return (.alerting, false, nil)
        case .thinking: return (.thinking, false, nil)
        case .working: return (.working, false, nil)
        case .launch: return (.loading, false, nil)
        case .success: return (.happy, true, nil)
        case .celebrate: return (.celebrate, false, 700)
        case .blink: return (nil, true, nil)
        case .surprise: return (.surprised, true, nil)
        case .failure: return (.sad, false, nil)
        }
    }
}

struct MascotBeatEvent: Equatable {
    let motion: MascotMotion
    let key: Int
}

/// How long a beat holds its state before the bot's own returns.
private let motionFaceSeconds: TimeInterval = 1.4

struct SwarmeAvatar: View {
    let color: String
    var size: CGFloat = 52
    var state: SwarmeState = .idle
    /// A `SwarmeSilhouetteData` id; unknown or nil is the default `circle`.
    var silhouette: String? = nil
    /// A request to animate, still subject to the on-screen frame budget.
    var animated: Bool = true
    /// Claim a frame slot ahead of decorative mascots (selected, busy).
    var priority: Bool = false
    var beat: MascotBeatEvent? = nil
    var trackPointer: Bool = true
    var effects: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = SwarmeFaceEngine()
    @State private var slot = AvatarFrameSlot()
    @State private var granted = false
    @State private var beatLive = false

    var body: some View {
        let wants = animated && !reduceMotion
        let live = (wants && granted) || (beatLive && !reduceMotion)
        let shape = SwarmeSilhouette.named(silhouette)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { timeline in
            Canvas { context, canvasSize in
                engine.request(state, now: timeline.date)
                if live { engine.step(now: timeline.date) } else { engine.settle() }
                engine.draw(
                    in: &context, size: canvasSize, color: color, silhouette: shape,
                    live: live, effects: effects && !reduceMotion, at: timeline.date
                )
            }
        }
        .frame(width: size, height: size)
        .onContinuousHover { phase in
            guard trackPointer, live else { return }
            switch phase {
            case let .active(location):
                engine.pointerGaze = CGPoint(
                    x: min(max(location.x / size * 2 - 1, -1), 1),
                    y: min(max(location.y / size * 2 - 1, -1), 1)
                )
            case .ended:
                engine.pointerGaze = .zero
            }
        }
        .onAppear { if wants { slot.request(priority: priority) { granted = $0 } } }
        .onDisappear { slot.release(); granted = false }
        .onChange(of: wants) { _, now in
            if now { slot.request(priority: priority) { granted = $0 } } else { slot.release(); granted = false }
        }
        .onChange(of: priority) { _, now in slot.setPriority(now) }
        .onChange(of: beat) { _, event in
            guard let event, !reduceMotion else { return }
            engine.play(event.motion, now: Date())
            beatLive = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(motionFaceSeconds + 0.1))
                beatLive = false
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Frame budget

/// At most 12 mascots animate at once; priority
/// claims (selected row, busy bot, a beat) are granted first. Visibility is
/// the lazy stacks' appear/disappear.
@MainActor
final class AvatarFrameBudget {
    static let shared = AvatarFrameBudget(limit: 12)
    let limit: Int

    final class Claim {
        var priority: Bool
        var granted = false
        let onChange: (Bool) -> Void
        init(priority: Bool, onChange: @escaping (Bool) -> Void) { self.priority = priority; self.onChange = onChange }
    }

    private var claims: [Claim] = []
    private var scheduled = false

    init(limit: Int) { self.limit = limit }

    func add(_ claim: Claim) { claims.append(claim); schedule() }
    func remove(_ claim: Claim) { claims.removeAll { $0 === claim }; schedule() }
    func changed() { schedule() }

    /// Coalesced: a list appearing is dozens of claims in one pass.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.recompute()
        }
    }

    private func recompute() {
        var left = limit
        var grant = Set<ObjectIdentifier>()
        for claim in claims where claim.priority && left > 0 { grant.insert(ObjectIdentifier(claim)); left -= 1 }
        for claim in claims where !claim.priority && left > 0 { grant.insert(ObjectIdentifier(claim)); left -= 1 }
        for claim in claims {
            let next = grant.contains(ObjectIdentifier(claim))
            if next != claim.granted {
                claim.granted = next
                claim.onChange(next)
            }
        }
    }
}

@MainActor
final class AvatarFrameSlot {
    private var claim: AvatarFrameBudget.Claim?

    func request(priority: Bool, onChange: @escaping (Bool) -> Void) {
        release()
        let claim = AvatarFrameBudget.Claim(priority: priority, onChange: onChange)
        self.claim = claim
        AvatarFrameBudget.shared.add(claim)
    }

    func setPriority(_ priority: Bool) {
        guard let claim, claim.priority != priority else { return }
        claim.priority = priority
        AvatarFrameBudget.shared.changed()
    }

    func release() {
        if let claim { AvatarFrameBudget.shared.remove(claim) }
        claim = nil
    }
}

// MARK: - Engine

/// The face, frame by frame. One per drawn mascot.
final class SwarmeFaceEngine {
    private var requested: SwarmeState = .idle
    private(set) var state: SwarmeState = .idle
    private var expression = 0
    private var currentRings: [[CGPoint]] = [SwarmeFaceData.ring(0, eye: 0), SwarmeFaceData.ring(0, eye: 1)]
    private var targetRings: [[CGPoint]] = [SwarmeFaceData.ring(0, eye: 0), SwarmeFaceData.ring(0, eye: 1)]
    private var morph: CGFloat = 1
    private var velocity: CGFloat = 0
    private var blinkStart: Date?
    private var spinStart: Date?
    private var spinDuration: TimeInterval = 0.9
    private var overrideState: SwarmeState?
    private var overrideUntil: Date?
    private var nextExpressionAt: Date?
    private var nextBlinkAt: Date?
    private var stateStart = Date()
    private var last: Date?
    private var started = false
    /// Pointer-follow offset, each axis -1…1.
    var pointerGaze: CGPoint = .zero

    private let spring: CGFloat = 7

    /// The bot's own state; a beat may override it for a moment.
    func request(_ new: SwarmeState, now: Date) {
        requested = new
        apply(now: now)
    }

    func play(_ motion: MascotMotion, now: Date) {
        let face = motion.face
        if face.blink { blinkStart = now }
        if let spin = face.spin { spinStart = now; spinDuration = TimeInterval(spin / 1000) }
        if let s = face.state {
            overrideState = s
            overrideUntil = now.addingTimeInterval(motionFaceSeconds)
        }
        apply(now: now)
    }

    private func apply(now: Date) {
        if let until = overrideUntil, now >= until { overrideState = nil; overrideUntil = nil }
        let desired = overrideState ?? requested
        guard !started || desired != state else { return }
        let first = !started
        started = true
        state = desired
        stateStart = now
        select(SwarmeFaceData.pools[desired]?.first ?? 0)
        if first { morph = 1; velocity = 0 } // first frame: rest on it, no morph in
        nextExpressionAt = schedule(SwarmeFaceData.expressionCadence[desired], from: now)
        nextBlinkAt = schedule(SwarmeFaceData.blink[desired], from: now)
    }

    /// A paused mascot gets one frame, so it must be the finished face.
    func settle() {
        morph = 1
        velocity = 0
        last = nil
    }

    private func schedule(_ range: (CGFloat, CGFloat)?, from now: Date) -> Date? {
        guard let range else { return nil }
        let ms = range.0 + CGFloat.random(in: 0...1) * (range.1 - range.0)
        return now.addingTimeInterval(TimeInterval(ms / 1000))
    }

    private func select(_ index: Int) {
        let i = ((index % SwarmeFaceData.expressionCount) + SwarmeFaceData.expressionCount) % SwarmeFaceData.expressionCount
        if i == expression && morph >= 1 { return }
        currentRings = displayedRings()
        targetRings = [SwarmeFaceData.ring(i, eye: 0), SwarmeFaceData.ring(i, eye: 1)]
        expression = i
        morph = 0
        velocity = 0
    }

    func step(now: Date) {
        let dt = CGFloat(min(now.timeIntervalSince(last ?? now), 0.1))
        last = now
        let f = spring
        velocity += (-2 * f * velocity - f * f * (morph - 1)) * dt
        morph += velocity * dt
        if !morph.isFinite { morph = 1; velocity = 0 }

        if let due = nextExpressionAt, now >= due {
            let pool = SwarmeFaceData.pools[state] ?? [0]
            let alternatives = pool.filter { $0 != expression }
            select(alternatives.randomElement() ?? pool[0])
            nextExpressionAt = schedule(SwarmeFaceData.expressionCadence[state], from: now)
        }
        if let due = nextBlinkAt, now >= due {
            blinkStart = now
            nextBlinkAt = schedule(SwarmeFaceData.blink[state], from: now)
        }
    }

    // MARK: Drawing

    private static let ribbonColors = ["#4ADE80", "#34D399", "#22D3EE", "#60A5FA"].map { Color(hex: $0) }
    private static let confettiColors = ["#F472B6", "#C084FC", "#818CF8", "#38BDF8", "#34D399", "#FACC15", "#FB7185"].map { Color(hex: $0) }

    private static func hash01(_ n: CGFloat) -> CGFloat {
        let x = sin(n * 127.1 + 311.7) * 43758.5453
        return x - floor(x)
    }

    /// The "!" and "?" glyphs, in face-box units.
    private static let bangFill: Path = {
        var p = SVGPath.parse("M99 58 Q99 43 114.3 43 Q129.6 43 129.6 58 L123 150 Q122 161 114.3 161 Q106.6 161 105.6 150 Z")
        p.addEllipse(in: CGRect(x: 114.3 - 15, y: 188 - 15, width: 30, height: 30))
        return p
    }()
    private static let queryStroke = SVGPath.parse("M88 76 A27 27 0 1 1 114.3 112 L114.3 132")
    private static let queryDot = Path(ellipseIn: CGRect(x: 114.3 - 13, y: 170 - 13, width: 26, height: 26))

    func draw(in context: inout GraphicsContext, size: CGSize, color: String, silhouette: SwarmeSilhouette,
              live: Bool, effects: Bool, at now: Date) {
        let rect = CGRect(origin: .zero, size: size)
        context.concatenate(SwarmeSilhouette.fit(rect))
        let elapsed = live ? CGFloat(now.timeIntervalSince(stateStart) * 1000) : 100_000
        let centre = SwarmeFaceData.faceBox / 2
        let fx = effects ? SwarmeFaceData.effects[state] : nil

        if let trails = fx?.trails, live { drawTrails(&context, trails, elapsed: elapsed, centre: centre) }

        var body = context
        if effects || live {
            body.concatenate(bodyTransform(SwarmeFaceData.motion[state] ?? SwarmeBodyMotion(), elapsed: elapsed))
        }
        let glyph = fx?.glyph
        let amount = glyph.map { live ? Self.glyphAmount($0, elapsed: elapsed) : 0 } ?? 0
        if amount < 1 {
            var content = body
            content.opacity = 1 - amount
            drawBody(in: &content, color: color, silhouette: silhouette, now: now, live: live)
        }
        if let glyph, amount > 0 {
            var g = body
            g.opacity = amount
            let scale = 0.72 + 0.28 * amount
            g.translateBy(x: centre, y: centre)
            g.scaleBy(x: scale, y: scale)
            g.translateBy(x: -centre, y: -centre)
            let paint = GraphicsContext.Shading.color(SwarmePalette.color(color))
            switch glyph.kind {
            case .bang:
                g.fill(Self.bangFill, with: paint)
            case .query:
                g.stroke(Self.queryStroke, with: paint, style: StrokeStyle(lineWidth: 19, lineCap: .round))
                g.fill(Self.queryDot, with: paint)
            }
        }

        if let confetti = fx?.confetti, live { drawConfetti(&context, confetti, elapsed: elapsed, centre: centre) }
    }

    private static func glyphAmount(_ spec: SwarmeGlyphSpec, elapsed: CGFloat) -> CGFloat {
        let position = elapsed.truncatingRemainder(dividingBy: spec.period)
        let start = spec.period - spec.hold
        if position < start { return 0 }
        let into = position - start
        let remaining = spec.hold - into
        return max(0, min(1, min(into, remaining) / 200))
    }

    private func drawTrails(_ context: inout GraphicsContext, _ spec: SwarmeTrailSpec, elapsed: CGFloat, centre: CGFloat) {
        for i in 0..<spec.count {
            let seedA = Self.hash01(CGFloat(i + 3)), seedB = Self.hash01(CGFloat(i + 29))
            let direction: CGFloat = i % 2 == 0 ? 1 : -1
            let period = spec.period * (0.8 + seedA * 0.5)
            let radius = spec.radius * (0.78 + seedB * 0.4)
            let start = direction * (elapsed / period) * 2 * .pi + seedA * 2 * .pi
            let span = 0.85 + seedB * 0.7
            var path = Path()
            for s in 0...12 {
                let k = CGFloat(s) / 12
                let angle = start + span * k
                let r = radius * (1 + sin(k * .pi) * 0.14)
                let p = CGPoint(x: centre + cos(angle) * r, y: centre + sin(angle) * r * 0.78)
                if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(Self.ribbonColors[i % Self.ribbonColors.count].opacity(0.85)),
                           style: StrokeStyle(lineWidth: 5 + seedA * 3, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawConfetti(_ context: inout GraphicsContext, _ spec: SwarmeConfettiSpec, elapsed: CGFloat, centre: CGFloat) {
        for i in 0..<spec.count {
            let seedA = Self.hash01(CGFloat(i + 1)), seedB = Self.hash01(CGFloat(i + 41)), seedC = Self.hash01(CGFloat(i + 91))
            let t = (elapsed + seedC * spec.period).truncatingRemainder(dividingBy: spec.period) / spec.life
            if t > 1 { continue }
            let angle = seedA * 2 * .pi
            let travel = spec.spread * (0.45 + seedB * 0.55) * (1 - (1 - t) * (1 - t))
            let distance = spec.origin + travel
            let gravity = 34 * t * t
            let x = centre + cos(angle) * distance
            let y = centre + sin(angle) * distance + gravity
            let length = 11 + seedB * 12
            let spin = angle + (seedC - 0.5) * 5 * t
            let ex = x + cos(spin) * length, ey = y + sin(spin) * length
            let bend = (seedA - 0.5) * length * 0.7
            let mx = (x + ex) / 2 - sin(spin) * bend, my = (y + ey) / 2 + cos(spin) * bend
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addQuadCurve(to: CGPoint(x: ex, y: ey), control: CGPoint(x: mx, y: my))
            let opacity = t < 0.12 ? t / 0.12 : 1 - (t - 0.12) / 0.88
            context.stroke(path, with: .color(Self.confettiColors[i % Self.confettiColors.count].opacity(opacity)),
                           style: StrokeStyle(lineWidth: 4 + seedB * 2.4, lineCap: .round))
        }
    }

    private func drawBody(in context: inout GraphicsContext, color: String, silhouette: SwarmeSilhouette, now: Date, live: Bool) {
        let body = silhouette.path
        context.fill(body, with: .color(SwarmePalette.color(color)))

        // The face is painted on the body: clipped to it, anchored in it.
        context.clip(to: body)
        let a = silhouette.anchor
        context.translateBy(x: a.x, y: a.y)
        context.scaleBy(x: a.scale, y: a.scale)

        let ink = GraphicsContext.Shading.color(SwarmePalette.eyeInk(color))
        let rings = displayedRings()
        let gx = live ? min(max(pointerGaze.x, -1), 1) * SwarmeFaceData.gazeTravel.x : 0
        let gy = live ? min(max(pointerGaze.y, -1), 1) * SwarmeFaceData.gazeTravel.y : 0
        let radians = (live ? spinTurn(now: now) : 0) * .pi / 180
        let blink = live ? blinkScale(now: now) : 1
        let sc = SwarmeFaceData.sphereCentre, sr = SwarmeFaceData.sphereRadius

        func project(_ x: CGFloat) -> (x: CGFloat, perspective: CGFloat, visible: Bool) {
            let base = asin(min(max((x - sc) / sr, -1), 1))
            let longitude = base + radians
            let depth = cos(longitude)
            let perspective = max(depth, 0.02) / max(cos(base), 0.02)
            return (sc + sr * sin(longitude), perspective, depth > 0.02)
        }

        for ring in rings {
            let c = Self.centre(ring)
            let p = project(c.x)
            guard p.visible else { continue }
            var path = Path()
            for (i, q) in ring.enumerated() {
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
            let t = CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: min(max(p.perspective, 0.02), 2.4), y: min(max(blink, 0.02), 2.4)))
                .concatenating(CGAffineTransform(translationX: p.x + gx, y: c.y + gy))
            context.fill(path.applying(t), with: ink)
        }
    }

    private func spinTurn(now: Date) -> CGFloat {
        guard let start = spinStart else { return 0 }
        let t = now.timeIntervalSince(start) / spinDuration
        if t >= 1 { spinStart = nil; return 0 }
        return 360 * CGFloat(max(t, 0))
    }

    /// The body's motion for a state, in face-box units, elapsed in ms.
    private func bodyTransform(_ m: SwarmeBodyMotion, elapsed: CGFloat) -> CGAffineTransform {
        let centre = SwarmeFaceData.faceBox / 2
        let ground = SwarmeFaceData.faceBox
        func wave(_ period: CGFloat, _ phase: CGFloat = 0) -> CGFloat { sin(elapsed / period * .pi * 2 + phase) }
        var dx: CGFloat = 0, dy: CGFloat = 0
        var rotation = m.tilt ?? 0
        var scale: CGFloat = 1, sx: CGFloat = 1, sy: CGFloat = 1
        if let (amplitude, period) = m.bob {
            let p = wave(period)
            dy -= amplitude * p
            if let squash = m.squash {
                let amount = squash * max(0, -p)
                sy = 1 - amount * 0.5
                sx = 1 + amount * 0.5
            }
        }
        if let (radius, period) = m.circle {
            dx += radius * wave(period)
            dy += radius * wave(period, .pi / 2)
        }
        if let (degrees, period) = m.sway { rotation += degrees * wave(period) }
        if let (fraction, period) = m.pulse { scale *= 1 + fraction * wave(period) }
        if let (amplitude, period) = m.jitter {
            dx += amplitude * wave(period)
            dy += amplitude * wave(period * 0.63, 1.1)
        }
        if let (from, duration) = m.enter {
            let t = elapsed / duration
            scale *= t >= 1 ? 1 : from + (1 - from) * Self.easeOutBack(max(t, 0))
        }
        if let settle = m.settle {
            let t = min(max(elapsed / 1400, 0), 1)
            scale *= 1 + (settle - 1) * Self.easeInOut(t)
        }
        // SVG applies the list right-to-left: squash, scale, rotate, translate.
        var t = CGAffineTransform.identity
        if sx != 1 || sy != 1 {
            t = t.concatenating(CGAffineTransform(translationX: -centre, y: -ground))
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: centre, y: ground))
        }
        if scale != 1 {
            t = t.concatenating(CGAffineTransform(translationX: -centre, y: -centre))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: centre, y: centre))
        }
        if rotation != 0 {
            t = t.concatenating(CGAffineTransform(translationX: -centre, y: -centre))
                .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
                .concatenating(CGAffineTransform(translationX: centre, y: centre))
        }
        if dx != 0 || dy != 0 { t = t.concatenating(CGAffineTransform(translationX: dx, y: dy)) }
        return t
    }

    private func blinkScale(now: Date) -> CGFloat {
        guard let start = blinkStart else { return 1 }
        let t = CGFloat(now.timeIntervalSince(start)) / 0.320
        if t >= 1 { blinkStart = nil; return 1 }
        return max(t < 0.42 ? 1 - t / 0.42 : (t - 0.42) / 0.58, 0.04)
    }

    private func displayedRings() -> [[CGPoint]] {
        let m = min(max(morph, 0), 1)
        if m >= 1 { return targetRings }
        return currentRings.enumerated().map { eye, ring in
            ring.enumerated().map { i, p in
                let q = targetRings[eye][i]
                return CGPoint(x: p.x + (q.x - p.x) * m, y: p.y + (q.y - p.y) * m)
            }
        }
    }
    private static func centre(_ ring: [CGPoint]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for p in ring { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(ring.count), y: y / CGFloat(ring.count))
    }

    private static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c: CGFloat = 1.7, u = t - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }
    private static func easeInOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t) }
}

/// The person, not a bot: a `raised` circle with the
/// initials at 0.38 × size, medium, ink-secondary.
struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(Theme.raised)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}
