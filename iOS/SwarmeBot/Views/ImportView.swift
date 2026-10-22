// Settings from the Mac (plan §7, D11): what the QR or the `.swarmeconfig`
// file carries, shown before anything is saved, with header values masked.
import CompanionCore
import SwiftUI

enum ImportSource: Identifiable {
    case link(PhoneConfigLink)
    case file(URL)

    var id: String {
        switch self {
        case let .link(link): return link.code
        case let .file(url): return url.absoluteString
        }
    }
}

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: ImportSource

    @State private var config: PhoneConfig?
    @State private var passphrase = ""
    @State private var working = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                if let config {
                    preview(config)
                } else if case .file = source {
                    Section {
                        SecureField(tr("Frase scelta sul Mac"), text: $passphrase)
                        Button(tr("Apri")) { Task { await openFile() } }.disabled(passphrase.isEmpty || working)
                    } footer: {
                        Text(tr("Il file è cifrato: serve la frase scelta quando è stato esportato."))
                    }
                } else if working {
                    Section { ProgressView(tr("Ricezione dal Mac…")) }
                }
                if let error {
                    Section { Text(verbatim: error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(tr("Dal Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annulla")) { dismiss() } }
                if let config, !done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(tr("Aggiungi")) {
                            Task {
                                working = true
                                await model.local.importConfig(config)
                                working = false
                                done = true
                                dismiss()
                            }
                        }
                        .disabled(working)
                    }
                }
            }
            .task {
                guard case let .link(link) = source else { return }
                working = true
                defer { working = false }
                do { config = try await link.fetch() } catch {
                    self.error = tr("Configurazione non ricevuta: %@. Il telefono deve essere sulla stessa rete del Mac, entro due minuti dal QR.", error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private func preview(_ config: PhoneConfig) -> some View {
        if !config.endpoints.isEmpty {
            Section(tr("Bot sul telefono")) {
                ForEach(Array(config.endpoints.enumerated()), id: \.offset) { _, endpoint in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: endpoint.name)
                        Text(verbatim: endpoint.baseUrl).font(.caption).foregroundStyle(.secondary)
                        Text(endpoint.apiKey == nil ? tr("Senza chiave") : tr("Con chiave")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !config.connectors.isEmpty {
            Section(tr("Connettori")) {
                ForEach(Array(config.connectors.enumerated()), id: \.offset) { _, connector in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: connector.name)
                        Text(verbatim: connector.url).font(.caption).foregroundStyle(.secondary)
                        ForEach((connector.headers ?? [:]).keys.sorted(), id: \.self) { name in
                            Text(verbatim: "\(name): ••••••").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if connector.auth == "oauth" {
                            Text(tr("OAuth: dopo, premi «Accedi» nel connettore.")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private func openFile() async {
        guard case let .file(url) = source else { return }
        working = true
        defer { working = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let phrase = passphrase
            config = try await Task.detached { try PhoneConfig.open(file: data, passphrase: phrase) }.value
            error = nil
        } catch {
            self.error = tr("Frase sbagliata o file danneggiato.")
        }
    }
}
