// How one bot looks, wherever it is drawn — `SwarmeAvatar` in Avatar.tsx with
// a `look`: an uploaded picture (still image, 9×8 sprite sheet or SVG)
// replaces the mascot; otherwise the mascot wears the bot's silhouette and
// plays the bot's motion beats.
import AppKit
import CompanionCore
import Observation
import SwarmeKit
import SwiftUI

struct BotAvatar: View {
    let bot: Bot
    var size: CGFloat = 32
    /// nil derives it from the bot (`SwarmeState.forBot`) without a transcript.
    var state: SwarmeState? = nil
    var animated: Bool = true
    var priority: Bool = false
    var trackPointer: Bool = true

    var body: some View {
        if let image = bot.mascotAvatarImage, !image.isEmpty {
            if let row = SpriteSheet.row(bot.mascotAvatarSheetRow) {
                SpriteSheetAvatar(name: image, row: row, size: size)
            } else {
                PictureAvatar(source: .attachment(image), size: size)
            }
        } else if let svg = bot.mascotAvatarSvg, !svg.isEmpty {
            PictureAvatar(source: .svg(svg), size: size)
        } else {
            SwarmeAvatar(
                color: bot.color, size: size, state: state ?? SwarmeState.forBot(bot, last: nil),
                silhouette: bot.mascotSilhouette, animated: animated, priority: priority,
                beat: MascotBeats.shared.events[bot.id], trackPointer: trackPointer
            )
        }
    }
}

// MARK: - Pictures

/// Decoded avatar pictures, shared by every place a bot is drawn.
@MainActor
final class AvatarImageStore {
    static let shared = AvatarImageStore()
    private var images: [String: NSImage] = [:]
    private var loading: [String: Task<NSImage?, Never>] = [:]

    func cached(_ key: String) -> NSImage? { images[key] }

    func image(named name: String, model: AppModel) async -> NSImage? {
        if let hit = images[name] { return hit }
        if let running = loading[name] { return await running.value }
        let task = Task<NSImage?, Never> { @MainActor in
            guard let data = await model.attachmentData(path: name) else { return nil }
            return NSImage(data: data)
        }
        loading[name] = task
        let image = await task.value
        loading[name] = nil
        if let image { images[name] = image }
        return image
    }

    /// SVG markup → image via AppKit's own SVG renderer (`NSSVGImageRep`).
    /// The markup passed the server's allowlist at upload.
    func svg(_ markup: String) -> NSImage? {
        let key = "svg:\(markup.hashValue)"
        if let hit = images[key] { return hit }
        guard let image = NSImage(data: Data(markup.utf8)) else { return nil }
        images[key] = image
        return image
    }
}

private struct PictureAvatar: View {
    enum Source: Equatable { case attachment(String), svg(String) }
    let source: Source
    let size: CGFloat
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Theme.raised)
            if let image = image ?? immediate {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: source) {
            if case let .attachment(name) = source {
                image = await AvatarImageStore.shared.image(named: name, model: model)
            }
        }
    }

    private var immediate: NSImage? {
        switch source {
        case let .svg(markup): return AvatarImageStore.shared.svg(markup)
        case let .attachment(name): return AvatarImageStore.shared.cached(name)
        }
    }
}

// MARK: - Sprite sheets

/// `lib/sprite-sheet.ts`: 9 rows × 8 columns, 250 ms per frame.
enum SpriteSheet {
    static let rows = 9
    static let cols = 8
    static let frameSeconds = 0.25

    static func row(_ value: Double?) -> Int? {
        guard let value, value.rounded() == value, value >= 0, value < Double(rows) else { return nil }
        return Int(value)
    }

    @MainActor private static var counts: [String: [Int]] = [:]

    /// Frames each row really draws: up to the last cell with a pixel of
    /// alpha > 8 and brightness > 12. An empty row is 1 (a still).
    @MainActor
    static func frameCounts(_ name: String, image: CGImage) -> [Int] {
        if let hit = counts[name] { return hit }
        let result = measure(image)
        counts[name] = result
        return result
    }

