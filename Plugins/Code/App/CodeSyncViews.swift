// What the branch is ahead of and behind its upstream, under the composer, and the three things to do about it:
// look at the remote, bring what it has (fast-forward only), send what is here. The engine runs git in the chat's folder.
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

struct CodeSyncChip: View {
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model
    @State private var showing = false

    private var git: ThreadGitState? { state.gitStates[chat.threadId] }
    private var working: Bool { state.syncing.contains(chat.threadId) }

    var body: some View {
        // only a branch that follows another has anything to compare
        if let git, git.repo, !(git.detached ?? false), let upstream = git.upstream {
            let ahead = git.ahead ?? 0, behind = git.behind ?? 0
            Button { showing = true } label: {
                HStack(spacing: 5) {
                    if working { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.up.arrow.down") }
                    if ahead > 0 { Text(verbatim: "↑\(ahead)").monospacedDigit() }
                    if behind > 0 { Text(verbatim: "↓\(behind)").monospacedDigit() }
                    if ahead == 0, behind == 0, !working { Image(systemName: "checkmark").font(.system(size: 10)) }
                }
                .font(.system(size: Theme.uiSize, weight: .medium))
                .foregroundStyle(behind > 0 ? Theme.warning : Theme.secondary)
                .fixedSize()
            }
            .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
            .help(Text(verbatim: summary(ahead: ahead, behind: behind, upstream: upstream)))
            .popover(isPresented: $showing) { details(git, ahead: ahead, behind: behind, upstream: upstream) }
        }
    }

    private func summary(ahead: Int, behind: Int, upstream: String) -> String {
        if ahead == 0, behind == 0 { return tr("In pari con %@", upstream) }
        return [ahead > 0 ? tr("%@ da inviare", String(ahead)) : nil, behind > 0 ? tr("%@ da scaricare", String(behind)) : nil]
            .compactMap { $0 }.joined(separator: " · ") + " — " + upstream
    }

    private func details(_ git: ThreadGitState, ahead: Int, behind: Int, upstream: String) -> some View {
        let busy = chat.isBusy(model)
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: upstream).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(verbatim: summary(ahead: ahead, behind: behind, upstream: "").replacingOccurrences(of: " — ", with: ""))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text(tr("I conteggi valgono dall'ultimo controllo del remoto."))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            if !git.changes.isEmpty, behind > 0 {
                Label(tr("Ci sono modifiche non committate: se toccano gli stessi file, git non scarica."), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.warning)
            }
            if busy { Text(tr("Attendi la fine del turno per scaricare.")).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
            if let error = state.syncErrors[chat.threadId] {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            Divider()
            HStack(spacing: 8) {
                Button { Task { await state.fetchRemote(model: model, threadId: chat.threadId) } } label: { Label(tr("Controlla"), systemImage: "arrow.clockwise").fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5)).disabled(working)
                    .help(tr("Guarda cosa c'è sul remoto, senza toccare i file"))
                Button { Task { await state.pull(model: model, threadId: chat.threadId) } } label: { Label(tr("Scarica"), systemImage: "arrow.down.circle").fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5)).disabled(working || busy || behind == 0)
                    .help(tr("Porta qui i commit del remoto, solo se non serve un merge"))
                Button { Task { await state.push(model: model, threadId: chat.threadId) } } label: { Label(tr("Invia"), systemImage: "arrow.up.circle").fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5)).disabled(working || ahead == 0)
                    .help(tr("Manda al remoto i commit fatti qui"))
                Button { Task { await state.sync(model: model, threadId: chat.threadId) } } label: { Label(tr("Sincronizza"), systemImage: "arrow.triangle.2.circlepath").fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5)).disabled(working || busy)
                    .help(tr("Controlla il remoto, scarica e poi invia"))
                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small) }
            }
        }
        .padding(16).frame(width: 440)
    }
}
