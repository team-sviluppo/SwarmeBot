// A phone bot's settings: its kind (endpoint, Gemma, Apple), the endpoint
// with its key and headers, instructions, and the connectors it may use.
import AgentCore
import SwiftUI

struct LocalBotEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var existing: LocalBot?

    @State private var name = ""
    @State private var kind: LocalBotKind = .endpoint
    @State private var baseUrl = ""
    @State private var apiKey = ""
    @State private var modelId = ""
    @State private var headersText = ""
    @State private var images = false
    @State private var instructions = ""
    @State private var connectorIds: Set<String> = []
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("Nome"), text: $name)
                    Picker(tr("Modello"), selection: $kind) {
                        Text(tr("API compatibile OpenAI")).tag(LocalBotKind.endpoint)
                        Text(verbatim: "Gemma 4 E4B").tag(LocalBotKind.gemma)
                        Text(verbatim: "Apple Intelligence").tag(LocalBotKind.apple)
                    }
                } footer: {
                    kindFooter
                }
                if kind == .endpoint { endpointSection }
                Section(tr("Istruzioni")) {
                    TextField(tr("Istruzioni di sistema (facoltative)"), text: $instructions, axis: .vertical).lineLimit(3...10)
                }
                if kind.takesTools {
                    Section {
                        if model.local.connectors.isEmpty {
                            Text(tr("Nessun connettore: aggiungili in Impostazioni › Connettori.")).foregroundStyle(.secondary)
                        }
                        ForEach(model.local.connectors) { connector in
                            Toggle(isOn: Binding(get: { connectorIds.contains(connector.id) }, set: { on in
                                if on { connectorIds.insert(connector.id) } else { connectorIds.remove(connector.id) }
                            })) {
                                Text(verbatim: connector.name)
                            }
                        }
                    } header: {
                        Text(tr("Connettori"))
                    }
                }
                if let error {
                    Section { Text(verbatim: error).foregroundStyle(.red) }
                }
                if let existing {
                    Section {
                        Button(tr("Elimina il bot"), role: .destructive) { confirmDelete = true }
                    }
                    .confirmationDialog(tr("Eliminare %@?", existing.name), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(tr("Elimina"), role: .destructive) {
                            model.local.delete(existing)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? tr("Nuovo bot") : tr("Modifica il bot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Annulla")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(tr("Salva")) { save() }.disabled(!canSave) }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder
    private var kindFooter: some View {
        switch kind {
        case .endpoint:
            Text(tr("Un server che parla l'API di OpenAI: LiteLLM, vLLM, Hermes Agent, un proxy."))
        case .gemma:
            if let reason = GemmaModel.unavailableReason {
                Text(verbatim: reason).foregroundStyle(.orange)
            } else if !GemmaModel.isComplete {
                Text(tr("Gira sul telefono, senza rete. Va scaricato una volta (circa 5 GB) in Impostazioni › Modelli sul telefono."))
            } else {
                Text(tr("Gira sul telefono, senza rete. Vede le immagini e usa i connettori."))
            }
        case .apple:
            switch AppleDriver.availability {
            case .available: Text(tr("Il modello di Apple sul telefono: solo chat, niente connettori né immagini."))
            case let .unavailable(reason): Text(verbatim: reason).foregroundStyle(.orange)
            }
        }
    }

    private var endpointSection: some View {
        Section {
            TextField(tr("Indirizzo, fino a /v1"), text: $baseUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField(tr("Chiave API"), text: $apiKey)
            HStack {
                TextField(tr("Modello"), text: $modelId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if loadingModels {
                    ProgressView()
                } else {
                    Menu {
                        ForEach(models, id: \.self) { id in Button { modelId = id } label: { Text(verbatim: id) } }
                        Button(tr("Leggi i modelli dall'endpoint")) { Task { await fetchModels() } }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            Toggle(tr("Invia le immagini"), isOn: $images)
            TextField(tr("Header, uno per riga: Nome: valore"), text: $headersText, axis: .vertical)
                .lineLimit(1...6)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(tr("Endpoint"))
        } footer: {
            Text(tr("La chiave resta nel Portachiavi di questo telefono."))
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return kind != .endpoint || (URL(string: baseUrl)?.scheme != nil && !modelId.isEmpty)
    }

    private var headers: [String: String] {
        var out: [String: String] = [:]
        for line in headersText.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private func load() {
        guard let existing else {
            name = tr("Assistente")
            kind = GemmaModel.isComplete && GemmaModel.unavailableReason == nil ? .gemma : .endpoint
            return
        }
        name = existing.name
        kind = existing.kind
        baseUrl = existing.endpoint?.baseUrl ?? ""
        modelId = existing.endpoint?.model ?? ""
        images = existing.endpoint?.images ?? false
        headersText = (existing.endpoint?.headers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        instructions = existing.instructions
        connectorIds = Set(existing.connectorIds)
        apiKey = Keychain.get(existing.apiKeyAccount) ?? ""
    }

    private func save() {
        var bot = existing ?? LocalBot(id: newId(), name: "", kind: kind, createdAt: Date())
        bot.name = name.trimmingCharacters(in: .whitespaces)
        if bot.kind != kind { bot.sessionId = nil }
        bot.kind = kind
        bot.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        bot.connectorIds = model.local.connectors.map(\.id).filter(connectorIds.contains)
        if kind == .endpoint {
            let config = EndpointConfig(baseUrl: baseUrl.trimmingCharacters(in: .whitespaces), model: modelId, headers: headers, images: images)
            if config.baseUrl != bot.endpoint?.baseUrl { bot.sessionId = nil }
            bot.endpoint = config
        }
        model.local.save(bot, apiKey: kind == .endpoint ? apiKey : nil)
        dismiss()
    }

    private func fetchModels() async {
        guard let url = URL(string: baseUrl.trimmingCharacters(in: .whitespaces).trimmingSuffix("/") + "/models") else { return }
        loadingModels = true
        defer { loadingModels = false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { throw DriverError(message: "HTTP \(status)") }
            models = (try JSON.parse(data))["data"]?.array?.compactMap { $0["id"]?.string } ?? []
            if modelId.isEmpty, let first = models.first { modelId = first }
            error = models.isEmpty ? tr("L'endpoint non ha elencato modelli.") : nil
        } catch {
            self.error = tr("Modelli non letti: %@", error.localizedDescription)
        }
    }
}
