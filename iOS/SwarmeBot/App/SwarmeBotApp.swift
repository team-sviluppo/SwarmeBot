// The iOS app (docs/plans/2026-10-22-app-ios.md).
import SwiftUI

@main
struct SwarmeBotApp: App {
    @State private var model = AppModel()
    @State private var localizer = Localizer.shared
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // dates, numbers and system controls in the app's language
                .environment(\.locale, localizer.language.locale)
                // the Mac app's dark look (Grok style)
                .preferredColorScheme(.dark)
                .tint(Theme.ink)
        }
        // a push is worded in the language the relay was told
        .onChange(of: localizer.language) {
            Task { await PushManager.shared.registerEverywhere() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                PushManager.shared.start(model)
                Notifier.shared.start(model)
                model.becameActive()
            case .background: model.wentToBackground()
            default: break
            }
        }
        // the servers' bots checked now and then with the app closed (no push needed)
        .backgroundTask(.appRefresh(Notifier.refreshTask)) {
            await model.refreshInBackground()
        }
    }
}
