// Impostazioni › Telefono: send this Mac's OpenAI-compatible server and HTTP connectors
// to the iOS app's own bots (docs/plans/2026-10-22-app-ios.md §7), with a QR
// on the local network or a file sealed with a passphrase. Never chats.
import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI
import UniformTypeIdentifiers

struct PhonePane: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: Set<String> = []
    @State private var showQR = false
    @State private var showExport = false

    private var items: [PhoneConfigExport.Item] { PhoneConfigExport.items(model) }

    var body: some View {
        Form {
            Section {
                if items.isEmpty {
                    Text(tr("Niente da inviare: configura il server compatibile OpenAI o un connettore HTTP.")).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Toggle(isOn: Binding(get: { chosen.contains(item.id) }, set: { on in
                        if on { chosen.insert(item.id) } else { chosen.remove(item.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.name)
                            Text(verbatim: item.detail).font(.caption).foregroundStyle(.secondary)
                            if let note = item.note { Text(verbatim: note).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
            } header: {
                Text(tr("Invia al telefono"))
            } footer: {
                Text(tr("Per i bot dell'app SwarmeBot su iPhone: indirizzi e chiavi, mai le chat. I connettori stdio non funzionano sul telefono e non compaiono."))
            }
            Section {
                HStack {
                    Button(tr("Mostra il QR…")) { showQR = true }
                    Button(tr("Esporta un file…")) { showExport = true }
                }
                .disabled(chosen.isEmpty)
            } footer: {
                Text(tr("Il QR funziona con il telefono sulla stessa rete: il Mac offre la configurazione cifrata per due minuti, una volta sola. Il file è cifrato con una frase che scegli tu."))
            }
        }
        .formStyle(.grouped)
        .onAppear { chosen = Set(items.map(\.id)) }
        .sheet(isPresented: $showQR) { PhoneQRSheet(config: PhoneConfigExport.build(model, chosen: chosen)) }
        .sheet(isPresented: $showExport) { PhoneExportSheet(config: PhoneConfigExport.build(model, chosen: chosen)) }
    }
}

private struct PhoneQRSheet: View {
    let config: PhoneConfig
    @Environment(\.dismiss) private var dismiss
    @State private var server = PhoneConfigServer()
    @State private var link: PhoneConfigLink?
    @State private var outcome: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(tr("Inquadra con il telefono")).font(.title3.weight(.semibold))
            if let outcome {
                Text(verbatim: outcome)
            } else if let link, let url = link.url, let image = PairingQRSheet.qr(url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 240, height: 240)
                Text(tr("Con la Fotocamera dell'iPhone o con il lettore QR dell'app. Vale due minuti, una volta sola."))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if let error {
                Text(verbatim: error).foregroundStyle(Theme.danger)
            } else {
                ProgressView()
            }
            Button(tr("Chiudi")) { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 380)
        .task {
            server.onFinish = { delivered in
                outcome = delivered ? tr("Inviato al telefono.") : tr("Tempo scaduto: il Mac non offre più la configurazione.")
            }
            do { link = try await server.start(config) } catch { self.error = error.localizedDescription }
        }
        .onDisappear { server.stop() }
    }
}

private struct PhoneExportSheet: View {
    let config: PhoneConfig
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var again = ""
    @State private var error: String?

    private var valid: Bool { passphrase.count >= 8 && passphrase == again }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Esporta per il telefono")).font(.title3.weight(.semibold))
            Text(tr("Scegli una frase di almeno 8 caratteri: servirà sul telefono per aprire il file."))
                .font(.callout).foregroundStyle(.secondary)
            SecureField(tr("Frase"), text: $passphrase)
            SecureField(tr("Ripeti la frase"), text: $again)
            if let error { Text(verbatim: error).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button(tr("Annulla")) { dismiss() }
                Button(tr("Salva…")) { save() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SwarmeBot.swarmeconfig"
        panel.allowedContentTypes = [UTType(filenameExtension: "swarmeconfig") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try config.file(passphrase: passphrase).write(to: url, options: .atomic)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
