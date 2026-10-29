// SwarmeBot for macOS — a thin shell: the app is SwarmeBotUI, and this
// executable only says which plugins it carries (docs/plans/2026-10-28-code-mode-t3.md §12).
import CodePluginApp
import SwarmeBotUI

MainActor.assumeIsolated {
    SwarmeApp.run(plugins: [CodeAppPlugin()])
}
