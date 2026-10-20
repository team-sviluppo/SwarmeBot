// What the mascot is made of: the states a bot can be in, the eye shapes that
// make up its expressions, which expressions each state drifts through and how
// the body moves, the palette, and the body silhouettes.
//
// The face is two dark eyes on a flat body, nothing else. Expressions live in
// the eyes: their size, lids, crescents, a wink. Every eye is a ring of
// `pointsPerRing` points so the engine can morph any expression into any other.
// Silhouettes are built from simple geometry here, not drawn by hand, so a new
// one is a few lines.
import SwiftUI

enum SwarmeState: String, CaseIterable {
    case sleeping = "sleeping"
    case waking = "waking"
    case idle = "idle"
    case listening = "listening"
    case thinking = "thinking"
    case searching = "searching"
    case working = "working"
    case excited = "excited"
    case surprised = "surprised"
    case suspicious = "suspicious"
    case angry = "angry"
    case drowsy = "drowsy"
    case happy = "happy"
    case curious = "curious"
    case confused = "confused"
    case bored = "bored"
    case proud = "proud"
    case shy = "shy"
    case sad = "sad"
    case laughing = "laughing"
    case scared = "scared"
    case playful = "playful"
    case celebrate = "celebrate"
    case orbit = "orbit"
    case radar = "radar"
    case progress = "progress"
    case spawning = "spawning"
    case humming = "humming"
    case loading = "loading"
    case dictating = "dictating"
    case sending = "sending"
    case receiving = "receiving"
    case uploading = "uploading"
    case writing = "writing"
    case notifying = "notifying"
    case alerting = "alerting"
    case bouncing = "bouncing"
    case dragging = "dragging"
    case poweringDown = "powering-down"
}

// MARK: - Eyes

/// One eye, described as the right one (positive x); the left mirrors it.
/// Face units: the face centre is the origin, y grows downwards, and the body
/// is about 100 units in radius.
struct SwarmeEye {
    var x: CGFloat = 23
    var y: CGFloat = -6
    /// Half-width and half-height of the open eye.
    var w: CGFloat = 8
    var h: CGFloat = 12.5
    /// How far the top and bottom halves bulge: 1 is an ellipse, 0 a flat
    /// edge, negative folds that half inwards (a crescent).
    var top: CGFloat = 1
    var bottom: CGFloat = 1
    /// An upper lid closing from the top, 0…1 of the eye's height.
    var lid: CGFloat = 0
    /// Lid slope: positive drops the inner corner (cross), negative the outer (sad).
    var tilt: CGFloat = 0
    /// Degrees, clockwise, around the eye's centre.
    var rotation: CGFloat = 0

    func ring(mirrored: Bool) -> [CGPoint] {
        let n = SwarmeFaceData.pointsPerRing
        let radians = rotation * .pi / 180
        let ca = cos(radians), sa = sin(radians)
        return (0..<n).map { i in
            let theta = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(n)
            let lx = w * cos(theta)
            let s = sin(theta)
            var ly = h * s * (s < 0 ? top : bottom)
            if s < 0, lid > 0 || tilt != 0 {
                let lidLine = -h + 2 * h * lid - tilt * h * (lx / w)
                let floor = h * bottom * (1 - min((lx / w) * (lx / w), 1)).squareRoot() - 0.8
                ly = max(ly, min(lidLine, floor))
            }
            let rx = lx * ca - ly * sa, ry = lx * sa + ly * ca
            return CGPoint(x: (x + rx) * (mirrored ? -1 : 1), y: y + ry)
        }
    }
}

struct SwarmeExpression {
    let right: SwarmeEye
    /// Nil mirrors the right eye.
    var left: SwarmeEye? = nil
}

enum SwarmeFaceData {
    /// The body's drawing box; `SwarmeSilhouette.fit` adds the margin.
    static let faceBox: CGFloat = 228.541
    /// Where the eyes turn around when the head spins, in face units.
    static let sphereCentre: CGFloat = 0
    static let sphereRadius: CGFloat = 70
    static let gazeTravel = CGPoint(x: 7, y: 5)
    static let pointsPerRing = 48

