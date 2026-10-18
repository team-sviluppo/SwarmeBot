import CompanionCore
import SwarmeKit
import SwiftUI

/// ⌘, — profile, engines, connectors, control of this Mac, keys and services, DeepSeek Harness, updates.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("Generale", systemImage: "person.crop.circle") }
            EnginesPane().tabItem { Label("Motori", systemImage: "cpu") }
            RemoteServersPane().tabItem { Label("Server remoti", systemImage: "server.rack") }
            ConnectorsPane().tabItem { Label("Connettori", systemImage: "puzzlepiece.extension") }
            MacControlPane().tabItem { Label("Controllo Mac", systemImage: "macbook.and.iphone") }
            KeysPane().tabItem { Label("Chiavi e servizi", systemImage: "key") }
            DeepSeekPane().tabItem { Label("DeepSeek", systemImage: "network") }
            UpdatesPane().tabItem { Label("Aggiornamenti", systemImage: "arrow.down.circle") }
        }
        .frame(width: 920, height: 560)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var email = ""
    @State private var timeout = 30

    var body: some View {
        Form {
            Section("Profilo") {
                TextField("Nome", text: $name)
                TextField("Email", text: $email)
                Button("Salva profilo") {
                    Task { await model.saveConfig(["profile": ["name": name, "email": email]]) }
                }
            }
            Section("Canali") {
                Stepper("Tempo massimo per turno di un membro: \(timeout) min", value: $timeout, in: 1...1440)
                Button("Salva") { Task { await model.saveConfig(["rooms": ["turnTimeoutMinutes": timeout]]) } }
            }
            Section("Dati") {
                LabeledContent("Dati del motore", value: "~/.swarmebot")
                LabeledContent("Log", value: "~/Library/Logs/SwarmeBot/server.log")
                Button("Mostra i log nel Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([HarnessLocator.logDirectory.appendingPathComponent("server.log")])
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = model.config?.profile?.name ?? ""
            email = model.config?.profile?.email ?? ""
            timeout = model.config?.rooms?.turnTimeoutMinutes ?? 30
        }
    }
}

// MARK: - Engines

private struct EnginesPane: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?

    var body: some View {
        HSplitView {
            List(model.instances, selection: $selected) { instance in
                HStack(spacing: 8) {
                    Circle()
                        .fill(instance.snapshot.isAvailable ? Theme.success : Theme.danger)
                        .frame(width: 8, height: 8)
                    ProviderMark(driverKind: instance.driverKind, name: instance.displayName ?? instance.driverKind, size: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(instance.displayName ?? instance.driverKind).font(.system(size: 13, weight: .medium))
                        Text(instance.driverKind).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .tag(instance.instanceId)
            }
            .frame(minWidth: 260, maxWidth: 320)
            Group {
                if let id = selected, let instance = model.instance(id) {
                    EngineDetail(instance: instance)
                } else {
                    Text("Seleziona un motore").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.refreshInstances() }
        .toolbar { Button("Ricontrolla") { Task { await model.refreshInstances() } } }
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
                LabeledContent("Stato", value: instance.snapshot.isAvailable ? "Disponibile" : "Non disponibile")
                if let reason = instance.snapshot.reason, !instance.snapshot.isAvailable {
                    Text(reason).font(.system(size: 12)).foregroundStyle(Theme.warning).textSelection(.enabled)
                }
                if let version = instance.snapshot.version { LabeledContent("Versione", value: version) }
                LabeledContent("Modelli", value: "\(instance.models.options.count)")
                Toggle("Mostra nel selettore modelli", isOn: Binding(
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
                Section("Eseguibile") {
                    TextField("Percorso (vuoto = \(instance.cliDefault ?? "predefinito"))", text: $cli)
                        .font(.system(size: 12, design: .monospaced))
                    if let candidates = instance.cliCandidates, !candidates.isEmpty {
                        Picker("Trovati nel PATH", selection: $cli) {
                            Text("Predefinito").tag("")
                            ForEach(candidates, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    HStack {
                        Button("Prova") {
                            testing = true
                            Task {
                                test = await model.testCLI(cli.isEmpty ? (instance.cliDefault ?? "") : cli, driver: instance.driverKind)
                                testing = false
                            }
                        }
                        Button("Salva") { Task { await model.patchInstance(instance, cli: cli) } }
                            .help("Salvare ricarica il motore: i turni in corso vengono interrotti.")
                        if testing { ProgressView().controlSize(.small) }
                    }
                    if let test {
                        Text(test.ok ? "✓ \(test.version ?? "funziona")" : "✕ \(test.message ?? "non parte")")
                            .font(.system(size: 12))
                            .foregroundStyle(test.ok ? Theme.success : Theme.danger)
                    }
                }
            }
            if let install = instance.install {
                Section("Installazione e accesso") {
                    if let command = install.command?.darwin {
                        CommandRow(command: command, label: "Installa")
                    }
                    if let signIn = install.signInCommand {
                        CommandRow(command: signIn, label: "Accedi")
                    }
                    if let docs = install.docsUrl, let url = URL(string: docs) {
                        Link("Documentazione", destination: url)
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

    var body: some View {
        HStack {
            Text(command).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Spacer()
            Button(label) { TerminalLauncher.run(command) }
        }
    }
}

enum TerminalLauncher {
    /// A `.command` file opened with Terminal: no Apple Events permission
    /// needed, and the user sees exactly what runs.
    static func run(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("swarmebot-\(UUID().uuidString).command")
        let script = "#!/bin/zsh -l\n\(command)\necho\necho 'Fatto. Puoi chiudere questa finestra.'\n"
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
    @State private var importResult: String?

    var body: some View {
        Form {
            Section {
                Text("Le chiavi restano nel Portachiavi di macOS e arrivano al motore all'avvio; non vengono scritte in config.json.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Chiavi") {
                ForEach(WorkspaceCredential.allCases, id: \.self) { credential in
                    HStack {
                        SecureField(credential.label, text: Binding(get: { values[credential] ?? "" }, set: { values[credential] = $0 }))
                        if configured(credential) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).help("Configurata")
                        }
                        Button("Salva") { Task { await model.saveCredential(credential, values[credential] ?? "") } }
                    }
                }
            }
            Section("Local Endpoint (LiteLLM, vLLM, OpenAI-compatibile)") {
                HStack {
                    TextField("URL base, es. http://127.0.0.1:4000/v1", text: $endpointURL)
                    Button("Salva") { Task { await model.saveConfig(["localEndpoint": ["baseUrl": endpointURL]]) } }
                }
            }
            Section("VPS") {
                HStack {
                    TextField("Alias SSH (da ~/.ssh/config)", text: $vpsAlias)
                    Button("Salva") { Task { await model.saveConfig(["vps": ["sshAlias": vpsAlias]]) } }
                }
            }
            Section("Dall'app Electron") {
                Text("Importa le chiavi salvate dalla versione Electron. macOS chiederà il permesso di leggere la voce \"SwarmeBot Safe Storage\" del Portachiavi.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Importa credenziali") {
                    do {
                        let imported = try CredentialStore.importFromElectron()
                        importResult = imported.isEmpty ? "Nessuna chiave da importare." : "Importate: \(imported.joined(separator: ", ")). Riavvia SwarmeBot per usarle."
                    } catch {
                        importResult = error.localizedDescription
                    }
                }
                if let importResult { Text(importResult).font(.system(size: 12)) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            endpointURL = model.config?.localEndpoint?.baseUrl ?? ""
            vpsAlias = model.config?.vps?.sshAlias ?? ""
        }
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
                Section("Connessione") {
                    TextField("URL base", text: $baseUrl)
                    Picker("Trasporto", selection: $transport) {
                        Text("Diretto").tag("direct")
                        Text("Abbinato").tag("paired")
                    }
                    TextField("Preset agente (facoltativo)", text: $preset)
                    Button("Salva") {
                        Task {
                            do {
                                try await model.client?.saveDeepSeekHarness(instanceId: instance.instanceId, baseUrl: baseUrl, transport: transport, agentPreset: preset)
                                message = "Salvato."
                            } catch { message = error.localizedDescription }
                        }
                    }
                }
                Section("Abbinamento") {
                    LabeledContent("Abbinato", value: settings?.connection.paired == true ? "Sì" : "No")
                    TextField("Link di abbinamento", text: $pairing)
                    Button("Abbina") {
                        Task {
                            do {
                                try await model.client?.pairDeepSeekHarness(instanceId: instance.instanceId, pairingLink: pairing)
                                message = "Abbinato."
                                await load(instance)
                            } catch { message = error.localizedDescription }
                        }
                    }
                    .disabled(pairing.isEmpty)
                }
                if let message { Text(message).font(.system(size: 12)) }
            } else {
                Text("Nessun motore DeepSeek Harness configurato.").foregroundStyle(.secondary)
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
            LabeledContent("Versione", value: updater.version)
            if updater.available {
                Toggle("Controlla automaticamente", isOn: $updater.automaticChecks)
                Button("Controlla ora") { updater.checkForUpdates() }
            } else {
                Text("Gli aggiornamenti automatici sono attivi solo nell'app pacchettizzata e firmata (scripts/bundle-app.sh con SPARKLE_PUBLIC_KEY).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Whether bots may drive this Mac (Cua). Off by default.
private struct MacControlPane: View {
    @Environment(AppModel.self) private var model
    @State private var localComputer = UserDefaults.standard.bool(forKey: "localComputerEnabled")

    var body: some View {
        Form {
            Section {
                Toggle("Consenti ai bot di usare questo Mac", isOn: $localComputer)
                    .onChange(of: localComputer) { _, on in
                        UserDefaults.standard.set(on, forKey: "localComputerEnabled")
                        model.retry()
                    }
            } footer: {
                Text("Spento di default: Cua non parte all'avvio e non cattura lo schermo. Accendilo solo se un bot deve usare questo Mac. Il driver nasce col turno, non prima.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 220)
    }
}
