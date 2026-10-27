# SwarmeBot

**A native macOS app for running a team of AI agents: one chat per bot, shared channels where bots
work together, automations, tools — on your Mac or on a server that never sleeps.**

SwarmeBot does not ship its own model. It drives the agent CLIs and APIs you already use (Claude Code,
Codex, pi, Gemini CLI, Cursor Agent, any OpenAI-compatible endpoint, and more) and gives them one
interface. Each **bot** has a name, a persona, a working folder, a model and its own memory and
history. You talk to bots one-to-one, put several of them in a **channel**, let them ask each other
for help, schedule them, trigger them from webhooks and give them tools through MCP connectors.

Everything runs in **`swarme-harness`**, a Swift engine with an HTTP + SSE API. The app is a client of
that engine. The same engine can run on a Linux or macOS **server**: your bots keep working with your
laptop closed, and every paired device sees the same chats. An **iPhone app** is a client of those
servers and also has private bots of its own.

> **Status:** active development, macOS 14+ and iOS 26+. The interface is in English and Italian
> (Settings › General).

---

## Contents

- [How it works](#how-it-works)
- [Features](#features)
- [Supported agents and models](#supported-agents-and-models)
- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [Testing](#testing)
- [Remote bots (SwarmeBot on a server)](#remote-bots-swarmebot-on-a-server)
- [iOS app](#ios-app)
- [Packaging and releases](#packaging-and-releases)
- [Project layout](#project-layout)
- [Data, privacy and security](#data-privacy-and-security)
- [Configuration reference](#configuration-reference)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

---

## How it works

```
┌──────────────────────────┐   HTTP + SSE (127.0.0.1)   ┌──────────────────────────────────────┐
│  SwarmeBot.app (SwiftUI) │ ─────────────────────────► │  swarme-harness (the engine)         │
│  sidebar · chat · panels │ ◄───────────────────────── │  bots · channels · turns · approvals │
└──────────────────────────┘     live event stream      │  store (JSON + SQLite) · automations │
                                                         │  MCP connectors · computers          │
                                                         └──────────────┬───────────────────────┘
                                                                        │ spawns / calls
                                     ┌───────────────┬──────────────────┼──────────────┬────────────────┐
                                     ▼               ▼                  ▼              ▼                ▼
                                Claude Code       Codex              pi           ACP agents     OpenAI-compatible
                                 (CLI)        (app-server)          (RPC)      (Gemini, Cursor…)   HTTP endpoint
```

- When the app starts, it launches `swarme-harness` on `127.0.0.1` (or attaches to one already
  running), supervises it and stops it on quit. If the app is killed, the engine exits on its own.
- A **turn** is one reply from a bot. The engine starts or resumes the agent's session, streams its
  text, reasoning and tool calls as events, asks you for permission when the agent wants to do
  something that needs it, and stores the result.
- Events reach every connected client over Server-Sent Events, with resume: a client that
  reconnects picks up where it left off.
- Each agent is driven through a **driver** that speaks its native protocol (stream-json, JSON-RPC,
  ACP, OpenAI chat completions…). Agents run as child processes in their own process group, so
  stopping a turn stops the whole tree.
- Data lives in `~/.swarmebot`: bots, channels and configuration as JSON, messages in SQLite.

---

## Features

### Bots and chats
- **Bots** with name, persona (system prompt), avatar (a generated mascot, an image or an SVG),
  working folder, engine and model. Pin, hide, mark unread, search.
- **Streaming chat** with reasoning, Markdown, and **tool calls folded** into groups that show what
  each call returned.
- **Permission and question cards**: when an agent asks to run a command or edit a file, or asks you
  a question (single or multiple choice), the chat shows a card. Per-bot **auto-approve** modes and
  "always allow" rules.
- **Edit and resend** a message and move between versions of the conversation (‹ 1/3 ›).
- **Queued messages**: write while the bot is working; messages run in order. **Stop** keeps the
  partial reply.
- **Tasks**: a bot's work is split into tasks (threads) you can create, switch, rename, pin, delete,
  each with its cost and token usage.
- **Attachments**: paste images, drop files, attach long text as a chip; reactions on messages.
- **Model picker** per bot with reasoning **effort** where the agent supports it.
- **Memory** and a **decision log** per bot.

### Channels (multi-bot)
- Channels with several bots and a **board** (shared notes for the room).
- Choose who answers: a **default responder**, **@mentions**, **@everyone**, one-step chains where a
  bot hands off to the next. One member speaks at a time; each has its own read cursor.
- Timeouts for channel turns, configurable in Settings.

### Bots talking to bots
- Every bot gets an `agents` MCP server: **`ask_bot`** (ask another bot and wait for the answer) and
  **`delegate_bot`** (hand off work that runs after the current turn, with a persistent queue).
- Approvals between bots appear as cards; conversations between two bots get their own channel.
- A **watchdog** unblocks stuck turns and flags **repeated tool calls**.

### Automations (⇧⌘R)
- **Routines**: a prompt that runs once or every day at a set time on chosen weekdays, in a given
  time zone. Missed runs are caught up within 12 hours, otherwise marked as missed. Run now, cancel,
  history of runs.
- **Webhooks**: a private URL that gives a bot a task when it receives a `POST`. The secret is shown
  once and stored only as a SHA-256 hash; rotation, test delivery, event-type filters, idempotency
  by delivery id, rate limits, history of deliveries. The payload reaches the bot inside an
  explicit *untrusted content* block.
- Automation turns run unattended and produce tasks you can read later.

### MCP connectors
- Add **MCP servers** once and hand them to any bot, whatever its agent: they are mounted on
  Claude, Codex and ACP agents, and run in the engine's own loop for API-based engines.
- **stdio** (local process) or **HTTP** transport; headers, secrets, and **OAuth** (with automatic
  client registration). SwarmeBot keeps the tokens: bots never see them, and switching agent does
  not require a new login.
- **Test connection**, list of tools with per-tool on/off, read-only markers.
- **Import** from `claude_desktop_config.json` or `.mcp.json`: values whose name contains KEY,
  TOKEN, SECRET, PASSWORD or AUTH become secrets.

### Library
- Per-bot **library** of PDFs and text files, enabled chat by chat. On macOS, PDF text extraction,
  OCR and semantic search; keyword search elsewhere.
- **Team library**: export bots and their setup as a package, import from a file or from GitHub
  (add, replace, or as a project), with validation of the manifest.

### Computers
- **Local VM**: a container-based desktop the bot controls through a `computer` MCP server.
- **Cloud computer** (Box): a remote desktop shown in the inspector, with **take over** and
  hand-back, and a "help" request from the bot when it is stuck.
- **This Mac** (off by default): lets a bot drive your Mac through Cua; a live preview of the screen
  via ScreenCaptureKit.

### Interface
- Sidebar with sections (user sections, pinned, unread, hidden), context menus, search.
- **⌘K** command palette: jump to chats, run commands, search messages and jump to the hit.
- **Inspector**: Details (persona, auto-approve, notifications, working folder), Library, Computer.
- macOS **notifications**, Dock badge and menu.
- **Settings** (⌘,, always this Mac's engine): language and theme, profile and channel timeouts;
  **Engines** (executable, test, visibility, install and log in through Terminal); **Remote servers**;
  **Connectors**; **Skills**; **Phone**; **Mac control**; **Keys and services** (API keys in the macOS
  Keychain, OpenAI-compatible server, VPS); **DeepSeek** (direct or paired connection); **Updates**.
  Each server has its own settings window (see [Server settings](#server-settings)).
- Automatic updates with **Sparkle** (signed appcast, EdDSA-verified archives).

### Remote bots
Run the engine on an Ubuntu or macOS server, set it up from the app over ssh, and chat with it over
HTTPS from any paired device. See [Remote bots](#remote-bots-swarmebot-on-a-server).

### iPhone
A client of your servers (same bots, same chats, push notifications) with private bots of its own:
an OpenAI-compatible endpoint, Gemma on the phone, Apple Foundation Models. See [iOS app](#ios-app).

---

## Supported agents and models

An **instance** is an agent the engine can use; a bot picks an instance and a model. Agents that are
not installed show up as unavailable, and Settings › Engines can install them and open a Terminal
to log in.

| Agent | How SwarmeBot drives it |
|---|---|
| **Claude Code** (`claude`) | stream-json, session resume, permission broker over MCP, `ask_user` questions |
| **Codex** (`codex app-server`) | JSON-RPC, approvals, questions, model list |
| **pi** (`pi --mode rpc`) | its own RPC, one session per file, model switching |
| **Antigravity** (`agy`) | print mode with conversation resume |
| **ACP agents** | Agent Client Protocol: Gemini CLI, Grok CLI, Kimi CLI, Factory Droid, Cursor Agent, OpenCode Go, Qwen Code, Hermes |
| **Grok API** (xAI) | direct API |
| **OpenAI-compatible server** | any server speaking the OpenAI API: LiteLLM, vLLM, Ollama, LM Studio… (with session continuity for Hermes behind LiteLLM) |
| **DeepSeek Harness** | Host API over HTTP + WebSocket, direct or paired |
| **Box agent** | an agent that works on a cloud computer |

Local models served by your OpenAI-compatible server can also be **injected** into Claude Code, Codex and the
ACP agents that support custom providers: SwarmeBot writes the agent's config for you.

You bring your own subscriptions and API keys: SwarmeBot never proxies your traffic through a
third-party service.

---

## Requirements

- **macOS 14 Sonoma** or later (Apple silicon or Intel).
- **Xcode** or the Swift toolchain, **Swift 6.0+** (developed with Swift 6.4).
- At least one agent installed and logged in (for example `claude`), or an OpenAI-compatible endpoint.
- Optional:
  - **Docker** — to build the Linux engine and to run the local-VM computer;
  - **Python 3** — parity tests;
  - **Caddy** — to run a Mac as a remote server.

## Build and run

```sh
git clone https://github.com/team-sviluppo/SwarmeBot.git
cd SwarmeBot
swift build
swift run SwarmeBot
```

On first launch the app creates `~/.swarmebot` and starts the engine. On a machine that already
has data there, it first makes a one-time full backup to
`~/Library/Application Support/SwarmeBot/backup-before-swift-engine`.

> **Developing? Use test data.** By default the app uses your real `~/.swarmebot` and your login
> Keychain. Set `SWARMEBOT_HOME` to keep everything the app owns (data, Application Support, logs,
> ssh identities, preferences; tokens in a 0600 file instead of the Keychain) inside another folder:
>
> ```sh
> SWARMEBOT_HOME=/tmp/sbdev swift run SwarmeBot
> ```
>
> Setting `HOME` is not enough on macOS: Foundation reads the home folder from the user database.
> Never run two engines on the same data folder.

Run the engine on its own, without the app:

```sh
OMB_PORT=38899 OMB_DATA_DIR=/tmp/swarme swift run swarme-harness
curl http://127.0.0.1:38899/api/health
```

Engine log: `~/Library/Logs/SwarmeBot/server.log`.

---

## Testing

```sh
swift test                                   # all unit and in-process integration tests
swift test --filter HarnessCoreTests         # the engine
swift test --filter CompanionCoreTests       # wire types, SSE parser, client state
swift test --filter SwarmeKitTests           # launcher, app model, remote administration
```

Some suites need external pieces and **skip themselves** unless enabled:

| Suite | Enable with | Needs |
|---|---|---|
| `HarnessIntegrationTests` | `scripts/integration-test.sh` (sets `SWARMEBOT_IT_PORT`) | an engine on a throwaway data folder |
| `RemoteAdminIntegrationTests`, `ServerSetupFlowIntegrationTests`, `EngineUpdateIntegrationTests`, `ConnectorCopyIntegrationTests`, `PiConfigIntegrationTests` | `SWARMEBOT_VPS_TEST=user@host[:port]`, `SWARMEBOT_VPS_HTTP`, `SWARMEBOT_VPS_ENGINE`, `SWARMEBOT_SSH_PASSWORD`, … | an Ubuntu 24.04 machine or container with systemd, sshd and sudo |
| `MacServerIntegrationTests` | `SWARMEBOT_MAC_SERVER_TEST` | this Mac as a server, with a throwaway admin user |

### End-to-end checks without spending tokens

`parity/` contains fake agents and services (`fake_claude.py`, `fake_codex.py`, `fake_acp.py`,
`fake_pi.py`, `fake_openai.py`, `fake_mcp.py`, `fake_docker.py`, `fake_box.py`, …) and
`parity/run_scenario.py`, which drives an engine through a whole scenario (streaming, permission
cards, questions, interruptions, channels, automations, computers) and records the normalized event
trace. `parity/compare.sh` runs the same scenario on two engines and diffs the traces; it was used to
port the engine from an earlier implementation and needs that reference in `SWARMEBOT_REPO`.

```sh
DRIVER=claude SCENARIO=rooms parity/compare.sh
parity/all.sh                       # every scenario and driver
```

Run parity jobs in parallel only with separate, short `TMPDIR`s (`TMPDIR=/tmp/sw1/`): unix socket
paths are limited to 104 bytes.

### Visual checks

```sh
SWARMEBOT_HOME=/tmp/sbdev SWARMEBOT_SNAPSHOT=/tmp/window.png swift run SwarmeBot
```

writes a screenshot of the window after 10 s (`SWARMEBOT_SNAPSHOT_DELAY`), without asking for the
screen-recording permission. `SWARMEBOT_BENCH=5000 .build/release/SwarmeBot` benchmarks a long
transcript (see `docs/benchmarks/r1-transcript.md`).

---

## Remote bots (SwarmeBot on a server)

### What it is

A **remote engine** is the whole `swarme-harness` — store, turns, agents, connectors, automations —
running as a service on a server you control. The Mac app and the iOS app are just clients.

- Start a conversation on your Mac, close the lid, keep going from another device: the turn runs on
  the server and every client sees the same chats.
- Routines and webhooks of a remote bot run on the server, even with every client disconnected.
- Supported servers: **Ubuntu 24.04 / 26.04** (x86_64, aarch64) and **macOS 14+**.
- Agents on the server: the setup installs **Claude Code** and **pi** and can log them in from the
  Mac; other CLIs can be installed from a terminal on the server. The **OpenAI-compatible server**
  (LiteLLM, vLLM, Hermes…) needs only a URL and a key, set in the [server's settings](#server-settings).
- One engine per unix user: several people can share a server, each with their own engine, data
  and agent logins.

### Architecture

```
                 chat: HTTPS + device token
 Mac app ───────┐
                ├──► [optional proxy in a DMZ] ──► Caddy on the server ──► unix socket ──► swarme-harness
 other device ──┘                                    (TLS, path prefix)                     (runs as your user;
                                                                                             claude / pi as children)
 Mac app ──ssh──► server        administration only: install, update, log in, first token
```

- **Two addresses per server.** An *admin address* (ssh host and port; can be private) used only by
  the Mac that administers the server, and a *chat URL* (`https://host/<prefix>/`) used by every
  client.
- **Chat is HTTPS with a per-device token**, for the Mac too. The engine listens only on a unix
  socket; Caddy terminates TLS, strips the path prefix and forwards to it. Webhooks get their own
  socket under `<prefix>/hooks/`.
- **ssh is only for administration.** Your ssh password is used once to install a dedicated key and
  is never stored. There is one key per (host, port, user); the host fingerprint is shown for you
  to approve and kept in SwarmeBot's own `known_hosts`. A changed host key blocks the connection.
- **Always on**: a `systemd --user` service with linger on Linux, a LaunchDaemon running as your
  user on macOS. Both start at boot without anyone logging in, and restart the engine if it dies.
- **Limits**: remote bots are meant to run with permissions bypassed, so use a dedicated unix user
  without sudo for the engine. The computer-use features are not available remotely. A channel of
  this Mac (or of the phone) can invite bots of a server as guests; their replies arrive whole at the
  end of the turn.

### Before you start

On the **server**:
- an account that can log in over ssh with a password or an existing key;
- `sudo` for that account, or root, for the one-time system steps (Caddy, socket folder, service);
- for a public setup, a DNS name pointing to the server and ports 80/443 open (Let's Encrypt);
- **macOS server**: Remote Login enabled and Caddy installed (`brew install caddy`). On Ubuntu the
  setup installs Caddy and the runtime libraries (`libsqlite3-0`, `libcurl4t64`) with `apt`.

On the **Mac**: SwarmeBot, and for the Claude login, Claude Code installed and logged in.

### Install a server from the app

1. **Settings › Remote servers › Add a server…** (*Impostazioni › Server remoti › Aggiungi un server…*).
2. Fill in the form:
   - **Name** — how the server appears in the app (e.g. `srv1 · deploy`);
   - **Server, ssh port, user** — the admin address (e.g. `10.0.4.12`, `22`, `deploy`);
   - **Caddy site** — the site Caddy serves: a domain (`bot.example.com`) for a public server, or
     `:8080` when another HTTPS proxy sits in front;
   - **Prefix** — the path for this user's engine (e.g. `/srv1/deploy`), so several users can share
     one Caddy;
   - **TLS** — *Public (Let's Encrypt)* or *None: behind an HTTPS proxy*;
   - **Chat URL** — only when a proxy fronts the server; otherwise derived from site and prefix.
3. **Connect**. The setup runs these steps and shows each one:

   | Step | What happens |
   |---|---|
   | Server fingerprint | `ssh-keyscan`; you compare the SHA256 fingerprint with the server console and approve it |
   | Dedicated key | an ed25519 key for this (host, port, user) is created and added to `authorized_keys`, using your password once |
   | Server check | OS, version, architecture, installed `claude` / `pi`, Caddy, service state |
   | Root steps | Caddy installed and running, socket folder, start at boot (linger or LaunchDaemon). Uses `sudo`, with your password if needed; never stored |
   | SwarmeBot engine | the engine for the server's OS and architecture is uploaded to `~/.swarmebot/bin` and its SHA-256 checked. Linux engines are downloaded from the release, pinned by digest; a Mac server gets the app's own engine |
   | Service and HTTPS routes | the service is installed and started; Caddy routes for `<prefix>/*` and `<prefix>/hooks/*` are written, validated with `caddy validate` and rolled back if invalid |
   | Token for this Mac | `swarme-harness device add` creates this Mac's device token; it goes to the Keychain |

4. **Show the server's bots**. The sidebar lists this Mac's sections and, below them, one section per
   server with all its bots. Opening a chat of a server switches the window to that engine: chat,
   inspector and automations are the server's.

The setup is idempotent: run it again to repair a server.

### Log the agents in on the server

A server user that never logged in at the console has no Keychain, so agents cannot store their
login the usual way. From the server's card in **Settings › Remote servers**:

- **Claude login on the server…** — run `claude setup-token` on your Mac, paste the long-lived
  token; it is stored on the server in `secrets.json` (0600) as `CLAUDE_CODE_OAUTH_TOKEN` and the
  engine restarts to pick it up.
- **Copy pi's configuration…** — copies `auth.json`, `models.json` and `settings.json` from
  `~/.pi/agent` (0600; files already on the server are kept as backups) and restarts the engine.
- **Open a terminal on the server** — a Terminal window already connected with the dedicated key,
  e.g. to install `pi` (`npm i -g …`) or Claude Code.

### Server settings

⌘, always edits **this Mac's** engine. A server's settings are in a window of their own:
**Settings › Remote servers › Remote server settings** (*Impostazioni › Server remoti ›
Impostazioni server remoto*) opens **[REMOTE SERVER] - <name>**, one window per server, with:

| Tab | What it changes on the server |
|---|---|
| General | profile (how bots address you) and channel timeouts |
| Engines | which agents the server sees, their executable, visibility in the model picker. Install and sign-in commands are shown, to be run in *Open a terminal on the server* |
| Connectors, Skills | the server's own MCP connectors and skills |
| Keys and services | API keys and the **OpenAI-compatible server** URL. Keys go to the server's `secrets.json` (0600), never to this Mac's Keychain or to `config.json` |
| DeepSeek | the server's DeepSeek Harness connection |

Language, theme, phone, Mac control, VPS and updates belong to this Mac and are not there.

An engine shows up in a bot's model picker only once it is available. For example, to give the bots
of a server an OpenAI-compatible endpoint (such as Hermes Agent behind LiteLLM), set its base URL and
key in the server's *Keys and services*: **OpenAI-compatible server** then appears in the picker of
that server's bots. The server calls the endpoint itself, so it must be able to reach it. Those bots'
chats live on the server, so the Mac and the iPhone see the same ones.

### Connectors on a server

The server's settings window manages the server's own connectors. From a
connector of *This Mac*, **Copy to server ▸ <server>** creates it on the server with its secrets and
runs *Test connection* there (a stdio command available on your Mac may be missing on the server).
OAuth connectors cannot be copied yet.

### Pair other devices

**Pair a phone or another Mac…** shows a QR code and a one-time code valid for 10 minutes. The QR
holds `swarmebot://pair?url=…&code=…&name=…`, never a token. On another Mac use **Connect a server
with a code…**, paste the chat URL and the code. **Paired devices…** lists devices with their last
activity and lets you **revoke** them; revocation closes their open streams immediately.

### Update the engine

The server card says whether the server runs the engine that matches this app. **Update engine**
replaces the binary and restarts the service, then waits for the chat URL to answer. If bots are
working, it refuses unless you confirm (*Update and interrupt*). A client that meets an engine with
an incompatible contract says so and tells you how to fix it.

### Try it locally

You can exercise the whole flow without a public server.

**Linux in a container**: a throwaway Ubuntu 24.04 container with systemd, sshd and a sudo user,
with ssh and Caddy's port published on localhost. Then:

```sh
scripts/build-linux-engine.sh aarch64            # or x86_64; Docker, ~minutes; → build/linux/
SWARMEBOT_HOME=/tmp/sbremote \
SWARMEBOT_LINUX_ENGINES=build/linux \
  swift run SwarmeBot
```

In *Add a server* use `127.0.0.1`, the published ssh port and user, site `:8080` (or the port you
published), prefix `/srv1/<user>`, TLS *None*, and set the chat URL to
`http://127.0.0.1:<published port>/srv1/<user>`.

**A Mac as server**: create a throwaway admin user, enable Remote Login limited to that user,
`brew install caddy`, and add `that-user@127.0.0.1` as a server. The same flow is automated by
`MacServerIntegrationTests` (`SWARMEBOT_MAC_SERVER_TEST`).

`SWARMEBOT_HOME` keeps the identities, tokens and the list of servers out of your real data.

### Manual install and administration

The app runs these for you, but the engine can be managed by hand on the server:

```sh
# start the engine in remote mode (normally done by the service)
swarme-harness serve --remote \
  --socket /run/swarmebot/$USER/engine.sock \
  --webhook-socket /run/swarmebot/$USER/hooks.sock \
  --public-url https://bot.example.com/srv1/$USER/

swarme-harness device add --name "My Mac" --kind mac   # prints a token once
swarme-harness device list
swarme-harness device revoke <id>
swarme-harness secret set CLAUDE_CODE_OAUTH_TOKEN     # value on stdin
swarme-harness secret unset CLAUDE_CODE_OAUTH_TOKEN
```

On Linux the sockets live in `/run/swarmebot/<user>/` (created by tmpfiles.d, group `caddy`); on
macOS in `~/.swarmebot/run`. The Caddy routes look like:

```caddyfile
bot.example.com {
	handle_path /srv1/deploy/hooks/* {
		reverse_proxy unix//run/swarmebot/deploy/hooks.sock
	}
	handle_path /srv1/deploy/* {
		reverse_proxy unix//run/swarmebot/deploy/engine.sock {
			flush_interval -1
			transport http {
				read_timeout 0
			}
		}
	}
}
```

### Behind a reverse proxy or on a private network

For a server with a private IP, put an HTTPS proxy in a DMZ in front of it (or use a tunnel such as
Cloudflare Tunnel, frp or Tailscale) and set the **chat URL** to the public address. The proxy only
forwards; authentication is done by the engine. Requirements for any proxy in front of the engine:

- **no response buffering** for the event stream (the engine sends `X-Accel-Buffering: no`) and a
  read timeout of at least 5 minutes; the engine sends a keepalive every 15 s;
- strip the path prefix, or forward it consistently with the chat URL;
- a body size limit large enough for image attachments;
- `X-Forwarded-For` is honored only from trusted proxies.

### Security of a remote engine

- Every public route requires a device token (`Authorization: Bearer …`), except `GET /api/health`
  and the one-time pairing claim. Tokens are 32 random bytes, stored on the server only as SHA-256
  hashes and on clients only in the Keychain.
- 10 failed attempts in a minute from one address → `429` for 5 minutes.
- Requests with an `Origin` header are refused; no CORS. Internal routes are not reachable from the
  public socket.
- Engine socket 0660 shared only with Caddy, data folder 0700; users of the same server cannot reach
  each other's engine.
- Connector secrets and agent tokens on the server are in 0600 files of the engine's user: root on
  that server can read them.
- Remote bots run with permissions bypassed: they can do whatever their unix user can. Give the
  engine a dedicated user without sudo.
- sshd can be restricted to your internal network; chat does not need it.

---

## iOS app

### What it does

The iPhone app (iOS 26+) lives in `iOS/` and has two kinds of bots, in separate sections of its list:

- **Server bots.** It is a client of your remote engines, like the Mac app: same bots, same chats, over
  HTTPS with its own device token. Pair it from the Mac (**Settings › Remote servers › Actions › Pair a
  phone or another Mac…**) by scanning the QR code. It shows streaming replies, permission and question
  cards (answerable from the notification too), attachments, older messages, and resumes the stream
  after the app was in the background or the network changed.
- **Private bots, on the phone only.** An **OpenAI-compatible endpoint** (with the same Hermes session
  rules as the engine), **Gemma 4 E4B** running on the phone with MLX (downloaded on request, about
  5 GB, iPhones with at least 8 GB of memory), and **Apple Foundation Models** (chat only). MCP
  connectors over HTTP, with OAuth. Their chats are stored on the phone only.
- **Settings from the Mac.** Endpoints and HTTP connectors can be sent from the Mac (**Settings ›
  Phone**) with a QR code on the same network or an encrypted `.swarmeconfig` file. Chats are never
  copied; OAuth connectors need a new login on the phone.
- **Push notifications** ("a bot finished", "a bot asks for approval") for server bots, through a
  relay that holds the AWS credentials and sends through Amazon SNS (see [`docs/push-relay.md`](docs/push-relay.md)).

Private bots of the Mac and of the phone are never synced. To see the same chats on both, put the bot
on a server.

### Build

Needs **Xcode 26** (iOS 26 SDK), [**XcodeGen**](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and the Metal Toolchain component for MLX
(`xcodebuild -downloadComponent MetalToolchain`). The Xcode project is generated from
`iOS/project.yml` and is git-ignored.

```sh
(cd iOS && xcodegen)
open iOS/SwarmeBot-iOS.xcodeproj                       # or, from the command line:
xcodebuild -project iOS/SwarmeBot-iOS.xcodeproj -scheme SwarmeBot-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

- The project uses the package's `AgentCore`, `CompanionCore` and `SwarmeL10n`. MLX, the Hugging Face
  libraries are added to the Xcode project only, never to `Package.swift`.
  Building it makes Xcode write their pins into the root `Package.resolved`: don't commit those.
- The **SwarmeBot-iOS Release** scheme runs an optimized build without the debugger, much faster on a
  device (MLX above all).
- Gemma does not run in the simulator. To try the app in the simulator against a throwaway engine
  (`swarme-harness serve --remote` behind Caddy), the debug launch arguments
  `-pairLink swarmebot://pair?…` and `-openFirstChat YES` skip the camera and the taps.
- To run on your own iPhone, create `iOS/Local.xcconfig` (git-ignored) with your team:

  ```
  DEVELOPMENT_TEAM = ABCDE12345
  ```

### Your own build (bundle ID, signing, pushes)

Apple ties push notifications to the app's bundle ID and APNs key, and the AWS credentials must stay
on the relay. So a build under another bundle ID needs its own Apple setup, its own Amazon SNS
applications and its own relay. Values come from `iOS/Shared.xcconfig` (the official build) and are overridden in
`iOS/Local.xcconfig`:

```
DEVELOPMENT_TEAM = <your Apple team ID>
SWARMEBOT_BUNDLE_ID = com.example.swarmebot
SWARMEBOT_PUSH_RELAY = https:/$()/bot.example.com/srv1/deploy/push
```

In an xcconfig file `//` starts a comment: `$()` keeps the URL whole. Then run `xcodegen` again.

1. **Apple Developer account.** Register the App ID `<bundle>` with these capabilities: **Push
   Notifications** and **Increased Memory Limit** (Gemma).

   With *Automatically manage signing* and your team in `DEVELOPMENT_TEAM`, Xcode creates the
   provisioning profiles; otherwise create a development or App Store profile for each App ID.
2. **APNs key.** In Certificates, Identifiers & Profiles › Keys, create a key with Apple Push
   Notifications service and download the `.p8` (keep its Key ID and your Team ID).
3. **Amazon SNS.** Create two platform applications with token authentication and the `.p8` (Key ID,
   Team ID, your bundle ID): *Apple iOS* for production (TestFlight, App Store) and *Apple iOS Sandbox*
   for builds run from Xcode. Then an IAM user for the relay that may only create endpoints and publish
   to them. The steps and the policy are in [`docs/push-relay.md`](docs/push-relay.md).
4. **Relay.** The easiest way is next to one of your remote engines, from the Mac that administers
   it: **Settings › Remote servers › Actions › Host the Push Notification Relay…** with the two
   application ARNs and the IAM user's access key. It answers on `<chat URL>/push`: that is
   `SWARMEBOT_PUSH_RELAY`. Install it on one server only. A manual install is described in
   [`docs/push-relay.md`](docs/push-relay.md).
5. **Build** with the values above. Without `SWARMEBOT_PUSH_RELAY` the app registers nowhere and pushes
   stay off; everything else works.

Other identifiers, which may stay as they are or be renamed together:

| Identifier | Where |
|---|---|
| Version and build number | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` in `iOS/project.yml` |
| Background refresh task `it.hextra.swarmebot.refresh` | `BGTaskSchedulerPermittedIdentifiers` in `iOS/project.yml` and `iOS/SwarmeBot/Model/Notifier.swift` |
| Exported file type `it.hextra.swarmebot.phone-config` (`.swarmeconfig`) | `iOS/project.yml`; the Mac app writes these files |
| URL scheme `swarmebot://` (pairing, OAuth callback) | `CFBundleURLTypes` in `iOS/project.yml` |
| Keychain service and log subsystem `it.hextra.swarmebot` | `iOS/SwarmeBot/Model/Keychain.swift`, `RemoteSession.swift` |
| App icon, display name | `iOS/SwarmeBot/Resources`, `INFOPLIST_KEY_CFBundleDisplayName` |

For TestFlight or the App Store, archive with the Release configuration (Product › Archive) and upload
from the Organizer.

---

## Packaging and releases

```sh
scripts/bundle-app.sh --arch arm64 --dmg        # build/SwarmeBot.app and build/SwarmeBot.dmg (ad-hoc signed)
scripts/bundle-app.sh --arch x86_64 --dmg       # Intel build: build/SwarmeBot-intel.dmg
```

Signed and notarized builds:

```sh
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<notarytool profile> \
SPARKLE_PUBLIC_KEY=<EdDSA public key> \
  scripts/bundle-app.sh --arch arm64 --dmg --notarize
```

`scripts/release-mac.sh --version X.Y.Z` builds, signs and notarizes both architectures, builds the
Linux engines (`scripts/linux-engines-manifest.sh`), tags `vX.Y.Z` and publishes DMGs, zips, Linux
engines and `appcast.xml` as a GitHub release (`--no-publish` to skip). Credentials are read from
`.env.mac-release.local` (git-ignored; start from `.env.mac-release.example`): `MAC_SIGN_IDENTITY`,
Apple ID or `NOTARY_PROFILE`, `SPARKLE_PUBLIC_KEY`. Forks should also set `RELEASES_REPO` and
`SPARKLE_FEED_URL` to their own repository.

Sparkle keys are generated once on the Mac that publishes:

```sh
curl -fsSL -o /tmp/Sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz
mkdir -p /tmp/sparkle && tar -xJf /tmp/Sparkle.tar.xz -C /tmp/sparkle
/tmp/sparkle/bin/generate_keys     # prints SUPublicEDKey; the private key stays in the Keychain
```

The Linux engine is built in Docker on `swift:6.4-noble` with the Swift runtime linked in, so it
runs on Ubuntu 24.04 and 26.04:

```sh
scripts/build-linux-engine.sh               # both architectures → build/linux/swarme-harness-<arch> + .sha256
```

x86_64 on Apple silicon runs under emulation: enable Rosetta in Docker Desktop, or
`docker run --privileged --rm tonistiigi/binfmt --install amd64`.

---

## Project layout

| Path | Contents |
|---|---|
| `Sources/SwarmeBot` | the SwiftUI app: views, mascot, notifications, Sparkle updater |
| `Sources/SwarmeKit` | app logic that is not UI: engine launcher and supervision, observable app model, Keychain, paths; `Remote/` for ssh identities, host keys, server setup, engine updates, Linux engine download |
| `Sources/CompanionCore` | wire types, SSE parser with resume, HTTP client, pure fold of events into state (Mac and iOS) |
| `Sources/AgentCore` | shared by the engine and the iOS app: ordered JSON, streaming, MCP client over HTTP, OAuth, OpenAI-compatible chat with Hermes continuity |
| `Sources/SwarmeL10n` | UI languages and the Italian → English tables, for the Mac and iOS apps |
| `Sources/HarnessCore` | the engine: JSON with stable key order, store and SQLite, turns, routes, HTTP server and SSE hub, channels, bot-to-bot comms, routines, webhooks, library, team packages, computers, MCP connectors and OAuth, permission broker, remote access |
| `Sources/HarnessDrivers` | one driver per agent; `ACP/` (protocol runtime + agents), `DeepSeek/` |
| `Sources/swarme-harness` | the engine executable and its subcommands |
| `Sources/swarme-push-relay` | the push notification relay (Amazon SNS) for the iOS app |
| `iOS/` | the iOS app: `project.yml` (XcodeGen), `SwarmeBot/`, tests |
| `Tests/` | `HarnessCoreTests`, `CompanionCoreTests`, `SwarmeKitTests` |
| `parity/` | fake agents and services, scenario runner, trace comparison |
| `scripts/` | bundling, release, Linux engine build, integration tests |
| `docs/` | HTTP/SSE contract, architecture and plans, benchmarks, design notes |

`HarnessCore`, `HarnessDrivers`, `AgentCore` and `swarme-harness` build on macOS and Linux; `AgentCore`,
`CompanionCore` and `SwarmeL10n` also on iOS; the Mac app and `SwarmeKit` are macOS only.

---

## Data, privacy and security

- Everything stays on your machine (or your server): `~/.swarmebot` holds `bots.json`,
  `groups.json`, `config.json`, `messages.db` (SQLite, WAL) and event logs.
- API keys you enter in Settings are stored in the **macOS Keychain** and handed to the engine at
  start; they are not written to `config.json`. Keys entered in a server's settings go only to that
  server's `secrets.json` (0600). Logs are redacted.
- The iOS app keeps device tokens, endpoint keys and OAuth tokens in its Keychain (available after
  first unlock, never synced to iCloud); private chats stay on the phone.
- The local engine listens only on `127.0.0.1` and refuses requests whose `Host` or `Origin` is not
  loopback.
- Agents run with your user's rights. Permission cards and auto-approve rules decide what they may do
  without asking; "This Mac" control is off by default.
- Webhook payloads are passed to bots as untrusted content.

---

## Configuration reference

**App**

| Variable | Effect |
|---|---|
| `SWARMEBOT_HOME` | use another folder in place of your home for everything the app owns; no Keychain |
| `SWARMEBOT_HARNESS_URL` | attach to an engine already running instead of starting one |
| `SWARMEBOT_SNAPSHOT`, `SWARMEBOT_SNAPSHOT_DELAY` | write a window screenshot after a delay |
| `SWARMEBOT_LINUX_ENGINES` | folder with locally built Linux engines (instead of downloading them) |
| `SWARMEBOT_BENCH` | run the transcript benchmark with N messages |

**Engine**

| Variable | Effect |
|---|---|
| `OMB_PORT` | HTTP port on 127.0.0.1 (local mode) |
| `OMB_DATA_DIR` | data folder (default `~/.swarmebot`) |
| `OMB_WEBHOOK_PORT` | webhook listener port (default 8800, local mode) |
| `OMB_TURN_STALL_MS` | watchdog threshold for stuck turns (default 20 minutes, minimum 1 minute) |
| `OMB_EXTRA_PATH` | extra `PATH` entries used to find agent CLIs |

---

## Documentation

- [`docs/contract/http-sse.md`](docs/contract/http-sse.md) — the HTTP + SSE API between clients and the engine.
- [`docs/plans/fase-2-architettura.md`](docs/plans/fase-2-architettura.md) — engine architecture, decisions and lessons learned.
- [`docs/plans/2026-10-16-bot-remoto.md`](docs/plans/2026-10-16-bot-remoto.md) — remote engine design and status.
- [`docs/plans/2026-10-15-connettori-mcp.md`](docs/plans/2026-10-15-connettori-mcp.md) — MCP connectors.
- [`docs/plans/2026-10-22-app-ios.md`](docs/plans/2026-10-22-app-ios.md) — the iOS app: decisions and status.
- [`docs/push-relay.md`](docs/push-relay.md) — the push relay and how to host your own.
- [`docs/benchmarks/r1-transcript.md`](docs/benchmarks/r1-transcript.md) — long-transcript performance.
- [`CLAUDE.md`](CLAUDE.md) — conventions for AI coding agents working on this repo.

Design documents are currently in Italian.

## Contributing

1. Branch from `main`.
2. `swift build` without new warnings, `swift test` green; for engine changes, a parity scenario or
   an integration test that covers the behavior.
3. Keep the HTTP + SSE contract stable: key order, error texts and status codes are part of it.
4. Keep `HarnessCore` / `HarnessDrivers` building on Linux (`#if canImport(...)` for Apple-only
   frameworks).
5. Commit messages: a plain-English subject describing the effect, a body with what changed and how
   it was tested.

## Credits

SwarmeBot is derived from [OpenMausBot](https://github.com/milind-soni/OpenMausBot) by Milind Soni and
the OpenMausBot contributors (Apache License 2.0): its engine was ported from TypeScript to Swift and
extended with the native macOS app and remote engines. SwarmeBot is not affiliated with or endorsed by
OpenMausBot. Third-party notices are in [NOTICE](NOTICE).

## License

Copyright 2026 Hextra Srl. Licensed under the [Apache License, Version 2.0](LICENSE); see [NOTICE](NOTICE).