    static let expressions: [SwarmeExpression] = [
        /* 0 calm */ SwarmeExpression(right: SwarmeEye()),
        /* 1 open */ SwarmeExpression(right: SwarmeEye(w: 8.5, h: 14)),
        /* 2 happy */ SwarmeExpression(right: SwarmeEye(y: -7, w: 9.5, h: 10, bottom: -0.45)),
        /* 3 joy */ SwarmeExpression(right: SwarmeEye(y: -8, w: 10.5, h: 12, bottom: -0.3)),
        /* 4 wide */ SwarmeExpression(right: SwarmeEye(x: 24, w: 10, h: 15.5)),
        /* 5 tiny */ SwarmeExpression(right: SwarmeEye(x: 19, y: -9, w: 5, h: 7.5)),
        /* 6 sleepy */ SwarmeExpression(right: SwarmeEye(w: 8.5, h: 11.5, lid: 0.52)),
        /* 7 asleep */ SwarmeExpression(right: SwarmeEye(y: -1, w: 9, h: 7, top: -0.5)),
        /* 8 cross */ SwarmeExpression(right: SwarmeEye(w: 8.5, h: 12, lid: 0.32, tilt: 0.6)),
        /* 9 sad */ SwarmeExpression(right: SwarmeEye(y: -2, w: 8, h: 11, lid: 0.2, tilt: -0.35)),
        /* 10 suspicious */ SwarmeExpression(right: SwarmeEye(w: 8.5, h: 11, lid: 0.58), left: SwarmeEye(w: 8.5, h: 11, lid: 0.36)),
        /* 11 wink */ SwarmeExpression(right: SwarmeEye(y: -7, w: 9.5, h: 9, bottom: -0.5), left: SwarmeEye(w: 8.5, h: 13)),
        /* 12 focus */ SwarmeExpression(right: SwarmeEye(w: 7, h: 10, lid: 0.22)),
        /* 13 look up */ SwarmeExpression(right: SwarmeEye(x: 27, y: -14, w: 8, h: 11.5), left: SwarmeEye(x: 17, y: -14, w: 8, h: 11.5)),
        /* 14 look aside */ SwarmeExpression(right: SwarmeEye(x: 31, y: -5, w: 8, h: 12.5), left: SwarmeEye(x: 13, y: -5, w: 8, h: 12.5)),
        /* 15 look down */ SwarmeExpression(right: SwarmeEye(x: 18, y: 3, w: 7, h: 9.5), left: SwarmeEye(x: 26, y: 3, w: 7, h: 9.5)),
        /* 16 curious */ SwarmeExpression(right: SwarmeEye(w: 10, h: 15), left: SwarmeEye(w: 7.5, h: 11)),
        /* 17 puzzled */ SwarmeExpression(right: SwarmeEye(w: 9, h: 13.5), left: SwarmeEye(w: 8, h: 11, lid: 0.42, tilt: 0.35)),
        /* 18 bored */ SwarmeExpression(right: SwarmeEye(x: 17, y: -4, w: 8.5, h: 11, lid: 0.55), left: SwarmeEye(x: 29, y: -4, w: 8.5, h: 11, lid: 0.55)),
        /* 19 content */ SwarmeExpression(right: SwarmeEye(y: -4, w: 9.5, h: 8, top: -0.4)),
        /* 20 laughing */ SwarmeExpression(right: SwarmeEye(y: -6, w: 10, h: 9, bottom: -0.7, rotation: 14)),
        /* 21 starry */ SwarmeExpression(right: SwarmeEye(x: 25, y: -7, w: 11, h: 16)),
        /* 22 determined */ SwarmeExpression(right: SwarmeEye(w: 8, h: 11.5, lid: 0.26, tilt: 0.32)),
    ]
    static var expressionCount: Int { expressions.count }

    /// Every expression's two rings, right then left, computed once.
    private static let rings: [[[CGPoint]]] = expressions.map { e in
        [e.right.ring(mirrored: false), (e.left ?? e.right).ring(mirrored: true)]
    }

    static func ring(_ expression: Int, eye: Int) -> [CGPoint] { rings[expression][eye] }

