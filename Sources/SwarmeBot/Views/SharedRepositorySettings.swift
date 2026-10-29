import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI

/// Local execution, centrally maintained definitions, and machine-local logins.
struct SharedRepositoriesPane: View {
    @State private var kind = SharedRepositoryKind(rawValue: ProcessInfo.processInfo.environment["SWARMEBOT_SHARED_CATALOG"] ?? "") ?? .bots

    var body: some View {
        VStack(spacing: 0) {
            Picker(tr("Catalogo condiviso"), selection: $kind) {
                Text(tr("Bot condivisi")).tag(SharedRepositoryKind.bots)
                Text(tr("Connettori MCP")).tag(SharedRepositoryKind.connectors)
            }
            .pickerStyle(.segmented).padding(16)
            SharedRepositoryBrowser(kind: kind).id(kind)
        }
    }
}

struct SharedRepositoryBrowser: View {
    let kind: SharedRepositoryKind
    @Environment(AppModel.self) private var model
    @State private var repository: SharedRepository?
    @State private var selected = Set<String>()
    @State private var bots: [Bot] = []
    @State private var busy = false

    private var isBots: Bool { kind == .bots }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isBots ? tr("Bot condivisi") : tr("Connettori MCP condivisi"))
                .font(.system(size: 17, weight: .semibold))
            Text(isBots
                 ? tr("I bot girano su questo Mac. Nome, ruolo e istruzioni si aggiornano dalla cartella condivisa all'avvio; avatar, modello e chat restano locali.")
                 : tr("Importa le configurazioni MCP che vuoi usare su questo Mac. Credenziali, login e attivazione restano locali; puoi assegnare i connettori importati ai bot."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "folder")
                Text(repository?.folder ?? tr("Nessuna cartella selezionata"))
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(repository?.folder ?? "")
                Spacer()
                Button(tr("Scegli cartella…"), action: chooseFolder)
                if let folder = repository?.folder {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) } label: { Image(systemName: "arrow.up.right.square") }
                        .help(tr("Mostra nel Finder"))
                    Button(tr("Scollega")) {
                        Task { await run { repository = await model.setSharedFolder(kind, nil); selected.removeAll() } }
                    }
                }
            }
            if let problem = repository?.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warning).textSelection(.enabled)
            }
            if repository?.folder != nil {
                HStack {
                    Button(tr("Aggiorna dal repository")) {
                        Task { await run { await model.syncSharedRepositories(); await load() } }
                    }
                    Spacer()
                    Menu(tr("Condividi dal Mac…")) {
                        if isBots {
                            ForEach(bots) { bot in
                                Button(bot.name) { publish(bot.id) }
                            }
                        } else {
                            ForEach(model.mcpConnectors) { connector in
                                Button(connector.name) { publish(connector.id) }
                            }
                        }
                    }
                    .disabled(isBots ? bots.isEmpty : model.mcpConnectors.isEmpty)
                    .help(isBots ? tr("Salva nome e istruzioni nella cartella condivisa.") : tr("Salva la configurazione senza credenziali nella cartella condivisa."))
                }
                if repository?.entries.isEmpty == true, repository?.problem == nil {
                    Text(tr("Il catalogo è vuoto. Usa Condividi dal Mac per aggiungere una configurazione esistente."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                List(repository?.entries ?? []) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: Binding(get: { selected.contains(entry.id) }, set: { on in
                            if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
                        }))
                        .labelsHidden().toggleStyle(.checkbox)
                        .disabled(entry.imported || entry.conflict)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.name).font(.system(size: 13, weight: .medium))
                                if entry.imported { Label(tr("Importato"), systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
                                if entry.conflict { Text(tr("ID già usato in locale")).font(.system(size: 11)).foregroundStyle(Theme.warning) }
                            }
                            Text(entry.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset).frame(minHeight: 90)
                HStack {
                    Button(tr("Seleziona tutti")) {
                        selected = Set((repository?.entries ?? []).filter { !$0.imported && !$0.conflict }.map(\.id))
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(isBots ? tr("Importa bot") : tr("Importa connettori")) {
                        Task { await run {
                            if let result = await model.importShared(kind, ids: selected.sorted()) {
                                repository = result; selected.removeAll(); await load()
                            }
                        } }
                    }
                    .buttonStyle(.borderedProminent).disabled(selected.isEmpty || repository?.problem != nil)
                }
            } else {
                Spacer()
            }
            Text(isBots
                 ? tr("Modifica il profilo di un bot importato per aggiornare nome e istruzioni condivisi. L'avatar si modifica solo su questo Mac.")
                 : tr("Dopo l'importazione completa il login in Connettori. Per condividere le modifiche alla configurazione usa Condividi dal Mac."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(tr("Se la cartella viene scollegata o non è disponibile, le copie locali vengono conservate."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(16).disabled(busy || model.status != .live)
        .task(id: model.status == .live) {
            guard model.status == .live else { return }
            await run { await load() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = tr("Usa questa cartella")
        if let path = repository?.folder { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await run {
            if let result = await model.setSharedFolder(kind, url.path) { repository = result; selected.removeAll() }
        } }
    }

    private func publish(_ id: String) {
        Task { await run {
            if let result = await model.publishShared(kind, id: id) { repository = result; await load() }
        } }
    }

    private func load() async {
        if let result = await model.refreshSharedRepository(kind) { repository = result }
        if isBots { bots = await model.shareableBots() }
        else { await model.refreshMCPConnectors() }
    }

    private func run(_ operation: () async -> Void) async {
        busy = true
        defer { busy = false }
        await operation()
    }
}
