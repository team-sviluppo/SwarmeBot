import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI

/// Settings › Skill: instruction folders added once, then handed to bots
/// (docs/plans/2026-10-21-skill.md). They live in a folder on the engine —
/// a shared one, if the user wants several Macs to see the same skills.
struct SkillsPane: View {
    @Environment(AppModel.self) private var model
    /// Debug aid for screenshots: `SWARMEBOT_SKILL_SELECT=source:<id>` or a skill name opens on it.
    @State private var selected: String? = ProcessInfo.processInfo.environment["SWARMEBOT_SKILL_SELECT"]
    @State private var newName = ""
    @State private var pendingImport: PendingImport?
    @State private var replaceImport: URL?
    @State private var error: String?
    @State private var copyingToServer = false
    private static let newId = "__new__"
    private static let newSourceId = "__newsource__"
    private static let sourcePrefix = "source:"

    /// A pick waiting for the user to accept that it ships scripts.
    struct PendingImport: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                SkillsFolderRow()
                Divider()
                List(selection: $selected) {
                    if !model.skillSources.isEmpty || selected == Self.newSourceId {
                        Section(tr("Sorgenti GitHub")) {
                            ForEach(model.skillSources) { source in
                                SkillSourceRow(source: source).tag(Self.sourcePrefix + source.id)
                            }
                            if selected == Self.newSourceId {
                                Label(tr("Nuova sorgente"), systemImage: "plus.circle").tag(Self.newSourceId)
                            }
                        }
                        Section(tr("Skill")) { skillRows }
                    } else {
                        skillRows
                    }
                }
                Divider()
                HStack {
                    Menu {
                        Button(tr("Scrivi una nuova skill")) { selected = Self.newId }
                        Button(tr("Aggiungi una sorgente GitHub…")) { selected = Self.newSourceId }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help(tr("Una nuova skill, o una cartella di skill da GitHub"))
                    Button(tr("Importa…"), action: pickImport)
                        .help(tr("Una cartella con SKILL.md, oppure un .zip o .skill che la contiene"))
                    Spacer()
                    // this Mac's connectors and skills, many at once, to a server
                    if !model.isRemote, !model.remoteEngines.isEmpty {
                        Button(tr("Copia su server…")) { copyingToServer = true }
                    }
                }
                .buttonStyle(.borderless)
                .padding(8)
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .padding([.horizontal, .bottom], 8)
                }
            }
            .frame(minWidth: 240, maxWidth: 300)
            Group {
                if selected == Self.newId {
                    NewSkillEditor { saved in selected = saved.id }
                        .id(Self.newId)
                } else if selected == Self.newSourceId {
                    SkillSourceEditor(source: nil) { saved in selected = Self.sourcePrefix + saved.id }
                        .id(Self.newSourceId)
                } else if let id = selected, id.hasPrefix(Self.sourcePrefix),
                          let source = model.skillSources.first(where: { $0.id == String(id.dropFirst(Self.sourcePrefix.count)) }) {
                    SkillSourceEditor(source: source) { _ in }.id(source.id)
                } else if let id = selected, let skill = model.skills.first(where: { $0.id == id }) {
                    SkillEditor(skill: skill).id(skill.id)
                } else {
                    VStack(spacing: 8) {
                        Text(tr("Le skill sono istruzioni, con script e riferimenti, che puoi dare ai bot.")).foregroundStyle(.secondary)
                        Text(tr("Valgono con tutti i motori. Scrivine una con + oppure importa una cartella con SKILL.md."))
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await model.refreshSkills() }
        .sheet(isPresented: $copyingToServer) { ServerCopySheet() }
        .confirmationDialog(tr("Questa skill contiene script"), isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                            presenting: pendingImport) { pending in
            Button(tr("Importa")) { Task { await upload(pending.url, replace: false) } }
        } message: { _ in
            Text(tr("I bot a cui la darai potranno eseguirli, con i permessi del motore. Importala solo se ti fidi di chi l'ha scritta."))
        }
        .confirmationDialog(tr("Esiste già una skill con questo nome"), isPresented: Binding(get: { replaceImport != nil }, set: { if !$0 { replaceImport = nil } }),
                            presenting: replaceImport) { url in
            Button(tr("Sostituisci"), role: .destructive) { Task { await upload(url, replace: true) } }
        } message: { _ in
            Text(tr("La cartella esistente verrà sostituita per intero."))
        }
    }

    @ViewBuilder
    private var skillRows: some View {
        ForEach(model.skills) { skill in
            SkillRow(skill: skill).tag(skill.id)
        }
        if selected == Self.newId {
            Label(tr("Nuova skill"), systemImage: "plus.circle").tag(Self.newId)
        }
    }

    private func pickImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder, .init(filenameExtension: "skill") ?? .zip]
        panel.allowsMultipleSelection = false
        panel.message = tr("Scegli una cartella con SKILL.md, o un archivio .zip o .skill")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        do {
            // read once here for the warning; the upload reads it again
            if SkillFolder.hasScripts(try SkillFolder.read(url)) {
                pendingImport = PendingImport(url: url)
            } else {
                Task { await upload(url, replace: false) }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func upload(_ url: URL, replace: Bool) async {
        switch await model.importSkill(from: url, replace: replace) {
        case let .success(skill):
            selected = skill.id
        case let .failure(failure):
            if case let APIError.status(code, _) = failure, code == 409 {
                replaceImport = url
            } else {
                error = failure.localizedDescription
            }
        }
    }
}

/// Where the engine keeps the skills, and the way to move them.
private struct SkillsFolderRow: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var typed = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("Cartella delle skill")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(verbatim: model.skillsFolder.map { ($0.folder as NSString).abbreviatingWithTildeInPath } ?? "…")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.skillsFolder?.folder ?? "")
            }
            Spacer(minLength: 4)
            Menu {
                Button(model.isRemote ? tr("Cambia percorso sul server…") : tr("Scegli cartella…"), action: change)
                if !model.isRemote, let folder = model.skillsFolder?.folder {
                    Button(tr("Mostra nel Finder")) { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                }
                if model.skillsFolder?.custom == true {
                    Divider()
                    Button(tr("Usa la cartella predefinita")) { Task { await model.setSkillsFolder(nil) } }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(tr("Una cartella condivisa (OneDrive, Dropbox, disco di rete) fa vedere le stesse skill da più Mac."))
        }
        .padding(8)
        .popover(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Percorso della cartella sul server")).font(.system(size: 12, weight: .semibold))
                TextField("", text: $typed).font(.system(size: 12, design: .monospaced)).frame(width: 320)
                HStack {
                    Spacer()
                    Button(tr("Annulla")) { editing = false }
                    Button(tr("Salva")) {
                        editing = false
                        Task { await model.setSkillsFolder(typed.trimmingCharacters(in: .whitespaces)) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func change() {
        if model.isRemote {
            typed = model.skillsFolder?.folder ?? ""
            editing = true
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Usa questa cartella")
        panel.message = tr("Le skill già presenti nella cartella diventano subito disponibili. Quelle nella cartella attuale restano dove sono.")
        if let folder = model.skillsFolder?.folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setSkillsFolder(url.path) }
    }
}

private struct SkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(verbatim: skill.name).font(.system(size: 13, weight: .medium))
                if skill.hasScripts {
                    Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Theme.warning)
                        .help(tr("Contiene script"))
                }
                if let origin = skill.source {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(.secondary)
                        .help(tr("Da GitHub · %@ · %@", origin.name, origin.sha))
                }
            }
            Text(skill.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

// MARK: - Editors

/// A new skill: a name, then its `SKILL.md` from a template.
private struct NewSkillEditor: View {
    @Environment(AppModel.self) private var model
    let onCreated: (Skill) -> Void
    @State private var name = ""
    @State private var content = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField(tr("Nome"), text: $name, prompt: Text(verbatim: "report-campagne"))
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: name) { old, new in
                        let slug = Self.slug(new)
                        if slug != new { name = slug }
                        // keep the template's name in step until the text is edited by hand
                        if content.isEmpty || content == SkillFolder.template(name: old) { content = SkillFolder.template(name: slug) }
                    }
            } header: {
                Text(tr("Nuova skill"))
            } footer: {
                Text(tr("Minuscole, cifre e trattini. In chat si richiama con /%@.", name.isEmpty ? tr("nome") : name))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                SkillTextEditor(text: $content)
            } header: {
                Text(verbatim: "SKILL.md")
            }
            Section {
                HStack {
                    Button(tr("Crea")) { Task { await create() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || name.isEmpty)
                    if busy { ProgressView().controlSize(.small) }
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onAppear { if content.isEmpty { content = SkillFolder.template(name: "") } }
    }

    private func create() async {
        busy = true
        error = nil
        switch await model.createSkill(content: content) {
        case let .success(skill): onCreated(skill)
        case let .failure(failure): error = failure.localizedDescription
        }
        busy = false
    }

    static func slug(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) { out.unicodeScalars.append(scalar) } else if !out.isEmpty, !out.hasSuffix("-") { out += "-" }
        }
        return String(out.prefix(64))
    }
}

/// An existing skill: its files, its `SKILL.md` to edit, and what to do with it.
private struct SkillEditor: View {
    @Environment(AppModel.self) private var model
    let skill: Skill
    @State private var content = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var note: String?
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var replaceOn: RemoteEngine?

    var body: some View {
        Form {
            Section {
                LabeledContent(tr("Richiamo in chat")) { Text(verbatim: "/\(skill.id)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                LabeledContent(tr("Peso nel prompt")) { Text(tr("~%@ token quando viene usata", String(skill.tokens))) }
                if skill.hasScripts {
                    Label(tr("Contiene script: i bot che la usano possono eseguirli."), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(Theme.warning)
                }
                if let origin = skill.source {
                    LabeledContent(tr("Da GitHub")) { Text(verbatim: "\(origin.name) · \(origin.sha)").font(.system(size: 12, design: .monospaced)) }
                    Text(tr("Questa skill la tiene aggiornata una sorgente GitHub: per cambiarla modifica il repository. Per una versione tua, copia il testo in una skill nuova con un altro nome."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } header: {
                Text(verbatim: skill.name)
            }
            Section(tr("File (%@)", String(skill.files.count))) {
                ForEach(skill.files, id: \.self) { file in
                    Text(verbatim: file).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Section {
                if loaded {
                    SkillTextEditor(text: $content).disabled(skill.source != nil)
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text(verbatim: "SKILL.md")
            }
            Section {
                HStack {
                    if skill.source == nil {
                        Button(tr("Salva")) { Task { await save() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy || !loaded || content == saved)
                    }
                    // a skill a GitHub source keeps goes with its source: alone it would clash with it on the server
                    if !model.isRemote, !model.remoteEngines.isEmpty, skill.source == nil {
                        Menu(tr("Copia su server")) {
                            ForEach(model.remoteEngines) { engine in
                                Button(engine.name) { Task { await copy(to: engine, replace: false) } }
                            }
                        }
                        .fixedSize()
                        .disabled(busy)
                    }
                    Spacer()
                    if skill.source == nil { Button(tr("Elimina"), role: .destructive) { confirmDelete = true } }
                    if busy { ProgressView().controlSize(.small) }
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .task {
            let text = await model.skillContent(skill) ?? ""
            content = text
            saved = text
            loaded = true
        }
        .confirmationDialog(tr("Eliminare %@?", skill.name), isPresented: $confirmDelete) {
            Button(tr("Elimina"), role: .destructive) { Task { await model.delete(skill: skill) } }
        } message: {
            Text(tr("Si cancella la cartella con tutti i suoi file, e la skill sparisce dai bot che la usano."))
        }
        .confirmationDialog(tr("Sul server c'è già una skill %@", skill.name), isPresented: Binding(get: { replaceOn != nil }, set: { if !$0 { replaceOn = nil } }),
                            presenting: replaceOn) { engine in
            Button(tr("Sostituisci"), role: .destructive) { Task { await copy(to: engine, replace: true) } }
        } message: { _ in
            Text(tr("La versione sul server verrà sostituita per intero da questa."))
        }
    }

    private func save() async {
        busy = true
        error = nil
        note = nil
        switch await model.updateSkill(skill, content: content) {
        case .success: saved = content
        case let .failure(failure): error = failure.localizedDescription
        }
        busy = false
    }

    private func copy(to engine: RemoteEngine, replace: Bool) async {
        busy = true
        defer { busy = false }
        error = nil
        note = nil
        do {
            _ = try await model.copySkill(skill, to: engine, replace: replace)
            note = tr("Copiata su %@.", engine.name)
        } catch let APIError.status(code, _) where code == 409 {
            replaceOn = engine
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// `SKILL.md` in a monospaced box that grows with it.
private struct SkillTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 260)
    }
}
