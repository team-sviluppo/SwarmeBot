import SwarmeBotUI
import SwarmeKit
import SwiftUI

/// The header and the column share the existing preference, per engine and bot.
struct CodeChatToggle: View {
    @AppStorage private var collapsed: Bool

    init(preferenceKey: String) {
        _collapsed = AppStorage(wrappedValue: false, "code.chat-column." + preferenceKey, store: AppPaths.defaults)
    }

    var body: some View {
        Button { collapsed.toggle() } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
        .buttonStyle(IconButtonStyle(size: 30, iconSize: 16, active: !collapsed))
        .help(tr("Colonna Chat (⌘⇧L)"))
        .accessibilityLabel(tr("Colonna Chat (⌘⇧L)"))
        .accessibilityValue(collapsed ? tr("Nascosta") : tr("Visibile"))
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}
