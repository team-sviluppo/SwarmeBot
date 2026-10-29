// Plan / Execute under the composer, and the approval of a plan under the reply that proposes it
// (docs/plans/2026-10-28-code-mode-t3.md, Parte 2 §3). The mode is the chat's and lives on the engine.
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

struct CodePlanToggle: View {
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model

    var body: some View {
        let plan = state.mode(of: chat.threadId) == .plan
        Menu {
            option(.execute, current: plan ? .plan : .execute)
            option(.plan, current: plan ? .plan : .execute)
        } label: {
            Label(plan ? tr("Modo Piano") : tr("Modo Esegui"), systemImage: plan ? "list.bullet.clipboard" : "bolt")
                .foregroundStyle(plan ? Theme.accent : Theme.secondary)
                .fixedSize()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
        .fixedSize()
        .help(plan ? tr("Modalità Piano: il bot esplora e propone un piano senza toccare i file")
                   : tr("Modalità Esegui: il bot può modificare i file. Scegli Piano per farsi proporre prima un piano"))
        .task(id: chat.threadId) { await state.refreshMode(model: model, threadId: chat.threadId) }
    }

    private func option(_ mode: CodeChatMode, current: CodeChatMode) -> some View {
        Button {
            Task { await state.setMode(model: model, threadId: chat.threadId, mode) }
        } label: {
            if mode == current { Label(title(mode), systemImage: "checkmark") } else { Text(title(mode)) }
        }
    }

    private func title(_ mode: CodeChatMode) -> String {
        mode == .plan ? tr("Piano — propone, non modifica") : tr("Esegui — può modificare i file")
    }
}

/// Under the newest reply while the chat is in Plan mode: approve it, or write what to change.
struct CodePlanApproval: View {
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(Theme.accent)
            Text(tr("Piano proposto: approvalo per far partire il lavoro, o scrivi cosa cambiare."))
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Button { Task { await state.approvePlan(model: model, threadId: chat.threadId) } } label: {
                Label(tr("Approva ed esegui"), systemImage: "play.fill").fixedSize()
            }
            .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
            .disabled(chat.isBusy(model))
            .help(tr("Passa a Esegui e dice al bot di procedere"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
    }
}
