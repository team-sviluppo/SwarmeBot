import CompanionCore
import ScreenCaptureKit
import SwarmeKit
import SwiftUI
import WebKit

// The Libreria tab is in LibraryViews.swift.

// MARK: - Computer

struct ComputerTab: View {
    let bot: Bot
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(tr("Computer del bot"), selection: Binding(
                get: { bot.computer == "vm" ? "vm" : bot.computer == "cloud" ? "cloud" : "off" },
                set: { value in Task { await model.patch(bot, BotPatch(computer: value)) } }
            )) {
                Text(tr("Nessuno")).tag("off")
                Text(tr("VM locale")).tag("vm")
                if bot.computer == "cloud" { Text(tr("Cloud")).tag("cloud") }
            }
            .font(.system(size: 12.5))

            switch bot.computer {
            case "vm": LocalVMSection(bot: bot)
            case "cloud": CloudComputerSection(bot: bot)
            default:
                Text(tr("Senza computer il bot lavora solo con i suoi strumenti (shell, file). Con la VM locale ha un desktop Linux isolato che puoi guardare e prendere in mano."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }

            Divider().overlay(Theme.hairline)
            ThisMacPreview()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

private struct LocalVMSection: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var status: LocalComputerStatus?
    @State private var working: String?
    @State private var watching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status {
                HStack(spacing: 6) {
                    Circle().fill(status.ready == true ? Theme.success : Theme.warning).frame(width: 7, height: 7)
                    Text(status.ready == true ? tr("Pronta") : (status.container ?? tr("sconosciuto")))
                        .font(.system(size: 12.5, weight: .medium))
                    if let runtime = status.runtime { Text(verbatim: "· \(runtime)").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary) }
                }
                if let problem = status.problem {
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                }
                HStack {
                    if status.imageMatches != true { action(tr("Prepara"), "pull") }
                    if status.container == "missing" { action(tr("Crea"), "run") }
                    if status.container == "stopped" { action(tr("Avvia"), "start") }
                    if status.container == "running" { action(tr("Ferma"), "stop") }
                    if status.container != "missing" { action(tr("Rimuovi"), "remove") }
                }
                if let working { ProgressView("\(working)…").controlSize(.small) }
            } else {
                ProgressView().controlSize(.small)
            }
            ControlStrip(bot: bot)
            Toggle(tr("Guarda il desktop"), isOn: $watching).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
            if watching { LiveScreen(botId: bot.id) }
        }
        .task(id: bot.id) { status = try? await model.client?.localComputer() }
    }

    private func action(_ title: String, _ verb: String) -> some View {
        Button(title) {
            working = title
            Task {
                do {
                    status = try await model.client?.localComputer(verb)
                } catch {
                    model.lastError = error.localizedDescription
                }
                working = nil
            }
        }
        .buttonStyle(PillButtonStyle())
        .disabled(working != nil)
    }
}

/// Take the wheel from the bot, give it back, or dismiss its plea for help.
private struct ControlStrip: View {
    let bot: Bot
    @Environment(AppModel.self) private var model

    var body: some View {
        let control = model.state.computerControl[bot.id]
        VStack(alignment: .leading, spacing: 6) {
            if let reason = control?.helpReason {
                Label(tr("Il bot chiede aiuto: %@", reason), systemImage: "hand.raised.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            HStack {
                if control?.held == true {
                    Button(tr("Restituisci al bot")) { act("release") }.buttonStyle(PillButtonStyle(prominent: true))
                } else {
                    Button(tr("Prendi il controllo")) { act("take") }.buttonStyle(PillButtonStyle())
                }
                if control?.helpReason != nil {
                    Button(tr("Ignora richiesta")) { act("dismiss-help") }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private func act(_ action: String) {
        Task {
            do {
                _ = try await model.client?.computerControl(botId: bot.id, action: action)
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }
}

/// The bot's desktop, from `screen` frames on the stream. The stream only
/// carries them while something watches, so this counts as a watcher.
private struct LiveScreen: View {
    let botId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let data = model.state.screens[botId]?.data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Theme.inset).aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(Text(tr("In attesa del primo fotogramma…")).font(.system(size: 11)).foregroundStyle(Theme.tertiary))
            }
        }
        .onAppear { model.watchScreens(true) }
        .onDisappear { model.watchScreens(false) }
    }
}

private struct CloudComputerSection: View {
    let bot: Bot
    @Environment(AppModel.self) private var model
    @State private var status: CloudComputerStatus?
    @State private var viewer: URL?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status {
                Text(status.backend == "vps" ? "VPS \(status.sshAlias ?? "")" : tr("Box: %@", status.box?.state ?? (status.configured == true ? tr("non creato") : tr("non configurato"))))
                    .font(.system(size: 12.5))
                if let state = model.state.computerState[bot.id] {
                    ProgressView(state == "waking" ? tr("Risveglio…") : tr("Preparazione…")).controlSize(.small)
                }
                if status.backend == "box" {
                    HStack {
                        Button(tr("Prepara")) { act("provision") }.buttonStyle(PillButtonStyle())
                        Button(tr("Apri desktop")) {
                            Task {
                                do { viewer = try await model.client?.joinCloudDesktop(botId: bot.id).url }
                                catch { model.lastError = error.localizedDescription }
                            }
                        }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        Button(tr("Sospendi")) { act("sleep") }.buttonStyle(PillButtonStyle())
                    }
                    .disabled(busy)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            ControlStrip(bot: bot)
        }
        .task(id: bot.id) { status = try? await model.client?.cloudComputer(botId: bot.id) }
        .sheet(item: Binding(get: { viewer.map { ViewerBox(url: $0) } }, set: { viewer = $0?.url })) { box in
            VStack(spacing: 0) {
                HStack { Text(tr("Desktop di %@", bot.name)).font(.headline); Spacer(); Button(tr("Chiudi")) { viewer = nil } }.padding(10)
                WebView(url: box.url)
            }
            .frame(minWidth: 1000, minHeight: 680)
        }
    }

    private struct ViewerBox: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private func act(_ action: String) {
        busy = true
        Task {
            do { try await model.client?.cloudComputer(botId: bot.id, action: action) }
            catch { model.lastError = error.localizedDescription }
            status = try? await model.client?.cloudComputer(botId: bot.id)
            busy = false
        }
    }
}

/// The cloud desktop viewer. The URL is a short-lived bearer credential:
/// it lives only in this view, never on disk.
struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// A live look at this Mac's main display — what a bot driving it would
/// see. Off until switched on, every time: it needs Screen Recording, and
/// nothing about this screen should be captured by default.
private struct ThisMacPreview: View {
    @State private var on = false
    @State private var frame: CGImage?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(tr("Anteprima di questo Mac"), isOn: $on).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
            if on {
                if let frame {
                    Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if let error {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                    Button(tr("Apri Privacy › Registrazione schermo")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .buttonStyle(PillButtonStyle())
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: on) {
            guard on else { frame = nil; return }
            while !Task.isCancelled {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first else { break }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = display.width / 2
                    config.height = display.height / 2
                    frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    error = nil
                } catch {
                    self.error = tr("Serve il permesso di Registrazione schermo per SwarmeBot.")
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
