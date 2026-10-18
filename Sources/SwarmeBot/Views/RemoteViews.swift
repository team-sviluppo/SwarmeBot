import CompanionCore
import CoreImage.CIFilterBuiltins
import SwarmeKit
import SwiftUI

// Remote engines — docs/plans/2026-10-16-bot-remoto.md §7: the engine picker
// atop the sidebar, Settings › Server remoti, the setup walk-through, pairing
// another device with a QR, and the device list.

/// "Questo Mac" or a remote engine, atop the sidebar. Shown once there is a remote engine.
struct EngineSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if !model.remoteEngines.isEmpty {
            Menu {
                Picker("Motore", selection: Binding(get: { model.engineChoice }, set: { model.select(engine: $0) })) {
                    Label("Questo Mac", systemImage: "laptopcomputer").tag(EngineChoice.local)
                    ForEach(model.remoteEngines) { engine in
                        Label(engine.name, systemImage: "server.rack").tag(EngineChoice.remote(engine.id))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Server remoti…") { openSettings() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.activeRemoteEngine == nil ? "laptopcomputer" : "server.rack")
                        .font(.system(size: 11))
                    Text(model.engineName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    statusDot
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.raised.opacity(0.5)))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .help("Il motore di cui vedi i bot: questo Mac o un server remoto")
        }
    }

