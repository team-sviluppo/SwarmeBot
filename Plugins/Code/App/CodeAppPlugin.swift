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

    /// On for a bot with its switch, and for a channel with its own (a channel of this engine only).
    public func isActive(for chat: ChatContext) -> Bool {
        if let room = chat.room { return room.codeMode == true && room.guests?.isEmpty != false && room.guest == nil }
        return chat.bot?.codeMode == true
    }

    public func composerAccessories(_ chat: ChatContext) -> [PluginView] {
        guard let code = CodeChat(chat) else { return [] }
        var chips = [PluginView(GitBranchChip(chat: code, state: state))]
        if code.kind == .room { chips.insert(PluginView(CodeContextMeter(chat: code)), at: 0) }
        if state.engineHasGitSync(chat.model) { chips.append(PluginView(CodeSyncChip(chat: code, state: state))) }
        if state.engineHasPhase4(chat.model) {
            chips.append(PluginView(CodePullRequestChip(chat: code, state: state)))
        }
        chips += [PluginView(CodeModeTerminalButton(chat: code, state: state)), PluginView(CodeOpenMenu(chat: code, state: state))]
        if state.engineHasWorkflow(chat.model) {
            chips.append(PluginView(CodeFilePicker(chat: code, state: state)))
            chips.append(PluginView(CodeShortcuts()))
        }
        if state.engineHasPhase3(chat.model) {
            chips.append(PluginView(CodeGitSummary(state: state, thread: chat.threadId)))
            chips.append(PluginView(CodeScriptButton(state: state, thread: chat.threadId)))
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
        guard let code = CodeChat(chat), state.engineHasWorkflow(chat.model) else { return [] }
        return [PluginTab(id: CodeDiffPanel.tabId, title: tr("Diff"), icon: "plus.forwardslash.minus", width: CodeDiffPanel.width,
                          content: PluginView(CodeDiffPanel(chat: code, state: state)))]
    }

    public func bottomPanels(_ chat: ChatContext) -> [PluginView] {
        guard state.engineHasPhase3(chat.model), state.scriptPanels.contains(chat.threadId) else { return [] }
        return [PluginView(CodeScriptPanel(state: state, thread: chat.threadId))]
    }

    public func chatColumn(_ chat: ChatContext) -> PluginView? {
        guard let bot = chat.bot, state.engineHasPhase3(chat.model) else { return nil }
        let key = (chat.model.activeRemoteEngine?.id ?? "local") + "." + bot.id
        return PluginView(CodeChatColumn(bot: bot, state: state, preferenceKey: key).id(key))
    }

    public func chatNavigation(_ chat: ChatContext) -> PluginView? {
        guard let bot = chat.bot, state.engineHasPhase3(chat.model) else { return nil }
        let key = (chat.model.activeRemoteEngine?.id ?? "local") + "." + bot.id
        return PluginView(CodeChatToggle(preferenceKey: key).id(key))
    }

    public func commands(_ model: AppModel) async -> [PluginCommand] {
        guard state.engineHasPhase3(model) else { return [] }
        struct Recent: Decodable { var botId: String; var threadId: String; var title: String; var name: String }
        struct Answer: Decodable { var chats: [Recent] }
        let recent = try? await model.client?.pluginRequest("GET", "/api/code/chats/recent", as: Answer.self)
        var commands = (recent?.chats ?? []).map { chat in
            PluginCommand(id: "code.chat.\(chat.threadId)", section: tr("Chat Code recenti"), title: chat.title, detail: chat.name, icon: "bubble.left") {
                Task { await model.openTask(botId: chat.botId, threadId: chat.threadId) }
            }
        }
        if let bot = model.selectedBot, bot.codeMode == true {
            commands.append(PluginCommand(id: "code.new-chat", section: tr("Comandi"), title: tr("Nuova chat"), icon: "plus") { Task { await model.createTask(title: nil) } })
        }
        if isActive(for: .current(model)) {
            commands.append(PluginCommand(id: "code.branch", section: tr("Comandi"), title: tr("Cambia branch"), icon: "arrow.triangle.branch") { self.state.branchPickerRequest += 1 })
            commands.append(PluginCommand(id: "code.scripts", section: tr("Comandi"), title: tr("Mostra output degli script"), icon: "play.rectangle") {
                if let thread = model.selectedThreadId { self.state.scriptPanels.insert(thread) }
            })
        }
        return commands
    }

    /// In a Code chat a reply gets a badge where its turn ends and nothing in the
    /// middle of it, in place of a card per file; the newest turn waits for the bot to be idle.
    public func replyFooter(_ message: Message, _ chat: ChatContext, _ position: TurnPosition) -> PluginView? {
        // another bot's review of the changes: not a turn of this chat, and it can be applied
        if message.review != nil, let code = CodeChat(chat) { return PluginView(CodeReviewFooter(message: message, chat: code, state: state)) }
        guard position.isTurnEnd, !(position.isLatest && chat.isBusy), let code = CodeChat(chat) else { return PluginView(EmptyView()) }
        // in a channel the badge says who spoke: one of them worked, the others read
        let badge = CodeModeBadge(message: message, chat: code, latest: position.isLatest, state: state,
                                  author: chat.room != nil ? message.from?.name : nil)
        // the newest reply of a chat in Plan mode is a plan to approve
        if position.isLatest, state.mode(of: chat.threadId) == .plan {
            return PluginView(VStack(alignment: .leading, spacing: 8) { badge; CodePlanApproval(chat: code, state: state) })
        }
        return PluginView(badge)
    }

    public func settingsSections(_ scope: SettingsScope) -> [PluginView] {
        switch scope {
        case let .bot(bot): return [PluginView(CodeBotSettings(bot: bot, state: state))]
        case .global: return [PluginView(CodeProjectsSettings(state: state)), PluginView(CodeGlobalSettings(state: state))]
        case let .room(room): return [PluginView(CodeRoomSettings(room: room, state: state))]
        }
    }

    public func chatChanged(_ chat: ChatContext) async {
        await state.refreshGit(model: chat.model, threadId: chat.threadId)
        await state.refreshResume(model: chat.model, threadId: chat.threadId)
        await state.refreshMode(model: chat.model, threadId: chat.threadId)
        // a turn that ended may have pushed: ask GitHub again rather than wait for the next round
        await state.refreshPullRequest(model: chat.model, threadId: chat.threadId, refresh: !chat.isBusy)
    }
}

