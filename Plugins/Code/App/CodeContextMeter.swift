import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

/// Keep session context next to the editor controls, including while a turn runs.
struct CodeContextMeter: View {
    let chat: CodeChat
    var compact = false
    @Environment(AppModel.self) private var model

    private var context: ContextUsage? {
        switch chat.kind {
        case .bot: return model.state.bot(chat.id)?.tasks?.first { $0.threadId == chat.threadId }?.context
        case .room: return model.state.rooms.first { $0.id == chat.id }?.context
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if !compact { Image(systemName: "gauge.medium") }
            let value = context?.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            Text(compact ? value : tr("Contesto %@", value)).monospacedDigit()
            if !compact, let fraction = context?.fraction {
                ProgressView(value: min(1, fraction)).frame(width: 45)
                    .tint(fraction >= 0.8 ? Theme.warning : Theme.accent)
            }
        }
        .font(.system(size: 11.5)).foregroundStyle((context?.fraction ?? 0) >= 0.8 ? Theme.warning : Theme.secondary)
        .padding(.horizontal, compact ? 3 : 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.raised.opacity(0.6)))
        .help(context?.fraction == nil
              ? tr("Percentuale non disponibile: il motore non ha ancora comunicato il limite del contesto")
              : tr("Ultimo contesto inviato: %@ token", String(format: "%.0f", context?.used ?? 0)))
        .accessibilityLabel(tr("Contesto della sessione"))
    }
}
