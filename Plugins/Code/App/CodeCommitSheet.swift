// The commit window: a message the AI wrote and the person can change, the files to take, what to do
// after (commit, push, a new branch, a pull request). The engine runs it as processes — no agent in the
// chat, no terminal on screen.
import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

struct CommitSheet: View {
    let bot: Bot
    let state: CodeState
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var generating = false
    @State private var selection: Set<String> = []
    @State private var mode: CommitMode = .commit
    @State private var branchName = ""
    @State private var running = false
    @State private var error: String?
    @State private var result: CommitResult?
    @State private var asked = false

    private var git: ThreadGitState? { state.gitStates[bot.threadId] }
    private var changes: [ThreadGitState.Change] { git?.changes ?? [] }
    private var branch: String { git?.branch ?? "" }
    private var busy: Bool { model.isBusy(bot) }

    private var canRun: Bool {
        !running && !generating && !busy && !selection.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode != .newBranch || !branchName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result { done(result) } else { form }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            selection = Set(changes.map(\.path))
            // the AI writes a first draft; the person owns the final words
            if !asked { asked = true; Task { await generate() } }
        }
    }

    // MARK: form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Commit")).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr("Messaggio")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Spacer()
                    if generating { ProgressView().controlSize(.small) }
                    Button { Task { await generate() } } label: { Label(tr("Scrivi con l'AI"), systemImage: "sparkles") }
                        .disabled(generating || running)
                }
                TextEditor(text: $message)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(height: 130)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.hairline.opacity(0.6)))
            }
            filesList
            modes
            if busy { Text(tr("Attendi la fine del turno per fare commit")).font(.system(size: 12)).foregroundStyle(Theme.warning) }
            if let error {
                ScrollView {
                    Text(verbatim: error).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.danger)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            HStack {
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button(tr("Annulla")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("Esegui")) { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
        }
    }

    private var filesList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("File (%@ di %@)", String(selection.count), String(changes.count)))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Button(selection.count == changes.count ? tr("Nessuno") : tr("Tutti")) {
                    selection = selection.count == changes.count ? [] : Set(changes.map(\.path))
                }
                .buttonStyle(.link).font(.system(size: 12))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(changes) { change in
                        Toggle(isOn: Binding(get: { selection.contains(change.path) }, set: { on in
                            if on { selection.insert(change.path) } else { selection.remove(change.path) }
                        })) {
                            HStack(spacing: 8) {
                                Text(verbatim: change.status).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.secondary).frame(width: 14)
                                Text(verbatim: ChangeTree.relative(change.path, root: git?.root)).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(8)
            }
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inset))
        }
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Poi")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            Picker("", selection: $mode) {
                Text(tr("Solo commit")).tag(CommitMode.commit)
                Text(branch.isEmpty ? tr("Commit e push") : tr("Commit e push su %@", branch)).tag(CommitMode.push)
                Text(tr("Commit e push su un nuovo branch")).tag(CommitMode.newBranch)
                Text(tr("Commit, push e apri una pull request")).tag(CommitMode.pullRequest)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if mode == .newBranch {
                TextField(tr("Nome del nuovo branch"), text: $branchName).textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: result

    private func done(_ result: CommitResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tr("Commit %@ fatto", result.commit), systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Theme.success)
            Text(verbatim: result.branch).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.secondary)
            if result.pushed { Label(tr("Push fatto"), systemImage: "arrow.up.circle") }
            if let url = result.prUrl, let link = URL(string: url) {
                Button { NSWorkspace.shared.open(link) } label: { Label(tr("Apri la pull request"), systemImage: "arrow.up.right.square") }
                Text(verbatim: url).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(tr("Chiudi")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: actions

    private func generate() async {
        generating = true
        error = nil
        defer { generating = false }
        do { message = try await state.commitMessage(model: model, threadId: bot.threadId) }
        catch { self.error = error.localizedDescription }
    }

    private func run() async {
        running = true
        error = nil
        defer { running = false }
        // all of them: let the engine take every change, new ones included
        let files = selection.count == changes.count ? nil : changes.map(\.path).filter(selection.contains)
        do {
            result = try await state.commit(model: model, threadId: bot.threadId, message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                                            files: files, mode: mode, branch: branchName.trimmingCharacters(in: .whitespaces))
        } catch { self.error = error.localizedDescription }
    }
}

/// Keys that belong to the plugin and have no visible control: ⌘⇧D opens the diff.
struct CodeShortcuts: View {
    var body: some View {
        Button("") { PluginHost.shared.openInspectorTab(CodeDiffPanel.tabId) }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// Impostazioni › Plugin: the model that writes every bot's commit messages on this engine.
struct CodeGlobalSettings: View {
    let state: CodeState
    @Environment(AppModel.self) private var model

    private var current: String {
        state.commitModel.map { "\($0.instanceId)\u{1F}\($0.model)" } ?? ""
    }

    var body: some View {
        Section {
            Picker(tr("Modello per i messaggi di commit"), selection: Binding(get: { current }, set: { pick($0) })) {
                Text(tr("Quello del bot")).tag("")
                ForEach(model.instances.filter { $0.snapshot.isAvailable }) { instance in
                    ForEach(instance.models.options) { option in
                        Text(verbatim: "\(instance.shownName): \(option.label)").tag("\(instance.instanceId)\u{1F}\(option.id)")
                    }
                }
            }
            Text(tr("Un modello solo scrive i messaggi di commit di tutti i bot, in una chiamata a parte che non sporca la chat."))
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
        } header: {
            Text(tr("Code"))
        }
        .task { await state.refreshSettings(model: model) }
    }

    private func pick(_ value: String) {
        let parts = value.components(separatedBy: "\u{1F}")
        let pick = parts.count == 2 ? CodeSettingsWire.Pick(instanceId: parts[0], model: parts[1]) : nil
        Task { await state.setCommitModel(model: model, pick) }
    }
}
