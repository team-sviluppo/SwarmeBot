import CompanionCore
import SwarmeKit
import SwiftUI

/// Sidebar · transcript · inspector, the three-column layout of the
/// Electron app, with the inspector closable (⌘⌥I).
/// Chrome state shared by the header and the root layout.
@MainActor
@Observable
final class UIState {
    static let shared = UIState()
    /// The right panel (bot settings / library / computer / events).
    var showInspector = true
    /// `SWARMEBOT_INSPECTOR_TAB` picks the opening tab — for snapshots.
    var inspectorTab: InspectorView.Tab = ProcessInfo.processInfo.environment["SWARMEBOT_INSPECTOR_TAB"].flatMap(InspectorView.Tab.init(rawValue:)) ?? .details
    /// The id of the plugin tab open in the right column, which then stands in for `inspectorTab`.
    /// `SWARMEBOT_PLUGIN_TAB` picks it at launch, for snapshots.
    var pluginTab: String? = ProcessInfo.processInfo.environment["SWARMEBOT_PLUGIN_TAB"]
}

/// Sidebar 272 · transcript · right panel (400, events 460) — the Electron
/// app's three columns, flat and opaque, under a hidden title bar.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var ui = UIState.shared
    /// Set once the engine first goes live; a later reconnect keeps the layout.
    @State private var loaded = false

    var body: some View {
        @Bindable var model = model
        Group {
            if MascotGallery.enabled {
                MascotGallery()
            } else if !loaded {
                // first launch: nothing to list until the engine is up
                ZStack {
                    Theme.app
                    StatusView(status: model.status)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    SidebarView()
                        .frame(width: 272)
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline.opacity(0.3)).frame(width: 1) }
                    ZStack {
                        Theme.app
                        if model.status == .live {
                            if model.selectedThreadId != nil {
                                ChatView()
                            } else {
                                EmptyChatView()
                            }
                        } else {
                            StatusView(status: model.status)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if ui.showInspector, model.status == .live, model.selectedThreadId != nil {
                        InspectorView()
                            .frame(width: InspectorView.width(model))
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline.opacity(0.4)).frame(width: 1) }
                            .transition(.offset(x: 28).combined(with: .opacity))
                    }
                }
                .animation(Theme.panelIn, value: ui.showInspector)
            }
        }
        .animation(Theme.appear, value: loaded)
        .onChange(of: model.status, initial: true) { _, status in
            if status == .live { loaded = true }
        }
        .ignoresSafeArea()
        .background(Theme.app)
        .background {
            // ⌘⌥I without a visible toolbar button
            Button("") { ui.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .opacity(0)
        }
        .overlay(alignment: .bottom) {
            if let error = model.lastError {
                ErrorBanner(text: error) { model.lastError = nil }
                    .padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.appear, value: model.lastError)
        .overlay {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Theme.scrim
                        .onTapGesture { model.showPalette = false }
                    GeometryReader { geo in
                        CommandPalette()
                            .frame(maxWidth: .infinity)
                            .padding(.top, geo.size.height * 0.14)
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.2), value: model.showPalette)
        .sheet(isPresented: $model.showNewRoom) { NewRoomSheet() }
        .onAppear {
            OpenWindowBridge.open = { id in
                if id == "settings" { return openSettings() }
                // `remote-settings:<engine id>`: a server's settings window
                if id.hasPrefix("remote-settings:") { return openWindow(id: "remote-settings", value: String(id.dropFirst(16))) }
                openWindow(id: id)
            }
        }
        .onChange(of: model.selection) { _, chat in
            guard let chat else { return }
            Task { await model.markRead(chat) }
        }
    }
}

struct StatusView: View {
    let status: AppModel.Status
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            SwarmeAvatar(color: "green", size: 72, state: icon)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
            if case .failed = status {
                Button(tr("Riprova")) { model.retry() }
                    .buttonStyle(PillButtonStyle(prominent: true))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .padding(40)
        .animation(Theme.appear, value: status)
    }

    private var icon: SwarmeState {
        switch status {
        case .failed: return .scared
        case .offline: return .alerting
        default: return .thinking
        }
    }

    private var title: String {
        switch status {
        case .starting, .connecting: return tr("Avvio di SwarmeBot")
        case .offline: return tr("Connessione persa")
        case .failed: return tr("Il motore non è partito")
        case .live: return ""
        }
    }

    private var detail: String {
        switch status {
        case let .starting(message): return message
        case .connecting: return tr("Collegamento al motore…")
        case let .offline(message): return tr("%@ Riprovo automaticamente.", message)
        case let .failed(message): return message
        case .live: return ""
        }
    }
}

struct EmptyChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            SwarmeAvatar(color: "blue", size: 88, state: .happy)
            Text(tr("Nessuna chat selezionata"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(tr("Scegli un bot a sinistra o creane uno nuovo."))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
            Button(tr("Nuovo bot")) { Task { await model.createBot() } }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(3)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 22))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.raised))
        .overlay(Capsule().stroke(Theme.hairline))
        .task {
            try? await Task.sleep(for: .seconds(6))
            dismiss()
        }
    }
}
