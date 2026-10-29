import CompanionCore
import SwarmeKit
import SwiftUI

/// ⌘, — profile, engines, connectors, the phone, control of this Mac, keys and services, DeepSeek Harness, updates.
/// Always this Mac's engine, whichever engine the main window shows; a server has RemoteSettingsView.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    /// Debug aid for screenshots: `SWARMEBOT_SETTINGS_TAB=phone` opens on that pane.
    @State private var tab = ProcessInfo.processInfo.environment["SWARMEBOT_SETTINGS_TAB"] ?? "general"

    var body: some View {
        tabs
            .environment(app.settingsModel(for: .local))
            .onDisappear { app.closeSettings(for: .local) }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            GeneralPane().tabItem { Label(tr("Generale"), systemImage: "person.crop.circle") }.tag("general")
            EnginesPane().tabItem { Label(tr("Motori"), systemImage: "cpu") }.tag("engines")
            RemoteServersPane().tabItem { Label(tr("Server remoti"), systemImage: "server.rack") }.tag("remote")
            ConnectorsPane().tabItem { Label(tr("Connettori"), systemImage: "puzzlepiece.extension") }.tag("connectors")
            SharedRepositoriesPane().tabItem { Label(tr("Condivisione"), systemImage: "folder.badge.person.crop") }.tag("sharing")
            SkillsPane().tabItem { Label(tr("Skill"), systemImage: "wand.and.stars") }.tag("skills")
            VaultPane().tabItem { Label(tr("Vault"), systemImage: "lock.shield") }.tag("vault")
            PhonePane().tabItem { Label(tr("Telefono"), systemImage: "iphone") }.tag("phone")
            MacControlPane().tabItem { Label(tr("Controllo Mac"), systemImage: "macbook.and.iphone") }.tag("mac")
            KeysPane().tabItem { Label(tr("Chiavi e servizi"), systemImage: "key") }.tag("keys")
            DeepSeekPane().tabItem { Label(tr("DeepSeek"), systemImage: "network") }.tag("deepseek")
            UpdatesPane().tabItem { Label(tr("Aggiornamenti"), systemImage: "arrow.down.circle") }.tag("updates")
        }
        .safeAreaInset(edge: .bottom) { SettingsProblem() }
        .frame(width: 920, height: 560)
    }
}

/// A server's settings, in a window of their own: what its engine lets this
/// Mac change from afar. Profile, engines, connectors, skills, keys, DeepSeek.
struct RemoteSettingsView: View {
    let engineId: String
    @Environment(AppModel.self) private var app
    @State private var tab = ProcessInfo.processInfo.environment["SWARMEBOT_SETTINGS_TAB"] ?? "general"

    var body: some View {
        if let engine = app.remoteEngines.first(where: { $0.id == engineId }) {
            TabView(selection: $tab) {
                GeneralPane(remote: true).tabItem { Label(tr("Generale"), systemImage: "person.crop.circle") }.tag("general")
                EnginesPane().tabItem { Label(tr("Motori"), systemImage: "cpu") }.tag("engines")
                ConnectorsPane().tabItem { Label(tr("Connettori"), systemImage: "puzzlepiece.extension") }.tag("connectors")
                SkillsPane().tabItem { Label(tr("Skill"), systemImage: "wand.and.stars") }.tag("skills")
            VaultPane().tabItem { Label(tr("Vault"), systemImage: "lock.shield") }.tag("vault")
                KeysPane().tabItem { Label(tr("Chiavi e servizi"), systemImage: "key") }.tag("keys")
                DeepSeekPane().tabItem { Label(tr("DeepSeek"), systemImage: "network") }.tag("deepseek")
            }
            .safeAreaInset(edge: .bottom) { SettingsProblem() }
            .frame(width: 920, height: 560)
            .navigationTitle(tr("[SERVER REMOTO] - %@", engine.name))
            .environment(app.settingsModel(for: .remote(engineId)))
            .onDisappear { app.closeSettings(for: .remote(engineId)) }
        } else {
            Text(tr("Questo server non è più tra i server remoti di questo Mac."))
                .foregroundStyle(.secondary)
                .frame(width: 420, height: 160)
        }
    }
}

