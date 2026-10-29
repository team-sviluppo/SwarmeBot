// The diff panel: the files a chat changed on the left, the diff of the one chosen on the right,
// with a comment on any line. "Invia revisione" sends the comments to the agent as one message;
// "Commit…" opens the commit window. It reads the engine's `git/diff` route, so on a server
// it shows the server's files.
import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

/// The changed files grouped by folder, for the tree on the left.
enum ChangeTree {
    struct Group: Equatable, Identifiable {
        var folder: String
        var files: [ThreadGitState.Change]
        var id: String { folder }
    }

    /// A change's path relative to the repository's root; the path itself when it lies elsewhere.
    static func relative(_ path: String, root: String?) -> String {
        guard let root, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// Folders in order, "" (the root) first, each with its files by name.
    static func groups(_ changes: [ThreadGitState.Change], root: String?) -> [Group] {
        Dictionary(grouping: changes) { (relative($0.path, root: root) as NSString).deletingLastPathComponent }
            .map { Group(folder: $0.key, files: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }
}

struct CodeDiffPanel: View {
    static let tabId = "code.diff"
    static let width: CGFloat = 660

    let bot: Bot
    let state: CodeState
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var diff: FileDiff?
    @State private var loading = false
    @State private var error: String?
    @State private var showCommit = false

    private var git: ThreadGitState? { state.gitStates[bot.threadId] }
    private var changes: [ThreadGitState.Change] { git?.changes ?? [] }
    private var pending: [DiffComment] { state.comments[bot.threadId] ?? [] }
    private var selectedChange: ThreadGitState.Change? { changes.first { $0.path == selected } }

    /// Reload when the choice changes or git says something else changed.
    private struct ReloadKey: Equatable {
        var path: String?
        var signature: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.hairline.opacity(0.4)).frame(height: 1)
            if git?.repo != true {
                placeholder(tr("La cartella della chat non è un repository git."))
            } else if changes.isEmpty {
                placeholder(tr("Nessuna modifica da mostrare."))
            } else {
                HStack(spacing: 0) {
                    fileList.frame(width: 200)
                    Rectangle().fill(Theme.hairline.opacity(0.4)).frame(width: 1)
                    viewer
                }
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: ReloadKey(path: selected, signature: changes.map { "\($0.path):\($0.status):\($0.bytes)" })) { await load() }
        .onChange(of: changes.map(\.path), initial: true) { _, paths in
            if selected == nil || !paths.contains(selected ?? "") { selected = paths.first }
        }
        .sheet(isPresented: $showCommit) { CommitSheet(bot: bot, state: state) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(changes.count == 1 ? tr("1 file modificato") : tr("%@ file modificati", String(changes.count)))
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
            Spacer()
            if !pending.isEmpty {
                Button { Task { await state.sendReview(model: model, threadId: bot.threadId) } } label: {
                    Label(tr("Invia revisione (%@)", String(pending.count)), systemImage: "text.bubble").fixedSize()
                }
                .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                .disabled(model.isBusy(bot))
                .help(model.isBusy(bot) ? tr("Attendi la fine del turno") : tr("Manda al bot tutti i commenti in un solo messaggio"))
            }
            Button { Task { await state.refreshGit(model: model, threadId: bot.threadId); await load() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle(size: 26, iconSize: 12))
            .help(tr("Ricarica"))
            Button { showCommit = true } label: {
                Label(tr("Commit…"), systemImage: "arrow.up.circle").fixedSize()
            }
            .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
            .disabled(changes.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: files

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(ChangeTree.groups(changes, root: git?.root)) { group in
                    if !group.folder.isEmpty {
                        Text(verbatim: group.folder).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            .lineLimit(1).truncationMode(.head).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                    }
                    ForEach(group.files) { change in
                        FileRow(change: change, chosen: change.path == selected, comments: pending.filter { $0.path == ChangeTree.relative(change.path, root: git?.root) }.count)
                            .onTapGesture { selected = change.path }
                            .contextMenu {
                                Button(tr("Aggiungi alla chat")) { state.addReference(FileReference(path: change.path), threadId: bot.threadId) }
                                Button(tr("Copia percorso")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(change.path, forType: .string)
                                }
                            }
                            // from here to the composer: a reference, on this Mac
                            .onDrag { NSItemProvider(object: URL(fileURLWithPath: change.path) as NSURL) }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: diff

    private var viewer: some View {
        VStack(spacing: 0) {
            if let change = selectedChange {
                HStack(spacing: 8) {
                    Text(verbatim: ChangeTree.relative(change.path, root: git?.root))
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { state.addReference(FileReference(path: change.path), threadId: bot.threadId) } label: {
                        Label(tr("Aggiungi alla chat"), systemImage: "paperclip").fixedSize()
                    }
                    .buttonStyle(ChipButtonStyle(filled: false, size: 11.5))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Rectangle().fill(Theme.hairline.opacity(0.3)).frame(height: 1)
            }
            if let error {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled).padding(12)
                Spacer()
            } else if loading && diff == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff, diff.binary {
                placeholder(tr("File binario: niente da mostrare."))
            } else if let diff, let change = selectedChange {
                DiffView(lines: DiffParser.parse(diff.diff), truncated: diff.truncated, path: ChangeTree.relative(change.path, root: git?.root),
                         threadId: bot.threadId, state: state)
            } else {
                Spacer()
            }
        }
    }

    private func load() async {
        guard let selected else { diff = nil; return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let fresh = try await state.diff(model: model, threadId: bot.threadId, path: selected)
            guard selected == self.selected else { return }
            diff = fresh
        } catch {
            // a newer load took over (the choice or the changes moved): its answer is the one to show
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if selected == self.selected { diff = nil; self.error = error.localizedDescription }
        }
    }
}

private struct FileRow: View {
    let change: ThreadGitState.Change
    let chosen: Bool
    let comments: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: change.status)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.14)))
            Text(verbatim: change.name).font(.system(size: 12.5)).foregroundStyle(change.exists ? Theme.ink : Theme.tertiary)
                .strikethrough(!change.exists).lineLimit(1)
            Spacer(minLength: 0)
            if comments > 0 {
                Text(verbatim: "\(comments)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.accent))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(chosen ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var color: Color {
        switch change.status {
        case "A", "?": return Theme.success
        case "D": return Theme.danger
        default: return Theme.warning
        }
    }
}

/// The numbered lines of one file's diff, with a comment on any of them.
private struct DiffView: View {
    let lines: [DiffLine]
    let truncated: Bool
    let path: String
    let threadId: String
    let state: CodeState
    /// The line being commented, by its id in `lines`.
    @State private var composing: Int?
    @State private var draft = ""

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    row(line)
                    ForEach((state.comments[threadId] ?? []).filter { matches($0, line) }) { comment in commentRow(comment) }
                    if composing == line.id { composer(line) }
                }
                if truncated {
                    Text(tr("Diff troncato: il file è molto lungo.")).font(.system(size: 11.5)).foregroundStyle(Theme.warning).padding(10)
                }
            }
            .frame(minWidth: 520, alignment: .leading)
        }
    }

    private func matches(_ comment: DiffComment, _ line: DiffLine) -> Bool {
        comment.path == path && line.kind != .hunk && line.kind != .note && comment.line == line.anchor && comment.removed == (line.kind == .removed)
    }

    private func row(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if line.kind == .hunk {
                Text(verbatim: line.text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 10).padding(.vertical, 3)
            } else {
                gutter(line.oldNumber)
                gutter(line.newNumber)
                Text(verbatim: marker(line)).font(.system(size: 12, design: .monospaced)).foregroundStyle(tint(line)).frame(width: 16)
                Text(verbatim: line.text.isEmpty ? " " : line.text).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(line.kind == .note ? Theme.tertiary : Theme.ink)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line))
        .contentShape(Rectangle())
        .onTapGesture {
            guard line.anchor != nil, line.kind != .note, line.kind != .hunk else { return }
            draft = ""
            composing = composing == line.id ? nil : line.id
        }
        .help(line.anchor != nil ? tr("Clic per commentare questa riga") : "")
    }