    static let pools: [SwarmeState: [Int]] = [
        .sleeping: [7, 19],
        .waking: [6, 0],
        .idle: [0, 1, 14],
        .listening: [1, 16, 0],
        .thinking: [13, 14, 12],
        .searching: [14, 13, 4, 16],
        .working: [12, 22, 0],
        .excited: [21, 3, 2],
        .surprised: [4, 21],
        .suspicious: [10, 8],
        .angry: [8, 22],
        .drowsy: [6, 7],
        .happy: [2, 3, 19],
        .curious: [16, 4, 1],
        .confused: [17, 16],
        .bored: [18, 6],
        .proud: [19, 2],
        .shy: [15, 5],
        .sad: [9, 15],
        .laughing: [20, 3],
        .scared: [5, 4],
        .playful: [11, 2, 3],
        .celebrate: [3, 20, 21],
        .orbit: [0, 1, 12],
        .radar: [14, 0, 12],
        .progress: [12, 0],
        .spawning: [4, 0],
        .humming: [19, 0],
        .loading: [0, 12],
        .dictating: [1, 16],
        .sending: [0, 1],
        .receiving: [1, 0],
        .uploading: [13, 12],
        .writing: [12, 15],
        .notifying: [4, 1],
        .alerting: [4, 21],
        .bouncing: [3, 2],
        .dragging: [4, 16],
        .poweringDown: [6, 7],
    ]

    /// How often a state picks another expression from its pool, ms.
    static let expressionCadence: [SwarmeState: (CGFloat, CGFloat)] = [
        .sleeping: (6000, 10000),
        .waking: (800, 800),
        .idle: (9000, 16000),
        .listening: (2800, 5000),
        .thinking: (2000, 3600),
        .searching: (1000, 1800),
        .working: (1800, 3200),
        .excited: (1100, 2000),
        .surprised: (2500, 4000),
        .suspicious: (2600, 4500),
        .angry: (2200, 3800),
        .drowsy: (4000, 8000),
        .happy: (2500, 4500),
        .curious: (1800, 3200),
        .confused: (2200, 3800),
        .bored: (3500, 6000),
        .proud: (3500, 6000),
        .shy: (3000, 5500),
        .sad: (4000, 7000),
        .laughing: (1200, 2400),
        .scared: (900, 1800),
        .playful: (1500, 3000),
        .celebrate: (1400, 2600),
        .orbit: (4000, 8000),
        .radar: (4000, 8000),
        .progress: (4000, 8000),
        .spawning: (1200, 1200),
        .humming: (5000, 9000),
        .loading: (6000, 10000),
        .dictating: (4000, 8000),
        .sending: (4000, 8000),
        .receiving: (4000, 8000),
        .uploading: (4000, 8000),
        .writing: (4000, 8000),
        .notifying: (1500, 2600),
        .alerting: (2000, 3600),
        .bouncing: (3000, 6000),
        .dragging: (1600, 3000),
        .poweringDown: (6000, 9000),
    ]

    /// Time between blinks, ms; states without an entry don't blink.
    static let blink: [SwarmeState: (CGFloat, CGFloat)] = [
        .idle: (6000, 14000),
        .listening: (3000, 7000),
        .thinking: (3500, 7000),
        .searching: (1600, 4000),
        .working: (2800, 5500),
        .excited: (2000, 4000),
        .surprised: (1800, 3500),
        .suspicious: (4500, 8000),
        .angry: (3500, 7000),
        .happy: (2500, 5000),
        .curious: (2500, 5500),
        .confused: (2800, 5500),
        .bored: (4000, 8000),
        .proud: (3500, 7000),
        .shy: (3000, 6000),
        .sad: (4000, 8000),
        .laughing: (2500, 5000),
        .scared: (1200, 3000),
        .playful: (2000, 4500),
        .celebrate: (2200, 4500),
        .humming: (4000, 8000),
        .notifying: (2000, 4000),
        .dragging: (2200, 4500),
    ]

