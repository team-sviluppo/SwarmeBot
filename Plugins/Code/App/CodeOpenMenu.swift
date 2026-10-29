// "Apri in…" under the composer: the folder in Finder or an editor, and the chat's
// own session picked up in a terminal.
import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

struct CodeOpenMenu: View {
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model
    @State private var error: String?

    private var folder: String? { state.gitStates[chat.threadId]?.folder }
    private var identity: SSHIdentity? { model.activeRemoteEngine.flatMap { model.identity(for: $0) } }
    private var resume: ResumeCommand? { state.resumeCommands[chat.threadId] }

    /// The editors installed here; on a server only those that can open one.
    private var editors: [EditorApp] {
        EditorApp.allCases.filter { editor in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleId) != nil && (!model.isRemote || editor.opensServerFolders)
        }
    }

    var body: some View {
        Group {
            if folder != nil {
                Menu {
                    if !model.isRemote {
                        Button(tr("Mostra nel Finder")) { reveal() }
                    }
                    ForEach(editors) { editor in
                        Button(editor.name) { open(in: editor) }
                    }
                    if let resume, resume.supported, resume.command != nil {
                        Divider()
                        Button(tr("Continua nel terminale")) { continueInTerminal(resume) }
                    }
                } label: {
                    Label(tr("Apri in…"), systemImage: "arrow.up.forward.app").fixedSize()
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
                .fixedSize()
                .help(tr("Apri la cartella in un editor o nel Finder, o continua la chat nel terminale"))
                .alert(tr("Errore"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button(tr("Chiudi")) { error = nil }
                } message: { Text(verbatim: error ?? "") }
            }
        }
    }

    private func reveal() {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    private func open(in editor: EditorApp) {
        guard let folder else { return }
        if model.isRemote {
            guard let identity else {
                error = tr("Configura una connessione SSH per aprire la cartella del server in un editor")
                return
            }
            guard let url = editor.remoteURL(identity: identity, folder: folder) else { return }
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleId) {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, failure in
                if let failure { Task { @MainActor in error = failure.localizedDescription } }
            }
        }
    }

    private func continueInTerminal(_ resume: ResumeCommand) {
        guard let command = resume.command else { return }
        if model.isRemote {
            guard let identity else {
                error = tr("Configura una connessione SSH per aprire il terminale sul server")
                return
            }
            do { try model.openTerminal(identity, command: command) } catch { self.error = error.localizedDescription }
        } else {
            TerminalLauncher.run(command)
        }
    }
}