    private func gutter(_ number: Int?) -> some View {
        Text(verbatim: number.map(String.init) ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
            .frame(width: 38, alignment: .trailing).padding(.trailing, 4)
    }

    private func marker(_ line: DiffLine) -> String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return ""
        }
    }

    private func tint(_ line: DiffLine) -> Color { line.kind == .added ? Theme.success : Theme.danger }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .added: return Theme.success.opacity(0.12)
        case .removed: return Theme.danger.opacity(0.12)
        case .hunk: return Theme.accent.opacity(0.08)
        default: return .clear
        }
    }

    private func commentRow(_ comment: DiffComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent)
            Text(verbatim: comment.body).font(.system(size: 12)).foregroundStyle(Theme.ink).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { state.removeComment(comment.id, threadId: threadId) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary).help(tr("Elimina il commento"))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.inset))
        .padding(.leading, 62).padding(.trailing, 12).padding(.vertical, 3)
    }

    private func composer(_ line: DiffLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(tr("Commento su questa riga"), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...5)
            HStack {
                Button(tr("Annulla")) { composing = nil }
                Button(tr("Aggiungi commento")) { add(on: line) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .padding(.leading, 62).padding(.trailing, 12).padding(.vertical, 3)
    }

    private func add(on line: DiffLine) {
        guard let anchor = line.anchor else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        state.addComment(DiffComment(path: path, line: anchor, removed: line.kind == .removed, excerpt: line.text, body: body), threadId: threadId)
        composing = nil
        draft = ""
    }
}