    static let motion: [SwarmeState: SwarmeBodyMotion] = [
        .sleeping: SwarmeBodyMotion(pulse: (0.028, 4600), tilt: 2),
        .waking: SwarmeBodyMotion(pulse: (0.03, 2200), enter: (0.92, 700)),
        .idle: SwarmeBodyMotion(pulse: (0.014, 3600)),
        .listening: SwarmeBodyMotion(bob: (2, 2600), pulse: (0.012, 2600)),
        .thinking: SwarmeBodyMotion(sway: (1.6, 3000), pulse: (0.01, 3000)),
        .searching: SwarmeBodyMotion(bob: (3, 1400), sway: (2.2, 1400)),
        .working: SwarmeBodyMotion(bob: (2.5, 900), squash: 0.22),
        .excited: SwarmeBodyMotion(bob: (9, 520), sway: (3, 1040), squash: 0.35),
        .surprised: SwarmeBodyMotion(jitter: (0.8, 120), enter: (1.14, 340)),
        .suspicious: SwarmeBodyMotion(sway: (2.4, 2600), tilt: -3),
        .angry: SwarmeBodyMotion(jitter: (1.3, 95), tilt: 2),
        .drowsy: SwarmeBodyMotion(pulse: (0.026, 5000), tilt: 3),
        .happy: SwarmeBodyMotion(bob: (5, 820), squash: 0.28),
        .curious: SwarmeBodyMotion(sway: (3.4, 1900), tilt: -4),
        .confused: SwarmeBodyMotion(sway: (3, 2200)),
        .bored: SwarmeBodyMotion(pulse: (0.016, 5200), tilt: 2),
        .proud: SwarmeBodyMotion(bob: (1.6, 2400), pulse: (0.02, 2400)),
        .shy: SwarmeBodyMotion(pulse: (0.016, 3000), tilt: 4),
        .sad: SwarmeBodyMotion(pulse: (0.02, 4600), tilt: 3),
        .laughing: SwarmeBodyMotion(bob: (7, 430), squash: 0.4),
        .scared: SwarmeBodyMotion(jitter: (2.2, 75)),
        .playful: SwarmeBodyMotion(bob: (6, 620), sway: (5, 1240), squash: 0.3),
        .celebrate: SwarmeBodyMotion(bob: (10, 480), sway: (4, 960), squash: 0.35),
        .orbit: SwarmeBodyMotion(circle: (6, 3200)),
        .radar: SwarmeBodyMotion(sway: (6, 2400), pulse: (0.012, 2400)),
        .progress: SwarmeBodyMotion(pulse: (0.022, 1600)),
        .spawning: SwarmeBodyMotion(pulse: (0.014, 3600), enter: (0.02, 820)),
        .humming: SwarmeBodyMotion(pulse: (0.016, 2800)),
        .loading: SwarmeBodyMotion(sway: (2.2, 1500), pulse: (0.012, 1500)),
        .dictating: SwarmeBodyMotion(bob: (2, 2000)),
        .sending: SwarmeBodyMotion(bob: (3, 900)),
        .receiving: SwarmeBodyMotion(bob: (3, 900)),
        .uploading: SwarmeBodyMotion(bob: (3, 1000)),
        .writing: SwarmeBodyMotion(bob: (1.6, 1100)),
        .notifying: SwarmeBodyMotion(bob: (4, 700), sway: (2.5, 700)),
        .alerting: SwarmeBodyMotion(jitter: (2.6, 85)),
        .bouncing: SwarmeBodyMotion(bob: (12, 560), squash: 0.45),
        .dragging: SwarmeBodyMotion(sway: (2, 900), tilt: -6),
        .poweringDown: SwarmeBodyMotion(tilt: 4, settle: 0.05),
    ]

