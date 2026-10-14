import CompanionCore
import SwarmeKit
import SwiftUI

/// Routines (scheduled prompts) and webhooks (prompts triggered from
/// outside), in their own window: they are managed, not chatted with.
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Routine").tag(0)
                Text("Webhook").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(12)
            Divider()
            if tab == 0 { RoutinesView() } else { WebhooksView() }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Theme.app)
        .task { await model.refreshAutomations() }
    }
}

// MARK: - Routines

private struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: RoutineDraft?

    var body: some View {
        HSplitView {
            List {
                ForEach(model.state.routines) { routine in
                    RoutineRow(routine: routine) { editing = RoutineDraft(routine) }
                }
            }
            .frame(minWidth: 380)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.state.routines.isEmpty {
                    ContentUnavailableView("Nessuna routine", systemImage: "clock", description: Text("Metti i bot su un ritmo: un prompt che parte a orari fissi."))
                }
            }
            RunsList(runs: model.state.routineRuns.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) })
                .scrollContentBackground(.hidden)
                .frame(minWidth: 280)
        }
        .toolbar {
            Button {
                editing = RoutineDraft(botId: model.visibleBots.first?.id ?? "")
            } label: {
                Label("Nuova routine", systemImage: "plus")
            }
        }
        .sheet(item: $editing) { draft in RoutineEditor(draft: draft) }
    }
}

private struct RoutineRow: View {
    let routine: Routine
    let edit: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { routine.enabled }, set: { value in Task { await model.setEnabled(routine, value) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.name).font(.system(size: 13, weight: .medium))
                Text(describe(routine.schedule)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                if let bot = model.state.bot(routine.botId) {
                    Text("→ \(bot.name)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if let next = routine.nextRunAt, routine.enabled {
                    Text("Prossima: \(Date(timeIntervalSince1970: next / 1000).formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Menu {
                Button("Esegui ora") { Task { await model.run(routine) } }
                Button("Modifica…", action: edit)
                Divider()
                Button("Elimina", role: .destructive) { Task { await model.delete(routine) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }

    private func describe(_ schedule: RoutineSchedule) -> String {
        if schedule.type == "once", let at = schedule.at {
            return "Una volta, " + Date(timeIntervalSince1970: at / 1000).formatted(date: .abbreviated, time: .shortened)
        }
        let days = schedule.weekdays ?? []
        let names = ["dom", "lun", "mar", "mer", "gio", "ven", "sab"]
        let label = days.count == 7 ? "ogni giorno" : days.sorted().map { names[$0 % 7] }.joined(separator: " ")
        return "\(label) alle \(schedule.time ?? "?")"
    }
}

private struct RunsList: View {
    let runs: [RoutineRun]
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Esecuzioni recenti") {
                ForEach(runs.prefix(80)) { run in
                    HStack(alignment: .top) {
                        Circle().fill(color(run.status)).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.routineName ?? "Webhook").font(.system(size: 12.5, weight: .medium))
                            Text(label(run)).font(.system(size: 11)).foregroundStyle(.secondary)
                            if let error = run.error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger).lineLimit(3) }
                        }
                        Spacer()
                        if run.isActive {
                            Button("Annulla") { Task { await model.cancel(run) } }.controlSize(.small)
                        } else if let threadId = run.threadId {
                            Button("Apri") { open(threadId: threadId, botId: run.botId) }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func open(threadId: String, botId: String) {
        model.selection = .bot(botId)
        if let task = model.state.bot(botId)?.tasks?.first(where: { $0.threadId == threadId }) {
            Task { await model.switchTask(task) }
        }
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }

    private func label(_ run: RoutineRun) -> String {
        let when = (run.startedAt ?? run.scheduledFor ?? run.createdAt).map {
            Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened)
        } ?? ""
        return "\(run.status) · \(when)"
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "completed": return Theme.success
        case "failed", "missed": return Theme.danger
        case "cancelled": return Theme.tertiary
        default: return Theme.accent
        }
    }
}

struct RoutineDraft: Identifiable {
    var id: String
    var existingId: String?
    var name = ""
    var prompt = ""
    var botId: String
    var enabled = true
    var once = false
    var at = Date().addingTimeInterval(3600)
    var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    var duration = 30

    init(botId: String) {
        id = UUID().uuidString
        self.botId = botId
    }

    init(_ routine: Routine) {
        id = routine.id
        existingId = routine.id
        name = routine.name
        prompt = routine.prompt
        botId = routine.botId
        enabled = routine.enabled
        once = routine.schedule.type == "once"
        if let at = routine.schedule.at { self.at = Date(timeIntervalSince1970: at / 1000) }
        if let hm = routine.schedule.time?.split(separator: ":"), hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) {
            time = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? time
        }
        weekdays = Set(routine.schedule.weekdays ?? [])
        duration = routine.durationMinutes ?? 30
    }

    var input: RoutineInput {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let schedule = once
            ? RoutineSchedule.once(at)
            : RoutineSchedule.daily(String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0), weekdays: weekdays.sorted())
        return RoutineInput(name: name, prompt: prompt, botId: botId, enabled: enabled, schedule: schedule, durationMinutes: duration)
    }
}

private struct RoutineEditor: View {
    @State var draft: RoutineDraft
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Nome", text: $draft.name)
            Picker("Bot", selection: $draft.botId) {
                ForEach(model.visibleBots) { Text($0.name).tag($0.id) }
            }
            TextField("Prompt", text: $draft.prompt, axis: .vertical).lineLimit(4...10)
            Picker("Quando", selection: $draft.once) {
                Text("Ripeti").tag(false)
                Text("Una volta").tag(true)
            }
            .pickerStyle(.segmented)
            if draft.once {
                DatePicker("Data e ora", selection: $draft.at)
            } else {
                DatePicker("Ora", selection: $draft.time, displayedComponents: .hourAndMinute)
                HStack {
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                        Toggle(["D", "L", "M", "M", "G", "V", "S"][day], isOn: Binding(
                            get: { draft.weekdays.contains(day) },
                            set: { if $0 { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) } }
                        ))
                        .toggleStyle(.button)
                    }
                }
            }
            Stepper("Durata massima: \(draft.duration) min", value: $draft.duration, in: 5...240, step: 5)
            Toggle("Attiva", isOn: $draft.enabled)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Salva") {
                    let input = draft.input
                    let id = draft.existingId
                    Task { await model.save(routine: input, id: id) }
                    dismiss()
                }
                .disabled(draft.name.isEmpty || draft.prompt.isEmpty || draft.botId.isEmpty || (!draft.once && draft.weekdays.isEmpty))
            }
        }
    }
}

