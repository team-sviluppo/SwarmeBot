// The plugins the connected engine carries, and the switch for each
// (docs/plans/2026-10-28-code-mode-t3.md §12). The app's own plugins are
// SwarmeBotUI's; a plugin shows its interface when both sides have it.
import CompanionCore
import Foundation

extension AppModel {
    public func refreshPlugins() async {
        guard let client else { return }
        // no route: an engine that predates plugins carries none
        enginePlugins = (try? await client.plugins()) ?? []
    }

    /// Whether the engine carries this plugin and has it on.
    public func engineHasPlugin(_ id: String) -> Bool {
        enginePlugins.contains { $0.id == id && $0.enabled }
    }

    public func setPlugin(_ id: String, enabled: Bool) async {
        guard let client else { return }
        do {
            enginePlugins = try await client.setPlugin(id: id, enabled: enabled)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