    static let effects: [SwarmeState: SwarmeEffects] = [
        .excited: SwarmeEffects(confetti: SwarmeConfettiSpec(count: 9, period: 2000, life: 1100, origin: 72, spread: 44)),
        .confused: SwarmeEffects(glyph: SwarmeGlyphSpec(kind: .query, period: 5200, hold: 1200)),
        .laughing: SwarmeEffects(confetti: SwarmeConfettiSpec(count: 7, period: 2400, life: 1000, origin: 70, spread: 38)),
        .celebrate: SwarmeEffects(confetti: SwarmeConfettiSpec(count: 16, period: 1500, life: 1300, origin: 74, spread: 54)),
        .orbit: SwarmeEffects(trails: SwarmeTrailSpec(count: 3, period: 2600, radius: 128)),
        .radar: SwarmeEffects(trails: SwarmeTrailSpec(count: 2, period: 2000, radius: 132)),
        .progress: SwarmeEffects(trails: SwarmeTrailSpec(count: 3, period: 1800, radius: 124)),
        .loading: SwarmeEffects(trails: SwarmeTrailSpec(count: 2, period: 2200, radius: 126)),
        .sending: SwarmeEffects(trails: SwarmeTrailSpec(count: 2, period: 1500, radius: 120)),
        .receiving: SwarmeEffects(trails: SwarmeTrailSpec(count: 2, period: 1500, radius: 120)),
        .uploading: SwarmeEffects(trails: SwarmeTrailSpec(count: 2, period: 1700, radius: 122)),
        .notifying: SwarmeEffects(glyph: SwarmeGlyphSpec(kind: .bang, period: 4200, hold: 900)),
        .alerting: SwarmeEffects(glyph: SwarmeGlyphSpec(kind: .bang, period: 2600, hold: 1100)),
    ]

    /// Faces a bot without a pinned expression or a telling role rests on.
    static let restingFaces: [SwarmeState] = [.idle, .happy, .curious, .working, .thinking, .listening, .proud]
}

// MARK: - Palette

enum SwarmePaletteData {
    /// The names are stored in bot records and team packages; only the shades are ours to change.
    static let hex: [String: String] = [
        "white": "#F2F2F4",
        "green": "#22B865",
        "blue": "#3B82F0",
        "red": "#E5484D",
        "orange": "#F59F1A",
        "purple": "#9064F2",
        "cyan": "#1CB3D4",
        "pink": "#EC5A9E",
        "yellow": "#F2C230",
        "teal": "#16B3A0",
        "coral": "#F26B3A",
    ]
    static let names: [String] = ["white", "green", "blue", "red", "orange", "purple", "cyan", "pink", "yellow", "teal", "coral"]
}

// MARK: - Silhouettes

enum SwarmeSilhouetteData {
    static let defaultId = "circle"
    /// Eyes are drawn this much larger than their face-unit sizes.
    static let eyeScale: CGFloat = 1.5
    /// Ids bot records may still carry from shapes that are gone.
    static let aliases: [String: String] = ["cursor": "droplet"]

