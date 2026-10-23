import AppKit
import SwarmeKit
import SwiftUI

@main
struct SwarmeBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("SwarmeBot", id: "main") {
            RootView()
                .environment(delegate.model)
                .appLanguage()
                .appAppearance()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 920)
        .commands { AppCommands(model: delegate.model) }

        Window(tr("Automazioni"), id: "automations") {
            AutomationsView()
                .environment(delegate.model)
                .appLanguage()
                .appAppearance()
        }
        .defaultSize(width: 900, height: 600)

        Window(tr("Libreria team"), id: "teams") {
            TeamLibraryView()
                .environment(delegate.model)
                .appLanguage()
                .appAppearance()
        }
        .defaultSize(width: 720, height: 560)

        // a server's settings (Impostazioni › Server remoti), one window per server
        WindowGroup(id: "remote-settings", for: String.self) { $engineId in
            if let engineId {
                RemoteSettingsView(engineId: engineId)
                    .environment(delegate.model)
                    .appLanguage()
                    .appAppearance()
            }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(delegate.model)
                .appLanguage()
                .appAppearance()
        }
    }
}

/// Dates, numbers and system controls in the app's language, not macOS's.
private struct AppLanguageEnvironment: ViewModifier {
    @State private var localizer = Localizer.shared

    func body(content: Content) -> some View {
        content.environment(\.locale, localizer.language.locale)
    }
}

extension View {
    func appLanguage() -> some View { modifier(AppLanguageEnvironment()) }
}

/// Owns the model so it outlives windows: closing the last window must not
/// tear down the harness and its running turns.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var signalSources: [DispatchSourceSignal] = []
    private var bench: BenchRunner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts us as a plain process; make it a real app with
        // a Dock icon and a menu bar.
        NSApp.setActivationPolicy(.regular)
        // a bundle shows Contents/Resources/AppIcon.icns by itself; a bare
        // build does not, so the Dock would show the generic app icon
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.resources.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        trapTerminationSignals()
        NotificationCenterBridge.shared.install(on: model)
        _ = Updater.shared
        if let raw = ProcessInfo.processInfo.environment["SWARMEBOT_BENCH"], let count = Int(raw) {
            bench = BenchRunner(model: model, count: count)
            bench?.run()
            return
        }
        model.start()
        MascotBeats.shared.attach(model)
        if let path = ProcessInfo.processInfo.environment["SWARMEBOT_SNAPSHOT"] {
            snapshot(to: URL(fileURLWithPath: path))
        }
        if let open = ProcessInfo.processInfo.environment["SWARMEBOT_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                switch open {
                case "palette": self.model.showPalette = true
                case "newroom": self.model.showNewRoom = true
                default: OpenWindowBridge.open?(open)
                }
            }
        }
    }

    /// Debug aid: write the main window to a PNG once the app has settled.
    /// Draws our own view hierarchy, so it needs no Screen Recording grant.
    private func snapshot(to url: URL) {
        let delay = Double(ProcessInfo.processInfo.environment["SWARMEBOT_SNAPSHOT_DELAY"] ?? "") ?? 10
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let wanted = ProcessInfo.processInfo.environment["SWARMEBOT_SNAPSHOT_WINDOW"]
            let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            if let wanted, !windows.contains(where: { $0.title == wanted }) {
                FileHandle.standardError.write(Data("snapshot: no window \(wanted) among \(windows.map(\.title))\n".utf8))
            }
            let window = wanted.flatMap { title in windows.first { $0.title == title } } ?? windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? windows.first
            let target = window?.attachedSheet ?? window
            guard let view = target?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// `kill`/Ctrl-C end the process without `applicationWillTerminate`, so
    /// route them through a normal quit — that is what stops the harness.
    private func trapTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            // Stop the harness first and exit outright: a sheet or a modal
            // panel makes AppKit refuse `terminate`, and a signal is not a
            // request that can be declined.
            source.setEventHandler { [weak self] in
                self?.model.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon brings the main window back. Not only when no
    /// window is visible: with Automazioni or Settings still open AppKit
    /// reports visible windows and did nothing, so the chat never came back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// Un-minimises the main window, or opens a new one: once closed,
    /// SwiftUI releases it, and there is nothing left to order front.
    private func showMainWindow() {
        let mains = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
        if let window = mains.first(where: \.isVisible) {
            window.makeKeyAndOrderFront(nil)
        } else if let window = mains.first(where: \.isMiniaturized) {
            window.deminiaturize(nil)
        } else {
            OpenWindowBridge.open?("main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Dock menu: unread chats first, so a waiting bot is one click away.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for bot in model.visibleBots.filter({ $0.unread || $0.activity == "waiting-on-you" }).prefix(10) {
            let item = NSMenuItem(title: bot.name, action: #selector(openBotFromDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = bot.id
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func openBotFromDock(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        model.selection = .bot(id)
        showMainWindow()
    }
}

/// Lets non-view code open a scene window by id (debug snapshots).
@MainActor
enum OpenWindowBridge {
    static var open: ((String) -> Void)?
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("Nuovo bot")) { Task { await model.createBot() } }
                .keyboardShortcut("n")
            Button(tr("Nuovo canale…")) { model.showNewRoom = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(tr("Vai a… / Cerca")) { model.showPalette = true }
                .keyboardShortcut("k")
        }
        CommandGroup(after: .appInfo) {
            Button(tr("Controlla aggiornamenti…")) { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.available)
        }
        CommandGroup(before: .windowList) {
            Button(tr("Automazioni")) { openWindow(id: "automations") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(tr("Libreria team")) { openWindow(id: "teams") }
            Divider()
        }
        CommandMenu("Bot") {
            Button(tr("Interrompi turno")) { Task { await model.interrupt() } }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            ForEach(Array(model.visibleBots.prefix(9).enumerated()), id: \.element.id) { index, bot in
                Button(bot.name) { model.selection = .bot(bot.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
