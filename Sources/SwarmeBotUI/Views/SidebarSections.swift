// Sidebar order: this Mac's sections, its channels and the servers, and the
// sections that have no bot yet.
//
// A section is only the `section` label each bot carries, so the harness
// knows nothing of order or of an empty section. Both live here, per Mac,
// as the Electron app kept the sections (`swarmebot.sectionOrder`); the
// channels, the unassigned bots and each server are items of the same list,
// so any of them can go anywhere.
import CompanionCore
import Foundation
import Observation
import SwarmeKit

/// One block of the sidebar, under its own header.
enum SidebarItem: Hashable {
    case section(String)
    /// This Mac's bots with no section.
    case unassigned
    /// This Mac's channels.
    case rooms
    /// A server, by its id.
    case engine(String)

    init?(stored: String) {
        switch stored {
        case "unassigned": self = .unassigned
        case "rooms": self = .rooms
        default:
            if stored.hasPrefix("section:") {
                self = .section(String(stored.dropFirst(8)))
            } else if stored.hasPrefix("engine:") {
                self = .engine(String(stored.dropFirst(7)))
            } else {
                return nil
            }
        }
    }

    var stored: String {
        switch self {
        case let .section(name): return "section:" + name
        case .unassigned: return "unassigned"
        case .rooms: return "rooms"
        case let .engine(id): return "engine:" + id
        }
    }

    var sectionName: String? {
        if case let .section(name) = self { return name }
        return nil
    }

    var isSection: Bool { sectionName != nil }
}

@MainActor
@Observable
final class SectionLayout {
    static let shared = SectionLayout()
    private static let key = "swarmebot.sidebarOrder"
    private static let legacyKey = "swarmebot.sectionOrder"

    /// Every item the user has seen or made, top to bottom.
    private(set) var items: [SidebarItem]

    private init() {
        if let stored = AppPaths.defaults.stringArray(forKey: Self.key) {
            items = stored.compactMap(SidebarItem.init(stored:))
        } else {
            // the sections' order of earlier versions, then the blocks as they were laid out
            items = (AppPaths.defaults.stringArray(forKey: Self.legacyKey) ?? []).map(SidebarItem.section)
                + [.unassigned, .rooms]
        }
    }

    /// The named sections, top to bottom.
    var names: [String] { items.compactMap(\.sectionName) }

    /// The bots' sections in the saved order, with empty saved sections kept
    /// (they are drop targets) and new names appended where they appeared.
    /// Unassigned bots stay last; `blocks` places them among the rest.
    func arrange(_ sections: [(name: String?, bots: [Bot])]) -> [(name: String?, bots: [Bot])] {
        let unseen = sections.compactMap(\.name).filter { !names.contains($0) }
        var out: [(name: String?, bots: [Bot])] = (names + unseen).map { name in
            (name, sections.first { $0.name == name }?.bots ?? [])
        }
        if let loose = sections.first(where: { $0.name == nil }) { out.append(loose) }
        return out
    }

    /// The items shown, in the saved order.
    func blocks(_ visible: [SidebarItem]) -> [SidebarItem] {
        Self.completed(items, with: visible).filter(visible.contains)
    }

    /// Remembers sections that bots brought in (another device, an import).
    func sync(_ found: [String]) { complete(with: found.map(SidebarItem.section)) }

    /// Remembers servers added since; they go at the bottom.
    func syncEngines(_ ids: [String]) { complete(with: ids.map(SidebarItem.engine)) }

    func add(_ name: String) {
        guard !name.isEmpty else { return }
        complete(with: [.section(name)])
    }

    func remove(_ name: String) { save(items.filter { $0 != .section(name) }) }

    func rename(_ old: String, to new: String) {
        var next = items.map { $0 == .section(old) ? .section(new) : $0 }
        // renaming onto an existing section merges the two
        var seen = Set<SidebarItem>()
        next = next.filter { seen.insert($0).inserted }
        save(next)
    }

    /// Menu: swap places with the neighbour shown above or below.
    func move(_ item: SidebarItem, by offset: Int, among visible: [SidebarItem]) {
        guard let index = visible.firstIndex(of: item), visible.indices.contains(index + offset) else { return }
        move(item, to: visible[index + offset], among: visible)
    }

    /// Drag and drop: `item` takes the place of `target`, which moves one step
    /// towards where `item` was.
    func move(_ item: SidebarItem, to target: SidebarItem, among visible: [SidebarItem]) {
        save(Self.moving(item, to: target, in: Self.completed(items, with: visible)))
    }

    static func canMove(_ item: SidebarItem, by offset: Int, among visible: [SidebarItem]) -> Bool {
        guard let index = visible.firstIndex(of: item) else { return false }
        return visible.indices.contains(index + offset)
    }

    /// The saved order with `extra` items it does not have yet: sections
    /// after the last section, the unassigned bots after them, the channels
    /// after those, servers at the bottom.
    static func completed(_ items: [SidebarItem], with extra: [SidebarItem]) -> [SidebarItem] {
        var out = items
        func afterSections(_ item: SidebarItem) {
            out.insert(item, at: out.lastIndex(where: \.isSection).map { $0 + 1 } ?? 0)
        }
        for item in extra where item.isSection && !out.contains(item) { afterSections(item) }
        if !out.contains(.unassigned) { afterSections(.unassigned) }
        if !out.contains(.rooms) { out.insert(.rooms, at: out.firstIndex(of: .unassigned).map { $0 + 1 } ?? out.endIndex) }
        for item in extra where !out.contains(item) { out.append(item) }
        return out
    }

    static func moving(_ item: SidebarItem, to target: SidebarItem, in order: [SidebarItem]) -> [SidebarItem] {
        guard item != target, let from = order.firstIndex(of: item), let to = order.firstIndex(of: target) else { return order }
        var next = order
        next.remove(at: from)
        // dragged down, it goes below the target; dragged up, above it
        let target = next.firstIndex(of: target) ?? next.endIndex
        next.insert(item, at: from < to ? target + 1 : target)
        return next
    }

    private func complete(with extra: [SidebarItem]) {
        let next = Self.completed(items, with: extra)
        if next != items { save(next) }
    }

    private func save(_ next: [SidebarItem]) {
        items = next
        AppPaths.defaults.set(next.map(\.stored), forKey: Self.key)
    }
}
