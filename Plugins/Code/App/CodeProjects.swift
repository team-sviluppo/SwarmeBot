// Projects, as the app shows them: the list in Impostazioni › Plugin, the editor, the picker that says
// which project a bot or a channel belongs to and which folder it works on, and the browser of a
// server's folders (the open panel only shows this Mac's).
import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

// MARK: - Which project a bot or a channel belongs to

/// Rows of a bot's or a channel's Code card: its project, and the folder of it that it works on.
struct CodeProjectRows: View {
    enum Owner {
        case bot(Bot)
        case room(Room)

        var plugins: [String: JSONValue]? {
            switch self {
            case let .bot(bot): return bot.plugins
            case let .room(room): return room.plugins
            }
        }
    }

    let owner: Owner
    let state: CodeState
    @Environment(AppModel.self) private var model

    private var current: (project: Project?, role: String?) { state.assignment(owner.plugins) }

    var body: some View {
        let (project, role) = current
        SettingRow(icon: "folder.badge.gearshape", tint: Theme.accent, title: tr("Progetto"),
                   subtitle: state.projects.isEmpty ? tr("Nessun progetto: si creano in Impostazioni › Plugin") : nil) {
            Picker("", selection: Binding(get: { project?.id ?? "" }, set: { set(project: $0.isEmpty ? nil : $0) })) {
                Text(tr("Nessuno")).tag("")
                ForEach(state.projects) { Text(verbatim: $0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 170)
        }
        if let project, !project.repos.isEmpty {
            CardDivider(leading: 48)
            SettingRow(icon: "hammer", tint: Theme.accent, title: tr("Lavora su"),
                       subtitle: tr("Le altre cartelle del progetto le legge soltanto.")) {
                Picker("", selection: Binding(get: { role ?? "" }, set: { set(project: project.id, role: $0.isEmpty ? nil : $0) })) {
                    Text(tr("Nessuna")).tag("")
                    ForEach(project.repos, id: \.role) { Text(verbatim: $0.displayLabel).tag($0.role) }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }
            if let role, let repo = project.repo(role) {
                Text(verbatim: repo.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary)
                    .lineLimit(1).truncationMode(.head).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    /// A new project clears the folder it works on, unless the same one is sent along.
    private func set(project: String?, role: String? = nil) {
        let data: [String: JSONValue] = ["projectId": project.map(JSONValue.string) ?? .null, "role": role.map(JSONValue.string) ?? .null]
        Task {
            switch owner {
            case let .bot(bot):
                var patch = BotPatch()
                patch.pluginData = ["code": data]
                await model.patch(bot, patch)
            case let .room(room):
                var patch = RoomPatch()
                patch.pluginData = ["code": data]
                await model.patch(room, patch)
            }
        }
    }
}

// MARK: - The list, in Settings

struct CodeProjectsSettings: View {
    let state: CodeState
    @Environment(AppModel.self) private var model
    @State private var editing: Project?
    @State private var creating = false

    var body: some View {
        Section {
            if !state.engineHasProjects(model) {
                Text(tr("Questo motore non ha ancora i progetti: aggiornalo.")).foregroundStyle(Theme.secondary)
            } else {
                if state.projects.isEmpty {
                    Text(tr("Nessun progetto.")).foregroundStyle(Theme.secondary)
                }
                ForEach(state.projects) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: project.name).font(.system(size: 13, weight: .medium))
                            Text(verbatim: project.repos.map(\.displayLabel).joined(separator: " · "))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                        }
                        Spacer()
                        Button(tr("Modifica…")) { editing = project }.disabled(!state.engineHasFlexibleProjects(model))
                    }
                }
                Button(tr("Nuovo progetto…")) { creating = true }.disabled(!state.engineHasFlexibleProjects(model))
                if !state.engineHasFlexibleProjects(model) {
                    Text(tr("Aggiorna il motore per gestire repository con etichette personalizzate.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(tr("Progetti"))
        } footer: {
            Text(tr("Un progetto riunisce le cartelle di un lavoro. Il bot o il canale sceglie su quale lavora; le altre le legge soltanto."))
        }
        .task { await state.refreshProjects(model: model) }
        .sheet(item: $editing) { project in ProjectEditor(state: state, project: project) }
        .sheet(isPresented: $creating) { ProjectEditor(state: state, project: nil) }
    }
}

// MARK: - The editor

struct ProjectEditor: View {
    let state: CodeState
    let project: Project?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var repos: [ProjectRepo] = []
    @State private var browsing: String?
    @State private var saving = false
    @State private var loading = true
    @State private var error: String?
    @State private var confirmDelete = false

    private var duplicateLabels: Bool {
        let labels = repos.map { ($0.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        return Set(labels).count != labels.count
    }
    private var canSave: Bool {
        !saving && !loading && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !duplicateLabels
            && repos.allSatisfy { !($0.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project == nil ? tr("Nuovo progetto") : tr("Progetto")).font(.headline)
            Form {
                TextField(tr("Nome"), text: $name)
                Section(tr("Repository")) {
                    ForEach($repos) { $repo in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField(tr("Etichetta"), text: Binding(get: { repo.label ?? "" }, set: { repo.label = $0 }))
                                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 160)
                                TextField(tr("Cartella"), text: $repo.path, prompt: Text(verbatim: "/"))
                                    .labelsHidden().textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                                    .help(Text(verbatim: repo.path))
                                Button(tr("Scegli…")) { choose(repo.id) }
                                Button { repos.removeAll { $0.id == repo.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).help(tr("Rimuovi repository"))
                            }
                            DisclosureGroup(tr("Script")) {
                                ForEach(Array((repo.scripts ?? []).indices), id: \.self) { index in
                                    HStack {
                                        TextField(tr("Nome"), text: scriptBinding(repo.id, index, \.name)).labelsHidden().frame(width: 90)
                                        TextField(tr("Comando"), text: scriptBinding(repo.id, index, \.command))
                                            .labelsHidden().font(.system(size: 11.5, design: .monospaced))
                                        Button { edit(repo.id) { $0.scripts?.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                                            .buttonStyle(.plain)
                                    }
                                }
                                Button(tr("Aggiungi script")) { edit(repo.id) { $0.scripts = ($0.scripts ?? []) + [ProjectScript(name: "", command: "")] } }
                                    .disabled((repo.scripts?.count ?? 0) >= 20)
                            }
                        }
                    }
                    Button(tr("Aggiungi repository")) {
                        repos.append(ProjectRepo(role: UUID().uuidString.lowercased(), path: "", scripts: [], label: ""))
                    }.disabled(loading)
                }
            }
            .formStyle(.grouped)
            if loading { ProgressView().controlSize(.small) }
            if duplicateLabels { Text(tr("Le etichette dei repository devono essere diverse.")).font(.caption).foregroundStyle(Theme.warning) }
            if model.isRemote {
                Text(tr("Le cartelle sono quelle del server: i percorsi non sono quelli di questo Mac."))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
            if let error { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
            HStack {
                if project != nil { Button(tr("Elimina"), role: .destructive) { confirmDelete = true } }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(tr("Annulla")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Salva")) { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20).frame(width: 720, height: 600)
        .task { await load() }
        .sheet(item: Binding(get: { browsing.map(Picking.init) }, set: { browsing = $0?.role })) { picking in
            ServerFolderPicker(state: state, start: repos.first { $0.id == picking.role }?.path) { chosen in
                edit(picking.role) { $0.path = chosen }
                browsing = nil
            }
        }
        .confirmationDialog(tr("Eliminare il progetto?"), isPresented: $confirmDelete) {
            Button(tr("Elimina"), role: .destructive) { Task { await delete() } }
        } message: { Text(tr("I bot e i canali che ne fanno parte restano senza progetto. Le cartelle non vengono toccate.")) }
    }

    private struct Picking: Identifiable { let role: String; var id: String { role } }

    private func edit(_ id: String, _ change: (inout ProjectRepo) -> Void) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        change(&repos[index])
    }

    private func load() async {
        guard loading else { return }
        name = project?.name ?? ""
        if let project {
            repos = project.repos.map { var repo = $0; repo.label = repo.displayLabel; return repo }
        } else {
            let bot = model.selectedBot
            let current = model.selectedRoom.flatMap { $0.pinnedCwd ?? $0.cwd }
                ?? bot?.tasks?.first(where: { $0.threadId == bot?.threadId })?.cwd ?? bot?.cwd
            do {
                let folder = try await state.folders(model: model, path: current, hidden: false)
                repos = [ProjectRepo(role: "default", path: folder.path, scripts: [], label: "Default")]
            } catch {
                self.error = error.localizedDescription
                repos = [ProjectRepo(role: "default", path: "", scripts: [], label: "Default")]
            }
        }
        loading = false
    }

    private func scriptBinding(_ role: String, _ index: Int, _ key: WritableKeyPath<ProjectScript, String>) -> Binding<String> {
        Binding(get: {
            guard let scripts = repos.first(where: { $0.id == role })?.scripts, scripts.indices.contains(index) else { return "" }
            return scripts[index][keyPath: key]
        }, set: { value in edit(role) { if $0.scripts?.indices.contains(index) == true { $0.scripts?[index][keyPath: key] = value } } })
    }

    private func choose(_ role: String) {
        if model.isRemote { browsing = role; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = false
        panel.prompt = tr("Scegli")
        panel.message = repos.first { $0.id == role }?.label ?? ""
        if let path = repos.first(where: { $0.id == role })?.path, !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit(role) { $0.path = url.path }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        do {
            try await state.saveProject(model: model, id: project?.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), repos: repos)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        guard let project else { return }
        do { try await state.deleteProject(model: model, project.id); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - A server's folders

struct ServerFolderPicker: View {
    let state: CodeState
    let start: String?
    let choose: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var listing: FolderListing?
    @State private var error: String?
    @State private var hidden = false
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Cartella sul server")).font(.headline)
            HStack {
                Button { Task { await load(listing?.parent) } } label: { Image(systemName: "chevron.up") }
                    .disabled(listing?.parent == nil).help(tr("Cartella superiore"))
                Button { Task { await load(listing?.home) } } label: { Image(systemName: "house") }.help(tr("Cartella home"))
                Text(verbatim: listing?.path ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            List {
                ForEach(listing?.dirs ?? [], id: \.self) { name in
                    Button { Task { await load(((listing?.path ?? "") as NSString).appendingPathComponent(name)) } } label: {
                        Label(name, systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
                if listing?.dirs.isEmpty == true { Text(tr("Nessuna sottocartella")).foregroundStyle(Theme.tertiary) }
            }
            .frame(height: 260)
            if let error { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
            Toggle(tr("Mostra le cartelle nascoste"), isOn: $hidden).onChange(of: hidden) { Task { await load(listing?.path) } }
            HStack {
                Spacer()
                Button(tr("Annulla")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Scegli questa cartella")) { if let path = listing?.path { choose(path) } }
                    .keyboardShortcut(.defaultAction).disabled(listing == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load(start?.isEmpty == false ? start : nil) }
    }

    private func load(_ path: String?) async {
        loading = true
        defer { loading = false }
        do {
            listing = try await state.folders(model: model, path: path, hidden: hidden)
            error = nil
        } catch {
            self.error = error.localizedDescription
            // a path that is not there: start again from home
            if listing == nil, path != nil { await load(nil) }
        }
    }
}
