// A phone bot's settings: its kind (endpoint, Gemma, Apple), the server and
// model it uses, instructions, the phone tools and the connectors it may use.
import AgentCore
import SwiftUI

struct LocalBotEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var existing: LocalBot?

    @State private var name = ""
    @State private var color = "blue"
    @State private var silhouette = SwarmeSilhouette.ids.randomElement() ?? SwarmeSilhouetteData.defaultId
    @State private var kind: LocalBotKind = .endpoint
    @State private var serverId: String?
    @State private var modelId = ""
    @State private var addingServer = false
    @State private var images = false
    @State private var instructions = ""
    @State private var connectorIds: Set<String> = []
    @State private var phoneTools: Set<PhoneToolGroup> = []
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var error: String?
    @State private var deleting: LocalBot?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        SwarmeAvatar(color: color, size: 88, state: .happy, silhouette: silhouette, trackPointer: false)
                        Spacer()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Self.palette, id: \.self) { name in
                                Button { color = name } label: {
                                    Circle().fill(SwarmePalette.color(name)).frame(width: 30, height: 30)
                                        .overlay { if name == color { Circle().stroke(Theme.ink, lineWidth: 2).padding(-4) } }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: name))
                            }
                        }
                        .padding(6)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(SwarmeSilhouette.ids, id: \.self) { id in
                                Button { silhouette = id } label: {
                                    SwarmeAvatar(color: color, size: 40, state: .idle, silhouette: id, animated: false, trackPointer: false, effects: false)
                                        .padding(4)
                                        .background(id == silhouette ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay {
                                            if id == silhouette { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.ink, lineWidth: 1.5) }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: id))
                            }
                        }
                        .padding(4)
                    }
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
                Section {
                    ForEach(PhoneToolGroup.allCases) { group in
                        Toggle(isOn: Binding(get: { phoneTools.contains(group) }, set: { on in
                            if on { phoneTools.insert(group) } else { phoneTools.remove(group) }
                        })) {
                            Label(group.title, systemImage: group.symbol)
                        }
                    }
                } header: {
                    Text(tr("Telefono"))
                } footer: {
                    Text(kind == .apple
                        ? tr("Il bot legge e scrive sul telefono; prima di creare qualcosa chiede conferma. Il modello di Apple ha poco contesto: accendi solo quello che serve.")
                        : tr("Il bot legge e scrive sul telefono; prima di creare qualcosa chiede conferma."))
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
                        Button(tr("Elimina il bot"), role: .destructive) { deleting = existing }
                    }
                }
            }
            .deleteBotDialog($deleting) { dismiss() }
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
            case .available: Text(tr("Il modello di Apple sul telefono: niente connettori né immagini, ma può usare il telefono."))
            case let .unavailable(reason): Text(verbatim: reason).foregroundStyle(.orange)
            }
        }
    }

    private var endpointSection: some View {
        Section {
            Picker(tr("Server"), selection: $serverId) {
                if serverId == nil { Text(tr("Scegli…")).tag(String?.none) }
                ForEach(model.local.servers) { server in
                    Text(verbatim: server.name).tag(Optional(server.id))
                }
            }
            Button(tr("Aggiungi un server"), systemImage: "plus") { addingServer = true }
            HStack {
                TextField(tr("Modello"), text: $modelId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if loadingModels {
                    ProgressView()
                } else {
                    Menu {
                        ForEach(models, id: \.self) { id in Button { modelId = id } label: { Text(verbatim: id) } }
                        Button(tr("Leggi i modelli dal server")) { Task { await fetchModels() } }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .disabled(server == nil)
                }
            }
            Toggle(tr("Invia le immagini"), isOn: $images)
        } header: {
            Text(tr("Server compatibile OpenAI"))
        } footer: {
            Text(tr("Indirizzo, chiave e header stanno nel server: si cambiano in Impostazioni › Server compatibili OpenAI."))
        }
        .sheet(isPresented: $addingServer) {
            ServerEditor(existing: nil) { serverId = $0.id }
        }
        .onChange(of: serverId) { _, _ in models = [] }
    }

    private var server: LocalServer? { model.local.servers.first { $0.id == serverId } }

    /// The Mac's mascot colours (`SwarmePaletteData`).
    static let palette = ["green", "blue", "red", "orange", "yellow", "purple", "pink", "cyan", "teal", "coral", "white"]

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return kind != .endpoint || (server != nil && !modelId.isEmpty)
    }

    private func load() {
        guard let existing else {
            name = tr("Assistente")
            kind = GemmaModel.isComplete && GemmaModel.unavailableReason == nil ? .gemma : .endpoint
            serverId = model.local.servers.first?.id
            return
        }
        name = existing.name
        color = existing.paletteColor
        silhouette = existing.shape
        kind = existing.kind
        serverId = existing.endpoint?.serverId
        modelId = existing.endpoint?.model ?? ""
        images = existing.endpoint?.images ?? false
        instructions = existing.instructions
        connectorIds = Set(existing.connectorIds)
        phoneTools = Set(existing.phoneTools ?? [])
    }

    private func save() {
        var bot = existing ?? LocalBot(id: newId(), name: "", kind: kind, createdAt: Date())
        bot.name = name.trimmingCharacters(in: .whitespaces)
        bot.color = color
        bot.silhouette = silhouette
        if bot.kind != kind { bot.sessionId = nil }
        bot.kind = kind
        bot.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        bot.connectorIds = model.local.connectors.map(\.id).filter(connectorIds.contains)
        bot.phoneTools = phoneTools.isEmpty ? nil : PhoneToolGroup.allCases.filter(phoneTools.contains)
        if kind == .endpoint {
            let config = EndpointConfig(serverId: serverId, model: modelId, images: images)
            if config.serverId != bot.endpoint?.serverId { bot.sessionId = nil }
            bot.endpoint = config
        }
        model.local.save(bot)
        dismiss()
    }

    private func fetchModels() async {
        guard let server else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            models = try await LocalBots.models(baseUrl: server.baseUrl, apiKey: Keychain.get(server.apiKeyAccount) ?? "", headers: server.headers)
            if modelId.isEmpty, let first = models.first { modelId = first }
            error = models.isEmpty ? tr("L'endpoint non ha elencato modelli.") : nil
        } catch {
            self.error = tr("Modelli non letti: %@", error.localizedDescription)
        }
    }
}

extension View {
    /// Asks before deleting a phone bot: its chats exist on this phone only.
    func deleteBotDialog(_ bot: Binding<LocalBot?>, deleted: @escaping () -> Void = {}) -> some View {
        modifier(DeleteBotDialog(bot: bot, deleted: deleted))
    }
}

private struct DeleteBotDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var bot: LocalBot?
    let deleted: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(tr("Eliminare %@?", bot?.name ?? ""), isPresented: Binding(get: { bot != nil }, set: { if !$0 { bot = nil } }),
                                   titleVisibility: .visible, presenting: bot) { target in
            Button(tr("Elimina"), role: .destructive) {
                model.local.delete(target)
                deleted()
            }
        } message: { _ in
            Text(tr("Le sue chat sono solo su questo telefono: si perdono anche quelle."))
        }
    }
}
