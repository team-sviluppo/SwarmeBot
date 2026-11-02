// The engine executable links the public plugins and any prepared private plugins.
import CodePluginEngine
import HarnessCore
import HarnessRunner
#if SWARMEBOT_PRIVATE_PLUGINS
import PrivatePluginsEngine
#endif

var plugins: [any EnginePlugin] = [CodeEnginePlugin()]
#if SWARMEBOT_PRIVATE_PLUGINS
plugins += PrivatePluginsEngine.make()
#endif
HarnessMain.run(plugins: plugins)
