import CompanionCore
import SwarmeKit
import SwiftUI

/// "Copia su server…": this Mac's connectors, skills and GitHub skill sources, picked together and
/// sent to a server in one go. HTTP connectors and skills start ticked, and so do sources with no token (one
/// with a token carries it to the server's vault, so it is the person's to tick); a
/// stdio connector runs a command of this Mac, so it only works there if the
/// server has it too, and starts unticked. An OAuth connector goes without
/// its login, which is done again on the server.
struct ServerCopySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var engineId = ""
    @State private var picked: Set<String> = []
    @State private var existing: (connectors: Set<String>, skills: Set<String>, sources: [SkillSource])?
    @State private var busy = false
    @State private var error: String?
    @State private var outcomes: [ServerCopyOutcome]?

    private var engine: RemoteEngine? { model.remoteEngines.first { $0.id == engineId } }
    private var copiableSkills: [Skill] { model.skills.filter { $0.source == nil } }

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
            // a skill a source keeps goes with its source
            picked = Set(model.mcpConnectors.filter { $0.transport == "http" }.map { "c:\($0.id)" } + copiableSkills.map { "s:\($0.id)" }
                         + model.skillSources.filter { $0.secret == nil }.map { "g:\($0.id)" })
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
                ForEach(model.mcpConnectors) { connector in
                    row(key: "c:\(connector.id)", name: connector.name, detail: detail(connector),
                        replaces: existing?.connectors.contains(connector.id) == true)
                }
            }
            Section(tr("Skill")) {
                if copiableSkills.isEmpty { Text(tr("Nessuna skill su questo Mac.")).foregroundStyle(.secondary) }
                ForEach(copiableSkills) { skill in
                    row(key: "s:\(skill.id)", name: skill.name, detail: skill.hasScripts ? tr("contiene script") : nil,
                        replaces: existing?.skills.contains(skill.id) == true)
                }
            }
            if !model.skillSources.isEmpty {
                Section(tr("Sorgenti GitHub")) {
                    ForEach(model.skillSources) { source in
                        row(key: "g:\(source.id)", name: source.name,
                            detail: source.secret.map { tr("col token %@, che va nel Vault del server", $0) } ?? tr("repository pubblico"),
                            replaces: existing?.sources.contains { SkillSourceCopy.same($0, source) } == true)
                    }
                }
            }
        }
        if model.mcpConnectors.contains(where: { $0.usesOAuth && picked.contains("c:\($0.id)") }) {
            Text(tr("I connettori OAuth si copiano senza il login: dopo la copia va rifatta l'autenticazione sul server."))
                .font(.system(size: 12)).foregroundStyle(Theme.warning)
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

    private func detail(_ connector: MCPConnector) -> String {
        if connector.usesOAuth { return tr("HTTP con OAuth: sul server va rifatto il login") }
        return connector.transport == "http" ? "HTTP" : tr("stdio: usa un comando di questo Mac, funziona solo se c'è anche sul server")
    }

    private func row(key: String, name: String, detail: String?, replaces: Bool) -> some View {
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
        .disabled(busy)
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
        let connectors = model.mcpConnectors.filter { picked.contains("c:\($0.id)") }
        let skills = copiableSkills.filter { picked.contains("s:\($0.id)") }
        let sources = model.skillSources.filter { picked.contains("g:\($0.id)") }
        outcomes = await model.copyToServer(connectors: connectors, skills: skills, sources: sources, engine: engine)
    }
}