    /// In the appearance picker's order: soft everyday shapes first, then SwarmeBot's own.
    static let all: [SwarmeSilhouetteSpec] = [
        shape("circle") { [ShapeKit.radial { _ in 1 }] },
        shape("oval") { [ShapeKit.superellipse(1, 0.84, 2)] },
        shape("squircle") { [ShapeKit.superellipse(0.94, 0.94, 4.6)] },
        shape("tile", face: (6, -4)) { [ShapeKit.rotate(ShapeKit.superellipse(0.9, 0.9, 3.4), 12)] },
        shape("slanted", face: (4, -2)) { [ShapeKit.rotate(ShapeKit.superellipse(1, 0.7, 3.2), -14)] },
        shape("pill", face: (14, 0), scale: 0.9) { [ShapeKit.capsule(CGPoint(x: -0.5, y: 0), CGPoint(x: 0.5, y: 0), 0.5)] },
        shape("capsule", scale: 0.88) { [ShapeKit.capsule(CGPoint(x: 0, y: -0.42), CGPoint(x: 0, y: 0.42), 0.58)] },
        shape("egg", face: (0, 8)) { [ShapeKit.parametric { t in CGPoint(x: 0.8 * cos(t) * (1 + 0.13 * sin(t)), y: sin(t)) }] },
        shape("pebble", face: (4, 2)) { [ShapeKit.radial { a in 1 + 0.07 * cos(2 * a + 0.6) + 0.04 * cos(3 * a + 1.9) }] },
        shape("blob", face: (6, -2)) { [ShapeKit.radial { a in 1 + 0.1 * cos(3 * a + 0.4) + 0.05 * cos(5 * a + 2.1) + 0.04 * sin(2 * a) }] },
        shape("cloud", face: (0, 6), scale: 0.92) {
            [ShapeKit.radial(squash: 0.86) { a in 0.82 + 0.18 * pow(abs(sin(3.5 * a)), 0.55) }]
        },
        shape("flower", scale: 0.84) { [ShapeKit.radial(smooth: 3) { a in 0.74 + 0.26 * pow(abs(cos(2.5 * (a + .pi / 2))), 0.5) }] },
        shape("clover", scale: 0.84) { [ShapeKit.radial(smooth: 8) { a in 0.7 + 0.3 * pow(abs(cos(2 * a)), 0.45) }] },
        shape("sparkle", scale: 0.66) {
            [ShapeKit.rotate(ShapeKit.radial(smooth: 5) { a in 0.56 + 0.44 * pow((1 + cos(4 * a)) / 2, 1.5) }, 12)]
        },
        shape("star", face: (0, 8), scale: 0.7) {
            [ShapeKit.radial(smooth: 8) { a in 0.56 + 0.44 * pow((1 + cos(5 * (a + .pi / 2))) / 2, 1.6) }]
        },
        shape("burst", scale: 0.86) { [ShapeKit.radial(smooth: 4) { a in 0.85 + 0.15 * pow((1 + cos(10 * a)) / 2, 0.6) }] },
        shape("droplet", face: (-6, 14), scale: 0.86) {
            [ShapeKit.rotate(ShapeKit.parametric { t in CGPoint(x: cos(t), y: sin(t) * pow(abs(sin(t / 2)), 1.1)) }, -125)]
        },
        shape("triangle", face: (0, 16), scale: 0.78) { [ShapeKit.polygon(3, corner: 0.3)] },
        shape("gem", scale: 0.8) { [ShapeKit.scale(ShapeKit.polygon(4, corner: 0.28), 0.86, 1)] },
        shape("pentagon", face: (0, 6), scale: 0.86) { [ShapeKit.polygon(5, corner: 0.3)] },
        shape("hexagon", scale: 0.9) { [ShapeKit.polygon(6, corner: 0.3, rotation: 30)] },
        shape("octagon", scale: 0.92) { [ShapeKit.polygon(8, corner: 0.3, rotation: 22.5)] },
        shape("shield", face: (0, -4), scale: 0.86) {
            [ShapeKit.rounded([
                CGPoint(x: -0.82, y: -0.86), CGPoint(x: 0.82, y: -0.86), CGPoint(x: 0.86, y: 0.08),
                CGPoint(x: 0, y: 1), CGPoint(x: -0.86, y: 0.08),
            ], corner: 0.3)]
        },
        // SwarmeBot's own: the app icon's head, a bee, the comb, a robot, a drone.
        shape("antenna", face: (0, 20), scale: 0.8) {
            let head = ShapeKit.rounded([
                CGPoint(x: -0.6, y: -0.5), CGPoint(x: 0.6, y: -0.5), CGPoint(x: 0.82, y: -0.18), CGPoint(x: 0.82, y: 0.3),
                CGPoint(x: 0.46, y: 0.78), CGPoint(x: -0.46, y: 0.78), CGPoint(x: -0.82, y: 0.3), CGPoint(x: -0.82, y: -0.18),
            ], corner: 0.35)
            return [head] + [-1, 1].flatMap { (side: CGFloat) in [
                ShapeKit.capsule(CGPoint(x: 0.3 * side, y: -0.46), CGPoint(x: 0.56 * side, y: -0.9), 0.06),
                ShapeKit.circle(CGPoint(x: 0.58 * side, y: -0.94), 0.12),
            ] }
        },
        shape("bee", face: (0, 18), scale: 0.82) {
            // a round body with two wings on top
            [
                ShapeKit.offset(ShapeKit.superellipse(0.8, 0.64, 2.2), 0, 0.22),
                ShapeKit.offset(ShapeKit.rotate(ShapeKit.superellipse(0.38, 0.2, 2), 25), -0.5, -0.46),
                ShapeKit.offset(ShapeKit.rotate(ShapeKit.superellipse(0.38, 0.2, 2), -25), 0.5, -0.46),
            ]
        },
        shape("comb", face: (0, 4), scale: 0.78) {
            // three cells of a honeycomb, slightly overlapping so they read as one body
            [CGPoint(x: 0, y: -0.375), CGPoint(x: -0.433, y: 0.375), CGPoint(x: 0.433, y: 0.375)].map { c in
                ShapeKit.offset(ShapeKit.scale(ShapeKit.polygon(6, corner: 0.22), 0.53, 0.53), c.x, c.y)
            }
        },
        shape("robot", face: (0, 14), scale: 0.84) {
            [
                ShapeKit.offset(ShapeKit.superellipse(0.76, 0.66, 4.2), 0, 0.12),
                ShapeKit.capsule(CGPoint(x: -0.86, y: -0.02), CGPoint(x: -0.86, y: 0.3), 0.12),
                ShapeKit.capsule(CGPoint(x: 0.86, y: -0.02), CGPoint(x: 0.86, y: 0.3), 0.12),
                ShapeKit.capsule(CGPoint(x: 0, y: -0.5), CGPoint(x: 0, y: -0.82), 0.06),
                ShapeKit.circle(CGPoint(x: 0, y: -0.86), 0.13),
            ]
        },
        shape("drone", face: (0, 22), scale: 0.84) {
            [ShapeKit.offset(ShapeKit.superellipse(0.74, 0.54, 2.4), 0, 0.24)] + [-1, 1].flatMap { (side: CGFloat) in [
                ShapeKit.capsule(CGPoint(x: 0.42 * side, y: -0.12), CGPoint(x: 0.66 * side, y: -0.56), 0.07),
                ShapeKit.offset(ShapeKit.superellipse(0.32, 0.08, 2), 0.66 * side, -0.6),
            ] }
        },
    ]

