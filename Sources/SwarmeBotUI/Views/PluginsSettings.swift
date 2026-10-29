// Impostazioni › Plugin: the plugins the engine carries, and a switch for each
// (docs/plans/2026-10-28-code-mode-t3.md §12). The switch is the engine's: it
// stops serving the plugin's routes and ignoring its flags; the data stays.
import CompanionCore
import SwarmeKit
import SwiftUI

struct PluginsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.enginePlugins.isEmpty {
                    Text(tr("Questo motore non ha plugin."))
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(model.enginePlugins) { plugin in
                    PluginRow(plugin: plugin)
                }
            } header: {
                Text(tr("Plugin del motore"))
            } footer: {
                Text(tr("Un plugin acceso aggiunge funzioni a bot e canali; spento, smette di rispondere e di essere ascoltato, ma non perde i suoi dati."))
            }
        }
        .formStyle(.grouped)
    }
}

private struct PluginRow: View {
    let plugin: EnginePluginInfo
    @Environment(AppModel.self) private var model

    /// The app has this plugin's interface linked in.
    private var inThisApp: Bool { PluginHost.shared.plugins.contains { $0.id == plugin.id } }
    private var missing: [String] {
        plugin.requires.filter { id in !model.enginePlugins.contains { $0.id == id && $0.enabled } }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: plugin.name).font(.system(size: 13, weight: .medium))
                    Text(verbatim: plugin.version).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
                if !plugin.requires.isEmpty {
                    Text(tr("Richiede %@", plugin.requires.joined(separator: ", ")))
                        .font(.system(size: 11.5)).foregroundStyle(missing.isEmpty ? Theme.tertiary : Theme.warning)
                }
                if !inThisApp {
                    Text(tr("Questa app non ha l'interfaccia di questo plugin."))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { plugin.enabled }, set: { next in Task { await model.setPlugin(plugin.id, enabled: next) } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!missing.isEmpty)
        }
    }
}
