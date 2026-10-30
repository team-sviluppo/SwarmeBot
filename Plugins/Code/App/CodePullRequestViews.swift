// The pull request of the chat's branch under the composer: its checks, its state, and the two things
// that come back after a push (docs/plans/2026-10-28-code-mode-t3.md, Parte 2 §7): "Fai sistemare al bot"
// when the CI fails, and the colleagues' comments. The engine asks GitHub with `gh`.
import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

/// What the chip shows for a pull request.
enum PullRequestLook {
    struct Look: Equatable {
        var icon: String
        var tint: Tint
        var summary: String
    }

    enum Tint { case ok, bad, wait, merged, quiet }

    static func look(_ pr: CodePullRequest) -> Look {
        switch pr.state {
        case "merged": return Look(icon: "arrow.triangle.merge", tint: .merged, summary: tr("Unita"))
        case "closed": return Look(icon: "xmark.circle", tint: .quiet, summary: tr("Chiusa"))
        default: break
        }
        if pr.draft { return Look(icon: "pencil.circle", tint: .quiet, summary: tr("Bozza")) }
        switch pr.checks.state {
        case "failure": return Look(icon: "xmark.circle.fill", tint: .bad, summary: tr("%@ check falliti", String(pr.checks.failed)))
        case "pending": return Look(icon: "clock", tint: .wait, summary: tr("CI in corso"))
        case "success": return Look(icon: "checkmark.circle.fill", tint: .ok, summary: tr("CI superata"))
        default: return Look(icon: "circle.dashed", tint: .quiet, summary: tr("Nessun check"))
        }
    }

    static func color(_ tint: Tint) -> Color {
        switch tint {
        case .ok: return Theme.success
        case .bad: return Theme.danger
        case .wait: return Theme.warning
        case .merged: return Theme.accent
        case .quiet: return Theme.secondary
        }
    }

    static func checkIcon(_ state: String) -> (String, Tint) {
        switch state {
        case "success": return ("checkmark.circle.fill", .ok)
        case "failure": return ("xmark.circle.fill", .bad)
        case "pending": return ("clock", .wait)
        default: return ("minus.circle", .quiet)
        }
    }

    static func decision(_ value: String?) -> String? {
        switch value {
        case "approved": return tr("Approvata")
        case "changes_requested": return tr("Modifiche richieste")
        case "review_required": return tr("Revisione richiesta")
        default: return nil
        }
    }

    static func mergeNote(_ pr: CodePullRequest) -> String? {
        guard pr.isOpen else { return nil }
        if pr.mergeable == "conflicting" || pr.merge == "dirty" { return tr("Ci sono conflitti con %@", pr.base ?? "base") }
        if pr.merge == "behind" { return tr("Il branch è indietro rispetto a %@", pr.base ?? "base") }
        return nil
    }
}

struct CodePullRequestChip: View {
    let chat: CodeChat
    let state: CodeState
    @Environment(AppModel.self) private var model
    @State private var showing = false
    @State private var working = false
    @State private var problem: String?

    private var status: CodePullRequestStatus? { state.pullRequests[chat.threadId] }
    private var branch: String? { state.gitStates[chat.threadId]?.branch }

    private struct PollKey: Hashable {
        var thread: String
        var branch: String?
    }

    var body: some View {
        // a zero-size anchor keeps the polling task alive while there is no pull request to show
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let pr = status?.pr {
                let look = PullRequestLook.look(pr)
                Button { showing = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: look.icon).foregroundStyle(PullRequestLook.color(look.tint))
                        Text(verbatim: "PR #\(pr.number)")
                        if pr.comments > 0 {
                            Image(systemName: "bubble.left").font(.system(size: 10))
                            Text(verbatim: String(pr.comments))
                        }
                    }
                    .font(.system(size: Theme.uiSize, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                }
                .buttonStyle(ChipButtonStyle(filled: true, size: Theme.uiSize))
                .help(Text(verbatim: "\(pr.title) · \(look.summary)"))
                .popover(isPresented: $showing) { details(pr) }
            }
        }
        .fixedSize()
        .task(id: PollKey(thread: chat.threadId, branch: branch)) {
            guard branch != nil else { return }
            while !Task.isCancelled {
                await state.refreshPullRequest(model: model, threadId: chat.threadId)
                try? await Task.sleep(for: CodeState.pollInterval(state.pullRequests[chat.threadId]))
            }
        }
    }

    private func details(_ pr: CodePullRequest) -> some View {
        let look = PullRequestLook.look(pr)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: look.icon).foregroundStyle(PullRequestLook.color(look.tint))
                Text(verbatim: "#\(pr.number) \(pr.title)").font(.headline).lineLimit(2)
            }
            Text(verbatim: [pr.head, pr.base].compactMap { $0 }.joined(separator: " → ") + "  ·  " + look.summary)
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if let decision = PullRequestLook.decision(pr.reviewDecision) {
                Text(verbatim: decision).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            if let note = PullRequestLook.mergeNote(pr) {
                Label(note, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            if !pr.checks.items.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(pr.checks.items) { check in
                            let icon = PullRequestLook.checkIcon(check.state)
                            Button { if let url = check.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: icon.0).foregroundStyle(PullRequestLook.color(icon.1))
                                    Text(verbatim: check.title).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(check.url == nil)
                        }
                    }
                }.frame(maxHeight: 180)
            }
            if let problem { Text(verbatim: problem).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
            Divider()
            HStack(spacing: 8) {
                Button { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } } label: { Label(tr("Apri su GitHub"), systemImage: "arrow.up.forward.square").fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                if pr.checks.state == "failure" {
                    Button { run { try await state.sendCIFailures(model: model, threadId: chat.threadId) } } label: { Label(tr("Fai sistemare al bot"), systemImage: "wrench.and.screwdriver").fixedSize() }
                        .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                        .disabled(working || chat.isBusy(model))
                        .help(tr("Manda al bot i log dei check falliti"))
                }
                if pr.comments > 0 || pr.isOpen {
                    Button { run { try await state.sendPullRequestComments(model: model, threadId: chat.threadId) } } label: { Label(tr("Importa i commenti"), systemImage: "text.bubble").fixedSize() }
                        .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                        .disabled(working || chat.isBusy(model))
                        .help(tr("Porta nella chat le revisioni e i commenti dei colleghi"))
                }
                Spacer(minLength: 0)
                Button { Task { await state.refreshPullRequest(model: model, threadId: chat.threadId, refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle(size: 26, iconSize: 12))
                    .help(tr("Ricarica"))
            }
            if working { ProgressView().controlSize(.small) }
        }
        .padding(16).frame(width: 420)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            working = true
            problem = nil
            defer { working = false }
            do {
                try await action()
                showing = false
            } catch { problem = error.localizedDescription }
        }
    }
}
