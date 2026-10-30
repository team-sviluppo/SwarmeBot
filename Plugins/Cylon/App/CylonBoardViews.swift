// The board of a job that touches several repositories, as a tab of the right column of a Cylon channel
// (docs/plans/2026-10-30-tabellone-multirepo.md): its tickets in order of priority (drag to change it), each with the
// phases of its channel, and the way to start them. The engine keeps the board and reads each ticket's state from
// its channel; this shows it and presses the buttons.
import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

enum CylonRoleTitle {
    static func title(_ role: String) -> String {
        switch role {
        case "backend": return tr("Backend")
        case "backoffice": return tr("Backoffice")
        case "app": return tr("App")
        case "bruno": return tr("Collection Bruno")
        default: return role
        }
    }
}

struct CylonBoardPanel: View {
    static let tabId = "cylon.board"
    static let width: CGFloat = 560

    let room: Room
    let state: CylonState
    @Environment(AppModel.self) private var model
    @State private var editing: CylonBoardWire?
    @State private var creating = false
    @State private var adding = false
    @State private var deleting = false
    @State private var replacing: CylonBoardWire.Item?

    private var projectId: String? {
        if case .string(let id)? = (room.plugins ?? [:]).pluginData("code")["projectId"], !id.isEmpty { return id }
        return nil
    }

