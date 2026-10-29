import SwiftUI

/// The app's entry point as a function, so that an executable can pass the
/// plugins it is linked with (`SwarmeApp.run(plugins: [CodeAppPlugin()])`). An
/// edition without plugins passes an empty list.
public enum SwarmeApp {
    @MainActor
    public static func run(plugins: [any AppPlugin] = []) -> Never {
        PluginHost.shared.install(plugins)
        SwarmeBotApp.main()
        // App.main() runs the event loop until the app quits
        exit(0)
    }
}
