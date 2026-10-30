import AppKit
import CompanionCore
import SwarmeBotUI
import SwarmeKit
import SwiftUI

// MARK: - The bar

/// Above the composer of a channel that follows the flow: the five phases, where the ticket is, and what to
/// send next. The engine keeps the state; this asks for it and presses the buttons.
struct CylonPhaseBar: View {
    let room: Room
    let state: CylonState
    @Environment(AppModel.self) private var model
    @State private var starting = false
    @State private var resetting = false
    @State private var open: String?
    @State private var folder = ""

    private var status: CylonStatus? { state.statuses[room.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let status, status.pipeline != nil {
                HStack(spacing: 6) {
                    ForEach(Array(status.phases.enumerated()), id: \.element.id) { index, phase in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.tertiary) }
                        phaseChip(phase, status: status)
                    }
                    Spacer(minLength: 0)
                }
                if let current = status.current { currentLine(current, status: status) }
            }
            if let error = state.errors[room.id] {
                Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 6)
        .task(id: room.id) {
            while !Task.isCancelled {
                await state.refresh(model: model, groupId: room.id)
                try? await Task.sleep(for: CylonState.pollInterval(state.statuses[room.id]))
            }
        }
        .sheet(isPresented: $starting) { CylonStartSheet(room: room, state: state) }
        .confirmationDialog(tr("Chiudere il flusso di questo ticket?"), isPresented: $resetting) {
            Button(tr("Chiudi il flusso"), role: .destructive) { Task { await state.act(model: model, groupId: room.id) { try await $0.cylonReset(groupId: room.id) } } }
        } message: {
            Text(tr("Lo stato delle fasi si cancella. I file del task e la chat restano dove sono."))
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.accent)
            Text(tr("Flusso Cylon")).font(.system(size: 12.5, weight: .semibold))
            if let pipeline = status?.pipeline {
                Text(verbatim: pipeline.title ?? pipeline.ticketId).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                if let slug = pipeline.slug {
                    Text(verbatim: "cylon-features/\(slug)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                if let url = pipeline.prUrl.flatMap(URL.init(string:)) {
                    Button { NSWorkspace.shared.open(url) } label: { Label(tr("Apri la PR"), systemImage: "arrow.up.forward.square").fixedSize() }
                        .buttonStyle(ChipButtonStyle(filled: true, size: 12))
                }
            }
            Spacer()
            if status?.pipeline == nil {
                Button { starting = true } label: { Label(tr("Avvia un ticket…"), systemImage: "play.circle").fixedSize() }
                    .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                    .disabled(status?.busy == true)
            } else {
                Menu {
                    Button(tr("Nuovo ticket…")) { starting = true }
                    Button(tr("Chiudi il flusso…"), role: .destructive) { resetting = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    // MARK: phases

    private func icon(_ phase: CylonStatus.Phase) -> (String, Color) {
        switch phase.state {
        case "done": return ("checkmark.circle.fill", Theme.success)
        case "skipped": return ("slash.circle", Theme.tertiary)
        case "failed": return ("xmark.circle.fill", Theme.danger)
        case "running": return ("circle.dotted", Theme.accent)
        default: return (phase.current == true ? "circle.inset.filled" : "circle", phase.current == true ? Theme.accent : Theme.tertiary)
        }
    }

    private func phaseChip(_ phase: CylonStatus.Phase, status: CylonStatus) -> some View {
        let look = icon(phase)
        return Button { open = phase.key } label: {
            HStack(spacing: 5) {
                if phase.state == "running", status.busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: look.0).foregroundStyle(look.1) }
                Text(verbatim: CylonPhaseKey.title(phase.key))
                    .font(.system(size: Theme.uiSize, weight: phase.current == true ? .semibold : .medium))
                    .foregroundStyle(phase.state == "skipped" ? Theme.tertiary : Theme.secondary)
                    .strikethrough(phase.state == "skipped")
                if CylonState.problem(phase, status: status) != nil, phase.state != "done", phase.state != "skipped" {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.warning)
                }
            }
            .fixedSize()
        }
        .buttonStyle(ChipButtonStyle(filled: phase.current == true, size: Theme.uiSize))
        .popover(isPresented: Binding(get: { open == phase.key }, set: { if !$0 { open = nil } })) { details(phase, status: status) }
    }

    /// Under the chips: what the next phase is, who does it, and the button.
    private func currentLine(_ phase: CylonStatus.Phase, status: CylonStatus) -> some View {
        HStack(spacing: 8) {
            let problem = CylonState.problem(phase, status: status)
            if let bot = phase.bot, problem == nil {
                Text(phase.state == "running" ? tr("%@ sta lavorando a: %@", bot.name ?? "?", CylonPhaseKey.title(phase.key)) : tr("Prossima: %@ · %@", CylonPhaseKey.title(phase.key), bot.name ?? "?"))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else if let problem {
                Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.system(size: 12)).foregroundStyle(Theme.warning).lineLimit(2)
            }
            if problem == nil, let wait = CylonState.busyNote(phase) {
                Label { Text(verbatim: wait) } icon: { Image(systemName: "clock") }
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if phase.state == "running" {
                Text(status.busy ? tr("In corso…") : tr("In attesa di te")).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                if status.busy == false, phase.canMarkDone == true {
                    Button(tr("Segna come fatta")) { Task { await act(phase, "done") } }.buttonStyle(ChipButtonStyle(filled: true, size: 12))
                }
            } else {
                Button { Task { await send(phase) } } label: {
                    Label(phase.state == "failed" ? tr("Riprova: %@", CylonPhaseKey.verb(phase.key)) : CylonPhaseKey.verb(phase.key), systemImage: "play.fill").fixedSize()
                }
                .buttonStyle(ChipButtonStyle(filled: true, size: 12.5))
                .disabled(phase.canRun != true || problem != nil)
                if phase.canSkip == true {
                    Button(tr("Salta")) { Task { await act(phase, "skip") } }.buttonStyle(ChipButtonStyle(filled: false, size: 12)).help(tr("Va avanti senza questa fase"))
                }
            }
        }
    }

    private func details(_ phase: CylonStatus.Phase, status: CylonStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: CylonPhaseKey.title(phase.key)).font(.headline)
            LabeledContent(tr("Skill")) { Text(verbatim: "/\(phase.skill)").font(.system(size: 12, design: .monospaced)) }
            LabeledContent(tr("Bot")) { Text(verbatim: phase.bot?.name ?? tr("Nessuno")) }
            if let command = phase.command {
                LabeledContent(tr("Manda")) { Text(verbatim: command).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled) }
            }
            if let note = phase.note { Text(verbatim: note).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            if let problem = CylonState.problem(phase, status: status) {
                Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }.font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            if phase.command == nil, ["run", "review", "pull"].contains(phase.key) {
                HStack {
                    TextField(tr("Cartella del task"), text: $folder, prompt: Text(verbatim: "login-page")).font(.system(size: 12, design: .monospaced))
                    Text(tr("in cylon-features/")).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            Divider()
            HStack {
                Button(phase.isDone ? tr("Rimanda") : CylonPhaseKey.verb(phase.key)) { Task { await send(phase) } }
                    .disabled(phase.canRun != true || CylonState.problem(phase, status: status) != nil)
                if phase.canSkip == true { Button(tr("Salta")) { Task { await act(phase, "skip") } } }
                if phase.canMarkDone == true { Button(tr("Segna come fatta")) { Task { await act(phase, "done") } } }
            }
        }
        .padding(16).frame(width: 380)
    }

    // MARK: actions

    private func send(_ phase: CylonStatus.Phase) async {
        open = nil
        let slug = phase.command == nil && !folder.trimmingCharacters(in: .whitespaces).isEmpty ? folder.trimmingCharacters(in: .whitespaces) : nil
        await state.act(model: model, groupId: room.id) { try await $0.cylonPhase(groupId: room.id, phase: phase.key, action: "run", slug: slug) }
    }

    private func act(_ phase: CylonStatus.Phase, _ action: String) async {
        open = nil
        await state.act(model: model, groupId: room.id) { try await $0.cylonPhase(groupId: room.id, phase: phase.key, action: action) }
    }
}

// MARK: - Starting a ticket

struct CylonStartSheet: View {
    let room: Room
    let state: CylonState
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ticket = ""
    @State private var tag = "cylon-plan"
    @State private var title = ""
    @State private var busy = false

    private var inMiddle: Bool { state.statuses[room.id]?.pipeline?.finished == false }

    var body: some View {
        Form {
            Section {
                TextField(tr("Ticket ClickUp"), text: $ticket, prompt: Text(verbatim: "86c2x9k"))
                    .font(.system(size: 12, design: .monospaced))
                Picker(tr("Il ticket ha il tag"), selection: $tag) {
                    Text(verbatim: "cylon-plan").tag("cylon-plan")
                    Text(verbatim: "cylon-spec").tag("cylon-spec")
                }
                TextField(tr("Nome (facoltativo)"), text: $title)
            } header: {
                Text(tr("Avvia un ticket"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Con cylon-spec il flusso parte dalla specifica, con cylon-plan dal piano. Un ticket cylon-investigate resta fuori dal flusso: si lavora a parte."))
                    Text(tr("Il canale riparte da una sessione pulita: lo stato tra le fasi sta nella cartella del task."))
                    if inMiddle { Text(tr("Il ticket in corso viene sostituito.")).foregroundStyle(Theme.warning) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = state.errors[room.id] { Text(verbatim: error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
            HStack {
                Button(tr("Annulla")) { dismiss() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(tr("Avvia")) { Task { await start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || ticket.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { state.errors[room.id] = nil }
    }

    private func start() async {
        busy = true
        await state.act(model: model, groupId: room.id) {
            try await $0.cylonStart(groupId: room.id, ticket: ticket.trimmingCharacters(in: .whitespaces), tag: tag, title: title.trimmingCharacters(in: .whitespaces), replace: inMiddle)
        }
        busy = false
        if state.errors[room.id] == nil { dismiss() }
    }
}

// MARK: - Settings

/// A channel's own: whether it follows the flow.
struct CylonRoomSettings: View {
    let room: Room
    let state: CylonState
    @Environment(AppModel.self) private var model

    private var hasProject: Bool {
        if case .string(let id)? = (room.plugins ?? [:]).pluginData("code")["projectId"], !id.isEmpty { return true }
        return false
    }

    var body: some View {
        SettingsCard(tr("Cylon")) {
            SettingRow(icon: "point.3.connected.trianglepath.dotted", tint: Theme.accent, title: tr("Segui il flusso Cylon"),
                       subtitle: hasProject ? tr("Spec, piano, esecuzione, revisione e PR: ogni fase la fa il bot scelto nel progetto, e la successiva aspetta la precedente. Si può saltare una fase.")
                           : tr("Serve un progetto per il canale (card Code): è lui a dire quale bot fa quale fase.")) {
                Toggle("", isOn: Binding(get: { CylonAppPlugin.follows(room) }, set: { next in
                    Task {
                        var patch = RoomPatch()
                        patch.pluginData = ["cylon": ["follow": .bool(next)]]
                        await model.patch(room, patch)
                    }
                }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
            }
        }
    }
}

/// Impostazioni › Plugin: the skill source, and who plays which phase in each project.
struct CylonGlobalSettings: View {
    let state: CylonState
    @Environment(AppModel.self) private var model

    private var bots: [Bot] { model.state.bots.filter { $0.hidden != true } }

    var body: some View {
        Section {
            Picker(tr("Sorgente delle skill"), selection: Binding(get: { state.sourceId ?? "" }, set: { id in
                Task { await state.setSource(model: model, id.isEmpty ? nil : id) }
            })) {
                Text(tr("Nessuna")).tag("")
                ForEach(model.skillSources) { Text(verbatim: $0.name).tag($0.id) }
            }
            if let source = model.skillSources.first(where: { $0.id == state.sourceId }) {
                if let error = source.last?.error {
                    Label { Text(verbatim: error).textSelection(.enabled) } icon: { Image(systemName: "xmark.octagon.fill") }.font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                ForEach(source.missing) { missing in
                    Label(missing.kind == "command" ? tr("Manca il comando %@ su questo motore", missing.name) : tr("Manca il connettore %@ su questo motore", missing.name),
                          systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Theme.warning)
                }
            } else if model.skillSources.isEmpty {
                Text(tr("Nessuna sorgente: aggiungi la cartella delle skill Cylon in Impostazioni › Skill.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if state.projects.isEmpty {
                Text(tr("Nessun progetto: i ruoli sono dei progetti, che si creano qui sopra.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(state.projects) { project in
                DisclosureGroup(project.name) {
                    ForEach(CylonPhaseKey.all, id: \.self) { phase in
                        Picker(CylonPhaseKey.title(phase), selection: Binding(get: { state.roles[project.id]?[phase] ?? "" }, set: { id in
                            Task { await state.setRole(model: model, project: project.id, phase: phase, botId: id.isEmpty ? nil : id) }
                        })) {
                            Text(tr("Nessuno")).tag("")
                            ForEach(bots) { Text(verbatim: $0.name).tag($0.id) }
                        }
                    }
                }
            }
        } header: {
            Text(tr("Cylon"))
        } footer: {
            Text(tr("Un bot per fase, cioè per modello: providers diversi non continuano la stessa sessione. I bot con una parte ricevono le skill della sorgente."))
        }
        .task { await state.refreshSettings(model: model); await model.refreshSkillSources() }
    }
}
