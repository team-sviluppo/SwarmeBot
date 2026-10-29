// The Code plugin, app side (docs/plans/2026-10-28-code-mode-t3.md §12): the
// git branch and a terminal under the composer, the files a turn changed at
// its end, and the bot's switch. The engine side is CodePluginEngine; this
// shows only for an engine that carries it.
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

@MainActor
public final class CodeAppPlugin: AppPlugin {
    public let id = "code"
    public let name = "Code"
    let state = CodeState()

    public init() {}

    public func isActive(for chat: ChatContext) -> Bool { chat.bot?.codeMode == true }

    public func composerAccessories(_ chat: ChatContext) -> [PluginView] {
        guard let bot = chat.bot else { return [] }
        var chips = [PluginView(GitBranchChip(bot: bot, state: state)), PluginView(CodeModeTerminalButton(bot: bot, state: state)),
                     PluginView(CodeOpenMenu(bot: bot, state: state))]
        if state.engineHasWorkflow(chat.model) {
            chips.append(PluginView(CodeFilePicker(bot: bot, state: state)))
            chips.append(PluginView(CodeShortcuts()))
        }
        return chips
    }

    public func composerChips(_ chat: ChatContext) -> [PluginView] {
        (state.references[chat.threadId] ?? []).map { PluginView(FileReferenceChip(file: $0, state: state, threadId: chat.threadId)) }
    }

    /// The files are named after the message, for the agent; they go with this message and no other.
    public func outgoingText(_ text: String, _ chat: ChatContext) -> String {
        let files = state.takeReferences(threadId: chat.threadId)
        return files.isEmpty ? text : text + "\n\n" + CodeState.referencesBlock(files)
    }

    /// A file of this Mac inside the chat's folder is a reference; one from elsewhere is attached as usual.
    public func claimDroppedFiles(_ urls: [URL], _ chat: ChatContext) -> [URL] {
        guard !chat.model.isRemote, state.engineHasWorkflow(chat.model) else { return [] }
        let git = state.gitStates[chat.threadId]
        let claimed = DroppedFiles.claimable(urls, folders: [git?.root, git?.folder].compactMap { $0 })
        for url in claimed { state.addReference(FileReference(path: url.path), threadId: chat.threadId) }
        return claimed
    }

    public func inspectorTabs(_ chat: ChatContext) -> [PluginTab] {
        guard let bot = chat.bot, state.engineHasWorkflow(chat.model) else { return [] }
        return [PluginTab(id: CodeDiffPanel.tabId, title: tr("Diff"), icon: "plus.forwardslash.minus", width: CodeDiffPanel.width,
                          content: PluginView(CodeDiffPanel(bot: bot, state: state)))]
    }

    /// In a Code chat a reply gets a badge where its turn ends and nothing in the
    /// middle of it, in place of a card per file; the newest turn waits for the bot to be idle.
    public func replyFooter(_ message: Message, _ chat: ChatContext, _ position: TurnPosition) -> PluginView? {
        guard position.isTurnEnd, !(position.isLatest && chat.isBusy) else { return PluginView(EmptyView()) }
        return PluginView(CodeModeBadge(message: message, threadId: chat.threadId, latest: position.isLatest, state: state))
    }

    public func settingsSections(_ scope: SettingsScope) -> [PluginView] {
        switch scope {
        case let .bot(bot): return [PluginView(CodeBotSettings(bot: bot))]
        case .global: return [PluginView(CodeGlobalSettings(state: state))]
        case .room: return []
        }
    }

    public func chatChanged(_ chat: ChatContext) async {
        await state.refreshGit(model: chat.model, threadId: chat.threadId)
        await state.refreshResume(model: chat.model, threadId: chat.threadId)
    }
}

/// The bot's switch for the plugin: the same `codeMode` flag every client reads.
private struct CodeBotSettings: View {
    let bot: Bot
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsCard(tr("Code")) {
            SettingRow(icon: "chevron.left.forwardslash.chevron.right", tint: Theme.accent, title: tr("Code mode"),
                       subtitle: tr("Mostra il branch git accanto alla cartella e raccoglie i file modificati a fine turno in un badge.")) {
                Toggle("", isOn: Binding(get: { bot.codeMode ?? false }, set: { next in Task { await model.patch(bot, BotPatch(codeMode: next)) } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
        }
    }
}
