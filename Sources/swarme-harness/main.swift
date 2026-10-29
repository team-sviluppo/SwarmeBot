// swarme-harness — the Swift engine. A thin shell: everything is in
// HarnessRunner, and this executable only says which plugins it carries
// (docs/plans/2026-10-28-code-mode-t3.md §12). An engine without plugins is
// `HarnessMain.run()`.
import CodePluginEngine
import HarnessRunner

HarnessMain.run(plugins: [CodeEnginePlugin()])