    private var boards: [CylonBoardWire] { projectId.flatMap { state.boards[$0] } ?? [] }
    private var board: CylonBoardWire? {
        guard let projectId else { return nil }
        return boards.first { $0.id == state.chosenBoard[projectId] } ?? boards.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let projectId {
                header(projectId)
                Rectangle().fill(Theme.hairline.opacity(0.4)).frame(height: 1)
                if let board { content(board, projectId: projectId) } else { empty }
            } else {
                note(tr("Il canale non ha un progetto: sceglilo nelle sue impostazioni (card Code), perché il tabellone è del progetto."))
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: projectId) {
            guard let projectId else { return }
            await state.refreshSettings(model: model)
            while !Task.isCancelled {
                await state.refreshBoards(model: model, projectId: projectId)
                try? await Task.sleep(for: CylonState.pollInterval(state.boards[projectId] ?? []))
            }
        }
        .sheet(isPresented: $creating) { if let projectId { CylonBoardSheet(projectId: projectId, board: nil, state: state) } }
        .sheet(item: $editing) { board in CylonBoardSheet(projectId: board.projectId, board: board, state: state) }
        .sheet(isPresented: $adding) { if let projectId, let board { CylonAddTicketSheet(projectId: projectId, board: board, state: state) } }
        .confirmationDialog(tr("Eliminare il tabellone?"), isPresented: $deleting) {
            Button(tr("Elimina"), role: .destructive) { if let projectId, let board { Task { await state.deleteBoard(model: model, projectId: projectId, id: board.id) } } }
        } message: {
            Text(tr("Si toglie solo l'elenco: i ticket e i flussi dei canali restano dove sono."))
        }
        .confirmationDialog(tr("Sostituire il ticket del canale?"), isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }), presenting: replacing) { item in
            Button(tr("Sostituisci con %@", item.ticketId), role: .destructive) { start(item, replace: true) }
        } message: { item in
            Text(tr("Il canale sta lavorando sul ticket %@: il suo flusso riparte da capo con questo.", item.otherTicket ?? "?"))
        }
    }

    // MARK: header

    private func header(_ projectId: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group").foregroundStyle(Theme.accent)
            if boards.isEmpty {
                Text(tr("Tabellone")).font(.system(size: 13, weight: .semibold))
            } else {
                Picker("", selection: Binding(get: { board?.id ?? "" }, set: { state.chosenBoard[projectId] = $0 })) {
                    ForEach(boards) { Text(verbatim: $0.title).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            if let url = board?.parentUrl.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "link") }
                    .buttonStyle(IconButtonStyle(size: 24, iconSize: 12)).help(tr("Apri il ticket madre"))
            }
            Spacer()
            Button { creating = true } label: { Label(tr("Nuovo tabellone"), systemImage: "plus").fixedSize() }
                .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
            if let board {
                Menu {
                    Button(tr("Modifica…")) { editing = board }
                    Button(tr("Elimina…"), role: .destructive) { deleting = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text(tr("Nessun tabellone")).font(.system(size: 13, weight: .semibold))
            Text(tr("Per un lavoro che tocca più repo: spezzalo in un ticket per repo su ClickUp, poi mettili qui in ordine di priorità."))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Button { creating = true } label: { Label(tr("Nuovo tabellone"), systemImage: "plus").fixedSize() }
                .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: the list

    @ViewBuilder
    private func content(_ board: CylonBoardWire, projectId: String) -> some View {
        if board.items.isEmpty {
            note(tr("Nessun ticket: aggiungine uno per ogni repo del lavoro."))
        } else {
            List {
                ForEach(Array(board.items.enumerated()), id: \.element.id) { index, item in
                    CylonBoardRow(rank: index + 1, item: item, onStart: { start(item, replace: false) }, onReplace: { replacing = item },
                                  onRemove: { Task { await state.actOnBoard(model: model, projectId: projectId) { try await $0.removeCylonBoardItem(board.id, item: item.id) } } })
                        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 12))
                        .listRowSeparatorTint(Theme.hairline.opacity(0.4))
                }
                .onMove { source, destination in
                    let order = CylonBoardOrder.moved(board.items.map(\.id), from: source, to: destination)
                    Task { await state.actOnBoard(model: model, projectId: projectId) { try await $0.updateCylonBoard(board.id, ["order": order]) } }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
        }
        footer(board, projectId: projectId)
    }

    private func footer(_ board: CylonBoardWire, projectId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Theme.hairline.opacity(0.4)).frame(height: 1)
            if let error = state.boardErrors[projectId] { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
            ForEach(board.busyBots) { bot in
                Label(bot.channel.map { tr("%@ sta lavorando nel canale %@: le sue fasi negli altri canali aspettano.", bot.name ?? "?", $0) }
                        ?? tr("%@ sta lavorando in un'altra conversazione: le sue fasi nei canali aspettano.", bot.name ?? "?"), systemImage: "clock")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 8) {
                Text(board.summary.total == 0 ? "" : tr("%@ di %@ con la PR aperta", String(board.summary.prOpen), String(board.summary.total)))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Button { Task { await state.actOnBoard(model: model, projectId: projectId) { try await $0.startCylonBoardItem(board.id, item: nil, replace: false) } } } label: {
                    Label(tr("Avvia il prossimo"), systemImage: "play.fill").fixedSize()
                }
                .buttonStyle(ChipButtonStyle(filled: true, size: 12.5)).disabled(board.summary.notStarted == 0)
                .help(tr("Avvia il primo ticket, nell'ordine di priorità, che nessuno ha ancora avviato"))
                Button { adding = true } label: { Label(tr("Aggiungi ticket…"), systemImage: "plus").fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private func start(_ item: CylonBoardWire.Item, replace: Bool) {
        guard let projectId, let board else { return }
        Task { await state.actOnBoard(model: model, projectId: projectId) { try await $0.startCylonBoardItem(board.id, item: item.id, replace: replace) } }
    }
}

// MARK: - A ticket

private struct CylonBoardRow: View {
    let rank: Int
    let item: CylonBoardWire.Item
    let onStart: () -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void
    @Environment(AppModel.self) private var model

    private func phaseTitle(_ key: String?) -> String { key.map(CylonPhaseKey.title) ?? "" }

    private var running: CylonStatus.Phase? { item.flow?.phases.first { $0.state == "running" } }
    private var failed: CylonStatus.Phase? { item.flow?.phases.first { $0.state == "failed" } }

    /// What the ticket is doing, in words.
    private var status: (text: String, color: Color) {
        switch item.state {
        case "not-started": return (tr("Non avviato"), Theme.tertiary)
        case "ready": return (tr("Prossima: %@", phaseTitle(item.flow?.current?.key)), Theme.secondary)
        case "running": return (tr("%@ in corso", phaseTitle(running?.key)), Theme.accent)
        case "waiting": return (tr("%@: in attesa di te", phaseTitle(running?.key)), Theme.warning)
        case "failed": return (tr("%@ non riuscita", phaseTitle(failed?.key)), Theme.danger)
        case "done": return (tr("Completato"), Theme.success)
        case "other-ticket": return (tr("Il canale lavora sul ticket %@", item.otherTicket ?? "?"), Theme.warning)
        case "channel-missing": return (tr("Il canale non esiste più"), Theme.danger)
        default: return (item.state, Theme.secondary)
        }
    }

    /// Something that keeps the next phase from going out (no bot for it, a skill missing, its bot busy elsewhere).
    private var problem: String? {
        guard ["ready", "not-started"].contains(item.state), let flow = item.flow, let phase = flow.current ?? flow.phases.first(where: { $0.state == "pending" }) else { return nil }
        return CylonState.problem(phase, status: flow) ?? CylonState.busyNote(phase)
    }

    private func icon(_ phase: CylonStatus.Phase) -> (String, Color) {
        switch phase.state {
        case "done": return ("checkmark.circle.fill", Theme.success)
        case "skipped": return ("slash.circle", Theme.tertiary)
        case "failed": return ("xmark.circle.fill", Theme.danger)
        case "running": return ("circle.dotted", Theme.accent)
        default: return ("circle", Theme.tertiary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: String(rank)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondary)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.raised)).help(tr("Priorità: trascina per cambiarla"))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: CylonRoleTitle.title(item.role)).font(.system(size: 13, weight: .semibold))
                    Text(verbatim: item.title ?? item.ticketId).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                    if item.title != nil { Text(verbatim: item.ticketId).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1) }
                }
                HStack(spacing: 8) {
                    if let name = item.channel?.name {
                        Button { model.selection = .room(item.groupId) } label: { Text(verbatim: "#\(name)").font(.system(size: 11.5)) }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent).help(tr("Vai al canale"))
                    }
                    if let flow = item.flow, item.state != "other-ticket", item.state != "channel-missing", item.state != "not-started" {
                        HStack(spacing: 3) {
                            ForEach(flow.phases) { phase in
                                let look = icon(phase)
                                Image(systemName: look.0).font(.system(size: 10)).foregroundStyle(look.1).help(CylonPhaseKey.title(phase.key))
                            }
                        }
                    }
                }
                Text(verbatim: status.text).font(.system(size: 12)).foregroundStyle(status.color)
                if let problem {
                    Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.system(size: 11.5)).foregroundStyle(Theme.warning).lineLimit(2)
                }
                if let url = item.prUrl.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(url) } label: { Label(tr("Apri la PR"), systemImage: "arrow.up.forward.square").font(.system(size: 11.5)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 6)
            if item.state == "not-started" {
                Button(action: onStart) { Label(tr("Avvia"), systemImage: "play.fill").fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5)).disabled(item.channel?.follows != true)
            } else if item.state == "other-ticket" {
                Button(action: onReplace) { Text(tr("Avvia…")).fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5)).help(tr("Il canale lavora su un altro ticket: chiede conferma per sostituirlo"))
            }
            Menu {
                if let url = item.url { Button(tr("Apri su ClickUp")) { NSWorkspace.shared.open(url) } }
                if item.channel != nil { Button(tr("Vai al canale")) { model.selection = .room(item.groupId) } }
                Divider()
                Button(tr("Togli dal tabellone"), role: .destructive, action: onRemove)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Sheets

/// A board's title and the link of its mother ticket: to make one, or to change one.
struct CylonBoardSheet: View {
    let projectId: String
    let board: CylonBoardWire?
    let state: CylonState
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var link = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField(tr("Nome del lavoro"), text: $title, prompt: Text(verbatim: "Login con Google"))
                TextField(tr("Ticket madre su ClickUp (facoltativo)"), text: $link, prompt: Text(verbatim: "https://app.clickup.com/t/…"))
                    .font(.system(size: 12, design: .monospaced))
            } header: {
                Text(board == nil ? tr("Nuovo tabellone") : tr("Modifica il tabellone"))
            } footer: {
                Text(tr("Un ticket per repo, spezzati e collegati su ClickUp da te. Il tabellone li mette in ordine di priorità e li avvia nei canali giusti."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = state.boardErrors[projectId] { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
            HStack {
                Button(tr("Annulla")) { dismiss() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(board == nil ? tr("Crea") : tr("Salva")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped).frame(width: 460)
        .onAppear {
            state.boardErrors[projectId] = nil
            title = board?.title ?? ""
            link = board?.parentUrl ?? ""
        }
    }

    private func save() async {
        busy = true
        let name = title.trimmingCharacters(in: .whitespaces), url = link.trimmingCharacters(in: .whitespaces)
        await state.actOnBoard(model: model, projectId: projectId) { client in
            if let board { return try await client.updateCylonBoard(board.id, ["title": name, "parentUrl": url.isEmpty ? NSNull() : url as Any]) }
            return try await client.createCylonBoard(projectId: projectId, title: name, parentUrl: url)
        }
        busy = false
        if state.boardErrors[projectId] == nil { dismiss() }
    }
}

/// One more ticket on the board: which repository, which ticket, where its flow starts.
struct CylonAddTicketSheet: View {
    let projectId: String
    let board: CylonBoardWire
    let state: CylonState
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var role = ""
    @State private var groupId = ""
    @State private var ticket = ""
    @State private var tag = "cylon-plan"
    @State private var title = ""
    @State private var busy = false

    private var roles: [String] { state.projects.first { $0.id == projectId }?.repos?.map(\.role) ?? [] }
    private var candidates: [Room] { CylonBoardChannels.candidates(rooms: model.state.rooms, projectId: projectId, role: role) }

    var body: some View {
        Form {
            Section {
                Picker(tr("Repo"), selection: $role) {
                    ForEach(roles, id: \.self) { Text(verbatim: CylonRoleTitle.title($0)).tag($0) }
                }
                if candidates.count > 1 {
                    Picker(tr("Canale"), selection: $groupId) { ForEach(candidates) { Text(verbatim: "#\($0.name)").tag($0.id) } }
                } else if let only = candidates.first {
                    LabeledContent(tr("Canale")) { Text(verbatim: "#\(only.name)").foregroundStyle(.secondary) }
                } else if !role.isEmpty {
                    Label(tr("Nessun canale con Cylon attivo lavora su %@: creane uno e scegli il progetto e «Lavora su» nelle sue impostazioni.", CylonRoleTitle.title(role)),
                          systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.warning)
                }
                TextField(tr("Ticket ClickUp"), text: $ticket, prompt: Text(verbatim: "86c2x9k")).font(.system(size: 12, design: .monospaced))
                Picker(tr("Il ticket ha il tag"), selection: $tag) {
                    Text(verbatim: "cylon-plan").tag("cylon-plan")
                    Text(verbatim: "cylon-spec").tag("cylon-spec")
                }
                TextField(tr("Nome (facoltativo)"), text: $title)
            } header: {
                Text(tr("Aggiungi un ticket"))
            } footer: {
                Text(tr("Con cylon-spec il flusso parte dalla specifica, con cylon-plan dal piano. L'ordine di priorità si cambia poi trascinando."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = state.boardErrors[projectId] { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
            HStack {
                Button(tr("Annulla")) { dismiss() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(tr("Aggiungi")) { Task { await add() } }
                    .keyboardShortcut(.defaultAction).disabled(busy || role.isEmpty || candidates.isEmpty || ticket.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped).frame(width: 480)
        .onAppear {
            state.boardErrors[projectId] = nil
            if role.isEmpty { role = roles.first ?? "" }
        }
        .onChange(of: role) { _, _ in groupId = candidates.first?.id ?? "" }
    }

    private func add() async {
        busy = true
        let chosen = candidates.count > 1 ? groupId : nil
        await state.actOnBoard(model: model, projectId: projectId) {
            try await $0.addCylonBoardItem(board.id, role: role, ticket: ticket.trimmingCharacters(in: .whitespaces), tag: tag, title: title.trimmingCharacters(in: .whitespaces), groupId: chosen)
        }
        busy = false
        if state.boardErrors[projectId] == nil { dismiss() }
    }
}
