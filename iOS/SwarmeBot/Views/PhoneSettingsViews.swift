// Impostazioni for the phone's own bots: the MCP connectors over HTTP and
// the on-device models.
import AgentCore
import SwiftUI

struct ConnectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: LocalConnector?
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                ForEach(model.local.connectors) { connector in
                    Button { editing = connector } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: connector.name).foregroundStyle(.primary)
                            Text(verbatim: connector.url).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(tr("Aggiungi un connettore"), systemImage: "plus") { adding = true }
            } footer: {
                Text(tr("Server MCP via HTTP. Sul telefono li usano i bot Gemma e quelli con un endpoint; i bot dei server hanno i loro."))
            }
        }
        .navigationTitle(tr("Connettori"))
        .sheet(item: $editing) { ConnectorEditor(existing: $0) }
        .sheet(isPresented: $adding) { ConnectorEditor(existing: nil) }
    }
}

struct ConnectorEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var existing: LocalConnector?

    @State private var name = ""
    @State private var url = ""
    @State private var auth: LocalConnector.Auth = .none
    @State private var headersText = ""
    @State private var clientId = ""
    @State private var status: String?
    @State private var working = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("Nome"), text: $name)
                    TextField(tr("Indirizzo MCP (https://…)"), text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Picker(tr("Accesso"), selection: $auth) {
                        Text(tr("Nessuno")).tag(LocalConnector.Auth.none)
                        Text(tr("Header")).tag(LocalConnector.Auth.headers)
                        Text(verbatim: "OAuth").tag(LocalConnector.Auth.oauth)
                    }
                }
                switch auth {
                case .none:
                    EmptyView()
                case .headers:
                    Section {
                        TextField(tr("Header, uno per riga: Nome: valore"), text: $headersText, axis: .vertical)
                            .lineLimit(1...6)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text(tr("I valori restano nel Portachiavi di questo telefono."))
                    }
                case .oauth:
                    Section {
                        TextField(tr("Client ID (solo se il server non registra da solo)"), text: $clientId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let existing {
                            if model.local.pool.oauth.tokens(existing) != nil {
                                Label(tr("Accesso effettuato"), systemImage: "checkmark.seal")
                                Button(tr("Esci"), role: .destructive) { model.local.pool.oauth.logout(existing); status = nil }
                            }
                            Button(tr("Accedi")) { Task { await login(existing) } }.disabled(working)
                        } else {
                            Text(tr("Salva il connettore, poi accedi.")).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text(tr("Redirect da registrare presso il servizio, se serve: %@", PhoneOAuth.redirect))
                    }
                }
                if let existing {
                    Section {
                        Button(tr("Prova la connessione")) { Task { await test(existing) } }.disabled(working)
                        if working { ProgressView() }
                        if let status { Text(verbatim: status).font(.footnote) }
                    }
                    Section {
                        Button(tr("Elimina il connettore"), role: .destructive) { confirmDelete = true }
                    }
                    .confirmationDialog(tr("Eliminare %@?", existing.name), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(tr("Elimina"), role: .destructive) {
                            model.local.delete(existing)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? tr("Nuovo connettore") : (existing?.name ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Chiudi")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Salva")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: url)?.scheme == nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var headers: [String: String] {
        var out: [String: String] = [:]
        for line in headersText.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        url = existing.url
        auth = existing.auth
        clientId = existing.oauthClientId ?? ""
        headersText = ConnectorSecrets.headers(existing).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private func save() {
        var connector = existing ?? LocalConnector(id: newId(), name: "", url: "", auth: .none, createdAt: Date())
        connector.name = name.trimmingCharacters(in: .whitespaces)
        connector.url = url.trimmingCharacters(in: .whitespaces)
        connector.auth = auth
        connector.oauthClientId = clientId.isEmpty ? nil : clientId
        let values = auth == .headers ? headers : [:]
        connector.headerNames = values.keys.sorted()
        model.local.save(connector, headers: values)
        if existing == nil { dismiss() }
    }

    private func login(_ connector: LocalConnector) async {
        save()
        working = true
        defer { working = false }
        do {
            try await model.local.pool.oauth.login(model.local.connectors.first { $0.id == connector.id } ?? connector)
            model.local.pool.reset(connector.id)
            status = tr("Accesso effettuato")
        } catch {
            status = error.localizedDescription
        }
    }

    private func test(_ connector: LocalConnector) async {
        save()
        working = true
        defer { working = false }
        do {
            let tools = try await model.local.pool.test(model.local.connectors.first { $0.id == connector.id } ?? connector)
            status = tools.isEmpty ? tr("Connesso, nessuno strumento.") : tr("Connesso: %@", tools.joined(separator: ", "))
        } catch {
            status = Redact.text(error.localizedDescription)
        }
    }
}

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    private var gemma: GemmaModel { model.local.gemma }

    var body: some View {
        Form {
            Section {
                gemmaStatus
            } header: {
                Text(verbatim: "Gemma 4 E4B")
            } footer: {
                Text(tr("Gira sul telefono, anche senza rete: vede le immagini e usa i connettori. Pesa circa 5 GB e non va nel backup."))
            }
            Section {
                switch AppleDriver.availability {
                case .available: Label(tr("Disponibile"), systemImage: "checkmark.circle")
                case let .unavailable(reason): Text(verbatim: reason).foregroundStyle(.secondary)
                }
            } header: {
                Text(verbatim: "Apple Intelligence")
            } footer: {
                Text(tr("Il modello di Apple sul telefono: solo chat, contesto breve, niente connettori."))
            }
        }
        .navigationTitle(tr("Modelli sul telefono"))
        .confirmationDialog(tr("Eliminare Gemma dal telefono?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(tr("Elimina"), role: .destructive) { gemma.deleteWeights() }
        }
    }

    @ViewBuilder
    private var gemmaStatus: some View {
        if let reason = GemmaModel.unavailableReason {
            Text(verbatim: reason).foregroundStyle(.secondary)
        }
        switch gemma.state {
        case .notDownloaded:
            Button(tr("Scarica (%@)", ByteCountFormatter.string(fromByteCount: GemmaModel.totalBytes, countStyle: .file))) { gemma.startDownload() }
        case let .downloading(fraction):
            ProgressView(value: fraction) { Text(tr("Download…")) } currentValueLabel: { Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0)))) }
            Button(tr("Interrompi"), role: .cancel) { gemma.cancelDownload() }
        case .verifying:
            ProgressView(tr("Verifica del file…"))
        case .downloaded, .loading, .ready:
            Label(gemma.state == .ready ? tr("In memoria") : tr("Scaricato"), systemImage: "checkmark.circle")
            Button(tr("Elimina dal telefono"), role: .destructive) { confirmDelete = true }
        case let .failed(message):
            Text(verbatim: message).foregroundStyle(.red)
            Button(tr("Riprova")) { gemma.startDownload() }
        }
    }
}
