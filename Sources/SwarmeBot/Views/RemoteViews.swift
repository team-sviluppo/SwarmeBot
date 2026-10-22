import CompanionCore
import CoreImage.CIFilterBuiltins
import SwarmeKit
import SwiftUI

// Remote engines — docs/plans/2026-10-16-bot-remoto.md §7: Settings › Server
// remoti, the setup walk-through, pairing another device with a QR, and the
// device list. In the window each server is a section of the sidebar.

// MARK: - Settings › Server remoti

struct RemoteServersPane: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var pairingWithCode = false
    @State private var devicesFor: RemoteEngine?
    @State private var qrFor: RemoteEngine?
    @State private var forgetting: RemoteEngine?
    @State private var claudeLoginFor: RemoteEngine?
    @State private var piCopyFor: RemoteEngine?
    @State private var pushRelayFor: RemoteEngine?
    @State private var configuring: String?
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                if model.remoteEngines.isEmpty {
                    Text(tr("Nessun server. Un bot su un server continua a lavorare anche a Mac spento, e lo ritrovi qui o sul telefono."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.remoteEngines) { engine in
                    HStack(alignment: .top) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.name).font(.system(size: 13, weight: .medium))
                            Text(engine.chatURL).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            if let identity = model.identity(for: engine) {
                                Text(tr("Amministrato da questo Mac come %@", identity.label)).font(.system(size: 11)).foregroundStyle(.tertiary)
                                if let relay = engine.pushRelayURL {
                                    Text(tr("Relay delle notifiche push: %@", relay)).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                EngineUpdateLine(engine: engine)
                                if configuring == engine.id {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text(tr("Installo Claude Code e omp sul server…")).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Spacer()
                        Menu(tr("Azioni")) {
                            Button(tr("Mostra i suoi bot")) { model.select(engine: .remote(engine.id)) }
                            Button(tr("Abbina un telefono o un altro Mac…")) { qrFor = engine }
                            Button(tr("Dispositivi abbinati…")) { devicesFor = engine }
                            if let identity = model.identity(for: engine) {
                                Divider()
                                Button(tr("Configura Claude Code e omp")) { configureAgents(engine) }
                                    .disabled(configuring != nil)
                                Button(tr("Login di Claude sul server…")) { claudeLoginFor = engine }
                                Button(tr("Copia la configurazione di pi…")) { piCopyFor = engine }
                                Button(tr("Ospita il relay delle notifiche push…")) { pushRelayFor = engine }
                                Button(tr("Apri un terminale sul server")) { try? model.openTerminal(identity) }
                            }
                            Divider()
                            Button(tr("Dimentica su questo Mac…"), role: .destructive) { forgetting = engine }
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text(tr("Server remoti"))
            } footer: {
                Text(tr("Il Mac amministra il server via ssh; la chat passa sempre in HTTPS con un token di questo dispositivo."))
            }
            Section {
                Button(tr("Aggiungi un server…")) { adding = true }
                Button(tr("Collega un server con un codice…")) { pairingWithCode = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { ServerSetupSheet() }
        .sheet(isPresented: $pairingWithCode) { PairWithCodeSheet() }
        .sheet(item: $devicesFor) { DevicesSheet(engine: $0) }
        .sheet(item: $qrFor) { PairingQRSheet(engine: $0) }
        .sheet(item: $claudeLoginFor) { ClaudeTokenSheet(engine: $0) }
        .sheet(item: $pushRelayFor) { PushRelaySheet(engine: $0) }
        .confirmationDialog(tr("Copiare la configurazione di pi su %@?", piCopyFor?.name ?? ""),
                            isPresented: Binding(get: { piCopyFor != nil }, set: { if !$0 { piCopyFor = nil } })) {
            Button(tr("Copia")) {
                guard let engine = piCopyFor else { return }
                Task {
                    do {
                        let copied = try await model.copyPiConfig(to: engine)
                        notice = tr("Copiati su %@: %@", engine.name, copied.joined(separator: ", "))
                    } catch {
                        notice = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(tr("auth.json, models.json e settings.json di ~/.pi/agent vanno sul server, leggibili solo dal suo utente. Contengono le chiavi API dei tuoi provider. I file già presenti sul server restano come copia di backup."))
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(tr("OK")) { notice = nil }
        }
        .confirmationDialog(tr("Dimenticare %@?", forgetting?.name ?? ""), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button(tr("Dimentica"), role: .destructive) {
                if let engine = forgetting { try? model.forgetRemoteEngine(engine.id) }
                forgetting = nil
            }
        } message: {
            Text(tr("Il server e i suoi bot continuano a funzionare; questo Mac non lo mostra più. Il dispositivo resta abbinato finché non lo revochi."))
        }
        .onAppear { model.reloadRemoteEngines() }
    }

    private func configureAgents(_ engine: RemoteEngine) {
        configuring = engine.id
        Task {
            do {
                notice = try await model.configureAgents(on: engine).joined(separator: "\n")
            } catch {
                notice = error.localizedDescription
            }
            configuring = nil
        }
    }
}

// MARK: - Setup walk-through

struct ServerSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow: ServerSetupFlow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Aggiungi un server")).font(.title2.weight(.semibold))
            if let flow {
                SetupBody(flow: flow) {
                    if let engine = flow.engine {
                        model.reloadRemoteEngines()
                        model.select(engine: .remote(engine.id))
                    }
                    dismiss()
                }
            }
            HStack {
                Spacer()
                Button(tr("Chiudi")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear { if flow == nil { flow = model.makeSetupFlow() } }
    }
}

private struct SetupBody: View {
    @Bindable var flow: ServerSetupFlow
    let finished: () -> Void
    @State private var showRoot = false

    /// Once connecting starts, the form gives its room to the steps: the
    /// fingerprint, the password fields and the errors must be in view.
    private var editing: Bool { flow.step == .hostKey && flow.scannedKeys.isEmpty && !flow.running }

    private var needsAction: Bool {
        !flow.scannedKeys.isEmpty || flow.error != nil || flow.probe != nil || !flow.agentsReport.isEmpty
            || (flow.needsPassword && flow.step == .key)
            || (flow.needsSudoPassword && flow.step >= .root && flow.step < .device)
    }

    var body: some View {
        Form {
            if editing {
                Section(tr("Server (amministrazione via ssh)")) {
                    TextField(tr("Nome da mostrare"), text: $flow.name, prompt: Text(verbatim: "srv1 · deploy"))
                    TextField(tr("Server"), text: $flow.host, prompt: Text(tr("10.0.4.12 o vps1.example.it")))
                        .onSubmit { flow.suggestPrefix() }
                    TextField(tr("Porta ssh"), value: $flow.port, format: .number.grouping(.never))
                    TextField(tr("Utente"), text: $flow.user, prompt: Text(verbatim: "deploy"))
                        .onSubmit { flow.suggestPrefix() }
                }
                Section {
                    TextField(tr("Sito Caddy"), text: $flow.site, prompt: Text(tr("bot.example.it, oppure :8080 dietro un proxy")))
                    TextField(tr("Prefisso"), text: $flow.prefix, prompt: Text(verbatim: "/srv1/deploy"))
                    Picker(tr("Certificato"), selection: $flow.tls) {
                        Text(tr("Pubblico (Let's Encrypt)")).tag(CaddySettings.TLS.public)
                        Text(tr("Nessuno: dietro un proxy HTTPS")).tag(CaddySettings.TLS.off)
                    }
                    TextField(tr("URL di chat (se c'è un proxy davanti)"), text: $flow.chatURLOverride, prompt: Text(flow.chatURL))
                } header: {
                    Text(tr("Chat (HTTPS)"))
                } footer: {
                    Text(tr("I dispositivi usano solo questo URL: %@", flow.chatURL))
                }
            } else {
                Section {
                    LabeledContent(tr("Server"), value: "\(flow.user)@\(flow.host)\(flow.port == 22 ? "" : ":\(flow.port)")")
                    LabeledContent(tr("Chat"), value: flow.chatURL)
                }
            }

            // what the person must do now goes first, above the list of steps
            if needsAction {
                Section {
                    if !flow.scannedKeys.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("Confronta il fingerprint con quello mostrato dalla console del server:")).font(.callout)
                            ForEach(flow.scannedKeys.prefix(1), id: \.self) { key in
                                Text(verbatim: "\(key.type)  \(key.fingerprint)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                Button(tr("È quello giusto: approva")) { Task { await flow.approve(key) } }
                            }
                        }
                    }
                    if flow.needsPassword, flow.step == .key {
                        SecureField(tr("Password ssh di %@", flow.user), text: $flow.sshPassword)
                    Text(tr("Serve una volta sola, per installare la chiave dedicata di questo Mac. Non viene salvata."))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if flow.needsSudoPassword, flow.step >= .root, flow.step < .device {
                        SecureField(tr("Password di sudo"), text: $flow.sudoPassword)
                    Text(tr("Per i passi di root qui sotto. Non viene salvata.")).font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(tr("Comandi eseguiti come root"), isExpanded: $showRoot) {
                            ScrollView {
                                Text(flow.rootPreview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 160)
                        }
                    }
                    if let probe = flow.probe {
                        Text(tr("%@ %@ · %@ · Claude: %@ · pi: %@", probe.os, probe.version, probe.arch, probe.claude ?? tr("non installato"), probe.pi ?? tr("non installato")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(flow.agentsReport, id: \.self) { line in
                        Text(line).font(.caption).textSelection(.enabled)
                    }
                    if let error = flow.error {
                        Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
                    }
                }
            }
            Section(tr("Avanzamento")) {
                ForEach(ServerSetupFlow.Step.allCases.filter { $0 != .done }, id: \.self) { step in
                    HStack {
                        Image(systemName: icon(step)).foregroundStyle(color(step))
                        Text(step.title)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // the sheet hangs off the Settings window (640 pt with its toolbar): the form
        // scrolls inside this, so the buttons below stay on screen
        .frame(height: 380)
        HStack {
            if flow.running { ProgressView().controlSize(.small) }
            if let activity = flow.activity { Text(activity).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if flow.step == .done {
                Button(tr("Mostra i bot del server"), action: finished).keyboardShortcut(.defaultAction)
            } else {
                Button(flow.step == .hostKey && flow.error == nil ? tr("Collegati") : tr("Continua")) {
                    flow.suggestPrefix()
                    Task { await flow.run() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(flow.running || !flow.scannedKeys.isEmpty)
            }
        }
    }

    private func icon(_ step: ServerSetupFlow.Step) -> String {
        if step < flow.step { return "checkmark.circle.fill" }
        if step == flow.step { return flow.error == nil ? "circle.dotted" : "exclamationmark.circle.fill" }
        return "circle"
    }

    private func color(_ step: ServerSetupFlow.Step) -> Color {
        if step < flow.step { return Theme.success }
        if step == flow.step, flow.error != nil { return Theme.danger }
        return .secondary
    }
}

// MARK: - Pairing

struct PairWithCodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chatURL = ""
    @State private var code = ""
    @State private var name = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Collega un server con un codice")).font(.title3.weight(.semibold))
            Text(tr("Su un dispositivo già abbinato: Server remoti › Abbina un telefono o un altro Mac. Copia qui l'URL e il codice."))
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField(tr("URL di chat"), text: $chatURL, prompt: Text(verbatim: "https://bot.example.it/srv1/deploy"))
                TextField(tr("Codice"), text: $code, prompt: Text(verbatim: "ABCD234567"))
                TextField(tr("Nome da mostrare"), text: $name)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button(tr("Annulla")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Collega")) {
                    working = true
                    Task {
                        do {
                            _ = try await model.pairRemoteEngine(chatURL: chatURL, code: code, name: name)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || chatURL.isEmpty || code.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct PairingQRSheet: View {
    let engine: RemoteEngine
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: RemotePairingCode?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(tr("Abbina un dispositivo a %@", engine.name)).font(.title3.weight(.semibold))
            if let pairing, let link = RemotePairingLink(chatURL: engine.chatURL, code: pairing.code, name: engine.name).url {
                if let image = Self.qr(link.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                }
                Text(tr("Codice: %@", pairing.code)).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                Text(tr("URL: %@", engine.chatURL)).font(.callout).textSelection(.enabled)
                Text(tr("Vale 10 minuti e una volta sola. Il QR non contiene il token.")).font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).foregroundStyle(Theme.danger)
            } else {
                ProgressView()
            }
            Button(tr("Chiudi")) { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 380)
        .task {
            do { pairing = try await model.remoteClient(engine).pairingCode() } catch { self.error = error.localizedDescription }
        }
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

struct DevicesSheet: View {
    let engine: RemoteEngine
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var list: RemoteDeviceList?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Dispositivi abbinati a %@", engine.name)).font(.title3.weight(.semibold))
            if let list {
                List(list.devices) { device in
                    HStack {
                        Image(systemName: device.kind == "ios" ? "iphone" : "laptopcomputer")
                        VStack(alignment: .leading) {
                            Text(device.name + (device.id == list.current ? tr(" (questo Mac)") : ""))
                            if let seen = device.lastSeenAt {
                                Text(tr("Visto %@", Date(timeIntervalSince1970: seen / 1000).appRelative()))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(tr("Revoca"), role: .destructive) {
                            Task {
                                do {
                                    try await model.remoteClient(engine).revokeDevice(device.id)
                                    await load()
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                        .disabled(device.id == list.current)
                    }
                }
                .frame(height: 220)
            } else if error == nil {
                ProgressView()
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
            HStack { Spacer(); Button(tr("Chiudi")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
    }

    private func load() async {
        do { list = try await model.remoteClient(engine).devices() } catch { self.error = error.localizedDescription }
    }
}

/// Claude's login for a server: no browser and maybe no Keychain there, so a
/// long-lived token made on this Mac goes to the engine's secrets.
struct ClaudeTokenSheet: View {
    let engine: RemoteEngine
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Login di Claude su %@", engine.name)).font(.title3.weight(.semibold))
            Text(tr("Nel Terminale di questo Mac esegui il comando qui sotto e accedi con il tuo abbonamento; poi incolla il token che stampa. Il token resta sul server in un file leggibile solo dal suo utente, e nel Portachiavi di questo Mac per i prossimi server che configuri."))
                .font(.callout).foregroundStyle(.secondary)
            Text(verbatim: "claude setup-token").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            SecureField(tr("sk-ant-…"), text: $token)
            if let error { Text(error).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button(tr("Annulla")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Salva sul server")) {
                    working = true
                    Task {
                        do {
                            try await model.setClaudeToken(token, for: engine)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        working = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// The iOS app's push relay on this server (docs/push-relay.md): the same
/// binary as the engine, its own service, `<prefix>/push` in Caddy. Meant for
/// the one server that serves the app's build: the OneSignal key can push to
/// every phone with the app, so it stays on that server only.
struct PushRelaySheet: View {
    let engine: RemoteEngine
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var appId = ""
    @State private var apiKey = ""
    @State private var sudoPassword = ""
    @State private var error: String?
    @State private var working = false
    @State private var relay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Relay delle notifiche push su %@", engine.name)).font(.title3.weight(.semibold))
            Text(tr("Il relay manda le push dell'app iOS tramite OneSignal. Gira con lo stesso programma del motore, che lo aggiorna insieme a sé, e risponde in HTTPS su %@/push. Va installato su un solo server: la chiave REST di OneSignal può mandare push a tutti i telefoni con l'app, quindi resta solo lì, in un file leggibile dal suo utente.", engine.chatURL))
                .font(.callout).foregroundStyle(.secondary)
            if let relay {
                Label(tr("Relay attivo"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text(tr("Nella build dell'app iOS (iOS/Local.xcconfig o Shared.xcconfig) metti:")).font(.callout)
                Text(verbatim: "SWARMEBOT_PUSH_RELAY = " + relay.replacingOccurrences(of: "://", with: ":/$()/"))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            } else {
                TextField(tr("OneSignal App ID"), text: $appId)
                SecureField(tr("OneSignal REST API key"), text: $apiKey)
                SecureField(tr("Password di sudo (se il server la chiede)"), text: $sudoPassword)
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(tr("Installo il relay sul server…")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if relay != nil {
                    Button(tr("Fine")) { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(tr("Annulla")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(engine.pushRelayURL == nil ? tr("Installa") : tr("Aggiorna le chiavi")) {
                        working = true
                        error = nil
                        Task {
                            do {
                                relay = try await model.installPushRelay(on: engine, appId: appId, apiKey: apiKey,
                                                                         sudoPassword: sudoPassword.isEmpty ? nil : sudoPassword)
                            } catch {
                                self.error = error.localizedDescription
                            }
                            working = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || appId.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// "Motore aggiornato" or "Aggiorna motore", for a server this Mac administers (§5.5).
private struct EngineUpdateLine: View {
    let engine: RemoteEngine
    @Environment(AppModel.self) private var model
    @State private var status: RemoteEngineStatus?
    @State private var error: String?
    @State private var working = false
    @State private var busyNames: [String]?

    var body: some View {
        HStack(spacing: 6) {
            if working {
                ProgressView().controlSize(.mini)
                Text(tr("Aggiorno il motore…")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(2)
            } else if let status {
                if status.updateAvailable {
                    Text(status.installed == nil ? tr("Motore non installato") : tr("Aggiornamento del motore disponibile"))
                        .font(.system(size: 11)).foregroundStyle(Theme.warning)
                    Button(tr("Aggiorna motore")) { Task { await update(force: false) } }.controlSize(.small)
                } else {
                    Text(tr("Motore aggiornato")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text(tr("Controllo il motore…")).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .task(id: engine.id) { await load() }
        .confirmationDialog(tr("Aggiornare adesso?"), isPresented: Binding(get: { busyNames != nil }, set: { if !$0 { busyNames = nil } })) {
            Button(tr("Aggiorna e interrompi"), role: .destructive) { Task { await update(force: true) } }
        } message: {
            Text(tr("Stanno lavorando: %@. L'aggiornamento riavvia il motore e interrompe i loro turni.", (busyNames ?? []).joined(separator: ", ")))
        }
    }

    private func load() async {
        do { status = try await model.engineStatus(engine); error = nil } catch { self.error = error.localizedDescription }
    }

    private func update(force: Bool) async {
        working = true
        defer { working = false }
        do {
            try await model.updateEngine(engine, force: force)
            await load()
        } catch let EngineUpdateError.busy(names) {
            busyNames = names
        } catch {
            self.error = error.localizedDescription
        }
    }
}