/// What went wrong reading or saving this engine's settings: without it a
/// server that does not answer looks like one with empty settings.
private struct SettingsProblem: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let problem = model.lastError ?? model.loadError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(problem).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(tr("Riprova")) {
                    model.lastError = nil
                    Task {
                        await model.refreshConfig()
                        await model.refreshInstances()
                    }
                }
                Button { model.lastError = nil; model.loadError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(10)
            .background(.bar)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    /// A server's: only what its engine keeps, not this app's language, look and folders.
    var remote = false
    @Environment(AppModel.self) private var model
    @State private var localizer = Localizer.shared
    @State private var appearance = AppearanceSettings.shared
    @State private var name = ""
    @State private var email = ""
    @State private var timeout = 30

    var body: some View {
        Form {
            if !remote { appSections }
            Section(tr("Profilo")) {
                TextField(tr("Nome"), text: $name)
                TextField(tr("Email"), text: $email)
                Button(tr("Salva profilo")) {
                    Task { await model.saveConfig(["profile": ["name": name, "email": email]]) }
                }
            }
            Section(tr("Canali")) {
                Stepper(tr("Tempo massimo per turno di un membro: %@ min", String(timeout)), value: $timeout, in: 1...1440)
                Button(tr("Salva")) { Task { await model.saveConfig(["rooms": ["turnTimeoutMinutes": timeout]]) } }
            }
            if !remote {
                Section(tr("Dati")) {
                    LabeledContent(tr("Dati del motore"), value: "~/.swarmebot")
                    LabeledContent(tr("Log"), value: "~/Library/Logs/SwarmeBot/server.log")
                    Button(tr("Mostra i log nel Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([HarnessLocator.logDirectory.appendingPathComponent("server.log")])
                    }
                }
            }
        }
        .formStyle(.grouped)
        // shown again: what the engine has now, not what this window read before
        .task {
            load()
            await model.refreshConfig()
            load()
        }
    }

    private func load() {
        name = model.config?.profile?.name ?? ""
        email = model.config?.profile?.email ?? ""
        timeout = model.config?.rooms?.turnTimeoutMinutes ?? 30
    }

    @ViewBuilder private var appSections: some View {
        Section(tr("Lingua")) {
            // each language named in itself, so it can be found whichever is shown
            Picker(tr("Lingua dell'app"), selection: $localizer.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.nativeName).tag(language)
                }
            }
        }
        Section(tr("Aspetto")) {
            Picker(tr("Tema"), selection: $appearance.appearance) {
                Text(tr("Scuro")).tag(AppAppearance.dark)
                Text(tr("Chiaro")).tag(AppAppearance.light)
                Text(tr("Sistema")).tag(AppAppearance.system)
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Engines

private struct EnginesPane: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
            List(model.instances, selection: $selected) { instance in
                HStack(spacing: 8) {
                    Circle()
                        .fill(instance.snapshot.isAvailable ? Theme.success : Theme.danger)
                        .frame(width: 8, height: 8)
                    ProviderMark(driverKind: instance.driverKind, name: instance.shownName, size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(instance.shownName).font(.system(size: 13, weight: .medium))
                        Text(instance.driverKind).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .tag(instance.instanceId)
            }
            Divider()
            HStack {
                Spacer()
                Button(tr("Ricontrolla")) { Task { await model.refreshInstances() } }
            }
            .padding(8)
            }
            .frame(minWidth: 260, maxWidth: 320)
            Group {
                if let id = selected, let instance = model.instance(id) {
                    EngineDetail(instance: instance)
                } else {
                    Text(tr("Seleziona un motore")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.refreshInstances() }
    }
}

private struct EngineDetail: View {
    let instance: Instance
    @Environment(AppModel.self) private var model
    @State private var cli = ""
    @State private var test: CLITestResult?
    @State private var testing = false
    /// Flips with the click. The saved value arrives later.
    @State private var visibleOverride: Bool?

    var body: some View {
        Form {
            Section {
                LabeledContent(tr("Stato"), value: instance.snapshot.isAvailable ? tr("Disponibile") : tr("Non disponibile"))
                if let reason = instance.snapshot.reason, !instance.snapshot.isAvailable {
                    Text(reason).font(.system(size: 12)).foregroundStyle(Theme.warning).textSelection(.enabled)
                }
                if let version = instance.snapshot.version { LabeledContent(tr("Versione"), value: version) }
                LabeledContent(tr("Modelli"), value: String(instance.models.options.count))
                Toggle(tr("Mostra nel selettore modelli"), isOn: Binding(
                    get: { visibleOverride ?? (instance.pickerVisible ?? true) },
                    set: { value in
                        visibleOverride = value
                        Task {
                            await model.patchInstance(instance, pickerVisible: .some(value))
                            visibleOverride = nil
                        }
                    }
                ))
                .disabled(!instance.snapshot.isAvailable)
            }
            if instance.cliDefault != nil {
                Section(tr("Eseguibile")) {
                    TextField(tr("Percorso (vuoto = %@)", instance.cliDefault ?? tr("predefinito")), text: $cli)
                        .font(.system(size: 12, design: .monospaced))
                    if let candidates = instance.cliCandidates, !candidates.isEmpty {
                        Picker(tr("Trovati nel PATH"), selection: $cli) {
                            Text(tr("Predefinito")).tag("")
                            ForEach(candidates, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    HStack {
                        Button(tr("Prova")) {
                            testing = true
                            Task {
                                test = await model.testCLI(cli.isEmpty ? (instance.cliDefault ?? "") : cli, driver: instance.driverKind)
                                testing = false
                            }
                        }
                        Button(tr("Salva")) { Task { await model.patchInstance(instance, cli: cli) } }
                            .help(tr("Salvare ricarica il motore: i turni in corso vengono interrotti."))
                        if testing { ProgressView().controlSize(.small) }
                    }
                    if let test {
                        Text(verbatim: test.ok ? "✓ " + (test.version ?? tr("funziona")) : "✕ " + (test.message ?? tr("non parte")))
                            .font(.system(size: 12))
                            .foregroundStyle(test.ok ? Theme.success : Theme.danger)
                    }
                }
            }
            if let install = instance.install {
                Section {
                    if let command = install.command?.darwin {
                        CommandRow(command: command, label: tr("Installa"), runsHere: !model.isRemote)
                    }
                    if let signIn = install.signInCommand {
                        CommandRow(command: signIn, label: tr("Accedi"), runsHere: !model.isRemote)
                    }
                    if let docs = install.docsUrl, let url = URL(string: docs) {
                        Link(tr("Documentazione"), destination: url)
                    }
                } header: {
                    Text(tr("Installazione e accesso"))
                } footer: {
                    if model.isRemote {
                        Text(tr("Questi comandi vanno eseguiti sul server: Server remoti › Azioni › Apri un terminale sul server."))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { cli = instance.cli ?? "" }
        .onChange(of: instance.instanceId) { _, _ in
            cli = instance.cli ?? ""
            test = nil
            visibleOverride = nil
        }
    }
}

/// A shell command the user runs themselves, in Terminal: installing and
/// signing in to a CLI are interactive and belong to the user, not the app.
private struct CommandRow: View {
    let command: String
    let label: String
    /// False for a server's engine: the command is shown, not run in this Mac's Terminal.
    var runsHere = true

    var body: some View {
        HStack {
            Text(command).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Spacer()
            if runsHere { Button(label) { TerminalLauncher.run(command) } }
        }
    }
}

enum TerminalLauncher {
    /// A `.command` file opened with Terminal: no Apple Events permission
    /// needed, and the user sees exactly what runs.
    static func run(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("swarmebot-\(UUID().uuidString).command")
        let done = tr("Fatto. Puoi chiudere questa finestra.")
        let script = "#!/bin/zsh -l\n\(command)\necho\necho '\(done)'\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: - Keys and services

private struct KeysPane: View {
    @Environment(AppModel.self) private var model
    @State private var values: [WorkspaceCredential: String] = [:]
    @State private var endpointURL = ""
    @State private var vpsAlias = ""

    var body: some View {
        Form {
            Section {
                Text(model.isRemote
                     ? tr("Le chiavi vanno al motore del server, che le tiene nel suo secrets.json (leggibile solo da lui); non passano dal Portachiavi di questo Mac e non vengono scritte in config.json.")
                     : tr("Le chiavi restano nel Portachiavi di macOS e arrivano al motore all'avvio; non vengono scritte in config.json."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section(tr("Chiavi")) {
                ForEach(WorkspaceCredential.allCases, id: \.self) { credential in
                    HStack {
                        SecureField(credential.label, text: Binding(get: { values[credential] ?? "" }, set: { values[credential] = $0 }))
                        if configured(credential) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).help(tr("Configurata"))
                        }
                        Button(tr("Salva")) { Task { await model.saveCredential(credential, values[credential] ?? "") } }
                    }
                }
            }
            Section(tr("Server compatibile OpenAI (LiteLLM, vLLM, Ollama…)")) {
                HStack {
                    TextField(tr("URL base, es. http://127.0.0.1:4000/v1"), text: $endpointURL)
                    Button(tr("Salva")) { Task { await model.saveConfig(["localEndpoint": ["baseUrl": endpointURL]]) } }
                }
            }
            // the computers of a server are not reachable from afar (501)
            if !model.isRemote {
                Section(tr("VPS")) {
                    HStack {
                        TextField(tr("Alias SSH (da ~/.ssh/config)"), text: $vpsAlias)
                        Button(tr("Salva")) { Task { await model.saveConfig(["vps": ["sshAlias": vpsAlias]]) } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            load()
            await model.refreshConfig()
            load()
        }
    }

    private func load() {
        endpointURL = model.config?.localEndpoint?.baseUrl ?? ""
        vpsAlias = model.config?.vps?.sshAlias ?? ""
    }

    private func configured(_ credential: WorkspaceCredential) -> Bool {
        switch credential {
        case .xaiApiKey: return model.config?.xai?.configured == true
        case .boxToken: return model.config?.box?.configured == true
        case .opencodeGoApiKey: return model.config?.opencodeGo?.configured == true
        case .localEndpointApiKey: return model.config?.localEndpoint?.apiKeyConfigured == true || model.config?.localEndpoint?.configured == true
        }
    }
}

// MARK: - DeepSeek Harness

private struct DeepSeekPane: View {
    @Environment(AppModel.self) private var model
    @State private var settings: DeepSeekHarnessSettings?
    @State private var baseUrl = ""
    @State private var transport = "direct"
    @State private var preset = ""
    @State private var pairing = ""
    @State private var message: String?

    private var instance: Instance? { model.instances.first { $0.driverKind == "deepseekHarness" || $0.driverKind.lowercased().contains("deepseek") } }

    var body: some View {
        Form {
            if let instance {
                Section(tr("Connessione")) {
                    TextField(tr("URL base"), text: $baseUrl)
                    Picker(tr("Trasporto"), selection: $transport) {
                        Text(tr("Diretto")).tag("direct")
                        Text(tr("Abbinato")).tag("paired")
                    }
                    TextField(tr("Preset agente (facoltativo)"), text: $preset)
                    Button(tr("Salva")) {
                        Task {
                            do {
                                try await model.client?.saveDeepSeekHarness(instanceId: instance.instanceId, baseUrl: baseUrl, transport: transport, agentPreset: preset)
                                message = tr("Salvato.")
                            } catch { message = error.localizedDescription }
                        }
                    }
                }
                Section(tr("Abbinamento")) {
                    LabeledContent(tr("Abbinato"), value: settings?.connection.paired == true ? tr("Sì") : tr("No"))
                    TextField(tr("Link di abbinamento"), text: $pairing)
                    Button(tr("Abbina")) {
                        Task {
                            do {
                                try await model.client?.pairDeepSeekHarness(instanceId: instance.instanceId, pairingLink: pairing)
                                message = tr("Abbinato.")
                                await load(instance)
                            } catch { message = error.localizedDescription }
                        }
                    }
                    .disabled(pairing.isEmpty)
                }
                if let message { Text(message).font(.system(size: 12)) }
            } else {
                Text(tr("Nessun motore DeepSeek Harness configurato.")).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: instance?.instanceId) { if let instance { await load(instance) } }
    }

    private func load(_ instance: Instance) async {
        guard let loaded = try? await model.client?.deepSeekHarness(instanceId: instance.instanceId) else { return }
        settings = loaded
        baseUrl = loaded.connection.baseUrl
        transport = loaded.connection.transport
        preset = loaded.connection.agentPreset ?? ""
    }
}

// MARK: - Updates

private struct UpdatesPane: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            LabeledContent(tr("Versione"), value: updater.version)
            if updater.available {
                Toggle(tr("Controlla automaticamente"), isOn: $updater.automaticChecks)
                Button(tr("Controlla ora")) { updater.checkForUpdates() }
            } else {
                Text(tr("Gli aggiornamenti automatici sono attivi solo nell'app pacchettizzata e firmata (scripts/bundle-app.sh con SPARKLE_PUBLIC_KEY)."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Whether bots may drive this Mac (Cua). Off by default.
private struct MacControlPane: View {
    @Environment(AppModel.self) private var model
    @State private var localComputer = AppPaths.defaults.bool(forKey: "localComputerEnabled")

    var body: some View {
        Form {
            Section {
                Toggle(tr("Consenti ai bot di usare questo Mac"), isOn: $localComputer)
                    .onChange(of: localComputer) { _, on in
                        AppPaths.defaults.set(on, forKey: "localComputerEnabled")
                        model.retry()
                    }
            } footer: {
                Text(tr("Spento di default: Cua non parte all'avvio e non cattura lo schermo. Accendilo solo se un bot deve usare questo Mac. Il driver nasce col turno, non prima."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 220)
    }
}
