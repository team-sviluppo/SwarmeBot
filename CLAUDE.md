# CLAUDE.md

Guidance for AI agents working in this repository.

## What this is

SwarmeBot for macOS, native: a SwiftUI app plus `swarme-harness`, a Swift engine that runs AI
"bots" (Claude, Codex, Pi, Antigravity, Grok, DeepSeek Harness, eight ACP agents, a Local
Endpoint / OpenAI-compatible API, a cloud Box agent) behind an HTTP + SSE API. The app is a client of
that API; the same engine also runs on a remote server (Ubuntu 24.04/26.04 or a Mac) so several
clients can share the same bots and chats.

History you need to read the docs correctly:
- The app replaced an Electron shell whose engine was Node (`server/index.ts` in the old repo).
  The Swift engine was ported route by route and frame by frame to the **same wire contract**
  (`docs/contract/http-sse.md`) and verified against Node with `parity/`.
- The Swift engine is now the only engine the app starts (`HarnessEngine.selected == .swift`) and it
  works on the **real data** in `~/.swarmebot` (backed up once to
  `~/Library/Application Support/SwarmeBot/backup-before-swift-engine`). Node and Electron
  leftovers are still in the code: the `HarnessEngine.node` case and the embedded-`node` and
  `../SwarmeBot` mentions in `scripts/bundle-app.sh` and `scripts/release-mac.sh`. Don't build on
  them. The README is user-facing and must not mention Electron or Node.
- This repo used to be called `SwarmeBotSwift`; older notes refer to it by that name.

The project language is **Italian** for UI strings, plans and design docs. Code, code comments
and commit messages are **English**.

The app is localized in English (default) and Italian, chosen in Settings › Generale
(`SwarmeKit/Localization.swift`). UI strings are written in Italian and wrapped in `tr("…")`; the
Italian text is the key and its English goes in `SwarmeL10n/Translations/Translations+<Area>.swift`.
Interpolations become `%@` (`tr("Eliminare %@?", name)`), SwiftUI titles take the `tr` String
(`Button(tr("Salva"))`), words not to translate use `Text(verbatim:)`, dates use `appFormatted`.
`LocalizationTests` fails on a missing English entry or a bare literal title (it also reads `iOS/SwarmeBot`,
whose English goes in `Translations+iOS.swift`). Engine text is English
and stays untranslated.

## Layout

| Target | Role |
|---|---|
| `CompanionCore` | Wire types, SSE parser, HTTP client (`Client`, `Client+Desktop`, `Client+Remote`), pure fold of stream frames into state. Originally copied from the iOS companion — see `docs/companion-core-divergence.md`. |
| `AgentCore` | Shared by the engine and the iOS app, no processes (macOS, iOS, Linux): ordered `JSON`, `StreamingBytes`, `Redact`, `MCPClient` over HTTP, `OAuthFlow`, `OpenAIChatEndpoint` (OpenAI-compatible streaming, tool loop, Hermes continuity). `HarnessCore` re-exports it. |
| `SwarmeL10n` | UI languages, `translate` and the Italian → English tables, for the Mac and iOS apps. |
| `SwarmeKit` | Desktop logic that is not a view: `HarnessLauncher` (start/supervise/stop the engine), observable `AppModel` (+`Desktop`, +`Remote`), `AppPaths`, Keychain credentials, `Remote/` (ssh identities, host keys, remote scripts, server setup flow, Linux engine download). |
| `SwarmeBot` | The SwiftUI app (`Views/`, `Mascot/`, Sparkle `Updater`, notifications). |
| `HarnessCore` | The engine: contracts (`RuntimeEvent`, drivers), `Store` + `MessageDB` (SQLite), `Harness` (turns), `Routes`, `HTTPServer`/`HTTPTransport`/`SSEHub`, rooms, comms between bots, routines, webhooks, library, team, computers (Box, local VM, VPS), MCP connectors + OAuth, permission broker, remote access (devices, pairing, rate limits). |
| `HarnessDrivers` | One file per provider driver; `ACP/ACPCore` (JSON-RPC runtime) + `ACP/ACPDrivers`; `DeepSeek/`. |
| `swarme-harness` | Engine executable. Subcommands: `serve [--remote …]`, `device add|list|revoke`, `secret set|unset`, and MCP stdio helpers spawned by the engine itself (`mcp-permission`, `mcp-agents`, `mcp-connector`, `mcp-container`, `mcp-vps`). New MCP helpers go here as subcommands, not as separate binaries. |
| `CSQLite3` | System libsqlite3 module, Linux only (macOS uses the built-in `SQLite3`). |

`iOS/` is the iOS app (`docs/plans/2026-10-22-app-ios.md`): an XcodeGen `project.yml` using the local
package's `AgentCore`, `CompanionCore` and `SwarmeL10n`; the `.xcodeproj` is generated and git-ignored.

