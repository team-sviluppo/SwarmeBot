// Sidebar sections: their order, and the ones that have no bot yet.
//
// A section is only the `section` label each bot carries, so the harness
// knows nothing of order or of an empty section. Both live here, per Mac,
// as the Electron app kept them (`swarmebot.sectionOrder`).
import CompanionCore
import Foundation
import Observation
import SwarmeKit

@MainActor
@Observable
final class SectionLayout {
    static let shared = SectionLayout()
    private static let key = "swarmebot.sectionOrder"

    /// Every named section the user has seen or made, top to bottom.
    private(set) var order: [String]

    private init() {
        order = AppPaths.defaults.stringArray(forKey: Self.key) ?? []
    }

    /// The bots' sections in the saved order, with empty saved sections kept
    /// (they are drop targets) and new names appended where they appeared.
    /// Unassigned bots stay last.
    func arrange(_ sections: [(name: String?, bots: [Bot])]) -> [(name: String?, bots: [Bot])] {
        let unseen = sections.compactMap(\.name).filter { !order.contains($0) }
        var out: [(name: String?, bots: [Bot])] = (order + unseen).map { name in
            (name, sections.first { $0.name == name }?.bots ?? [])
        }
        if let loose = sections.first(where: { $0.name == nil }) { out.append(loose) }
        return out
    }

    var names: [String] { order }

    /// Remembers sections that bots brought in (another device, an import).
    func sync(_ found: [String]) {
        let unseen = found.filter { !order.contains($0) }
        if !unseen.isEmpty { save(order + unseen) }
    }

    func add(_ name: String) {
        guard !name.isEmpty, !order.contains(name) else { return }
        save(order + [name])
    }

    func remove(_ name: String) { save(order.filter { $0 != name }) }

    func rename(_ old: String, to new: String) {
        var next = order.map { $0 == old ? new : $0 }
        // renaming onto an existing section merges the two
        var seen = Set<String>()
        next = next.filter { seen.insert($0).inserted }
        save(next)
    }

    func move(_ name: String, by offset: Int) {
        guard let index = order.firstIndex(of: name) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        var next = order
        next.swapAt(index, target)
        save(next)
    }

    /// Drag and drop: `name` lands where `target` is, `target` moves down.
    func move(_ name: String, before target: String) {
        guard name != target, order.contains(name), order.contains(target) else { return }
        var next = order.filter { $0 != name }
        next.insert(name, at: next.firstIndex(of: target) ?? next.endIndex)
        save(next)
    }

    func canMove(_ name: String, by offset: Int) -> Bool {
        guard let index = order.firstIndex(of: name) else { return false }
        return order.indices.contains(index + offset)
    }

    private func save(_ next: [String]) {
        order = next
        AppPaths.defaults.set(next, forKey: Self.key)
    }
}
