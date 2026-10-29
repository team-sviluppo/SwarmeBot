// A review of the chat's changes by another bot (docs/plans/2026-10-28-code-mode-t3.md, Parte 2 §5):
// "Chiedi revisione a…" asks another bot, ideally on another model, to read the diff; the review comes
// back into this chat as a message from that bot, and "Applica" hands it to the one that made the changes.
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

struct CodeReviewMenu: View {
    let chat: CodeChat
    let state: CodeState
    var size: CGFloat = 12.5
    @Environment(AppModel.self) private var model

    private var run: CodeReviewRun? { state.reviews[chat.threadId] }
    private var reviewers: [Bot] { state.reviewers(model: model, chat: chat) }

    var body: some View {
        HStack(spacing: 8) {
            if let run, run.running {
                ProgressView().controlSize(.small)
                Text(tr("Revisione di %@…", run.reviewerName)).font(.system(size: size)).foregroundStyle(Theme.secondary).lineLimit(1)
                Button { Task { await model.openTask(botId: run.reviewerId, threadId: run.reviewerThread) } } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(IconButtonStyle(size: 24, iconSize: 12))
                .help(tr("Apri la chat del revisore: potrebbe aspettare un permesso"))
                Button { Task { await state.cancelReview(model: model, threadId: chat.threadId) } } label: { Image(systemName: "stop.circle") }
                    .buttonStyle(IconButtonStyle(size: 24, iconSize: 12))
                    .help(tr("Annulla la revisione"))
            } else {
                Menu {
                    if reviewers.isEmpty { Text(tr("Nessun altro bot disponibile")) }
                    ForEach(reviewers) { bot in
                        Button { Task { await state.startReview(model: model, threadId: chat.threadId, botId: bot.id) } } label: {
                            Text(verbatim: "\(bot.name) · \(bot.modelSelection.model)")
                        }
                        .disabled(bot.busy == true)
                    }
                } label: {
                    Label(tr("Chiedi revisione a…"), systemImage: "person.badge.shield.checkmark").fixedSize()
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ChipButtonStyle(filled: true, size: size))
                .fixedSize()
                .disabled(chat.isBusy(model))
                .help(chat.isBusy(model) ? tr("Attendi la fine del turno") : tr("Manda il diff a un altro bot: la revisione arriva in questa chat"))
            }
        }
        .task(id: run?.running == true) {
            // the review lands in the chat on its own; this only keeps the state of the button true
            while !Task.isCancelled, state.reviews[chat.threadId]?.running == true {
                try? await Task.sleep(for: .seconds(2))
                await state.refreshReview(model: model, threadId: chat.threadId)
            }
        }
        .task(id: chat.threadId) { await state.refreshReview(model: model, threadId: chat.threadId) }
    }
}

/// What a failed review says, under the toolbar; it stays until the next one starts.
struct CodeReviewProblem: View {
    let chat: CodeChat
    let state: CodeState

    var body: some View {
        if let text = state.reviewErrors[chat.threadId] ?? (state.reviews[chat.threadId]?.status == "failed" ? state.reviews[chat.threadId]?.error : nil) {
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Under a review in the transcript: hand it to the bot that made the changes.
struct CodeReviewFooter: View {
    let message: Message
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if message.review?.applied == true {
                Label(tr("Passata al bot"), systemImage: "checkmark").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
            } else {
                Button { Task { await state.applyReview(model: model, threadId: chat.threadId, message: message) } } label: {
                    Label(tr("Applica"), systemImage: "arrow.turn.down.right").fixedSize()
                }
                .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                .disabled(chat.isBusy(model))
                .help(chat.isBusy(model) ? tr("Attendi la fine del turno")
                      : chat.kind == .room ? tr("Manda la revisione al canale, perché chi ha fatto le modifiche la affronti")
                      : tr("Manda la revisione al bot che ha fatto le modifiche: sistema ciò che è giusto e spiega il resto"))
            }
        }
    }
}
