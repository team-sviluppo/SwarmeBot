import CompanionCore
import SwarmeKit
import SwiftUI

/// Settings › Connettori: MCP servers added once, then handed to bots
/// (docs/plans/2026-10-15-connettori-mcp.md §7). Secrets are typed here and
/// never shown again: the harness only says whether one is set.
struct ConnectorsPane: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var importing = false
    private static let newId = "__new__"

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(model.mcpConnectors) { connector in
                        ConnectorRow(connector: connector).tag(connector.id)
                    }
                    if selected == Self.newId {
                        Label("Nuovo connettore", systemImage: "plus.circle").tag(Self.newId)
                    }
                }
                Divider()
                HStack {
                    Button { selected = Self.newId } label: { Image(systemName: "plus") }
                        .help("Aggiungi un connettore")
                    Button("Importa JSON…") { importing = true }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 240, maxWidth: 300)
            Group {
                if selected == Self.newId {
                    ConnectorEditor(input: MCPConnectorInput(), connector: nil) { saved in selected = saved.id }
                        .id(Self.newId)
                } else if let id = selected, let connector = model.mcpConnectors.first(where: { $0.id == id }) {
                    ConnectorEditor(input: MCPConnectorInput(connector), connector: connector) { _ in }
                        .id(connector.id)
                } else {
                    VStack(spacing: 8) {
                        Text("I connettori sono server MCP che puoi dare ai bot.").foregroundStyle(.secondary)
                        Text("Aggiungine uno con + oppure importa la configurazione di Claude Desktop.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.refreshMCPConnectors() }
        .sheet(isPresented: $importing) { ConnectorImportSheet() }
    }
}

private struct ConnectorRow: View {
    let connector: MCPConnector

    private var dot: Color {
        guard connector.isEnabled else { return Theme.tertiary }
        if connector.usesOAuth, connector.oauthState?.status != "connected" { return Theme.warning }
        guard let check = connector.lastCheck else { return Theme.warning }
        return check.ok ? Theme.success : Theme.danger
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(connector.name).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        var parts = [connector.transport == "http" ? "HTTP" : "stdio", connector.id]
        if let count = connector.lastCheck?.tools?.count, connector.lastCheck?.ok == true { parts.append("\(count) strumenti") }
        if connector.usesOAuth, connector.oauthState?.status != "connected" { parts.append("da collegare") }
        if !connector.isEnabled { parts.append("disattivato") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Editor

private struct ConnectorEditor: View {
    @Environment(AppModel.self) private var model
    @State var input: MCPConnectorInput
    let connector: MCPConnector?
    let onCreated: (MCPConnector) -> Void
    @State private var argsText = ""
    @State private var idEdited = false
    @State private var error: String?
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var copied: String?

    init(input: MCPConnectorInput, connector: MCPConnector?, onCreated: @escaping (MCPConnector) -> Void) {
        _input = State(initialValue: input)
        _argsText = State(initialValue: input.args.joined(separator: "\n"))
        self.connector = connector
        self.onCreated = onCreated
    }

    private var existing: Bool { connector != nil }

    var body: some View {
        Form {
            Section("Connettore") {
                TextField("Nome", text: $input.name)
                    .onChange(of: input.name) { _, name in
                        if !existing, !idEdited { input.id = Self.slug(name) }
                    }
                TextField("Identificativo", text: Binding(get: { input.id }, set: { input.id = $0; idEdited = true }))
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(existing)
                    .help("Il nome con cui le harness vedono i suoi strumenti (mcp__\(input.id.isEmpty ? "id" : input.id)__…). Non si può cambiare dopo.")
                Picker("Trasporto", selection: $input.transport) {
                    Text("stdio (processo locale)").tag("stdio")
                    Text("HTTP").tag("http")
                }
                .pickerStyle(.segmented)
                Toggle("Attivo", isOn: $input.enabled)
            }

            if input.transport == "stdio" {
                Section {
                    TextField("Comando", text: $input.command, prompt: Text("npx"))
                        .font(.system(size: 12, design: .monospaced))
                    TextField("Argomenti, uno per riga", text: $argsText, prompt: Text("-y\n@modelcontextprotocol/server-everything"), axis: .vertical)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2...8)
                    TextField("Cartella di lavoro (facoltativa)", text: $input.cwd)
                        .font(.system(size: 12, design: .monospaced))
                } header: {
                    Text("Processo")
                } footer: {
                    if !input.command.isEmpty {
                        Label("Esegue `\(([input.command] + parsedArgs).joined(separator: " "))` sul tuo Mac, con i tuoi permessi.",
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.warning)
                    }
                }
                EntriesSection(title: "Variabili d'ambiente", namePrompt: "NOME", entries: $input.env)
            } else {
                Section("Server") {
                    TextField("URL", text: $input.url, prompt: Text("https://example.com/mcp"))
                        .font(.system(size: 12, design: .monospaced))
                    Picker("Autenticazione", selection: $input.auth) {
                        Text("Nessuna o header").tag("none")
                        Text("OAuth").tag("oauth")
                    }
                    .pickerStyle(.segmented)
                }
                if input.auth == "oauth" {
                    OAuthSection(connector: connector, input: $input) { await saveForLogin() }
                }
                EntriesSection(title: "Header", namePrompt: input.auth == "oauth" ? "X-Api-Version" : "Authorization", entries: $input.headers)
            }

            if let connector { ToolsSection(connector: connector, input: $input) }

            Section("Avanzate") {
                Stepper("Tempo massimo per chiamata: \(Int(input.toolTimeoutSeconds)) s", value: $input.toolTimeoutSeconds, in: 5...900, step: 5)
            }

            Section {
                HStack {
                    Button(existing ? "Salva" : "Salva e prova") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || input.id.isEmpty)
                    if let connector {
                        Button("Prova connessione") {
                            busy = true
                            Task {
                                await model.test(connector: connector)
                                busy = false
                            }
                        }
                        .disabled(busy)
                        // a connector of this Mac's engine can go to a server, with its secrets (R14)
                        if !model.isRemote, !model.remoteEngines.isEmpty, !connector.usesOAuth {
                            Menu("Copia su server") {
                                ForEach(model.remoteEngines) { engine in
                                    Button(engine.name) { Task { await copy(connector, to: engine) } }
                                }
                            }
                            .fixedSize()
                            .disabled(busy)
                        }
                        Spacer()
                        Button("Elimina", role: .destructive) { confirmDelete = true }
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
                if let copied {
                    Text(copied).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Eliminare \(input.name)?", isPresented: $confirmDelete) {
            Button("Elimina", role: .destructive) {
                if let connector { Task { await model.delete(connector: connector) } }
            }
        } message: {
            Text("Anche i suoi segreti vengono cancellati.")
        }
    }

    private var parsedArgs: [String] {
        argsText.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func copy(_ connector: MCPConnector, to engine: RemoteEngine) async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let remote = try await model.copyConnector(connector, to: engine)
            let check = remote.lastCheck
            copied = check?.ok == true
                ? "Copiato su \(engine.name): \(check?.tools?.count ?? 0) strumenti, provato sul server"
                : "Copiato su \(engine.name), ma la prova sul server non è riuscita: \(check?.error ?? "errore sconosciuto")"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        busy = true
        error = nil
        var body = input
        body.args = parsedArgs
        switch await model.save(connector: body, existing: existing) {
        case let .success(saved):
            // an OAuth connector has nothing to test before the login
            if !existing {
                onCreated(saved)
                if !saved.usesOAuth { await model.test(connector: saved) }
            }
        case let .failure(failure):
            error = failure.localizedDescription
        }
        busy = false
    }

    /// The login uses what is saved: save the edits first.
    private func saveForLogin() async -> MCPConnector? {
        error = nil
        var body = input
        body.args = parsedArgs
        switch await model.save(connector: body, existing: existing) {
        case let .success(saved):
            if !existing { onCreated(saved) }
            return saved
        case let .failure(failure):
            error = failure.localizedDescription
            return nil
        }
    }

    static func slug(_ name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { out.unicodeScalars.append(scalar) } else if !out.hasSuffix("_"), !out.isEmpty { out += "_" }
        }
        while let first = out.first, !first.isLetter { out.removeFirst() }
        return String(out.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

/// Name/value rows; a lock turns a value into a secret, typed once.
private struct EntriesSection: View {
    let title: String
    let namePrompt: String
    @Binding var entries: [MCPConnectorInput.Entry]

    var body: some View {
        Section(title) {
            ForEach($entries) { $entry in
                HStack(spacing: 6) {
                    TextField("Nome", text: $entry.name, prompt: Text(namePrompt))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 200)
                    if entry.secret {
                        SecureField("Valore", text: $entry.value,
                                    prompt: Text(entry.keepStored ? "salvato — vuoto per non cambiarlo" : "valore segreto"))
                    } else {
                        TextField("Valore", text: $entry.value)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Button {
                        entry.secret.toggle()
                        entry.keepStored = false
                    } label: {
                        Image(systemName: entry.secret ? "lock.fill" : "lock.open")
                    }
                    .buttonStyle(.borderless)
                    .help(entry.secret ? "Segreto: non verrà più mostrato" : "Rendi segreto")
                    Button { entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .labelsHidden()
            }
            Button("Aggiungi") { entries.append(.init(name: "", value: "", secret: false)) }
                .buttonStyle(.borderless)
        }
    }
}

/// The server's tools from the last check, each one on or off for every bot.
private struct ToolsSection: View {
    let connector: MCPConnector
    @Binding var input: MCPConnectorInput

    private var tools: [MCPConnectorCheck.Tool] { connector.lastCheck?.tools ?? [] }

    private func isOn(_ name: String) -> Bool {
        switch input.toolMode {
        case "allow": return input.toolNames.contains(name)
        case "deny": return !input.toolNames.contains(name)
        default: return true
        }
    }

    /// Stored as "everything but": a tool the server adds later starts on.
    private func set(_ name: String, _ on: Bool) {
        var off = Set(tools.map(\.name).filter { !isOn($0) })
        if on { off.remove(name) } else { off.insert(name) }
        input.toolMode = off.isEmpty ? "all" : "deny"
        input.toolNames = off.sorted()
    }

    private var tokens: Int {
        tools.filter { isOn($0.name) }.reduce(0) { $0 + ($1.chars ?? 0) } / 4
    }

    var body: some View {
        Section {
            if let check = connector.lastCheck {
                if check.ok {
                    Label("\(check.server?.name ?? "Server") \(check.server?.version ?? "") · \(tools.count) strumenti · circa \(tokens) token nel contesto",
                          systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Theme.success)
                } else {
                    Label(check.error ?? "Connessione non riuscita", systemImage: "xmark.octagon")
                        .font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
            } else {
                Text("Non ancora provato: usa «Prova connessione».").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(tools) { tool in
                Toggle(isOn: Binding(get: { isOn(tool.name) }, set: { set(tool.name, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(tool.name).font(.system(size: 12, design: .monospaced))
                            if tool.readOnly == true {
                                Text("sola lettura").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if let description = tool.description, !description.isEmpty {
                            Text(description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        } header: {
            Text("Strumenti")
        } footer: {
            if !tools.isEmpty {
                Text("Gli strumenti spenti non arrivano a nessun bot. Ricordati di salvare.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// OAuth: the login happens in the browser and comes back to the engine,
/// which keeps the tokens; Settings only shows whether it holds one.
private struct OAuthSection: View {
    let connector: MCPConnector?
    @Binding var input: MCPConnectorInput
    let saveFirst: () async -> MCPConnector?
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var busy = false
    @State private var note: String?
    @State private var redirect: String?
    @State private var manual = false

    private var status: String { connector?.oauthState?.status ?? "disconnected" }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Circle().fill(status == "connected" ? Theme.success : status == "expired" ? Theme.warning : Theme.tertiary)
                    .frame(width: 8, height: 8)
                Text(status == "connected" ? "Connesso" : status == "expired" ? "Accesso scaduto" : "Non connesso")
                    .font(.system(size: 12.5))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if status == "connected", let connector {
                    Button("Esci") { Task { await model.oauthLogout(connector) } }
                }
                Button(status == "connected" ? "Accedi di nuovo…" : "Accedi…") { Task { await login() } }
                    .disabled(busy || input.url.isEmpty || input.id.isEmpty)
            }
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Client registrato a mano", isExpanded: $manual) {
                TextField("Client ID", text: $input.oauthClientId, prompt: Text("vuoto = registrazione automatica"))
                    .font(.system(size: 12, design: .monospaced))
                SecureField("Client secret", text: $input.oauthClientSecret,
                            prompt: Text(input.oauthClientSecretStored ? "salvato — vuoto per non cambiarlo" : "facoltativo"))
                TextField("Scope", text: $input.oauthScope, prompt: Text("vuoto = quelli che chiede il server"))
                    .font(.system(size: 12, design: .monospaced))
                if let redirect {
                    LabeledContent("Redirect URI") { Text(redirect).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled) }
                }
            }
        } header: {
            Text("OAuth")
        } footer: {
            Text("SwarmeBot tiene i token: i bot non li vedono e, se cambi harness, non devi accedere di nuovo.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .onAppear { manual = !input.oauthClientId.isEmpty }
    }

    private func login() async {
        busy = true
        defer { busy = false }
        guard let saved = await saveFirst() else { return }
        switch await model.oauthLogin(saved) {
        case let .success(started):
            redirect = started.redirect
            note = "Completa l'accesso nel browser: lo stato qui si aggiorna da solo."
            openURL(started.url)
        case let .failure(error):
            note = error.localizedDescription
        }
    }
}

// MARK: - Import

private struct ConnectorImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var outcome: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importa connettori").font(.headline)
            Text("Incolla la configurazione di Claude Desktop (claude_desktop_config.json) o un file .mcp.json. I valori il cui nome contiene KEY, TOKEN, SECRET, PASSWORD o AUTH diventano segreti.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline))
            if let outcome {
                Text(outcome).font(.system(size: 12)).foregroundStyle(failed ? Theme.danger : Theme.success).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }
                Button("Importa") {
                    busy = true
                    Task {
                        switch await model.importConnectors(text) {
                        case let .success(result):
                            failed = result.created.isEmpty
                            var lines = ["Importati: \(result.created.isEmpty ? "nessuno" : result.created.map(\.name).joined(separator: ", "))"]
                            for skip in result.skipped { lines.append("Saltato \(skip.name ?? "?"): \(skip.reason ?? "")") }
                            outcome = lines.joined(separator: "\n")
                        case let .failure(error):
                            failed = true
                            outcome = error.localizedDescription
                        }
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
