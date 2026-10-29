import CompanionCore
import SwarmeKit
import SwiftUI

/// Settings › Skill › Sorgenti GitHub: a folder of skills in a repository, kept installed by the engine
/// (docs/plans/2026-10-28-code-mode-t3.md §11). The engine downloads, checks and swaps; this only says where
/// from, with which token, for which bots, and shows what happened.

/// A source in the list: its name, and what the last run found at a glance.
struct SkillSourceRow: View {
    let source: SkillSource

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(verbatim: source.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if source.last?.ok == false {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.danger)
                } else if !source.missing.isEmpty {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(Theme.warning)
                }
            }
            Text(verbatim: summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var summary: String {
        guard source.enabled else { return tr("Spenta") }
        if source.syncing { return tr("Aggiornamento…") }
        guard let installed = source.installed else { return tr("Non ancora scaricata") }
        return tr("%@ skill · %@", String(installed.skills.count), installed.shortSha)
    }
}

struct SkillSourceEditor: View {
    /// nil: a source being made.
    let source: SkillSource?
    let onSaved: (SkillSource) -> Void
    @Environment(AppModel.self) private var model

    @State private var name = ""
    @State private var repo = ""
    @State private var path = "skills"
    @State private var ref = "main"
    @State private var secret = ""
    @State private var enabled = true
    @State private var assignAll = false
    @State private var assignBots: Set<String> = []
    @State private var commands = ""
    @State private var connectors = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var confirmRollback = false
    @State private var copyTo: RemoteEngine?
    @State private var note: String?

    /// The engine's own copy, which the update and the rollback move on.
    private var current: SkillSource? { source.flatMap { id in model.skillSources.first { $0.id == id.id } } ?? source }

    private var secrets: [VaultSecret] { model.vault?.secrets.filter { $0.set } ?? [] }
    private var bots: [Bot] { model.state.bots.filter { $0.hidden != true } }

