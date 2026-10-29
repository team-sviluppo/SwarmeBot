// Code mode: the git branch next to the folder chip, and at the end of a turn
// one "N files modified" badge in place of a card per file.
import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI

/// The folder's active git branch, under the composer. Nothing for a folder
/// that is not a repo, which is also what an engine without the route gives.
/// The state it reads is kept fresh by `refreshingGit`.
struct GitBranchChip: View {
    let bot: Bot
    @Environment(AppModel.self) private var model

    @State private var choosing = false
    @State private var branches: [GitBranch] = []
    @State private var search = ""
    @State private var loading = false
    @State private var switching = false
    @State private var error: String?

    var body: some View {
        Group {
            if let git = model.gitStates[bot.threadId], git.repo, let branch = git.branch, !branch.isEmpty {
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
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("Cambia branch")).font(.headline)
                        TextField(tr("Cerca branch"), text: $search)
                        if loading || switching { ProgressView().controlSize(.small) }
                        if let error { Text(verbatim: error).foregroundStyle(Theme.danger).textSelection(.enabled) }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { item in
                                    Button {
                                        Task { await checkout(item) }
                                    } label: {
                                        HStack {
                                            Image(systemName: item.remote ? "network" : "arrow.triangle.branch")
                                            Text(verbatim: item.name).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            if !item.remote && git.detached != true && item.name == branch {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                        .padding(6).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(switching || model.isBusy(bot))
                                }
                            }
                        }.frame(height: 280)
                        if !loading && branches.isEmpty && error == nil { Text(tr("Nessun branch disponibile")) }
                        if model.isBusy(bot) { Text(tr("Attendi la fine del turno per cambiare branch")) }
                    }
                    .padding(16).frame(width: 360)
                    .task {
                        loading = true
                        error = nil
                        branches = []
                        defer { loading = false }
                        do { branches = try await model.gitBranches(threadId: bot.threadId) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func checkout(_ branch: GitBranch) async {
        switching = true
        error = nil
        defer { switching = false }
        do {
            try await model.checkoutBranch(threadId: bot.threadId, ref: branch.ref)
            choosing = false
        } catch { self.error = error.localizedDescription }
    }
}

struct CodeModeTerminalButton: View {
    let bot: Bot
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
                    let folder = try await model.codeModeFolder(threadId: bot.threadId)
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

private struct GitRefreshKey: Equatable {
    var threadId: String
    var folder: String
    var busy: Bool
    var codeMode: Bool
}

extension View {
    /// Keeps a Code mode chat's git state current: when the chat, its folder
    /// or Code mode itself changes, and when a turn starts or ends (the agent
    /// may have switched branch or edited files). It goes on a view that is
    /// always there: SwiftUI never runs a task on one that is empty.
    func refreshingGit(bot: Bot, folder: String, model: AppModel) -> some View {
        task(id: GitRefreshKey(threadId: bot.threadId, folder: folder, busy: model.isBusy(bot), codeMode: bot.codeMode == true)) {
            if bot.codeMode == true { await model.refreshGit(threadId: bot.threadId) }
        }
    }
}

/// What ends a turn in Code mode: the messages that close a turn (a bot text
/// followed by the next user message or by nothing), and the newest of them.
struct TurnEnds {
    var ids: Set<String> = []
    var latest: String?

    init(_ messages: [Message]) {
        var pending: String?
        for message in messages {
            guard message.kind == .text else { continue }
            if message.role == .user {
                if let pending { ids.insert(pending) }
                pending = nil
            } else {
                pending = message.id
            }
        }
        if let pending {
            ids.insert(pending)
            latest = pending
        }
    }
}

/// "N files modified" in place of the file cards of a reply. Click to list
/// them. On the newest turn of a git folder the files are what git says is
/// changed — what a commit would take — and "Commit & push" asks the agent
/// to do it; anywhere else they are the files the reply points at.
struct CodeModeBadge: View {
    let message: Message
    let threadId: String
    /// The newest turn's last message, once the bot is idle.
    let latest: Bool
    @Environment(AppModel.self) private var model
    @State private var replyFiles: [ReplyFile] = []
    @State private var expanded = false

    private var git: ThreadGitState? {
        guard latest, let state = model.gitStates[threadId], state.repo else { return nil }
        return state
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
                        Button { Task { await model.commitAndPush() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.circle").font(.system(size: 11, weight: .semibold))
                                Text(tr("Commit & push")).font(.system(size: 12.5, weight: .medium))
                            }
                            .fixedSize()
                        }
                        .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                        .help(tr("Chiede all'agente di fare commit e push delle modifiche"))
                    }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { ChangedFileRow(row: $0, threadId: threadId) }
                    }
                    .padding(.leading, 18)
                    .transition(.opacity)
                }
            }
        }
        .task(id: message.id) {
            replyFiles = await model.replyFiles(threadId: threadId, messageId: message.id, text: message.text ?? "")
        }
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
                Text(count == 1 ? tr("1 file modificato") : tr("%@ file modificati", String(count)))
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
        .help(row.file.path)
        .contextMenu {
            if row.exists { Button(tr("Apri")) { Task { await open() } } }
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
