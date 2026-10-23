// Settings windows, each bound to one engine.
//
// ⌘, always edits this Mac's engine; a remote server has its own window
// (Impostazioni › Server remoti › Impostazioni del server). The window's model
// follows whichever engine it shows, so a settings window bound to another
// engine gets a settings-only model of its own: the same client and the same
// config, instances, connectors and skills, kept fresh by the event stream,
// without the fleet, the transcripts or the peers.
import CompanionCore
import Foundation

extension AppModel {
    /// The model a settings window edits `choice` with: this one while the
    /// window shows that engine, a settings-only one otherwise.
    public func settingsModel(for choice: EngineChoice) -> AppModel {
        if choice == engineChoice, !settingsOnly { return self }
        if let cached = settingsModels[choice] { return cached }
        let model = AppModel(settingsFor: choice, owner: self)
        settingsModels[choice] = model
        model.connectToChoice()
        return model
    }

    /// A settings window closed: its own model, if any, stops streaming.
    public func closeSettings(for choice: EngineChoice) {
        settingsModels.removeValue(forKey: choice)?.stopSettings()
    }

    /// The servers changed: settings models of forgotten ones go, the others see the new list.
    func syncSettingsModels() {
        for (choice, model) in settingsModels {
            if case let .remote(id) = choice, !remoteEngines.contains(where: { $0.id == id }) {
                closeSettings(for: choice)
            } else {
                model.remoteEngines = remoteEngines
            }
        }
    }

    /// This Mac's engine (re)started on `port`: its settings model follows it.
    func localEngineRunning(on port: Int) {
        guard let model = settingsModels[.local], model.localPort != port else { return }
        model.localPort = port
        model.connectToChoice()
    }

    /// What a settings window keeps up to date from the stream.
    func settingsFrame(_ frame: Frame) {
        switch frame {
        case .config:
            Task { await refreshInstances() }
            Task { await refreshConfig() }
        case let .usageLimit(instanceId, limit):
            if let index = instances.firstIndex(where: { $0.instanceId == instanceId }) { instances[index].usageLimit = limit }
        case .mcpConnectors:
            Task { await refreshMCPConnectors() }
        case .skills:
            Task { await refreshSkills() }
        default:
            break
        }
    }

    private func stopSettings() {
        streamTask?.cancel()
        streamTask = nil
        client = nil
    }
}