    private var statusDot: some View {
        let color: Color
        switch model.status {
        case .live: color = Theme.success
        case .connecting, .starting: color = Theme.secondary
        case .offline, .failed: color = Theme.danger
        }
        return Circle().fill(color).frame(width: 6, height: 6)
    }
}

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
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                if model.remoteEngines.isEmpty {
                    Text("Nessun server. Un bot su un server continua a lavorare anche a Mac spento, e lo ritrovi qui o sul telefono.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.remoteEngines) { engine in
                    HStack(alignment: .top) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.name).font(.system(size: 13, weight: .medium))
                            Text(engine.chatURL).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            if let identity = model.identity(for: engine) {
                                Text("Amministrato da questo Mac come \(identity.label)").font(.system(size: 11)).foregroundStyle(.tertiary)
                                EngineUpdateLine(engine: engine)
                            }
                        }
                        Spacer()
                        Menu("Azioni") {
                            Button("Mostra i suoi bot") { model.select(engine: .remote(engine.id)) }
                            Button("Abbina un telefono o un altro Mac…") { qrFor = engine }
                            Button("Dispositivi abbinati…") { devicesFor = engine }
                            if let identity = model.identity(for: engine) {
                                Divider()
                                Button("Login di Claude sul server…") { claudeLoginFor = engine }
                                Button("Copia la configurazione di pi…") { piCopyFor = engine }
                                Button("Apri un terminale sul server") { try? model.openTerminal(identity) }
                            }
                            Divider()
                            Button("Dimentica su questo Mac…", role: .destructive) { forgetting = engine }
                        }
                        .fixedSize()
                    }
                }
            } header: {
                Text("Server remoti")
            } footer: {
                Text("Il Mac amministra il server via ssh; la chat passa sempre in HTTPS con un token di questo dispositivo.")
            }
            Section {
                Button("Aggiungi un server…") { adding = true }
                Button("Collega un server con un codice…") { pairingWithCode = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { ServerSetupSheet() }
        .sheet(isPresented: $pairingWithCode) { PairWithCodeSheet() }
        .sheet(item: $devicesFor) { DevicesSheet(engine: $0) }
        .sheet(item: $qrFor) { PairingQRSheet(engine: $0) }
        .sheet(item: $claudeLoginFor) { ClaudeTokenSheet(engine: $0) }
        .confirmationDialog("Copiare la configurazione di pi su \(piCopyFor?.name ?? "")?",
                            isPresented: Binding(get: { piCopyFor != nil }, set: { if !$0 { piCopyFor = nil } })) {
            Button("Copia") {
                guard let engine = piCopyFor else { return }
                Task {
                    do {
                        let copied = try await model.copyPiConfig(to: engine)
                        notice = "Copiati su \(engine.name): \(copied.joined(separator: ", "))"
                    } catch {
                        notice = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("auth.json, models.json e settings.json di ~/.pi/agent vanno sul server, leggibili solo dal suo utente. Contengono le chiavi API dei tuoi provider. I file già presenti sul server restano come copia di backup.")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        }
        .confirmationDialog("Dimenticare \(forgetting?.name ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Dimentica", role: .destructive) {
                if let engine = forgetting { try? model.forgetRemoteEngine(engine.id) }
                forgetting = nil
            }
        } message: {
            Text("Il server e i suoi bot continuano a funzionare; questo Mac non lo mostra più. Il dispositivo resta abbinato finché non lo revochi.")
        }
        .onAppear { model.reloadRemoteEngines() }
    }
}

// MARK: - Setup walk-through

struct ServerSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow: ServerSetupFlow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aggiungi un server").font(.title2.weight(.semibold))
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
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
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

    var body: some View {
        Form {
            Section("Server (amministrazione via ssh)") {
                TextField("Nome da mostrare", text: $flow.name, prompt: Text("srv1 · deploy"))
                TextField("Server", text: $flow.host, prompt: Text("10.0.4.12 o vps1.example.it"))
                    .onSubmit { flow.suggestPrefix() }
                TextField("Porta ssh", value: $flow.port, format: .number.grouping(.never))
                TextField("Utente", text: $flow.user, prompt: Text("deploy"))
                    .onSubmit { flow.suggestPrefix() }
            }
            .disabled(flow.step > .hostKey)
            Section {
                TextField("Sito Caddy", text: $flow.site, prompt: Text("bot.example.it, oppure :8080 dietro un proxy"))
                TextField("Prefisso", text: $flow.prefix, prompt: Text("/srv1/deploy"))
                Picker("Certificato", selection: $flow.tls) {
                    Text("Pubblico (Let's Encrypt)").tag(CaddySettings.TLS.public)
                    Text("Nessuno: dietro un proxy HTTPS").tag(CaddySettings.TLS.off)
                }
                TextField("URL di chat (se c'è un proxy davanti)", text: $flow.chatURLOverride, prompt: Text(flow.chatURL))
            } header: {
                Text("Chat (HTTPS)")
            } footer: {
                Text("I dispositivi usano solo questo URL: \(flow.chatURL)")
            }
            .disabled(flow.step > .hostKey)

            Section("Avanzamento") {
                ForEach(ServerSetupFlow.Step.allCases.filter { $0 != .done }, id: \.self) { step in
                    HStack {
                        Image(systemName: icon(step)).foregroundStyle(color(step))
                        Text(step.title)
                    }
                }
                if !flow.scannedKeys.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Confronta il fingerprint con quello mostrato dalla console del server:").font(.callout)
                        ForEach(flow.scannedKeys.prefix(1), id: \.self) { key in
                            Text("\(key.type)  \(key.fingerprint)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Button("È quello giusto: approva") { Task { await flow.approve(key) } }
                        }
                    }
                }
                if flow.needsPassword, flow.step == .key {
                    SecureField("Password ssh di \(flow.user) (solo per installare la chiave, non viene salvata)", text: $flow.sshPassword)
                }
                if flow.needsSudoPassword, flow.step >= .root, flow.step < .device {
                    SecureField("Password di sudo", text: $flow.sudoPassword)
                    DisclosureGroup("Comandi eseguiti come root", isExpanded: $showRoot) {
                        ScrollView {
                            Text(flow.rootPreview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 160)
                    }
                }
                if let probe = flow.probe {
                    Text("\(probe.os) \(probe.version) · \(probe.arch) · Claude: \(probe.claude ?? "non installato") · pi: \(probe.pi ?? "non installato")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = flow.error {
                    Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        HStack {
            if flow.running { ProgressView().controlSize(.small) }
            if let activity = flow.activity { Text(activity).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if flow.step == .done {
                Button("Mostra i bot del server", action: finished).keyboardShortcut(.defaultAction)
            } else {
                Button(flow.step == .hostKey && flow.error == nil ? "Collegati" : "Continua") {
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
            Text("Collega un server con un codice").font(.title3.weight(.semibold))
            Text("Su un dispositivo già abbinato: Server remoti › Abbina un telefono o un altro Mac. Copia qui l'URL e il codice.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("URL di chat", text: $chatURL, prompt: Text("https://bot.example.it/srv1/deploy"))
                TextField("Codice", text: $code, prompt: Text("ABCD234567"))
                TextField("Nome da mostrare", text: $name)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Collega") {
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
            Text("Abbina un dispositivo a \(engine.name)").font(.title3.weight(.semibold))
            if let pairing, let link = RemotePairingLink(chatURL: engine.chatURL, code: pairing.code, name: engine.name).url {
                if let image = Self.qr(link.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                }
                Text("Codice: \(pairing.code)").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                Text("URL: \(engine.chatURL)").font(.callout).textSelection(.enabled)
                Text("Vale 10 minuti e una volta sola. Il QR non contiene il token.").font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).foregroundStyle(Theme.danger)
            } else {
                ProgressView()
            }
            Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction)
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
            Text("Dispositivi abbinati a \(engine.name)").font(.title3.weight(.semibold))
            if let list {
                List(list.devices) { device in
                    HStack {
                        Image(systemName: device.kind == "ios" ? "iphone" : "laptopcomputer")
                        VStack(alignment: .leading) {
                            Text(device.name + (device.id == list.current ? " (questo Mac)" : ""))
                            if let seen = device.lastSeenAt {
                                Text("Visto \(Date(timeIntervalSince1970: seen / 1000).formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Revoca", role: .destructive) {
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
            HStack { Spacer(); Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction) }
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
            Text("Login di Claude su \(engine.name)").font(.title3.weight(.semibold))
            Text("Nel Terminale di questo Mac esegui il comando qui sotto e accedi con il tuo abbonamento; poi incolla il token che stampa. Il token resta sul server in un file leggibile solo dal suo utente.")
                .font(.callout).foregroundStyle(.secondary)
            Text("claude setup-token").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            SecureField("sk-ant-…", text: $token)
            if let error { Text(error).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salva sul server") {
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
                Text("Aggiorno il motore…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(2)
            } else if let status {
                if status.updateAvailable {
                    Text(status.installed == nil ? "Motore non installato" : "Aggiornamento del motore disponibile")
                        .font(.system(size: 11)).foregroundStyle(Theme.warning)
                    Button("Aggiorna motore") { Task { await update(force: false) } }.controlSize(.small)
                } else {
                    Text("Motore aggiornato").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Controllo il motore…").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .task(id: engine.id) { await load() }
        .confirmationDialog("Aggiornare adesso?", isPresented: Binding(get: { busyNames != nil }, set: { if !$0 { busyNames = nil } })) {
            Button("Aggiorna e interrompi", role: .destructive) { Task { await update(force: true) } }
        } message: {
            Text("Stanno lavorando: \((busyNames ?? []).joined(separator: ", ")). L'aggiornamento riavvia il motore e interrompe i loro turni.")
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