    var body: some View {
        Form {
            Section {
                TextField(tr("Nome"), text: $name, prompt: Text(verbatim: repo.isEmpty ? "owner/name" : repo))
                TextField(tr("Repository"), text: $repo, prompt: Text(verbatim: "owner/name"))
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(source != nil && current?.installed != nil)
                TextField(tr("Cartella"), text: $path, prompt: Text(verbatim: "skills"))
                    .font(.system(size: 12, design: .monospaced))
                TextField(tr("Ref"), text: $ref, prompt: Text(verbatim: "main"))
                    .font(.system(size: 12, design: .monospaced))
                Picker(tr("Token"), selection: $secret) {
                    Text(tr("Nessuno (repository pubblico)")).tag("")
                    ForEach(secrets) { Text(verbatim: $0.name).tag($0.name) }
                    if !secret.isEmpty, !secrets.contains(where: { $0.name == secret }) { Text(verbatim: secret).tag(secret) }
                }
                Toggle(tr("Aggiorna automaticamente"), isOn: $enabled)
            } header: {
                Text(source == nil ? tr("Nuova sorgente GitHub") : tr("Sorgente GitHub"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Per un repository privato crea un token fine-grained di GitHub, solo lettura (Contents: read) e solo su quel repository, e salvalo nel Vault di questo motore (Impostazioni › Vault)."))
                    Text(tr("Chi può scrivere su questo repository esegue codice su ogni motore che lo segue: proteggi il ramo."))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                Toggle(tr("A tutti i bot"), isOn: $assignAll)
                if !assignAll {
                    ForEach(bots) { bot in
                        Toggle(isOn: Binding(get: { assignBots.contains(bot.id) }, set: { on in
                            if on { assignBots.insert(bot.id) } else { assignBots.remove(bot.id) }
                        })) { Text(verbatim: bot.name) }
                    }
                }
            } header: {
                Text(tr("Chi le riceve"))
            } footer: {
                Text(tr("Le skill della sorgente si aggiungono a quelle che il bot ha già. Un bot può spegnerne una sua, e nei canali valgono per i membri scelti."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section {
                TextField(tr("Comandi"), text: $commands, prompt: Text(verbatim: "bru"))
                    .font(.system(size: 12, design: .monospaced))
                TextField(tr("Connettori"), text: $connectors, prompt: Text(verbatim: "clickup"))
                    .font(.system(size: 12, design: .monospaced))
            } header: {
                Text(tr("Cosa serve alle skill"))
            } footer: {
                Text(tr("Separati da virgola. Se mancano su questo motore te lo dico qui."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if let current { status(current) }

            Section {
                HStack {
                    Button(source == nil ? tr("Aggiungi") : tr("Salva")) { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || repo.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let current {
                        Button(tr("Aggiorna ora")) { Task { await run { await model.syncSkillSource(current, force: current.held) } } }
                            .disabled(busy || current.syncing)
                        if current.canRollback {
                            Button(tr("Torna alla versione precedente")) { confirmRollback = true }.disabled(busy)
                        }
                        if !model.isRemote, !model.remoteEngines.isEmpty {
                            Menu(tr("Copia su server")) {
                                ForEach(model.remoteEngines) { engine in
                                    Button(engine.name) {
                                        if current.secret != nil { copyTo = engine } else { Task { await copy(current, to: engine, withSecret: false) } }
                                    }
                                }
                            }
                            .fixedSize().disabled(busy)
                        }
                    }
                    Spacer()
                    if source != nil { Button(tr("Elimina"), role: .destructive) { confirmDelete = true } }
                    if busy || current?.syncing == true { ProgressView().controlSize(.small) }
                }
                if let error { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
                if let note { Text(verbatim: note).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .confirmationDialog(tr("Copiare anche il token?"), isPresented: Binding(get: { copyTo != nil }, set: { if !$0 { copyTo = nil } }), presenting: copyTo) { engine in
            Button(tr("Copia con il token")) { if let current { Task { await copy(current, to: engine, withSecret: true) } } }
            Button(tr("Copia senza il token")) { if let current { Task { await copy(current, to: engine, withSecret: false) } } }
        } message: { engine in
            Text(tr("Il segreto %@ va nel Vault di %@ via ssh e sostituisce uno con lo stesso nome. Senza, il server deve averlo già.", current?.secret ?? "", engine.name))
        }
        .task { await model.refreshVault() }
        .confirmationDialog(tr("Eliminare questa sorgente?"), isPresented: $confirmDelete) {
            Button(tr("Elimina"), role: .destructive) { if let current { Task { await model.deleteSkillSource(current) } } }
        } message: {
            Text(tr("Si eliminano anche le %@ skill che ha installato.", String(current?.installed?.skills.count ?? 0)))
        }
        .confirmationDialog(tr("Tornare alla versione precedente?"), isPresented: $confirmRollback) {
            Button(tr("Torna indietro"), role: .destructive) { if let current { Task { await run { await model.rollbackSkillSource(current) } } } }
        } message: {
            Text(tr("Le skill tornano com'erano prima dell'ultimo aggiornamento. Quel commit non viene reinstallato finché il repository non avanza."))
        }
    }

    // MARK: status

    @ViewBuilder
    private func status(_ source: SkillSource) -> some View {
        Section(tr("Stato")) {
            if let installed = source.installed {
                LabeledContent(tr("Installata")) {
                    Text(verbatim: "\(installed.shortSha) · \(Date(timeIntervalSince1970: installed.at / 1000).appFormatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12, design: .monospaced))
                }
                ForEach(installed.skills, id: \.name) { entry in
                    HStack(spacing: 6) {
                        Text(verbatim: "/\(entry.name)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        if !entry.present {
                            Label(tr("cartella mancante"), systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.warning)
                        }
                    }
                }
            } else {
                Text(tr("Ancora niente di scaricato: premi Aggiorna ora.")).foregroundStyle(.secondary)
            }
            if let last = source.last {
                if let error = last.error {
                    Label { Text(verbatim: error).textSelection(.enabled) } icon: { Image(systemName: "xmark.octagon.fill") }
                        .font(.system(size: 12)).foregroundStyle(Theme.danger)
                } else if last.held == true {
                    Label(tr("Si è tornati a una versione precedente: il commit più nuovo non viene installato finché il repository non avanza."), systemImage: "pause.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warning)
                } else if last.rolledBack == true {
                    Label(tr("Tornata alla versione precedente."), systemImage: "arrow.uturn.backward.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let updated = last.updated, !updated.isEmpty {
                    updatedSummary(updated)
                } else if last.unchanged == true {
                    Label(tr("Aggiornata: niente di nuovo."), systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let conflicts = last.conflicts, !conflicts.isEmpty {
                    Label(tr("Non installate perché esiste già una skill con lo stesso nome: %@", conflicts.joined(separator: ", ")), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warning)
                }
                Text(tr("Ultimo controllo: %@", Date(timeIntervalSince1970: last.checkedAt / 1000).appFormatted(date: .abbreviated, time: .shortened)))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            ForEach(source.missing) { missing in
                Label(missing.kind == "command" ? tr("Manca il comando %@ su questo motore", missing.name) : tr("Manca il connettore %@ su questo motore", missing.name),
                      systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            if let secret = source.secret, source.secretPresent == false {
                Label(tr("Il segreto %@ non è nel Vault di questo motore", secret), systemImage: "key").font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
        }
    }

    /// An update's news: a warning of what changed, since the skills can run scripts.
    private func updatedSummary(_ updated: SkillSource.Updated) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(tr("Aggiornata: ecco cosa è cambiato"), systemImage: "arrow.down.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if !updated.added.isEmpty { Text(tr("Nuove: %@", updated.added.joined(separator: ", "))).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            if !updated.changed.isEmpty { Text(tr("Modificate: %@", updated.changed.joined(separator: ", "))).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            if !updated.removed.isEmpty { Text(tr("Rimosse: %@", updated.removed.joined(separator: ", "))).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
    }

    // MARK: actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let source else { return }
        name = source.name == source.repo ? "" : source.name
        repo = source.repo
        path = source.path
        ref = source.ref
        secret = source.secret ?? ""
        enabled = source.enabled
        assignAll = source.assign.all
        assignBots = Set(source.assign.botIds)
        commands = source.requires.commands.joined(separator: ", ")
        connectors = source.requires.connectors.joined(separator: ", ")
    }

    private func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func run(_ work: () async -> Void) async {
        busy = true
        error = nil
        await work()
        busy = false
    }

    /// The source onto a server, with its token if asked; the server's own first update says whether it works there.
    private func copy(_ source: SkillSource, to engine: RemoteEngine, withSecret: Bool) async {
        busy = true
        error = nil
        note = nil
        defer { busy = false }
        do {
            let copied = try await model.copySkillSource(source, to: engine, withSecret: withSecret)
            if let failure = copied.last?.error { error = tr("Copiata su %@, ma il primo aggiornamento sul server non è riuscito: %@", engine.name, failure) }
            else { note = tr("Copiata su %@: %@ skill installate. Sul server vanno date ai bot che devono usarle.", engine.name, String(copied.installed?.skills.count ?? 0)) }
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        let trimmedRepo = repo.trimmingCharacters(in: .whitespaces)
        var fields: [String: Any] = [
            "repo": trimmedRepo, "path": path.trimmingCharacters(in: .whitespaces), "ref": ref.trimmingCharacters(in: .whitespaces),
            "name": name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedRepo : name.trimmingCharacters(in: .whitespaces),
            "secret": secret.isEmpty ? NSNull() : secret as Any, "enabled": enabled,
            "assign": ["all": assignAll, "botIds": assignAll ? [] : Array(assignBots).sorted()] as [String: Any],
            "requires": ["commands": list(commands), "connectors": list(connectors)],
        ]
        if path.trimmingCharacters(in: .whitespaces).isEmpty { fields["path"] = "." }
        busy = true
        error = nil
        let result = source == nil ? await model.addSkillSource(fields) : await model.updateSkillSource(source?.id ?? "", fields)
        busy = false
        switch result {
        case let .success(saved): onSaved(saved)
        case let .failure(failure): error = failure.localizedDescription
        }
    }
}
