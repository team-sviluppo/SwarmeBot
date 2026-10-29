// The secrets vault (docs/plans/2026-10-25-vault.md): Settings › Vault keeps
// the secrets of the engine shown, the bot's card says which ones the bot may
// use and how. A value is typed here and never shown again.
import CompanionCore
import SwarmeKit
import SwiftUI

enum VaultText {
    static func preset(_ preset: String) -> String {
        switch preset {
        case "github": return "GitHub"
        case "huggingface": return "Hugging Face"
        case "npm": return "npm"
        default: return tr("Generico")
        }
    }

    static func presetHelp(_ preset: String) -> String {
        switch preset {
        case "github": return tr("Il comando riceve anche GH_TOKEN e GITHUB_TOKEN, e git è autenticato verso https://github.com senza mettere il token nell'URL.")
        case "huggingface": return tr("Il comando riceve anche HF_TOKEN e HUGGING_FACE_HUB_TOKEN, che hf e huggingface_hub leggono da soli.")
        case "npm": return tr("Il comando riceve anche NPM_TOKEN e NODE_AUTH_TOKEN: il .npmrc del progetto deve usarli.")
        default: return tr("Il comando riceve una variabile con il nome del secret.")
        }
    }
}

/// Settings › Vault.
struct VaultPane: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    private static let newId = "__new__"

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                status
                Divider()
                List(selection: $selected) {
                    ForEach(model.vault?.secrets ?? []) { secret in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: secret.name).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            Text(secret.description.isEmpty ? VaultText.preset(secret.preset) : secret.description)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(secret.name)
                    }
                    if selected == Self.newId {
                        Label(tr("Nuovo secret"), systemImage: "plus.circle").tag(Self.newId)
                    }
                }
                Divider()
                HStack {
                    Button { selected = Self.newId } label: { Image(systemName: "plus") }
                        .help(tr("Aggiungi un secret"))
                        .disabled(!model.vaultEditable || model.vault?.locked == true)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 240, maxWidth: 300)
            Group {
                if selected == Self.newId {
                    VaultSecretEditor(secret: nil) { selected = $0 }.id(Self.newId)
                } else if let name = selected, let secret = model.vault?.secrets.first(where: { $0.name == name }) {
                    VaultSecretEditor(secret: secret) { selected = $0 }.id(secret.name)
                } else {
                    VStack(spacing: 8) {
                        Text(tr("Il vault custodisce token e chiavi che i bot usano nei comandi, senza mai vederne il valore."))
                            .foregroundStyle(.secondary)
                        Text(tr("Aggiungi un secret con +, poi scegli nei dettagli di ogni bot quali può usare."))
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.refreshVault() }
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(model.vault?.locked == true ? Theme.warning : .secondary)
            Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private var icon: String {
        if model.vault?.locked == true { return "lock.trianglebadge.exclamationmark" }
        return model.vault?.encrypted == true ? "lock.shield" : "lock"
    }

    private var statusText: String {
        guard let vault = model.vault else { return "…" }
        if vault.locked { return tr("Il vault è bloccato: manca la sua chiave su questo motore, i secret non si possono usare.") }
        if model.isRemote {
            return model.vaultEditable
                ? tr("Sul server, in un file leggibile solo dal suo utente. Le modifiche passano via ssh.")
                : tr("Solo lettura: il vault di un server si modifica dal Mac che lo amministra.")
        }
        return vault.encrypted ? tr("Cifrato su questo Mac, con la chiave nel Portachiavi.") : tr("Su questo Mac, in un file leggibile solo da te.")
    }
}

private struct VaultSecretEditor: View {
    /// Nil: a new secret.
    let secret: VaultSecret?
    let onSaved: (String?) -> Void
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var preset = "generic"
    @State private var about = ""
    @State private var hint = ""
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?
    @State private var done: String?
    @State private var confirmDelete = false

    private var editable: Bool { model.vaultEditable && model.vault?.locked != true }

    var body: some View {
        Form {
            Section {
                if secret == nil {
                    TextField(tr("Nome"), text: $name, prompt: Text(verbatim: "GITHUB_TOKEN"))
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: name) { _, typed in
                            let clean = typed.uppercased().replacingOccurrences(of: " ", with: "_")
                            if clean != typed { name = clean }
                        }
                } else {
                    LabeledContent(tr("Nome")) { Text(verbatim: name).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
                Picker(tr("Tipo"), selection: $preset) {
                    ForEach(["generic", "github", "huggingface", "npm"], id: \.self) { Text(VaultText.preset($0)).tag($0) }
                }
                Text(VaultText.presetHelp(preset)).font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField(tr("Valore"), text: $value,
                            prompt: Text(secret == nil ? tr("Il token o la chiave") : tr("Lascia vuoto per non cambiarlo")))
            }
            Section {
                TextField(tr("Descrizione"), text: $about, prompt: Text(tr("Cos'è, per il bot: es. token dell'organizzazione acme")))
                TextField(tr("Come usarlo"), text: $hint, prompt: Text(tr("Istruzioni per il bot: es. usalo solo per push su origin")), axis: .vertical)
                    .lineLimit(2...5)
            } footer: {
                Text(tr("Il bot vede nome, descrizione e istruzioni. Il valore non arriva mai al modello: lo mette il motore nei comandi, e se compare in un output viene mascherato."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(secret == nil ? tr("Aggiungi") : tr("Salva")) { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!editable || busy || name.isEmpty || (secret == nil && value.isEmpty))
                    // a secret of this Mac's vault can go to a server this Mac administers
                    if let secret, !model.isRemote, !model.remoteEngines.isEmpty {
                        Menu(tr("Copia su server")) {
                            ForEach(model.remoteEngines) { engine in
                                Button(engine.name) { Task { await copy(secret, to: engine) } }
                            }
                        }
                        .fixedSize()
                        .disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    if secret != nil {
                        Button(tr("Elimina"), role: .destructive) { confirmDelete = true }.disabled(!editable || busy)
                    }
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
                if let done {
                    Text(done).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!editable && secret == nil)
        .onAppear(perform: load)
        .confirmationDialog(tr("Eliminare %@?", name), isPresented: $confirmDelete) {
            Button(tr("Elimina"), role: .destructive) { Task { await delete() } }
        } message: {
            Text(tr("Anche i bot che lo usano lo perdono."))
        }
    }

    private func load() {
        guard let secret else { return }
        name = secret.name
        preset = secret.preset
        about = secret.description
        hint = secret.hint
    }

    private func save() async {
        busy = true
        defer { busy = false }
        error = nil
        done = nil
        let input = VaultSecretInput(name: name, preset: preset, description: about, hint: hint, value: value.isEmpty ? nil : value)
        do {
            try await model.saveVaultSecret(input, existing: secret != nil)
            value = ""
            done = tr("Salvato")
            if secret == nil { onSaved(name) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do {
            try await model.deleteVaultSecret(name)
            onSaved(nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copy(_ secret: VaultSecret, to engine: RemoteEngine) async {
        busy = true
        defer { busy = false }
        error = nil
        done = nil
        do {
            try await model.copyVaultSecret(secret, to: engine)
            done = tr("Copiato su %@", engine.name)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Dettagli › Secret: which secrets of the vault the bot may use, and how.
struct BotSecretsCard: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var note = ""
    @State private var error: String?

    private var grants: VaultBotGrants { model.vault?.grants(botId: bot.id) ?? VaultBotGrants() }
    private var driverKind: String? { model.instances.first { $0.instanceId == bot.modelSelection.instanceId }?.driverKind }

    var body: some View {
        SettingsCard(tr("Secret")) {
            if let vault = model.vault, !vault.secrets.isEmpty {
                if let warning = engineWarning {
                    Text(warning)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.top, 9)
                }
                ForEach(Array(vault.secrets.enumerated()), id: \.element.id) { index, secret in
                    if index > 0 { CardDivider(leading: 48) }
                    row(secret)
                }
                CardDivider(leading: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Istruzioni per i secret")).font(.system(size: 12, weight: .medium))
                    TextField(tr("Istruzioni per i secret"), text: $note,
                              prompt: Text(tr("Es. non fare mai force push; scarica i modelli in ./models")), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { save(grants.secrets, note: note) }
                    if note != grants.note {
                        Button(tr("Salva istruzioni")) { save(grants.secrets, note: note) }.controlSize(.small)
                    }
                }
                .padding(12)
                .disabled(!model.vaultEditable)
                if let error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                        .padding(.horizontal, 12).padding(.bottom, 9)
                }
            } else {
                SettingRow(icon: "key", tint: Theme.accentText, title: tr("Nessun secret"),
                           subtitle: tr("Aggiungili in Impostazioni › Vault, poi scegli qui quali usa questo bot.")) {
                    SettingsLink { Text(tr("Apri")) }
                }
            }
        }
        .task { await model.refreshVault() }
        .onAppear { note = grants.note }
        .onChange(of: bot.id) { _, _ in note = grants.note }
        .onChange(of: grants.note) { _, saved in note = saved }
    }

    private var engineWarning: String? {
        guard let kind = driverKind, let support = model.vault?.support else { return nil }
        if !support.env.contains(kind) { return tr("Il motore di questo bot non ha una shell: i secret non si possono usare.") }
        if !support.safe.contains(kind), grants.secrets.contains(where: { $0.mode == "safe" }) {
            return tr("Il motore di questo bot non ha lo strumento sicuro: usa la modalità variabile d'ambiente, oppure cambia motore.")
        }
        return nil
    }

    private func row(_ secret: VaultSecret) -> some View {
        let entry = grants.secrets.first { $0.name == secret.name }
        return SettingRow(icon: "key", tint: entry != nil ? Theme.accentText : Theme.tertiary, title: secret.name,
                          subtitle: secret.description.isEmpty ? VaultText.preset(secret.preset) : secret.description) {
            HStack(spacing: 10) {
                if let entry {
                    Picker("", selection: Binding(get: { entry.mode }, set: { mode in
                        save(grants.secrets.map { $0.name == secret.name ? VaultGrant(name: $0.name, mode: mode) : $0 }, note: grants.note)
                    })) {
                        Text(tr("Sicura")).tag("safe")
                        Text(tr("Variabile d'ambiente")).tag("env")
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                    .help(entry.mode == "env"
                          ? tr("Il valore è nell'ambiente della CLI del bot per tutto il turno: comodo, ma il modello può leggerlo se lo stampa.")
                          : tr("Il bot usa il secret solo tramite lo strumento run_with_secrets: il motore esegue il comando e maschera il valore nell'output."))
                }
                Toggle("", isOn: Binding(get: { entry != nil }, set: { use in
                    save(use ? grants.secrets + [VaultGrant(name: secret.name, mode: "safe")] : grants.secrets.filter { $0.name != secret.name },
                         note: grants.note)
                }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
            }
            .disabled(!model.vaultEditable)
        }
    }

    private func save(_ secrets: [VaultGrant], note: String) {
        error = nil
        Task {
            do {
                try await model.setVaultGrants(botId: bot.id, VaultBotGrants(secrets: secrets, note: note))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
