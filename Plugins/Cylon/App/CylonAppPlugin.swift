// The Cylon plugin, app side (docs/plans/2026-10-28-code-mode-t3.md §10): the bar of phases above the composer of
// a channel that follows the Cylon flow, and its settings. The engine imposes the flow (CylonPluginEngine);
// this shows where the ticket is and sends a phase when a button is pressed.
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

@MainActor
public final class CylonAppPlugin: AppPlugin {
    public let id = "cylon"
    public let name = "Cylon"
    let state = CylonState()

    public init() {}

    /// On for a channel with its switch: a bot on its own has no flow.
    public func isActive(for chat: ChatContext) -> Bool {
        guard let room = chat.room, room.guest == nil else { return false }
        return Self.follows(room)
    }

    static func follows(_ room: Room) -> Bool {
        if case .bool(true)? = (room.plugins ?? [:]).pluginData("cylon")["follow"] { return true }
        return false
    }

    public func bottomPanels(_ chat: ChatContext) -> [PluginView] {
        guard let room = chat.room else { return [] }
        return [PluginView(CylonPhaseBar(room: room, state: state).id(room.id))]
    }

    public func settingsSections(_ scope: SettingsScope) -> [PluginView] {
        switch scope {
        case let .room(room): return [PluginView(CylonRoomSettings(room: room, state: state))]
        case .global: return [PluginView(CylonGlobalSettings(state: state))]
        case .bot: return []
        }
    }

    public func chatChanged(_ chat: ChatContext) async {
        guard let room = chat.room else { return }
        await state.refresh(model: chat.model, groupId: room.id)
    }
}
