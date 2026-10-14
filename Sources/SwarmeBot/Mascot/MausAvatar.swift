// The bot's face — a port of the desktop's `CursorAvatar` engine
// (`src/components/CursorAvatar.tsx`) wrapped like its `MausAvatar`
// (`src/components/Avatar.tsx`).
//
// A state picks a pool of expressions and drifts through them on its
// cadence, a critically damped spring morphs eyes and mouth between them, it
// blinks on its own rhythm, the body bobs / sways / breathes / jitters per
// state, and states carry effects: ribbons behind the body, confetti in
// front, or a "!"/"?" glyph standing in for it. One-shot motion beats borrow
// a state for 1.4 s, blink or spin the eyes around the head's sphere; the
// eyes follow the pointer. All numbers come from the generated
// `MausFaceData.swift`.
import SwiftUI

/// The desktop's `MausMotion`: one-shot beats the app plays on events.
enum MascotMotion: String {
    case arrive, `switch`, customize, alert, thinking, working, launch, success, celebrate, blink, surprise, failure

    /// `MOTION_FACE` in Avatar.tsx.
    var face: (state: MausState?, blink: Bool, spin: CGFloat?) {
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

struct MausAvatar: View {
    let color: String
    var size: CGFloat = 52
    var state: MausState = .idle
    /// A `MAUS_SILHOUETTES` id; unknown or nil is the default `circle`.
    var silhouette: String? = nil
    /// A request to animate, still subject to the on-screen frame budget.
    var animated: Bool = true
    /// Claim a frame slot ahead of decorative mascots (selected, busy).
    var priority: Bool = false
    var beat: MascotBeatEvent? = nil
    var trackPointer: Bool = true
    var effects: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = MausFaceEngine()
    @State private var slot = AvatarFrameSlot()
    @State private var granted = false
    @State private var beatLive = false

    var body: some View {
        let wants = animated && !reduceMotion
        let live = (wants && granted) || (beatLive && !reduceMotion)
        let shape = MausSilhouette.named(silhouette)
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

/// `lib/avatar-frames.ts`: at most 12 mascots animate at once; priority
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
final class MausFaceEngine {
    private var requested: MausState = .idle
    private(set) var state: MausState = .idle
    private var expression = 0
    private var currentRings: [[CGPoint]] = [MausFaceData.ring(0, eye: 0), MausFaceData.ring(0, eye: 1)]
    private var targetRings: [[CGPoint]] = [MausFaceData.ring(0, eye: 0), MausFaceData.ring(0, eye: 1)]
    private var currentMouth = MausFaceData.mouth(0)
    private var targetMouth = MausFaceData.mouth(0)
    private var currentGaze = MausFaceData.gaze(0)
    private var targetGaze = MausFaceData.gaze(0)
    private var morph: CGFloat = 1
    private var velocity: CGFloat = 0
    private var blinkStart: Date?
    private var spinStart: Date?
    private var spinDuration: TimeInterval = 0.9
    private var overrideState: MausState?
    private var overrideUntil: Date?
    private var nextExpressionAt: Date?
    private var nextBlinkAt: Date?
    private var stateStart = Date()
    private var last: Date?
    private var started = false
    /// Pointer-follow offset, each axis -1…1.
    var pointerGaze: CGPoint = .zero

    /// `lookAround`: the app passes `forward ? 0 : 1` with forward on, so
    /// the eyes always face the viewer; the authored gaze is kept at zero.
    private let lookAround: CGFloat = 0
    private let spring: CGFloat = 7

    /// The bot's own state; a beat may override it for a moment.
    func request(_ new: MausState, now: Date) {
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
        select(MausFaceData.pools[desired]?.first ?? 0)
        if first { morph = 1; velocity = 0 } // first frame: rest on it, no morph in
        nextExpressionAt = schedule(MausFaceData.expressionCadence[desired], from: now)
        nextBlinkAt = schedule(MausFaceData.blink[desired], from: now)
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
        let i = ((index % MausFaceData.expressionCount) + MausFaceData.expressionCount) % MausFaceData.expressionCount
        if i == expression && morph >= 1 { return }
        currentRings = displayedRings()
        currentMouth = displayedMouth()
        currentGaze = displayedGaze()
        targetRings = [MausFaceData.ring(i, eye: 0), MausFaceData.ring(i, eye: 1)]
        targetMouth = MausFaceData.mouth(i)
        targetGaze = MausFaceData.gaze(i)
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
            let pool = MausFaceData.pools[state] ?? [0]
            let alternatives = pool.filter { $0 != expression }
            select(alternatives.randomElement() ?? pool[0])
            nextExpressionAt = schedule(MausFaceData.expressionCadence[state], from: now)
        }
        if let due = nextBlinkAt, now >= due {
            blinkStart = now
            nextBlinkAt = schedule(MausFaceData.blink[state], from: now)
        }
    }

    // MARK: Drawing

    private static let ribbonColors = ["#4ADE80", "#34D399", "#22D3EE", "#60A5FA"].map { Color(hex: $0) }
    private static let confettiColors = ["#F472B6", "#C084FC", "#818CF8", "#38BDF8", "#34D399", "#FACC15", "#FB7185"].map { Color(hex: $0) }

    private static func hash01(_ n: CGFloat) -> CGFloat {
        let x = sin(n * 127.1 + 311.7) * 43758.5453
        return x - floor(x)
    }

    /// GLYPH_BANG / GLYPH_QUERY from CursorAvatar.tsx.
    private static let bangFill: Path = {
        var p = SVGPath.parse("M99 58 Q99 43 114.3 43 Q129.6 43 129.6 58 L123 150 Q122 161 114.3 161 Q106.6 161 105.6 150 Z")
        p.addEllipse(in: CGRect(x: 114.3 - 15, y: 188 - 15, width: 30, height: 30))
        return p
    }()
    private static let queryStroke = SVGPath.parse("M88 76 A27 27 0 1 1 114.3 112 L114.3 132")
    private static let queryDot = Path(ellipseIn: CGRect(x: 114.3 - 13, y: 170 - 13, width: 26, height: 26))

    func draw(in context: inout GraphicsContext, size: CGSize, color: String, silhouette: MausSilhouette,
              live: Bool, effects: Bool, at now: Date) {
        let rect = CGRect(origin: .zero, size: size)
        context.concatenate(MausSilhouette.fit(rect))
        let elapsed = live ? CGFloat(now.timeIntervalSince(stateStart) * 1000) : 100_000
        let centre = MausFaceData.faceBox / 2
        let fx = effects ? MausFaceData.effects[state] : nil

        if let trails = fx?.trails, live { drawTrails(&context, trails, elapsed: elapsed, centre: centre) }

        var body = context
        if effects || live {
            body.concatenate(bodyTransform(MausFaceData.motion[state] ?? MausBodyMotion(), elapsed: elapsed))
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
            let bounds = glyph.kind == .bang ? Self.bangFill.boundingRect : Self.queryStroke.boundingRect.union(Self.queryDot.boundingRect)
            let paint = GraphicsContext.Shading.linearGradient(
                Gradient(stops: MausPalette.gradientStops(color)),
                startPoint: CGPoint(x: bounds.maxX, y: bounds.minY), endPoint: CGPoint(x: bounds.minX, y: bounds.maxY)
            )
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

    private static func glyphAmount(_ spec: MausGlyphSpec, elapsed: CGFloat) -> CGFloat {
        let position = elapsed.truncatingRemainder(dividingBy: spec.period)
        let start = spec.period - spec.hold
        if position < start { return 0 }
        let into = position - start
        let remaining = spec.hold - into
        return max(0, min(1, min(into, remaining) / 200))
    }

    private func drawTrails(_ context: inout GraphicsContext, _ spec: MausTrailSpec, elapsed: CGFloat, centre: CGFloat) {
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

    private func drawConfetti(_ context: inout GraphicsContext, _ spec: MausConfettiSpec, elapsed: CGFloat, centre: CGFloat) {
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

    private func drawBody(in context: inout GraphicsContext, color: String, silhouette: MausSilhouette, now: Date, live: Bool) {
        let body = silhouette.path
        let bounds = silhouette.bounds
        context.fill(body, with: .linearGradient(
            Gradient(stops: MausPalette.gradientStops(color)),
            startPoint: CGPoint(x: bounds.maxX, y: bounds.minY),
            endPoint: CGPoint(x: bounds.minX, y: bounds.maxY)
        ))

        // The face is painted on the body: clipped to it, anchored in it.
        context.clip(to: body)
        let a = silhouette.anchor
        context.translateBy(x: a.x, y: a.y)
        context.scaleBy(x: a.scale, y: a.scale)
        context.translateBy(x: -MausFaceData.faceCentre.x, y: -MausFaceData.faceCentre.y)

        let ink = GraphicsContext.Shading.color(MausPalette.eyeInk(color))
        let gaze = displayedGaze()
        let ox = gaze.x * lookAround, oy = gaze.y * lookAround
        let rings = displayedRings().map { $0.map { CGPoint(x: $0.x + ox, y: $0.y + oy) } }
        let gx = live ? min(max(pointerGaze.x, -1), 1) * MausFaceData.gazeTravel.x : 0
        let gy = live ? min(max(pointerGaze.y, -1), 1) * MausFaceData.gazeTravel.y : 0
        let radians = (live ? spinTurn(now: now) : 0) * .pi / 180
        let blink = live ? blinkScale(now: now) : 1
        let sc = MausFaceData.sphereCentre, sr = MausFaceData.sphereRadius

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

        let spec = displayedMouth()
        let frame = Self.mouthFrame(rings, spec)
        let p = project(frame.x)
        if p.visible {
            let t = CGAffineTransform(translationX: -frame.x, y: -frame.y)
                .concatenating(CGAffineTransform(scaleX: min(max(p.perspective, 0.02), 2.4), y: 1))
                .concatenating(CGAffineTransform(translationX: p.x + gx, y: frame.y + gy))
            context.stroke(
                Self.mouthPath(frame, spec).applying(t),
                with: ink,
                style: StrokeStyle(lineWidth: MausFaceData.mouthStroke, lineCap: .round)
            )
        }
    }

    private func spinTurn(now: Date) -> CGFloat {
        guard let start = spinStart else { return 0 }
        let t = now.timeIntervalSince(start) / spinDuration
        if t >= 1 { spinStart = nil; return 0 }
        return 360 * CGFloat(max(t, 0))
    }

    /// The desktop's `bodyTransform`, in face-box units, elapsed in ms.
    private func bodyTransform(_ m: MausBodyMotion, elapsed: CGFloat) -> CGAffineTransform {
        let centre = MausFaceData.faceBox / 2
        let ground = MausFaceData.faceBox
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
    private func displayedMouth() -> [CGFloat] {
        let m = min(max(morph, 0), 1)
        return currentMouth.enumerated().map { i, v in v + (targetMouth[i] - v) * m }
    }
    private func displayedGaze() -> CGPoint {
        let m = min(max(morph, 0), 1)
        return CGPoint(x: currentGaze.x + (targetGaze.x - currentGaze.x) * m, y: currentGaze.y + (targetGaze.y - currentGaze.y) * m)
    }

    private static func centre(_ ring: [CGPoint]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for p in ring { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(ring.count), y: y / CGFloat(ring.count))
    }

    private static func mouthFrame(_ rings: [[CGPoint]], _ spec: [CGFloat]) -> (x: CGFloat, y: CGFloat, angle: CGFloat) {
        let c0 = centre(rings[0]), c1 = centre(rings[1])
        let theta = atan2(c1.y - c0.y, c1.x - c0.x)
        var halfHeight: CGFloat = 0
        for ring in rings {
            var lo = CGFloat.infinity, hi = -CGFloat.infinity
            for p in ring { lo = min(lo, p.y); hi = max(hi, p.y) }
            halfHeight = max(halfHeight, (hi - lo) / 2)
        }
        let drop = halfHeight + spec[2]
        return (
            x: (c0.x + c1.x) / 2 - sin(theta) * drop,
            y: (c0.y + c1.y) / 2 + cos(theta) * drop,
            angle: theta + spec[3] * .pi / 180
        )
    }

    private static func mouthPath(_ frame: (x: CGFloat, y: CGFloat, angle: CGFloat), _ spec: [CGFloat]) -> Path {
        let ca = cos(frame.angle), sa = sin(frame.angle)
        func at(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
            CGPoint(x: frame.x + lx * ca - ly * sa, y: frame.y + lx * sa + ly * ca)
        }
        var path = Path()
        path.move(to: at(-spec[0], 0))
        path.addQuadCurve(to: at(spec[0], 0), control: at(0, spec[1]))
        return path
    }

    private static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c: CGFloat = 1.7, u = t - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }
    private static func easeInOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t) }
}

/// The person, not a bot: `InitialsAvatar` — a `raised` circle with the
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
