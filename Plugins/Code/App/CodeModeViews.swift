// Code mode, as the plugin shows it: the git branch next to the folder chip, and
// at the end of a turn one "N files modified" badge in place of a card per file.
import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

/// Repository status lives in the composer's existing chip row, for bots and channels alike.
struct CodeGitSummary: View {
    let state: CodeState
    let thread: String
    var body: some View {
        if let git = state.gitStates[thread], git.repo {
            Button { PluginHost.shared.openInspectorTab(CodeDiffPanel.tabId) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus.forwardslash.minus")
                    if git.changes.isEmpty { Text(tr("Nessuna modifica")) }
                    else {
                        Text(tr("%@ file modificati", String(git.changes.count)))
                        if let added = git.additions, let deleted = git.deletions {
                            Text(verbatim: "+\(added) −\(deleted)").monospacedDigit()
                        }
                    }
                }
            }.buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize)).fixedSize()
                .help(git.summaryPartial == true ? tr("Le righe dei file non tracciati non sono incluse nel conteggio") : tr("Stato attuale della cartella condivisa"))
        }
    }
}

/// The folder's active git branch, under the composer. Nothing for a folder
/// that is not a repo, which is also what an engine without the route gives.
/// The state it reads is kept fresh by the plugin's `chatChanged`.
struct GitBranchChip: View {
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model

    @State private var choosing = false
    @State private var branches: [GitBranch] = []
    @State private var search = ""
    @State private var loading = false
    @State private var switching = false
    @State private var error: String?

