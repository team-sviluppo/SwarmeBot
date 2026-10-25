import CompanionCore
import SwarmeKit
import SwiftUI

/// "Copia su server…": this Mac's connectors and skills, picked together and
/// sent to a server in one go. HTTP connectors and skills start ticked; a
/// stdio connector runs a command of this Mac, so it only works there if the
/// server has it too, and starts unticked. OAuth connectors are signed in on
/// the server itself.
struct ServerCopySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var engineId = ""
    @State private var picked: Set<String> = []
    @State private var existing: (connectors: Set<String>, skills: Set<String>)?
    @State private var busy = false
    @State private var error: String?
    @State private var outcomes: [ServerCopyOutcome]?

    private var engine: RemoteEngine? { model.remoteEngines.first { $0.id == engineId } }
    private var copiable: [MCPConnector] { model.mcpConnectors.filter { !$0.usesOAuth } }
    private var oauth: [MCPConnector] { model.mcpConnectors.filter(\.usesOAuth) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Copia connettori e skill su un server")).font(.headline)
            if let outcomes { report(outcomes) } else { form }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task {
            engineId = model.remoteEngines.first?.id ?? ""
            // opened from one pane, the other list may not be loaded yet
            await model.refreshMCPConnectors()
            await model.refreshSkills()
            picked = Set(copiable.filter { $0.transport == "http" }.map { "c:\($0.id)" } + model.skills.map { "s:\($0.id)" })
        }
        .task(id: engineId) {
            existing = nil
            guard let engine else { return }
            existing = try? await model.serverInventory(engine)
        }
    }

    @ViewBuilder
    private var form: some View {
        Picker(tr("Server"), selection: $engineId) {
            ForEach(model.remoteEngines) { Text(verbatim: $0.name).tag($0.id) }
        }
        List {
            Section(tr("Connettori")) {
                if model.mcpConnectors.isEmpty { Text(tr("Nessun connettore su questo Mac.")).foregroundStyle(.secondary) }
                ForEach(copiable) { connector in
                    row(key: "c:\(connector.id)", name: connector.name,
                        detail: connector.transport == "http"
                            ? "HTTP"
                            : tr("stdio: usa un comando di questo Mac, funziona solo se c'è anche sul server"),
                        replaces: existing?.connectors.contains(connector.id) == true)
                }
                ForEach(oauth) { connector in
                    row(key: "c:\(connector.id)", name: connector.name, detail: tr("OAuth: sul server si collega a parte"),
                        replaces: false, disabled: true)
                }
            }
            Section(tr("Skill")) {
                if model.skills.isEmpty { Text(tr("Nessuna skill su questo Mac.")).foregroundStyle(.secondary) }
                ForEach(model.skills) { skill in
                    row(key: "s:\(skill.id)", name: skill.name, detail: skill.hasScripts ? tr("contiene script") : nil,
                        replaces: existing?.skills.contains(skill.id) == true)
                }
            }
        }
        if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(tr("Annulla")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            Button(tr("Copia (%@)", String(picked.count))) { Task { await copy() } }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || engine == nil || picked.isEmpty)
        }
    }

    private func row(key: String, name: String, detail: String?, replaces: Bool, disabled: Bool = false) -> some View {
        Toggle(isOn: Binding(get: { picked.contains(key) }, set: { if $0 { picked.insert(key) } else { picked.remove(key) } })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name).font(.system(size: 13))
                HStack(spacing: 6) {
                    if let detail { Text(detail) }
                    if replaces { Text(tr("già sul server: verrà sostituito")).foregroundStyle(Theme.warning) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disabled || busy)
    }

    @ViewBuilder
    private func report(_ outcomes: [ServerCopyOutcome]) -> some View {
        List(outcomes) { outcome in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: outcome.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(outcome.error == nil ? Theme.success : Theme.danger)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: outcome.name).font(.system(size: 13))
                    if let text = outcome.error ?? outcome.note {
                        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        Text(tr("Sul server i connettori e le skill copiati vanno poi dati ai bot che devono usarli."))
            .font(.system(size: 12)).foregroundStyle(.secondary)
        HStack { Spacer(); Button(tr("Fatto")) { dismiss() }.keyboardShortcut(.defaultAction) }
    }

    private func copy() async {
        guard let engine else { return }
        busy = true
        defer { busy = false }
        let connectors = copiable.filter { picked.contains("c:\($0.id)") }
        let skills = model.skills.filter { picked.contains("s:\($0.id)") }
        outcomes = await model.copyToServer(connectors: connectors, skills: skills, engine: engine)
    }
}