/// The bot's switch for the plugin: the same `codeMode` flag every client reads.
private struct CodeBotSettings: View {
    let bot: Bot
    let state: CodeState
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
            if state.engineHasProjects(model) {
                CardDivider(leading: 48)
                CodeProjectRows(owner: .bot(bot), state: state)
            }
        }
        .task { await state.refreshProjects(model: model) }
    }
}

/// A channel's own: Code mode for all its members, and the project it belongs to, which counts over its members'.
private struct CodeRoomSettings: View {
    let room: Room
    let state: CodeState
    @Environment(AppModel.self) private var model

    /// A guest works on its own engine and its own folders: there is no one folder for the channel.
    private var mixed: Bool { room.guest != nil || room.guests?.isEmpty == false }
    private var hasFolder: Bool { (room.pinnedCwd ?? room.cwd)?.isEmpty == false }

    var body: some View {
        if state.engineHasChannels(model) || state.engineHasProjects(model) {
            SettingsCard(tr("Code")) {
                if state.engineHasChannels(model) {
                    SettingRow(icon: "chevron.left.forwardslash.chevron.right", tint: Theme.accent, title: tr("Code mode"),
                               subtitle: mixed ? tr("Non disponibile in un canale con membri di altri motori.") : !hasFolder ? tr("Scegli prima una cartella condivisa per il canale.")
                                   : tr("Tutti i membri lavorano nella cartella del canale, uno alla volta: il branch, i file modificati, il diff e il commit sono di tutti.")) {
                        Toggle("", isOn: Binding(get: { room.codeMode ?? false }, set: { next in
                            Task {
                                var patch = RoomPatch()
                                patch.codeMode = next
                                await model.patch(room, patch)
                            }
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .tint(Theme.accent)
                        .disabled(mixed || (!hasFolder && room.codeMode != true))
                    }
                }
                if state.engineHasProjects(model) {
                    if state.engineHasChannels(model) { CardDivider(leading: 48) }
                    CodeProjectRows(owner: .room(room), state: state)
                }
            }
            .task { await state.refreshProjects(model: model) }
        }
    }
}