Other folders: `docs/` (contract, plans, benchmarks, design), `parity/` (Node↔Swift comparison and
fake CLIs/servers), `scripts/` (bundle, release, Linux build, integration tests), `Resources/` (app
Info.plist, icon, entitlements). `build/`, `release/`, `.build/` and `.env.mac-release.local` are
git-ignored; never commit them.

## Build, run, test

```sh
swift build
swift test                                   # unit + in-process integration tests
swift test --filter HarnessCoreTests         # engine only
swift run SwarmeBot                          # the app (see warning below)
OMB_PORT=38899 OMB_DATA_DIR=/tmp/swarme swift run swarme-harness   # engine alone, throwaway data
(cd iOS && xcodegen) && xcodebuild -project iOS/SwarmeBot-iOS.xcodeproj -scheme SwarmeBot-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test          # the iOS app
```

The iOS app talks to remote engines only; try it against a throwaway `serve --remote` engine behind Caddy
(debug launch arguments `-pairLink swarmebot://pair?…` and `-openFirstChat YES` skip the camera and the
taps). MLX (Gemma) does not run on the simulator. Building the iOS project makes Xcode write its own pins
(MLX, OneSignal…) into the root `Package.resolved`: don't commit those, the root file pins the package's
dependencies only. The push relay (`swarme-push-relay`) is documented in `docs/push-relay.md`.

**Running the app touches real data.** By default it opens `~/.swarmebot` and the login Keychain.
Before launching it, ask the user, or isolate it with `SWARMEBOT_HOME=/some/test/folder`, which
moves everything the app owns (data, Application Support, Logs, ssh identities, preferences) and
replaces the Keychain with a 0600 file. `HOME` does **not** do this on macOS.
`SWARMEBOT_HOME` does **not** isolate the engine: the launcher first attaches to any engine that
answers on its known ports (8799…), so with the user's SwarmeBot open a test app shows and acts on
the real engine. Check `lsof -iTCP:8799 -sTCP:LISTEN` first; if it is taken, start a test engine
on its own port (`OMB_PORT=38899 OMB_WEBHOOK_PORT=38900 OMB_DATA_DIR=<test>/.swarmebot
.build/debug/swarme-harness`) and launch the app with `SWARMEBOT_HARNESS_URL=http://127.0.0.1:38899`.
Never run two engines on the same data directory.

Useful environment variables:
- `SWARMEBOT_HARNESS_URL` — attach to an engine already running instead of starting one.
- `SWARMEBOT_SNAPSHOT=/path.png` (+ `SWARMEBOT_SNAPSHOT_DELAY`) — screenshot the window, no screen-recording permission needed.
- `SWARMEBOT_LINUX_ENGINES=build/linux` — use locally built Linux engines instead of downloading them.
- Engine: `OMB_PORT`, `OMB_DATA_DIR`, `OMB_WEBHOOK_PORT` (same names as the old Node engine).
- Logs: `~/Library/Logs/SwarmeBot/server.log`.

Tests that need external things skip themselves unless enabled:
- `SWARMEBOT_IT_PORT` — `HarnessIntegrationTests`, via `scripts/integration-test.sh`.
- `SWARMEBOT_VPS_TEST`, `_HTTP`, `_ENGINE`, `_FAKE_MCP`, `_SLOW_CLAUDE` — `RemoteAdminIntegrationTests`,
  `ConnectorCopyTests` against an Ubuntu container with systemd/sshd/sudo.
- `SWARMEBOT_MAC_SERVER_TEST` — `MacServerIntegrationTests` (this Mac as server, throwaway user).

### Parity with the Node engine

`parity/all.sh` runs every scenario on both engines with fake CLIs and servers
(`parity/fake_*.py`) and diffs the normalized SSE traces; `parity/compare.sh` runs one
(`DRIVER=claude|codex|pi|agy|grok|dsh|acp:<kind>`, `SCENARIO=base|advanced|team|rooms|automations|computer`).
It needs the Node reference checkout in `SWARMEBOT_REPO` (default `../SwarmeBot`, which on this
machine is *this* repo, so set it explicitly). If the Node repo isn't available, say that parity
was not run rather than claiming it passed.

When running parity in parallel, give each run its own **short** `TMPDIR` (`TMPDIR=/tmp/swX/`):
`$TMPDIR/swarme-parity` is shared and the permission broker's unix socket path is limited to 104 bytes.

### Packaging, release, Linux engine

```sh
scripts/bundle-app.sh [--arch arm64|x86_64] [--dmg] [--notarize]
scripts/release-mac.sh --version X.Y.Z [--no-publish]   # signs, notarizes, uploads to team-sviluppo/SwarmeBot
scripts/build-linux-engine.sh [aarch64|x86_64]          # Docker, swift:6.4-noble → build/linux/
scripts/linux-engines-manifest.sh <version>             # writes Resources/linux-engines.json (git-ignored)
```

