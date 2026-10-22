// The iOS app (docs/plans/2026-10-22-app-ios.md).
import SwiftUI

@main
struct SwarmeBotApp: App {
    @State private var model = AppModel()
    @State private var localizer = Localizer.shared
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                PushManager.shared.start(model)
                model.becameActive()
            case .background: model.wentToBackground()
            default: break
            }
        }
    }
}
