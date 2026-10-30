import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

struct CodeChatRow: Decodable, Identifiable {
    var threadId: String
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var pinned: Bool
    var archived: Bool
    var unread: Bool
    var status: String
    var git: ThreadGitState?
    var id: String { threadId }
    var icon: String {
        switch status {
        case "working": return "circle.inset.filled"
        case "waiting": return "exclamationmark.circle"
        case "unread": return "circle.fill"
        case "error": return "xmark.circle"
        default: return "checkmark.circle"
        }
    }
}

struct CodeChatColumn: View {
    let bot: Bot
    let state: CodeState
    @AppStorage private var collapsed: Bool
    @Environment(AppModel.self) private var model
    @State private var rows: [CodeChatRow] = []
    @State private var query = ""
    @State private var filter = "all"
    @State private var branch = ""
    @State private var archivedOpen = false
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var error: String?
    @State private var renaming: CodeChatRow?
    @State private var title = ""
    @State private var deleting: CodeChatRow?

    init(bot: Bot, state: CodeState, preferenceKey: String) {
        self.bot = bot; self.state = state
        _collapsed = AppStorage(wrappedValue: false, "code.chat-column." + preferenceKey, store: AppPaths.defaults)
    }

    private var filtered: [CodeChatRow] {
        rows.filter {
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.git?.branch?.localizedCaseInsensitiveContains(query) == true))
            && (filter == "all" || (filter == "working" ? ["working", "waiting"].contains($0.status) : $0.unread))
            && (branch.isEmpty || $0.git?.branch == branch)
        }.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
    }

    static func dateGroup(_ milliseconds: Double, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        if calendar.isDate(date, inSameDayAs: now) { return 0 }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return 1 }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return 2 }
        return 3
    }

    var body: some View {
        if !collapsed { expanded }
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(tr("Chat")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { Task { await model.createTask(title: nil) } } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).disabled(model.isBusy(bot)).help(tr("Nuova chat"))
            }.padding(12).frame(height: 50)
            CodeContextMeter(chat: CodeChat(bot: bot))
                .padding(.horizontal, 10).padding(.bottom, 8)
            TextField(tr("Cerca chat"), text: $query)
                .textFieldStyle(.roundedBorder).font(.system(size: 11.5)).padding(.horizontal, 10)
                .help(tr("Titolo o branch; premi Invio per cercare nei messaggi"))
                .onSubmit { Task { await search() } }
                .onChange(of: query) { _, _ in hits = [] }
            HStack(spacing: 5) {
                filterButton(tr("Tutte"), value: "all")
                filterButton(tr("Al lavoro"), value: "working")
                filterButton(tr("Da leggere"), value: "unread")
            }.padding(.vertical, 8)
            Picker(tr("Branch"), selection: $branch) {
                Text(tr("Tutti i branch")).tag("")
                ForEach(Array(Set(rows.compactMap { $0.git?.branch })).sorted(), id: \.self) { Text(verbatim: $0).tag($0) }
            }.font(.system(size: 11)).padding(.horizontal, 10).padding(.bottom, 6)
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(Theme.danger).padding(8) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if searching { ProgressView().controlSize(.small) }
                    if !hits.isEmpty {
                        ForEach(hits) { hit in
                            Button { Task { await model.open(hit) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.task ?? tr("Chat")).font(.system(size: 12, weight: .medium))
                                    Text(hit.snippet).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(3)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.buttonStyle(.plain)
                        }
                    } else {
                        ForEach(0..<4) { group in
                            let chats = filtered.filter { !$0.archived && Self.dateGroup($0.updatedAt) == group }
                            if !chats.isEmpty {
                                Text([tr("Oggi"), tr("Ieri"), tr("Questa settimana"), tr("Più vecchie")][group])
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary).padding(.top, 10).padding(.leading, 8)
                                ForEach(chats) { row($0) }
                            }
                        }
                        if filtered.contains(where: \.archived) {
                            DisclosureGroup(tr("Archiviate"), isExpanded: $archivedOpen) {
                                ForEach(filtered.filter(\.archived)) { row($0) }
                            }.font(.system(size: 11)).padding(6)
                        }
                    }
                }.padding(6)
            }
        }
        .frame(width: 240).background(Theme.card)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline.opacity(0.4)).frame(width: 1) }
        .task(id: bot.id) {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: bot.threadId) { await refresh() }
        .alert(tr("Rinomina task"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(tr("Titolo"), text: $title)
            Button(tr("Salva")) {
                if let renaming { Task { await mutate { try await $0.renameTask(botId: bot.id, threadId: renaming.threadId, title: title) } } }
            }
            Button(tr("Annulla"), role: .cancel) {}
        }
        .confirmationDialog(tr("Eliminare la chat?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("Elimina"), role: .destructive) {
                if let deleting { Task { await mutate { _ = try await $0.deleteTask(botId: bot.id, threadId: deleting.threadId) } } }
            }
        }
    }

    private func filterButton(_ title: String, value: String) -> some View {
        Button(title) { filter = value }.buttonStyle(.plain).font(.system(size: 10.5))
            .padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(filter == value ? Theme.raised : .clear))
    }

    private func row(_ item: CodeChatRow) -> some View {
        Button { Task { await model.openTask(botId: bot.id, threadId: item.threadId) } } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.icon).font(.system(size: 10))
                    .foregroundStyle(item.status == "error" ? Theme.danger : item.unread || item.status == "working" ? Theme.accent : Theme.secondary)
                    .frame(width: 14).padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(item.title).font(.system(size: 12.5, weight: item.unread ? .semibold : .regular)).lineLimit(1)
                        if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                    }
                    Text(Date(timeIntervalSince1970: item.updatedAt / 1000).appRelative()).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    if let git = item.git, git.repo {
                        Text(verbatim: git.branch ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        if !git.changes.isEmpty {
                            HStack(spacing: 5) {
                                if let added = git.additions, let deleted = git.deletions {
                                    Text(verbatim: "+\(added) −\(deleted)").foregroundStyle(Theme.secondary)
                                }
                                Label(String(git.changes.count), systemImage: "doc.on.doc").foregroundStyle(Theme.tertiary)
                            }.font(.system(size: 10.5, design: .monospaced))
                                .help(git.summaryPartial == true ? tr("Le righe dei file non tracciati non sono incluse nel conteggio") : tr("Stato attuale della cartella condivisa"))
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(bot.threadId == item.threadId ? Theme.raised : .clear))
        }
        .buttonStyle(.plain).help(item.title)
        .contextMenu {
            Button(tr("Rinomina")) { title = item.title; renaming = item }
            Button(item.pinned ? tr("Sblocca") : tr("Fissa")) { Task { await mutate { try await $0.setTaskPinned(botId: bot.id, threadId: item.threadId, pinned: !item.pinned) } } }
            Button(item.archived ? tr("Ripristina") : tr("Archivia")) {
                Task { await mutate { try await $0.pluginRequest("PATCH", "/api/threads/\(item.threadId)/code/chat", body: ["archived": !item.archived]) } }
            }
            Divider()
            Button(tr("Apri terminale")) { openTerminal(item) }
            Menu(tr("Apri in editor")) {
                ForEach(EditorApp.allCases.filter { (!model.isRemote || $0.opensServerFolders) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }) { editor in
                    Button(editor.name) { openEditor(editor, item) }
                }
            }
            Button(tr("Copia percorso")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.git?.folder ?? "", forType: .string)
            }.disabled(item.git?.folder == nil)
            Divider()
            Button(tr("Elimina"), role: .destructive) { deleting = item }.disabled(item.pinned || rows.count <= 1 || item.status == "working" || item.status == "waiting")
        }
    }

    private func refresh() async {
        guard let client = model.client else { return }
        do {
            struct Answer: Decodable { var chats: [CodeChatRow] }
            let result = try await client.pluginRequest("GET", "/api/bots/\(bot.id)/code/chats", as: Answer.self)
            guard !Task.isCancelled else { return }
            rows = result.chats
            error = nil
            if rows.contains(where: { $0.threadId == bot.threadId && $0.unread }) {
                try await client.pluginRequest("PATCH", "/api/threads/\(bot.threadId)/code/chat", body: ["read": true])
                if let index = rows.firstIndex(where: { $0.threadId == bot.threadId }) { rows[index].unread = false; if rows[index].status == "unread" { rows[index].status = "done" } }
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func search() async {
        guard let client = model.client, !query.isEmpty else { return }
        let wanted = query
        searching = true
        defer { searching = false }
        do {
            struct Answer: Decodable { var hits: [SearchHit] }
            let result = try await client.pluginRequest("GET", "/api/bots/\(bot.id)/code/chats/search", query: [URLQueryItem(name: "q", value: wanted)], as: Answer.self)
            if query == wanted { hits = result.hits }
        } catch { self.error = error.localizedDescription }
    }

    private func mutate(_ action: (CompanionClient) async throws -> Void) async {
        guard let client = model.client else { return }
        do { try await action(client); await refresh() } catch { self.error = error.localizedDescription }
    }

    private func openTerminal(_ item: CodeChatRow) {
        guard let folder = item.git?.folder else { return }
        let command = "cd -- " + RemoteScripts.quote(folder) + " && exec \"${SHELL:-/bin/sh}\" -l"
        if model.isRemote {
            guard let engine = model.activeRemoteEngine, let identity = model.identity(for: engine) else {
                error = tr("Configura una connessione SSH per aprire il terminale sul server"); return
            }
            do { try model.openTerminal(identity, command: command) } catch { self.error = error.localizedDescription }
        } else { TerminalLauncher.run(command) }
    }

    private func openEditor(_ editor: EditorApp, _ item: CodeChatRow) {
        guard let folder = item.git?.folder else { return }
        if model.isRemote {
            guard let engine = model.activeRemoteEngine, let identity = model.identity(for: engine), let url = editor.remoteURL(identity: identity, folder: folder) else {
                error = tr("Configura una connessione SSH per aprire la cartella del server in un editor"); return
            }
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleId) {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
