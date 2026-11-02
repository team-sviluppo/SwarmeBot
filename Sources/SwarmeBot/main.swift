// The app executable links the public plugins and any prepared private plugins.
import CodePluginApp
import SwarmeBotUI
#if SWARMEBOT_PRIVATE_PLUGINS
import PrivatePluginsApp
#endif

MainActor.assumeIsolated {
    var plugins: [any AppPlugin] = [CodeAppPlugin()]
    #if SWARMEBOT_PRIVATE_PLUGINS
    plugins += PrivatePluginsApp.make()
    #endif
    SwarmeApp.run(plugins: plugins)
}