    var body: some View {
        Group {
            if let git = state.gitStates[chat.threadId], git.repo, let branch = git.branch, !branch.isEmpty {
                Button { search = ""; choosing = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: git.detached == true ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                        Text(verbatim: chipText(branch, 32))
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .font(.system(size: Theme.uiSize, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1).fixedSize()
                }
                .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
                .help(tr("Cambia branch"))
                .popover(isPresented: $choosing) {
                    picker(current: branch, detached: git.detached == true)
                        .task {
                            loading = true
                            error = nil
                            branches = []
                            defer { loading = false }
                            do { branches = try await state.gitBranches(model: model, threadId: chat.threadId) }
                            catch { self.error = error.localizedDescription }
                        }
                }
            }
        }
        .onChange(of: state.branchPickerRequest) { _, _ in choosing = true }
    }

    private var matches: [GitBranch] {
        branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var newName: String { search.trimmingCharacters(in: .whitespaces) }

    private func picker(current: String, detached: Bool) -> some View {
        let sections = BranchSections(matches, current: detached ? nil : current, searching: !search.isEmpty)
        return VStack(alignment: .leading, spacing: 10) {
            Text(tr("Cambia branch")).font(.headline)
            TextField(tr("Cerca branch"), text: $search)
            if loading || switching { ProgressView().controlSize(.small) }
            if let error { Text(verbatim: error).foregroundStyle(Theme.danger).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section(tr("Recenti"), sections.recent, current: current, detached: detached)
                    section(tr("Locali"), sections.local, current: current, detached: detached)
                    section(tr("Remoti"), sections.remote, current: current, detached: detached)
                    // nothing by that name: offer to make it
                    if !loading, matches.isEmpty, !newName.isEmpty {
                        Button { Task { await create(newName) } } label: {
                            Label(tr("Crea branch '%@'", newName), systemImage: "plus").padding(6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(switching || chat.isBusy(model))
                    }
                }
            }.frame(height: 280)
            if !loading && branches.isEmpty && error == nil { Text(tr("Nessun branch disponibile")) }
            if chat.isBusy(model) { Text(tr("Attendi la fine del turno per cambiare branch")) }
        }
        .padding(16).frame(width: 360)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [GitBranch], current: String, detached: Bool) -> some View {
        if !items.isEmpty {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.horizontal, 6).padding(.top, 6)
            ForEach(items) { item in
                Button {
                    Task { await checkout(item) }
                } label: {
                    HStack {
                        Image(systemName: item.remote ? "network" : "arrow.triangle.branch")
                        Text(verbatim: item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if !item.remote && !detached && item.name == current {
                            Image(systemName: "checkmark")
                        }
                    }
                    .padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(switching || chat.isBusy(model))
            }
        }
    }

    private func checkout(_ branch: GitBranch) async {
        switching = true
        error = nil
        defer { switching = false }
        do {
            try await state.checkoutBranch(model: model, threadId: chat.threadId, ref: branch.ref)
            choosing = false
        } catch { self.error = error.localizedDescription }
    }

    private func create(_ name: String) async {
        switching = true
        error = nil
        defer { switching = false }
        do {
            try await state.createBranch(model: model, threadId: chat.threadId, name: name)
            choosing = false
        } catch { self.error = error.localizedDescription }
    }
}

/// How the picker groups the branches it shows: the few most recently committed
/// to on top (not the current one, which the check mark already marks), then the
/// rest of the local ones, then the remote ones. Searching drops "recent": it is a
/// shortcut for when the list is not narrowed down.
struct BranchSections: Equatable {
    static let recentCount = 5
    var recent: [GitBranch] = []
    var local: [GitBranch] = []
    var remote: [GitBranch] = []

    /// `branches` come newest commit first, as the engine sends them.
    init(_ branches: [GitBranch], current: String?, searching: Bool) {
        let locals = branches.filter { !$0.remote }
        if !searching {
            recent = Array(locals.filter { $0.name != current }.prefix(Self.recentCount))
        }
        let shown = Set(recent.map(\.ref))
        local = locals.filter { !shown.contains($0.ref) }
        remote = branches.filter(\.remote)
    }
}

struct CodeModeTerminalButton: View {
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model
    @State private var opening = false
    @State private var error: String?

    var body: some View {
        Button {
            Task {
                opening = true
                defer { opening = false }
                do {
                    let remote = model.isRemote
                    let identity = model.activeRemoteEngine.flatMap { model.identity(for: $0) }
                    let folder = try await state.folder(model: model, threadId: chat.threadId)
                    let command = "cd -- " + RemoteScripts.quote(folder) + " && exec \"${SHELL:-/bin/sh}\" -l"
                    if remote {
                        guard let identity else {
                            error = tr("Configura una connessione SSH per aprire il terminale sul server")
                            return
                        }
                        try model.openTerminal(identity, command: command)
                    } else {
                        TerminalLauncher.run(command)
                    }
                } catch { self.error = error.localizedDescription }
            }
        } label: {
            Label(tr("Apri terminale"), systemImage: "terminal").fixedSize()
        }
        .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
        .disabled(opening)
        .alert(tr("Errore"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(tr("Chiudi")) { error = nil }
        } message: { Text(verbatim: error ?? "") }
    }
}

/// "N files modified" in place of the file cards of a reply. Click to list
/// them. On the newest turn of a git folder the files are what git says is
/// changed — what a commit would take — and "Commit & push" asks the agent
/// to do it; anywhere else they are the files the reply points at.
struct CodeModeBadge: View {
    let message: Message
    let chat: CodeChat
    /// The newest turn's last message, once the bot is idle.
    let latest: Bool
    let state: CodeState
    /// In a channel, who spoke: "Codex · 3 files modified".
    var author: String?
    private var threadId: String { chat.threadId }
    @Environment(AppModel.self) private var model
    @State private var replyFiles: [ReplyFile] = []
    @State private var expanded = false
    @State private var committing = false

    private var git: ThreadGitState? {
        guard latest, let git = state.gitStates[threadId], git.repo else { return nil }
        return git
    }

    private var rows: [ChangedFile] {
        if let git { return git.changes.map { ChangedFile(file: $0.file, status: $0.status, exists: $0.exists) } }
        return replyFiles.map { ChangedFile(file: $0, status: nil, exists: true) }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 6) {
            if !rows.isEmpty {
                HStack(spacing: 8) {
                    badge(count: rows.count)
                    if git != nil {
                        Button { if state.engineHasWorkflow(model) { committing = true } else { Task { await state.commitAndPush(model: model) } } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle").font(.system(size: 11, weight: .semibold))
                                Text(tr("Commit & push")).font(.system(size: 12.5, weight: .medium))
                            }
                            .fixedSize()
                        }
                        .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                        .help(state.engineHasWorkflow(model) ? tr("Apre la finestra di commit") : tr("Chiede all'agente di fare commit e push delle modifiche"))
                        if state.engineHasPhase4(model) { CodeReviewMenu(chat: chat, state: state) }
                    }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { ChangedFileRow(row: $0, threadId: threadId, state: state) }
                    }
                    .padding(.leading, 18)
                    .transition(.opacity)
                }
            }
        }
        .task(id: message.id) {
            replyFiles = await model.replyFiles(threadId: threadId, messageId: message.id, text: message.text ?? "")
        }
        .sheet(isPresented: $committing) { CommitSheet(chat: chat, state: state) }
    }

    private func badge(count: Int) -> some View {
        Button {
            withAnimation(Theme.quick) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(Theme.tertiary)
                Image(systemName: "doc.badge.ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                Text(verbatim: author.map { "\($0) · " } ?? "").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                    + Text(count == 1 ? tr("1 file modificato") : tr("%@ file modificati", String(count)))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.panel))
            .overlay(Capsule().stroke(Theme.hairline.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(expanded ? tr("Nascondi i file") : tr("Mostra i file"))
    }
}

struct ChangedFile: Identifiable {
    var file: ReplyFile
    /// Git's letter for it; nil for a file a reply merely points at.
    var status: String?
    var exists: Bool

    var id: String { file.path }
}

private struct ChangedFileRow: View {
    let row: ChangedFile
    let threadId: String
    let state: CodeState
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let status = row.status {
                Text(verbatim: status)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color(status))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color(status).opacity(0.14)))
                    .help(label(status))
            }
            Text(verbatim: row.file.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(row.exists ? Theme.ink : Theme.tertiary)
                .strikethrough(!row.exists)
                .lineLimit(1)
            Text(verbatim: (row.file.path as NSString).deletingLastPathComponent.abbreviatingWithTildeInPath)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && row.exists ? Theme.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if row.exists { Task { await open() } } }
        .onDrag { row.exists && !model.isRemote ? NSItemProvider(object: URL(fileURLWithPath: row.file.path) as NSURL) : NSItemProvider() }
        .help(row.file.path)
        .contextMenu {
            if row.exists { Button(tr("Apri")) { Task { await open() } } }
            if row.exists, state.engineHasWorkflow(model) {
                Button(tr("Aggiungi alla chat")) { state.addReference(FileReference(path: row.file.path), threadId: threadId) }
            }
            if row.exists, !model.isRemote {
                Button(tr("Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.file.path)]) }
            }
            Button(tr("Copia percorso")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.file.path, forType: .string)
            }
        }
    }

    private func open() async {
        if let url = await model.localURL(for: row.file, threadId: threadId) { NSWorkspace.shared.open(url) }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "A", "?": return Theme.success
        case "D": return Theme.danger
        default: return Theme.warning
        }
    }

    private func label(_ status: String) -> String {
        switch status {
        case "A": return tr("Aggiunto")
        case "D": return tr("Eliminato")
        case "R": return tr("Rinominato")
        case "?": return tr("Non tracciato")
        default: return tr("Modificato")
        }
    }
}

private extension String {
    var abbreviatingWithTildeInPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
