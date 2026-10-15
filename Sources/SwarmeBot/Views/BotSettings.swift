// The Dettagli tab of the inspector: who the bot is, how it looks, how it
// behaves. Grouped cards on the panel, the layout of the Electron app's
// settings panel brought up to date.
import AppKit
import CompanionCore
import SwarmeKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Building blocks

/// A titled group: caption above, content on a rounded `inset` card.
struct SettingsCard<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.hairline.opacity(0.6), lineWidth: 1))
        }
    }
}

/// Hairline between the rows of a card, inset past the icon.
struct CardDivider: View {
    var leading: CGFloat = 12
    var body: some View {
        Rectangle().fill(Theme.hairline.opacity(0.6)).frame(height: 1).padding(.leading, leading)
    }
}

/// Icon in a tinted square, title, optional explanation, then the control.
struct SettingRow<Control: View>: View {
    let icon: String
    var tint: Color = Theme.accent
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// Segmented control in the inspector style (tabs, appearance mode).
struct SegmentedPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = selection == value
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Theme.raised : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.app.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.hairline.opacity(0.5)))
        .animation(Theme.quick, value: selection)
    }
}

// MARK: - Dettagli

/// Text fields commit when they lose focus or on ⏎, not per keystroke: each
/// commit is a PATCH and a `bot` frame to every client.
struct BotDetails: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var title = ""
    @State private var about = ""
    @FocusState private var focus: Field?

    private enum Field { case name, title, about }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hero
            AppearanceCard(bot: bot)
            profile
            behaviour
            BotConnectorsCard(bot: bot)
            workspace
            if let tasks = bot.tasks, tasks.count > 1 { taskList(tasks) }
            if let allowed = bot.alwaysAllow, !allowed.isEmpty { permissions(allowed) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .onAppear(perform: load)
        .onChange(of: bot.id) { _, _ in load() }
        .onChange(of: focus) { previous, _ in commit(previous) }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            BotAvatar(bot: bot, size: 84, state: MausState.forBot(bot, last: model.visibleTranscript(bot.threadId).last), priority: true)
            VStack(spacing: 2) {
                Text(bot.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(bot.title.isEmpty ? "Nessun ruolo" : bot.title)
                    .font(.system(size: 12.5)).foregroundStyle(bot.title.isEmpty ? Theme.tertiary : Theme.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: Profilo

    private var profile: some View {
        SettingsCard("Profilo") {
            VStack(alignment: .leading, spacing: 12) {
                input("Nome", text: $name, field: .name, prompt: "Nome del bot")
                input("Ruolo", text: $title, field: .title, prompt: "Che cosa fa, in poche parole")
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        caption("Istruzioni")
                        Spacer()
                        if about != bot.description {
                            Button("Annulla") { about = bot.description }
                                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                            Button("Salva") { commit(.about) }
                                .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
                        }
                    }
                    TextEditor(text: $about)
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: .about)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .frame(minHeight: 110, maxHeight: 260)
                        .background(fieldBackground(focused: focus == .about))
                }
            }
            .padding(12)
        }
    }

    private func input(_ label: String, text: Binding<String>, field: Field, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            caption(label)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: field)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(fieldBackground(focused: focus == field))
                .onSubmit { commit(field) }
        }
    }

    private func fieldBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.app.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(focused ? Theme.focus.opacity(0.8) : Theme.hairline.opacity(0.6), lineWidth: 1))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
    }

    // MARK: Comportamento

    private var behaviour: some View {
        SettingsCard("Comportamento") {
            toggle("checkmark.shield", tint: Theme.success, "Approva da solo",
                   "Esegue gli strumenti senza chiederti conferma.", value: bot.autoApprove ?? false) { BotPatch(autoApprove: $0) }
            CardDivider(leading: 48)
            toggle("bell", tint: Theme.warning, "Notifiche",
                   "Avvisa quando finisce un turno o ti fa una domanda.", value: bot.notifications) { BotPatch(notifications: $0) }
            CardDivider(leading: 48)
            toggle("pin", tint: Theme.accent, "Fissato in alto",
                   nil, value: bot.pinned ?? false) { BotPatch(pinned: $0) }
        }
    }

    private func toggle(_ icon: String, tint: Color, _ title: String, _ subtitle: String?, value: Bool,
                        patch: @escaping (Bool) -> BotPatch) -> some View {
        SettingRow(icon: icon, tint: tint, title: title, subtitle: subtitle) {
            Toggle("", isOn: Binding(get: { value }, set: { next in Task { await model.patch(bot, patch(next)) } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }

    // MARK: Cartella

    /// The open chat's folder (what its turns run in), else the bot's
    /// default — the same folder the composer's folder button shows.
    private var workspace: some View {
        let path = bot.tasks?.first(where: { $0.threadId == bot.threadId })?.cwd.flatMap { $0.isEmpty ? nil : $0 } ?? bot.cwd
        var isDirectory: ObjCBool = false
        let missing = path.map { !(FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue) } ?? false
        return SettingsCard("Cartella di lavoro") {
            SettingRow(icon: missing ? "exclamationmark.triangle.fill" : "folder", tint: missing ? Theme.warning : Theme.accentText,
                       title: path.map { ($0 as NSString).lastPathComponent } ?? "Cartella del bot",
                       subtitle: missing ? "Non esiste più: scegline un'altra" :
                           path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "La cartella privata del bot") {
                Button("Scegli…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Scegli"
                    panel.message = "Cartella di lavoro di questa chat e delle prossime"
                    if let path, !missing { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    Task { await model.setWorkingFolder(url.path) }
                }
                .buttonStyle(PillButtonStyle())
            }
        }
    }

    // MARK: Chat e permessi

    private func taskList(_ tasks: [BotTask]) -> some View {
        SettingsCard("Chat") {
            ForEach(Array(tasks.enumerated()), id: \.element.threadId) { index, task in
                if index > 0 { CardDivider() }
                let current = task.threadId == bot.threadId
                HStack(spacing: 8) {
                    Circle().fill(current ? Theme.accent : Theme.hairline).frame(width: 6, height: 6)
                    Text(task.title).font(.system(size: 12.5, weight: current ? .medium : .regular)).lineLimit(1)
                        .foregroundStyle(current ? Theme.ink : Theme.secondary)
                    Spacer(minLength: 0)
                    if task.pinned == true { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func permissions(_ allowed: [String]) -> some View {
        SettingsCard("Sempre consentiti") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(allowed, id: \.self) { key in
                    Text(key).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
    }

    // MARK: State

    private func load() {
        name = bot.name
        title = bot.title
        about = bot.description
    }

    private func commit(_ field: Field?) {
        switch field {
        case .name:
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { name = bot.name; return }
            if trimmed != bot.name { Task { await model.patch(bot, BotPatch(name: trimmed)) } }
        case .title:
            if title != bot.title { Task { await model.patch(bot, BotPatch(title: title)) } }
        case .about:
            if about != bot.description { Task { await model.patch(bot, BotPatch(description: about)) } }
        case nil:
            break
        }
    }
}

// MARK: - Aspetto

/// Mascot (shape, expression, colour) or a picture of its own. A picture
/// replaces the mascot, so the two are modes rather than more knobs.
private struct AppearanceCard: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .mascot
    @State private var uploading = false
    @State private var dropTargeted = false
    @State private var error: String?

    enum Mode: Hashable { case mascot, picture }

    /// `PICKABLE_STATES` of the Electron app.
    private static let expressions: [MausState] = [
        .idle, .happy, .curious, .drowsy, .working, .thinking, .listening, .sleeping, .suspicious, .proud,
    ]
    private let grid = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    private var wearsPicture: Bool {
        !(bot.mascotAvatarImage ?? "").isEmpty || !(bot.mascotAvatarSvg ?? "").isEmpty
    }

    var body: some View {
        SettingsCard("Aspetto") {
            Button("Ripristina") {
                var patch = BotPatch(color: "green")
                patch.mascotSilhouette = ""
                patch.mascotExpression = ""
                patch.clearPicture = true
                Task { await model.patch(bot, patch) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary)
            .help("Mascotte verde, forma e espressione predefinite")
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                SegmentedPicker(options: [(Mode.mascot, "Mascotte"), (Mode.picture, "Immagine")], selection: $mode)
                switch mode {
                case .mascot: mascot
                case .picture: picture
                }
                if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
            }
            .padding(12)
        }
        .onAppear { mode = wearsPicture ? .picture : .mascot }
        .onChange(of: bot.id) { _, _ in mode = wearsPicture ? .picture : .mascot; error = nil }
    }

    // MARK: Mascot

    private var mascot: some View {
        let shape = MausSilhouette.ids.contains(bot.mascotSilhouette ?? "") ? bot.mascotSilhouette! : MausSilhouetteData.defaultId
        let face = MausState.forBot(bot, last: nil)
        return VStack(alignment: .leading, spacing: 14) {
            if wearsPicture {
                Label("Il bot usa un'immagine: la mascotte torna quando la rimuovi.", systemImage: "info.circle")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            section("Forma") {
                LazyVGrid(columns: grid, spacing: 6) {
                    ForEach(MausSilhouette.ids, id: \.self) { id in
                        tile(selected: shape == id, help: id) {
                            var patch = BotPatch()
                            patch.mascotSilhouette = id
                            Task { await model.patch(bot, patch) }
                        } content: {
                            MausAvatar(color: bot.color, size: 36, state: face, silhouette: id, animated: false, trackPointer: false, effects: false)
                        }
                    }
                }
            }
            section("Espressione") {
                LazyVGrid(columns: grid, spacing: 6) {
                    ForEach(Self.expressions, id: \.self) { state in
                        tile(selected: MausState.normalize(bot.mascotExpression) == state, help: state.rawValue) {
                            var patch = BotPatch()
                            patch.mascotExpression = MausState.normalize(bot.mascotExpression) == state ? "" : state.rawValue
                            Task { await model.patch(bot, patch) }
                        } content: {
                            MausAvatar(color: bot.color, size: 36, state: state, silhouette: shape, animated: false, trackPointer: false, effects: false)
                        }
                    }
                }
            }
            section("Colore") {
                HStack(spacing: 0) {
                    ForEach(MausPaletteData.names, id: \.self) { name in
                        let on = bot.color == name
                        Button { Task { await model.patch(bot, BotPatch(color: name)) } } label: {
                            Circle()
                                .fill(Color(hex: MausPaletteData.hex[name] ?? "#888888"))
                                .frame(width: 22, height: 22)
                                .padding(3)
                                .overlay(Circle().stroke(on ? Theme.accentBorder : .clear, lineWidth: 2))
                                .frame(maxWidth: .infinity)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }
        }
        .opacity(wearsPicture ? 0.55 : 1)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary)
            content()
        }
    }

    private func tile<Content: View>(selected: Bool, help: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.raised : Theme.app.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.accentBorder : Theme.hairline.opacity(0.4), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Picture

    private var picture: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: pick) {
                HStack(spacing: 12) {
                    Group {
                        if wearsPicture {
                            BotAvatar(bot: bot, size: 44, animated: false)
                        } else {
                            Image(systemName: uploading ? "arrow.up.circle" : "photo.badge.plus")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Theme.raised))
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(uploading ? "Caricamento…" : wearsPicture ? "Cambia immagine" : "Scegli un'immagine")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                        Text("Trascina qui o clicca: PNG, JPG, GIF, WebP o SVG")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dropTargeted ? Theme.raised : Theme.app.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(dropTargeted ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(uploading)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)

            if let image = bot.mascotAvatarImage, !image.isEmpty {
                let sheetRow = SpriteSheet.row(bot.mascotAvatarSheetRow)
                section("Tipo") {
                    SegmentedPicker(options: [(false, "Immagine fissa"), (true, "Spritesheet 9×8")], selection: Binding(
                        get: { sheetRow != nil },
                        set: { sheet in
                            var patch = BotPatch()
                            patch.mascotAvatarSheetRow = sheet ? 0 : -1
                            Task { await model.patch(bot, patch) }
                        }
                    ))
                }
                if let sheetRow {
                    section("Animazione") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                            ForEach(0..<SpriteSheet.rows, id: \.self) { row in
                                tile(selected: sheetRow == row, help: "Riga \(row + 1)") {
                                    var patch = BotPatch()
                                    patch.mascotAvatarSheetRow = row
                                    Task { await model.patch(bot, patch) }
                                } content: {
                                    SpriteSheetAvatar(name: image, row: row, size: 36)
                                }
                            }
                        }
                    }
                }
            }

            if wearsPicture {
                Button {
                    var patch = BotPatch()
                    patch.clearPicture = true
                    Task { await model.patch(bot, patch) }
                    mode = .mascot
                } label: {
                    Label("Rimuovi immagine e usa la mascotte", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger.opacity(0.9))
            }
        }
    }

    private static let types: [UTType] = [.png, .jpeg, .gif, .webP, .svg]

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = false
        panel.prompt = "Usa"
        panel.message = "Immagine per \(bot.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        upload(url)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in upload(url) }
        }
        return true
    }

    private func upload(_ url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension),
              Self.types.contains(where: { type.conforms(to: $0) }),
              let mime = type.preferredMIMEType else {
            error = "Formato non supportato: usa PNG, JPG, GIF, WebP o SVG."
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            error = "Impossibile leggere il file."
            return
        }
        error = nil
        uploading = true
        Task {
            let before = model.lastError
            await model.uploadAvatar(bot, data: data, mime: mime)
            if let failure = model.lastError, failure != before { error = failure }
            uploading = false
        }
    }
}