    /// A shape from unit-space parts (y down, about 1 in radius). `face` moves the
    /// eyes from the box's centre, in face-box units; `scale` sizes them.
    private static func shape(_ id: String, face: (CGFloat, CGFloat) = (0, 0), scale: CGFloat = 1,
                              _ parts: @escaping () -> [[CGPoint]]) -> SwarmeSilhouetteSpec {
        SwarmeSilhouetteSpec(id: id, build: {
            let c = SwarmeFaceData.faceBox / 2
            return (ShapeKit.fit(parts()), (x: c + face.0, y: c + face.1, scale: scale * eyeScale))
        })
    }
}

/// Geometry for silhouettes. Parts are point lists in unit space; `fit`
/// centres the whole set in the face box and turns it into one path.
enum ShapeKit {
    /// The body's radius in face-box units.
    static let radius: CGFloat = 100

    static func radial(samples: Int = 360, smooth: Int = 0, squash: CGFloat = 1, _ r: (CGFloat) -> CGFloat) -> [CGPoint] {
        var radii = (0..<samples).map { r(2 * .pi * CGFloat($0) / CGFloat(samples)) }
        if smooth > 0 {
            radii = radii.indices.map { i in
                let window = (-smooth...smooth).map { radii[(i + $0 + samples) % samples] }
                return window.reduce(0, +) / CGFloat(window.count)
            }
        }
        return radii.enumerated().map { i, value in
            let a = 2 * .pi * CGFloat(i) / CGFloat(samples)
            return CGPoint(x: value * cos(a), y: value * sin(a) * squash)
        }
    }

    static func parametric(samples: Int = 360, _ point: (CGFloat) -> CGPoint) -> [CGPoint] {
        (0..<samples).map { point(2 * .pi * CGFloat($0) / CGFloat(samples)) }
    }

    /// |x/a|^n + |y/b|^n = 1: an ellipse at 2, a squircle around 4.
    static func superellipse(_ a: CGFloat, _ b: CGFloat, _ n: CGFloat) -> [CGPoint] {
        parametric { t in
            let c = cos(t), s = sin(t)
            return CGPoint(x: a * copysign(pow(abs(c), 2 / n), c), y: b * copysign(pow(abs(s), 2 / n), s))
        }
    }

