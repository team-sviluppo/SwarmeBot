import CompanionCore
import SwarmeKit
import SwiftUI

/// Above the transcript (`ChatView.tsx` header): 50 pt, avatar 22 + title
/// + Chief of Staff badge on the left; on the right Stop, the task picker,
/// pin, export, usage, folder, the model pill, computer and inspector.
struct ChatHeader: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: BotTask?
    @State private var title = ""
    @State private var showRoomSettings = false
    @State private var ui = UIState.shared

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                if let bot = model.selectedBot {
                    BotAvatar(bot: bot, size: 22, state: SwarmeState.forBot(bot, last: model.visibleTranscript(bot.threadId).last), priority: true)
                        .padding(2)
                    Text(bot.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if bot.chiefOfStaff == true {
                        Label(tr("Chief of Staff"), systemImage: "crown.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    }
                    if model.isBusy(bot) { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                } else if let room = model.selectedRoom {
                    Image(systemName: "number").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    Text(room.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(tr("%@ membri", String(room.memberIds.count + (room.guests?.count ?? 0)))).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    if room.busyBotId != nil { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            Spacer(minLength: 8)
            if busy {
                Button { Task { await model.interrupt() } } label: {
                    Label { Text(tr("Stop")) } icon: { Image(systemName: "stop.fill").font(.system(size: 10)) }
                }
                .buttonStyle(ChipButtonStyle(filled: true, size: 13, tint: Theme.danger))
                .help(tr("Interrompi (⌘.)"))
            }
            if let bot = model.selectedBot {
                Button(tr("Nuova chat")) { Task { await model.createTask(title: nil) } }
                    .buttonStyle(ChipButtonStyle(filled: false, size: 13))
                    .disabled(model.isBusy(bot))
                    .help(tr("Apri una chat nuova"))
                taskMenu(bot)
                Button {
                    Task { await model.patch(bot, BotPatch(pinned: !(bot.pinned ?? false))) }
                } label: { Image(systemName: bot.pinned == true ? "pin.fill" : "pin") }
                    .buttonStyle(IconButtonStyle(size: 28, iconSize: 14, active: bot.pinned == true))
                    .help(bot.pinned == true ? tr("Rimuovi dai fissati") : tr("Fissa in alto"))
                exportButton(bot.threadId)
                if let chip = usageChip(currentTask(bot)?.usage) {
                    Text(chip.text)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.raised.opacity(0.6)))
                        .overlay(Capsule().stroke(Theme.hairline.opacity(0.4)))
                        .help(chip.help)
                }
                if let limit = model.instance(bot.modelSelection.instanceId)?.usageLimit, limit.isCurrent() {
                    SessionLimitChip(limit: limit)
                }
                Button { toggle(.computer) } label: { Image(systemName: "display") }
                    .buttonStyle(IconButtonStyle(size: 30, iconSize: 16, active: ui.showInspector && ui.inspectorTab == .computer))
                    .help(tr("Computer"))
            } else if let room = model.selectedRoom {
                Button { showRoomSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(IconButtonStyle(size: 28, iconSize: 15))
                    .help(tr("Impostazioni canale"))
                    .sheet(isPresented: $showRoomSettings) { RoomSettingsSheet(room: room) }
                exportButton(room.threadId)
            }
            Button { toggle(nil) } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(IconButtonStyle(size: 30, iconSize: 16, active: ui.showInspector && ui.inspectorTab != .computer))
                .help(tr("Pannello (⌥⌘I)"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 50)
        .alert(tr("Rinomina task"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(tr("Titolo"), text: $title)
            Button(tr("Salva")) {
                if let task = renaming { Task { await model.renameTask(task, title: title) } }
            }
            Button(tr("Annulla"), role: .cancel) {}
        }
    }

    private var busy: Bool {
        if let bot = model.selectedBot { return model.isBusy(bot) }
        return model.selectedRoom?.busyBotId != nil
    }

    private func toggle(_ tab: InspectorView.Tab?) {
        if let tab {
            if ui.showInspector && ui.inspectorTab == tab { ui.showInspector = false } else { ui.inspectorTab = tab; ui.showInspector = true }
        } else {
            if ui.inspectorTab == .computer { ui.inspectorTab = .details }
            ui.showInspector.toggle()
        }
    }

    private func currentTask(_ bot: Bot) -> BotTask? {
        bot.tasks?.first { $0.threadId == bot.threadId }
    }

    /// Cost of the chat, and the average reply speed when output tokens and
    /// the time spent writing them are both known.
    private func usageChip(_ usage: TaskUsage?) -> (text: String, help: String)? {
        guard let usage else { return nil }
        var parts: [String] = []
        var notes: [String] = []
        if let cost = usage.costUsd, cost > 0 {
            parts.append(String(format: "$%.2f", cost))
            notes.append(tr("Costo del task"))
        }
        if let rate = usage.tokensPerSecond {
            parts.append(Self.formatRate(rate))
            let estimated = usage.estimatedOutput ?? 0
            let timed = usage.timedOutput ?? 0
            if estimated <= 0 {
                notes.append(tr("Velocità media di risposta"))
            } else if timed > 0, estimated >= timed - 0.01 {
                notes.append(tr("Velocità stimata dal testo"))
            } else {
                notes.append(tr("Velocità media di risposta, in parte stimata"))
            }
        }
        guard !parts.isEmpty else { return nil }
        return (parts.joined(separator: " · "), notes.joined(separator: " · "))
    }

    private static func formatRate(_ rate: Double) -> String {
        if rate >= 10 { return String(format: "%.0f tok/s", rate.rounded()) }
        return String(format: "%.1f tok/s", rate)
    }

    private func exportButton(_ threadId: String) -> some View {
        Button {
            Task {
                guard let export = await model.export(threadId: threadId) else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = export.filename
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try? export.data.write(to: url)
            }
        } label: { Image(systemName: "square.and.arrow.up") }
            .buttonStyle(IconButtonStyle(size: 28, iconSize: 14))
            .help(tr("Esporta conversazione"))
    }

    /// The current chat's title; opens the list of this bot's chats.
    private func taskMenu(_ bot: Bot) -> some View {
        TaskPickerButton(bot: bot) { task in
            title = task.title
            renaming = task
        }
    }
}

private struct TaskPickerButton: View {
    let bot: Bot
    let rename: (BotTask) -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        let tasks = bot.tasks ?? []
        let current = tasks.first { $0.threadId == bot.threadId }
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(current?.title ?? tr("Chat")).lineLimit(1).frame(maxWidth: 160)
                if tasks.count > 1 { Text(verbatim: "\(tasks.count)").opacity(0.6) }
                if current?.pinned == true { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.accent) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.system(size: 12.5))
            .foregroundStyle(hovering || open ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(hovering || open ? Theme.raised : .clear))
            .overlay(Capsule().stroke(Theme.hairline.opacity(0.4)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(tr("Chat di questo bot"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TaskList(bot: bot, close: { open = false }, rename: { task in
                open = false
                rename(task)
            })
        }
    }
}

/// Every chat of the bot, newest first: click to open, and on hover pin or
/// delete. Delete asks once more in place, because it takes the messages too.
private struct TaskList: View {
    let bot: Bot
    let close: () -> Void
    let rename: (BotTask) -> Void
    @Environment(AppModel.self) private var model
    @State private var confirming: String?

    var body: some View {
        let tasks = (bot.tasks ?? []).sorted { ($0.pinned == true ? 1 : 0, $0.createdAt) > ($1.pinned == true ? 1 : 0, $1.createdAt) }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Chat")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(verbatim: "\(tasks.count)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button {
                    close()
                    Task { await model.createTask(title: nil) }
                } label: {
                    Label(tr("Nuova"), systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(ChipButtonStyle(filled: true))
                .disabled(model.isBusy(bot))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(tasks, id: \.threadId) { task in
                        row(task, deletable: tasks.count > 1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
        .background(Theme.card)
    }

    private func row(_ task: BotTask, deletable: Bool) -> some View {
        let current = task.threadId == bot.threadId
        let pinned = task.pinned == true
        let canDelete = deletable && !pinned && !(current && model.isBusy(bot))
        return TaskRow(
            task: task, current: current, confirming: confirming == task.threadId, canDelete: canDelete,
            open: {
                confirming = nil
                if !current { Task { await model.switchTask(task) } }
                close()
            },
            pin: { Task { await model.setTaskPinned(task, !pinned) } },
            rename: { rename(task) },
            delete: {
                if confirming == task.threadId {
                    confirming = nil
                    Task { await model.deleteTask(task) }
                } else {
                    confirming = task.threadId
                }
            }
        )
    }
}

private struct TaskRow: View {
    let task: BotTask
    let current: Bool
    let confirming: Bool
    let canDelete: Bool
    let open: () -> Void
    let pin: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: current ? "checkmark" : "bubble.left")
                .font(.system(size: 11, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? Theme.accent : Theme.tertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.system(size: 13, weight: current ? .medium : .regular))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Text(Date(timeIntervalSince1970: task.createdAt / 1000).appRelative())
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 4)
            if confirming {
                Button(tr("Elimina"), action: delete)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.dangerInk)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.danger))
            } else if hovering {
                Button(action: rename) { Image(systemName: "pencil") }
                    .buttonStyle(IconButtonStyle(size: 24, iconSize: 12))
                    .help(tr("Rinomina"))
                Button(action: pin) { Image(systemName: task.pinned == true ? "pin.slash" : "pin") }
                    .buttonStyle(IconButtonStyle(size: 24, iconSize: 12))
                    .help(task.pinned == true ? tr("Sblocca") : tr("Fissa: non si può eliminare"))
                Button(action: delete) { Image(systemName: "trash") }
                    .buttonStyle(IconButtonStyle(size: 24, iconSize: 12))
                    .disabled(!canDelete)
                    .opacity(canDelete ? 1 : 0.35)
                    .help(canDelete ? tr("Elimina chat") : tr("Le chat fissate, l'ultima rimasta e quella in corso non si eliminano"))
            } else if task.pinned == true {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .hoverHighlight(selected: current, radius: 8)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
    }
}

/// Name, bulletin, members and who answers by default.
struct RoomSettingsSheet: View {
    let room: Room
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bulletin = ""
    @State private var members: Set<String> = []
    @State private var guests: Set<String> = []
    @State private var responder = "mentions"
    @State private var responderBot = ""
    @State private var folder = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            TextField(tr("Nome"), text: $name)
            Section {
                // a real multi-line editor: the instructions can be long
                TextEditor(text: $bulletin)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 240)
            } header: {
                Text(tr("Istruzioni del canale"))
            } footer: {
                Text(tr("Le leggono tutti i membri a ogni turno, insieme alle loro istruzioni."))
            }
            Picker(tr("Risponde"), selection: $responder) {
                Text(tr("Solo chi è @menzionato")).tag("mentions")
                Text(tr("Tutti")).tag("everyone")
                Text(tr("Un membro")).tag("member")
            }
            if responder == "member" {
                Picker(tr("Membro"), selection: $responderBot) {
                    ForEach(memberBots) { Text($0.name).tag($0.id) }
                    ForEach(chosenGuests, id: \.memberId) { Text(verbatim: $0.name).tag($0.memberId) }
                }
            }
            RoomFolderField(folder: $folder, locked: room.pinnedCwd != nil)
            Section(tr("Membri")) {
                ForEach(model.state.bots.filter { $0.hidden != true }) { bot in
                    Toggle(bot.name, isOn: Binding(
                        get: { members.contains(bot.id) },
                        set: { if $0 { members.insert(bot.id) } else { members.remove(bot.id) } }
                    ))
                }
            }
            if room.guest == nil { GuestSections(selected: $guests, known: room.guests ?? []) }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 680)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(tr("Elimina canale"), role: .destructive) { confirmDelete = true }
            }
            ToolbarItem(placement: .cancellationAction) { Button(tr("Annulla")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("Salva")) {
                    let patch = RoomPatch(
                        name: name, bulletin: bulletin, memberIds: members.isEmpty ? nil : Array(members),
                        responder: responder, responderBotId: responder == "member" ? responderBot : nil,
                        // once the first turn has pinned it the folder cannot move
                        cwd: room.pinnedCwd == nil && folder != (room.cwd ?? "") ? folder : nil,
                        guests: room.guest == nil && guests != Set((room.guests ?? []).map(\.memberId)) ? chosenGuests : nil
                    )
                    Task { await model.patch(room, patch) }
                    dismiss()
                }
                .disabled((members.isEmpty && guests.isEmpty)
                          || (responder == "member" && !members.contains(responderBot) && !guests.contains(responderBot)))
            }
        }
        .confirmationDialog(tr("Eliminare #%@?", room.name), isPresented: $confirmDelete) {
            Button(tr("Elimina"), role: .destructive) {
                Task { await model.delete(room) }
                dismiss()
            }
        }
        .onAppear {
            name = room.name
            bulletin = room.bulletin
            members = Set(room.memberIds)
            guests = Set((room.guests ?? []).map(\.memberId))
            responder = room.defaultResponder.kind
            responderBot = room.defaultResponder.botId ?? room.memberIds.first ?? ""
            folder = room.pinnedCwd ?? room.cwd ?? ""
        }
    }

    private var memberBots: [Bot] { members.compactMap { model.state.bot($0) } }

    /// The guests ticked: the ones the room has keep their names, new ones come from the servers.
    private var chosenGuests: [RoomGuest] {
        let kept = (room.guests ?? []).filter { guests.contains($0.memberId) }
        let added = model.roomGuests(guests.subtracting(kept.map(\.memberId)))
        return kept + added
    }
}

/// Bots of the remote servers, by server, to add to a channel of this Mac as
/// guests: they answer from their server, in their own folders there.
struct GuestSections: View {
    @Binding var selected: Set<String>
    /// The room's guests, shown even when their server is offline.
    var known: [RoomGuest] = []
    @Environment(AppModel.self) private var model

    var body: some View {
        let candidates = model.guestCandidates
        let offline = known.filter { guest in !candidates.contains { $0.engine.id == guest.peerId && $0.bots.contains { $0.id == guest.botId } } }
        ForEach(candidates, id: \.engine.id) { entry in
            Section {
                ForEach(entry.bots) { bot in
                    let id = RoomGuest(peerId: entry.engine.id, botId: bot.id, name: bot.name, color: bot.color).memberId
                    Toggle(isOn: Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } })) {
                        HStack {
                            BotAvatar(bot: bot, size: 28, animated: false)
                            Text(bot.name)
                        }
                    }
                }
            } header: {
                Text(tr("Ospiti da %@", entry.engine.name))
            } footer: {
                Text(tr("Rispondono dal loro server e lavorano nelle loro cartelle: la cartella del canale vale solo per i bot di questo Mac."))
            }
        }
        if !offline.isEmpty {
            Section(tr("Ospiti non raggiungibili")) {
                ForEach(offline, id: \.memberId) { guest in
                    Toggle(guest.name, isOn: Binding(get: { selected.contains(guest.memberId) },
                                                     set: { if $0 { selected.insert(guest.memberId) } else { selected.remove(guest.memberId) } }))
                }
            }
        }
    }
}