Releases publish to GitHub and Sparkle updates real users: only with an explicit request.
Linux engines are not bundled; the app downloads them from the release and checks the pinned SHA-256.

## Engineering rules

**Wire contract.** `docs/contract/http-sse.md` is frozen. Keep key order, error texts and status
codes identical to what clients expect. The wire distinguishes a missing key from `null`.
- `JSON` preserves key order and unknown fields: a field the engine doesn't know must survive every write.
- `JSON` is `ExpressibleByNilLiteral`: in `cond ? nil : value` the `nil` becomes `JSON.null` and the
  key is written. Use `Optional<JSON>.none` to remove it.
- Frame order matters to clients (e.g. a bot goes "working" before the task folder is set).

**Concurrency.** The engine runs under `dispatchMain()`, which parks the main thread:
- never `MainActor.assumeIsolated` inside a `DispatchQueue.main` block (traps);
- no `Timer` on the main run loop (never fires) — use `Task.sleep`;
- to get back to the main actor in order, feed an `AsyncStream` consumed by one `Task { @MainActor }`.

**Processes.** Launch CLIs through `CLIProcess` (own process group, whole-tree kill, signals reset
with `POSIX_SPAWN_SETSIGDEF` — ignored signals survive `exec`, and a CLI that inherited them could
not be interrupted).

**Linux.** `HarnessCore`, `HarnessDrivers` and `swarme-harness` must keep building on Linux. Use
`POSIXCompat` (`Sys.*`), `StreamingBytes` instead of `URLSession.bytes`, and `#if canImport(...)`
for CryptoKit, SQLite3, FoundationNetworking, PDFKit/Vision/NaturalLanguage. `SwarmeKit`,
`CompanionCore` and the app are macOS 14+ only.

**Remote shell scripts** (`SwarmeKit/Remote/RemoteScripts.swift`): always `sh -c '<script>' sh 'arg'…`
with stdin used only for data. Never put script and data on the same `sh -s` stdin (dash reads in
blocks and would execute the data). Passwords go through `SSH_ASKPASS` and an environment variable
of the ssh process only — never argv or disk.

**Security posture of the remote engine.** Chats from every client (Mac included) go over HTTPS
with a per-device token; ssh is for administration from the Mac only. Device tokens are stored as
SHA-256 hashes; `/api/internal/*` is not reachable remotely; computer routes answer 501 remotely.

**Out of scope** (user decision, don't port or revive): Composio / connected apps, voice/TTS,
Android phone tools, dweb, the old iOS companion sidecar (Bonjour, ports 8810/8811). Their
routes answer 501 on purpose. A future iOS app will be a client of remote engines, so the source
of truth for chats must stay on the engine, not on the Mac.

**If Node had a bug**, don't copy it: keep parity by adjusting the scenario and record it in the
Lessons of `docs/plans/fase-2-architettura.md`.

## Docs to read before working on an area

- `docs/contract/http-sse.md` — routes and frames.
- `docs/plans/fase-2-architettura.md` — engine decisions, progress, **Lessons** (read before touching the engine).
- `docs/plans/2026-10-16-bot-remoto.md` — remote engine: decisions R1–R16, architecture, §14 progress and "Resta da fare".
- `docs/plans/2026-10-15-connettori-mcp.md` — MCP connectors.
- `docs/plans/2026-10-13-swift-native-macos-analisi.md` — the original plan.
- `docs/design/grok-style-spec.md` — UI style.
- `docs/benchmarks/r1-transcript.md` — long-transcript performance (`SWARMEBOT_BENCH=5000`).

When you finish a piece of planned work, update the progress section of the relevant plan, and
list honestly what was verified live and what was not.

## Verification before committing

1. `swift build` with no new warnings (a warning once hid a real bug: `return .none` in a
   function returning `Continuity?` is `nil`, not `Continuity.none`).
2. `swift test` green.
3. Engine changes: `parity/all.sh` (or the relevant `compare.sh` scenario), adding a scenario for new
   behavior visible on the wire.
4. UI changes: run the app on test data (`SWARMEBOT_HOME`) and check the screen, e.g. with
   `SWARMEBOT_SNAPSHOT`.
5. Live turns on real model subscriptions are allowed when needed: short prompts, cheap models,
   and report the cost/tokens shown by the engine.

## Git

- Work happens on feature branches off `main` (none open at the moment: `feat/remote-engine`
  was merged in PR #4); PRs target `main` on `team-sviluppo/SwarmeBot`.
- Commit messages follow the recent `git log`: an English subject in plain words describing the
  effect ("Copy a connector to a remote engine, with its secrets"), a body explaining what changed
  and how it was tested, then the co-author trailer.
- Don't push, open PRs or publish releases without being asked.