    static func circle(_ centre: CGPoint, _ r: CGFloat) -> [CGPoint] {
        parametric(samples: 72) { t in CGPoint(x: centre.x + r * cos(t), y: centre.y + r * sin(t)) }
    }

    /// A stadium around the segment a–b.
    static func capsule(_ a: CGPoint, _ b: CGPoint, _ r: CGFloat) -> [CGPoint] {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let half = 36
        let around: (CGPoint, CGFloat) -> [CGPoint] = { centre, start in
            (0...half).map { i in
                let t = start + .pi * CGFloat(i) / CGFloat(half)
                return CGPoint(x: centre.x + r * cos(t), y: centre.y + r * sin(t))
            }
        }
        return around(b, angle - .pi / 2) + around(a, angle + .pi / 2)
    }

    /// A regular polygon with a vertex on top and rounded corners.
    static func polygon(_ sides: Int, corner: CGFloat, rotation: CGFloat = 0) -> [CGPoint] {
        let vertices = (0..<sides).map { i -> CGPoint in
            let a = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(sides) + rotation * .pi / 180
            return CGPoint(x: cos(a), y: sin(a))
        }
        return rounded(vertices, corner: corner)
    }

    /// Rounds each corner over `corner` (0…0.5) of its two edges and leaves
    /// the rest of the edges straight: the corners are pinned first, then
    /// smoothed with Chaikin's corner cutting.
    static func rounded(_ vertices: [CGPoint], corner: CGFloat) -> [CGPoint] {
        let n = vertices.count
        var pinned: [CGPoint] = []
        for i in 0..<n {
            let v = vertices[i], prev = vertices[(i + n - 1) % n], next = vertices[(i + 1) % n]
            pinned.append(CGPoint(x: v.x + (prev.x - v.x) * corner, y: v.y + (prev.y - v.y) * corner))
            pinned.append(v)
            pinned.append(CGPoint(x: v.x + (next.x - v.x) * corner, y: v.y + (next.y - v.y) * corner))
        }
        return chaikin(pinned, iterations: 4)
    }

    private static func chaikin(_ points: [CGPoint], iterations: Int) -> [CGPoint] {
        var current = points
        for _ in 0..<iterations {
            var next: [CGPoint] = []
            next.reserveCapacity(current.count * 2)
            for i in current.indices {
                let p = current[i], q = current[(i + 1) % current.count]
                next.append(CGPoint(x: 0.75 * p.x + 0.25 * q.x, y: 0.75 * p.y + 0.25 * q.y))
                next.append(CGPoint(x: 0.25 * p.x + 0.75 * q.x, y: 0.25 * p.y + 0.75 * q.y))
            }
            current = next
        }
        return current
    }

    static func rotate(_ points: [CGPoint], _ degrees: CGFloat) -> [CGPoint] {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        return points.map { CGPoint(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
    }

    static func scale(_ points: [CGPoint], _ sx: CGFloat, _ sy: CGFloat) -> [CGPoint] {
        points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
    }

    static func offset(_ points: [CGPoint], _ dx: CGFloat, _ dy: CGFloat) -> [CGPoint] {
        points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// All parts as one path: centred on the box, the larger side scaled to
    /// the body's diameter, every part wound the same way so overlaps fill.
    static func fit(_ parts: [[CGPoint]]) -> Path {
        let all = parts.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return Path() }
        let k = 2 * radius / max(maxX - minX, maxY - minY)
        let c = SwarmeFaceData.faceBox / 2
        let mx = (minX + maxX) / 2, my = (minY + maxY) / 2
        var path = Path()
        for part in parts where part.count > 2 {
            var area: CGFloat = 0
            for i in part.indices {
                let p = part[i], q = part[(i + 1) % part.count]
                area += p.x * q.y - q.x * p.y
            }
            let ordered = area < 0 ? part.reversed() : part
            let mapped = ordered.map { CGPoint(x: c + ($0.x - mx) * k, y: c + ($0.y - my) * k) }
            path.addLines(mapped)
            path.closeSubpath()
        }
        return path
    }
}
