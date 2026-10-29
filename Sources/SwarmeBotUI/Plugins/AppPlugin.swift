// App plugins (docs/plans/2026-10-28-code-mode-t3.md §12).
//
// A plugin is a Swift module linked into the app executable at build time:
// `SwarmeApp.run(plugins: [CodeAppPlugin()])`. The core defines the places a
// plugin may add to (below) and never imports one. A place exists once a
// plugin needs it, so the interface follows real uses rather than guesses.
//
// A plugin shows only where both sides have it: it is linked into this app,
// and the engine the window shows carries it and has it on (`GET /api/plugins`).
// Past that, `isActive(for:)` says whether it is on for this particular chat.
import CompanionCore
import SwarmeKit
import SwiftUI

public typealias PluginView = AnyView

/// The chat a plugin is asked about: a bot's, or a channel's.
public struct ChatContext {
    public let model: AppModel
    public let bot: Bot?
    public let room: Room?
    public let threadId: String
    /// The folder the chat works in, when the place asking knows it.
    public var folder: String?
    public var isBusy: Bool

    public init(model: AppModel, bot: Bot?, room: Room?, threadId: String, folder: String? = nil, isBusy: Bool) {
        self.model = model
        self.bot = bot
        self.room = room
        self.threadId = threadId
        self.folder = folder
        self.isBusy = isBusy
    }
}

public enum SettingsScope {
    case bot(Bot)
    case room(Room)
    case global
}

/// Where a bot reply stands in its turn: the last of the turn, and the newest turn's last.
public struct TurnPosition: Sendable {
    public var isTurnEnd: Bool
    public var isLatest: Bool

    public init(isTurnEnd: Bool, isLatest: Bool) {
        self.isTurnEnd = isTurnEnd
        self.isLatest = isLatest
    }
}

@MainActor
public protocol AppPlugin: AnyObject {
    /// The id the engine's plugin of the same name carries (`code`).
    var id: String { get }
    var name: String { get }

    /// Whether the plugin is on for this chat (for Code, the bot's switch).
    func isActive(for chat: ChatContext) -> Bool
    /// Chips under the composer, after the folder.
    func composerAccessories(_ chat: ChatContext) -> [PluginView]
    /// What goes under a bot reply in place of the cards of the files it points at;
    /// nil leaves the cards. Asked for every bot text of a chat the plugin is active in.
    func replyFooter(_ message: Message, _ chat: ChatContext, _ position: TurnPosition) -> PluginView?
    /// Rows of the settings of a bot or channel (the plugin's switch, its options).
    func settingsSections(_ scope: SettingsScope) -> [PluginView]
    /// The chat, its folder or its busy state changed: refresh what the plugin shows.
    func chatChanged(_ chat: ChatContext) async
}

public extension AppPlugin {
    func isActive(for chat: ChatContext) -> Bool { false }
    func composerAccessories(_ chat: ChatContext) -> [PluginView] { [] }
    func replyFooter(_ message: Message, _ chat: ChatContext, _ position: TurnPosition) -> PluginView? { nil }
    func settingsSections(_ scope: SettingsScope) -> [PluginView] { [] }
    func chatChanged(_ chat: ChatContext) async {}
}

/// The plugins linked into this app, and which of them apply where.
@MainActor
public final class PluginHost {
    public static let shared = PluginHost()
    public private(set) var plugins: [any AppPlugin] = []

    /// Called once, before the first window. The first plugin with an id wins.
    public func install(_ list: [any AppPlugin]) {
        var seen: Set<String> = []
        plugins = list.filter { seen.insert($0.id).inserted }
    }

    /// The plugins the engine of `model` carries and has on.
    public func available(on model: AppModel) -> [any AppPlugin] {
        plugins.filter { model.engineHasPlugin($0.id) }
    }

    /// The plugins on for this chat.
    public func active(for chat: ChatContext) -> [any AppPlugin] {
        available(on: chat.model).filter { $0.isActive(for: chat) }
    }

    public func composerAccessories(_ chat: ChatContext) -> [PluginView] {
        active(for: chat).flatMap { $0.composerAccessories(chat) }
    }

    /// The first plugin's footer for the reply, if any takes it over.
    public func replyFooter(_ message: Message, _ chat: ChatContext, _ position: TurnPosition) -> PluginView? {
        for plugin in active(for: chat) {
            if let footer = plugin.replyFooter(message, chat, position) { return footer }
        }
        return nil
    }

    public func settingsSections(_ scope: SettingsScope, on model: AppModel) -> [PluginView] {
        available(on: model).flatMap { $0.settingsSections(scope) }
    }

    /// Whether any plugin is on for this chat, so the transcript knows to work out its turns.
    public func hasActive(for chat: ChatContext) -> Bool { !active(for: chat).isEmpty }
}

/// What keeps `chatChanged` running: the chat, its folder, its state, and whether a plugin applies.
private struct ChatChangeKey: Equatable {
    var threadId: String
    var folder: String?
    var busy: Bool
    var active: [String]
    var engine: [String]
}

extension View {
    /// Tells the plugins that apply when the chat, its folder or its busy state
    /// changes. It goes on a view that is always there: SwiftUI never runs a task
    /// on one that is empty.
    @MainActor
    func pluginsFollowing(_ chat: ChatContext) -> some View {
        let host = PluginHost.shared
        let active = host.active(for: chat)
        let key = ChatChangeKey(threadId: chat.threadId, folder: chat.folder, busy: chat.isBusy, active: active.map(\.id),
                                engine: chat.model.enginePlugins.map { "\($0.id):\($0.enabled)" })
        return task(id: key) {
            for plugin in active { await plugin.chatChanged(chat) }
        }
    }
}