/// The channel's working folder: where every member's tools run. Chosen with
/// the system panel on this Mac, typed as a path on a remote engine.
private struct RoomFolderField: View {
    @Binding var folder: String
    /// The first turn already pinned it.
    let locked: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if model.isRemote && !locked {
                TextField(tr("Percorso della cartella sul server"), text: $folder)
            } else {
                LabeledContent(tr("Cartella del canale")) {
                    HStack(spacing: 8) {
                        Text(folder.isEmpty ? tr("Una per ogni bot") : (folder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if !locked {
                            Button(tr("Scegli…"), action: choose)
                            if !folder.isEmpty { Button(tr("Rimuovi")) { folder = "" } }
                        }
                    }
                }
            }
        } footer: {
            Text(locked ? tr("Fissata al primo messaggio: non si può più cambiare.")
                        : tr("Tutti i bot del canale lavorano in questa cartella. Si fissa al primo messaggio."))
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Scegli")
        panel.message = tr("Cartella di lavoro di tutti i bot del canale")
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
    }
}

/// Pick members and a name; the harness names it after the first member
/// when the name is empty.
struct NewRoomSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: Set<String> = []
    @State private var guests: Set<String> = []
    @State private var folder = ""

    var body: some View {
        Form {
            TextField(tr("Nome (facoltativo)"), text: $name)
            RoomFolderField(folder: $folder, locked: false)
            Section(tr("Membri")) {
                ForEach(model.state.bots.filter { $0.hidden != true }) { bot in
                    Toggle(isOn: Binding(
                        get: { members.contains(bot.id) },
                        set: { if $0 { members.insert(bot.id) } else { members.remove(bot.id) } }
                    )) {
                        HStack {
                            BotAvatar(bot: bot, size: 28, animated: false)
                            Text(bot.name)
                        }
                    }
                }
            }
            GuestSections(selected: $guests)
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(tr("Annulla")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("Crea")) {
                    let ordered = model.state.bots.map(\.id).filter(members.contains)
                    let chosen = model.roomGuests(guests)
                    Task { await model.createRoom(name: name, memberIds: ordered, cwd: folder, guests: chosen) }
                    dismiss()
                }
                .disabled(members.isEmpty && guests.isEmpty)
            }
        }
    }
}

/// How much of the subscription's session window (five hours) is used:
/// green under 50%, yellow up to 80%, red past it.
private struct SessionLimitChip: View {
    let limit: UsageLimit
    /// Theme.warning is orange; this reads as yellow.
    private static let yellow = Theme.caution

    var body: some View {
        let percent = Int((limit.utilization * 100).rounded())
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(verbatim: "\(percent)%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.35)))
        .help(help(percent))
    }

    private var color: Color {
        limit.utilization < 0.5 ? Theme.success : limit.utilization <= 0.8 ? Self.yellow : Theme.danger
    }

    private func help(_ percent: Int) -> String {
        var text = tr("Sessione di 5 ore dell'abbonamento: %@% usato", String(percent))
        if let reset = limit.resetDate {
            text += tr(", si azzera alle %@", reset.appFormatted(date: .omitted, time: .shortened))
        }
        return text
    }
}