// MARK: - Webhooks

private struct WebhooksView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var creating = false
    @State private var credential: WebhookCredential?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(model.state.webhooks) { webhook in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(webhook.name).font(.system(size: 13, weight: .medium))
                        Text("\(webhook.deliveryCount ?? 0) consegne · \(model.state.bot(webhook.botId)?.name ?? "?")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .tag(webhook.id)
                }
            }
            .frame(minWidth: 240)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.state.webhooks.isEmpty {
                    ContentUnavailableView("Nessun webhook", systemImage: "link", description: Text("Un URL privato che, quando riceve un POST, dà un compito a un bot."))
                }
            }
            Group {
                if let id = selected, let webhook = model.state.webhooks.first(where: { $0.id == id }) {
                    WebhookDetail(webhook: webhook) { credential = $0 }
                } else {
                    Text("Seleziona un webhook").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
        .toolbar {
            Button { creating = true } label: { Label("Nuovo webhook", systemImage: "plus") }
        }
        .safeAreaInset(edge: .bottom) {
            if let ingress = model.webhookIngress, !ingress.available {
                Text("Ricezione webhook non disponibile: \(ingress.error ?? "porta occupata")")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.warning).padding(8)
            }
        }
        .sheet(isPresented: $creating) {
            WebhookCreator { credential = $0 }
        }
        .sheet(item: Binding(get: { credential.map { CredentialBox(credential: $0) } }, set: { credential = $0?.credential })) { box in
            CredentialSheet(credential: box.credential)
        }
    }
}

private struct CredentialBox: Identifiable {
    let credential: WebhookCredential
    var id: String { credential.url ?? credential.endpointUrl ?? "credential" }
}

private struct WebhookDetail: View {
    let webhook: WebhookTrigger
    let showCredential: (WebhookCredential) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let attempts = model.state.webhookAttempts.filter { $0.webhookId == webhook.id }.sorted { $0.receivedAt > $1.receivedAt }
        Form {
            Section {
                Toggle("Attivo", isOn: Binding(get: { webhook.enabled }, set: { v in Task { await model.update(webhook, ["enabled": v]) } }))
                LabeledContent("Bot", value: model.state.bot(webhook.botId)?.name ?? "?")
                LabeledContent("Prompt") { Text(webhook.prompt).textSelection(.enabled) }
                if webhook.verificationPending == true {
                    Text("In attesa del primo evento di verifica.").foregroundStyle(Theme.warning)
                }
            }
            Section {
                HStack {
                    Button("Invia test") { Task { await model.test(webhook) } }
                    Button("Ruota URL privato") {
                        Task { if let credential = await model.rotate(webhook) { showCredential(credential) } }
                    }
                    Spacer()
                    Button("Elimina", role: .destructive) { Task { await model.delete(webhook) } }
                }
            }
            Section("Consegne recenti") {
                if attempts.isEmpty { Text("Nessuna").foregroundStyle(.secondary) }
                ForEach(attempts.prefix(30)) { attempt in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(attempt.outcome).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(attempt.outcome == "rejected" ? Theme.danger : Theme.ink)
                            Text(attempt.eventName ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Date(timeIntervalSince1970: attempt.receivedAt / 1000).formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        if let preview = attempt.preview ?? attempt.reason {
                            Text(preview).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WebhookCreator: View {
    let created: (WebhookCredential) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var botId = ""
    @State private var events = ""

    var body: some View {
        Form {
            TextField("Nome", text: $name)
            Picker("Bot", selection: $botId) { ForEach(model.visibleBots) { Text($0.name).tag($0.id) } }
            TextField("Compito (il payload ricevuto viene aggiunto sotto)", text: $prompt, axis: .vertical).lineLimit(3...8)
            TextField("Tipi di evento (facoltativo, separati da virgola)", text: $events)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 360)
        .onAppear { botId = model.visibleBots.first?.id ?? "" }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Crea") {
                    let types = events.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let input = WebhookInput(name: name, prompt: prompt, botId: botId, enabled: true, eventTypes: types)
                    Task {
                        if let credential = await model.create(webhook: input) { created(credential) }
                    }
                    dismiss()
                }
                .disabled(name.isEmpty || prompt.isEmpty || botId.isEmpty)
            }
        }
    }
}

/// The private URL, shown once: the harness never returns the secret again.
private struct CredentialSheet: View {
    let credential: WebhookCredential
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("URL privato del webhook").font(.headline)
            Text("Copialo ora: il segreto non verrà mostrato di nuovo.").foregroundStyle(Theme.warning)
            if let url = credential.url {
                HStack {
                    Text(url).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    Button("Copia") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
            }
            if let endpoint = credential.endpointUrl, let secret = credential.secret {
                Text("Oppure: POST \(endpoint) con header Authorization: Bearer \(secret)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack { Spacer(); Button("Fatto") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520)
    }
}