    private static func measure(_ image: CGImage) -> [Int] {
        let width = image.width, height = image.height
        let frameW = width / cols, frameH = height / rows
        guard frameW >= 1, frameH >= 1,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Array(repeating: cols, count: rows) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return Array(repeating: cols, count: rows) }
        func ink(_ col: Int, _ row: Int) -> Bool {
            for y in (row * frameH)..<((row + 1) * frameH) {
                var at = (y * width + col * frameW) * 4
                for _ in 0..<frameW {
                    if data[at + 3] > 8 && max(data[at], data[at + 1], data[at + 2]) > 12 { return true }
                    at += 4
                }
            }
            return false
        }
        return (0..<rows).map { row in
            var last = -1
            for col in 0..<cols where ink(col, row) { last = col }
            return last + 1 == 0 ? 1 : last + 1
        }
    }
}

struct SpriteSheetAvatar: View {
    let name: String
    let row: Int
    let size: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: CGImage?
    @State private var frames = SpriteSheet.cols

    var body: some View {
        ZStack {
            Color.black
            if let sheet {
                TimelineView(.periodic(from: .now, by: SpriteSheet.frameSeconds)) { timeline in
                    let index = reduceMotion || frames < 2 ? 0
                        : Int(timeline.date.timeIntervalSinceReferenceDate / SpriteSheet.frameSeconds) % frames
                    if let cell = cell(sheet, column: index) {
                        Image(decorative: cell, scale: 1).resizable().interpolation(.high)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: name) {
            guard let image = await AvatarImageStore.shared.image(named: name, model: model),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            frames = SpriteSheet.frameCounts(name, image: cg)[row]
            sheet = cg
        }
    }

    private func cell(_ sheet: CGImage, column: Int) -> CGImage? {
        let w = sheet.width / SpriteSheet.cols, h = sheet.height / SpriteSheet.rows
        return sheet.cropping(to: CGRect(x: column * w, y: row * h, width: w, height: h))
    }
}

// MARK: - Motion beats

/// The store's motion triggers (`store.tsx`), derived here by diffing the
/// model: selecting a bot → switch, a new bot → arrive, marked unread →
/// surprise, a turn starting → working and ending → celebrate, a tool
/// finishing → success / failure, reasoning → thinking, a reply → blink.
@MainActor
@Observable
final class MascotBeats {
    static let shared = MascotBeats()
    private(set) var events: [String: MascotBeatEvent] = [:]

    @ObservationIgnored private var counter = 0
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var snapshot: [String: Snap] = [:]
    @ObservationIgnored private var thinking: Set<String> = []
    @ObservationIgnored private var lastSelection: ChatID?
    @ObservationIgnored private var seeded = false

    private struct Snap: Equatable {
        var busy: Bool
        var unread: Bool
        var lastId: String?
    }

    func fire(_ motion: MascotMotion, for botId: String) {
        counter += 1
        events[botId] = MascotBeatEvent(motion: motion, key: counter)
    }

    func attach(_ model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.state.bots
            _ = model.selection
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
        diff()
    }

    private func diff() {
        guard let model, model.status == .live else { return }
        let bots = model.state.bots
        var next: [String: Snap] = [:]
        for bot in bots {
            let last = model.state.messages[bot.threadId]?.last
            let snap = Snap(busy: model.isBusy(bot), unread: bot.unread, lastId: last?.id)
            next[bot.id] = snap
            guard seeded else { continue }
            guard let before = snapshot[bot.id] else { fire(.arrive, for: bot.id); continue }
            if !before.busy && snap.busy { fire(.working, for: bot.id); thinking.remove(bot.id) }
            if before.busy && !snap.busy { fire(.celebrate, for: bot.id) }
            if !before.unread && snap.unread { fire(.surprise, for: bot.id) }
            if before.lastId != snap.lastId, let last, last.role == .bot {
                switch last.kind {
                case .activity:
                    if let ok = last.tool?.ok { fire(ok ? .success : .failure, for: bot.id) }
                case .text:
                    if !snap.busy || before.busy == snap.busy { fire(.blink, for: bot.id) }
                default: break
                }
            }
            if snap.busy, !thinking.contains(bot.id), model.live.reasoning[bot.threadId]?.isEmpty == false {
                thinking.insert(bot.id)
                fire(.thinking, for: bot.id)
            }
        }
        if seeded, model.selection != lastSelection, case let .bot(id) = model.selection {
            fire(.switch, for: id)
        }
        lastSelection = model.selection
        snapshot = next
        seeded = true
    }
}
