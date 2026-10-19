# Analisi di fattibilità — SwarmeBot nativo macOS in Swift/SwiftUI

Data: 2026-10-13 · Rev. 2 · Stato: **analisi** (nessuna implementazione avviata)

**Decisione presa (rev. 2): solo macOS.** Windows e Ubuntu vengono abbandonati; non resta
nessuna build Electron da mantenere in parallelo.
Riferimento: repo attuale `SwarmeBot` (commit `1cd755d`), piano precedente
`2026-08-28-flutter-dart-migration-plan.md` (le cui §3.1–3.2 su parità degli harness valgono
anche qui e non vengono ripetute).

---

## 0. Verdetto

**Fattibile, rischio medio, ed è più facile del port Flutter** per tre motivi concreti trovati
nella repo:

1. **Esiste già un client Swift del harness.** `ios/Sources/CompanionCore` (Client, SSE,
   Models, Store, Markdown, Failover — ~1.900 LOC + test) è un package SwiftPM che dichiara
   già `.macOS(.v13)`. Parla le stesse API (`/api/bots`, `/api/events`, `/api/threads/…`,
   respond, always-allow, tasks, branch, reactions, search, export). È il cuore del client
   macOS, già testato contro fixture catturate da un harness reale.
2. **L'app è già "due processi".** La UI React non ha trasporti propri: comandi HTTP + un solo
   stream SSE. Si può sostituire la UI senza toccare il harness.
3. **Le parti native sono già Swift o binari nativi**: `speech-helper.swift` (cade comunque),
   Cua Driver (binario nativo lanciato come MCP stdio), avatar Maus già in SwiftUI
   (`ios/App/MausAvatar.swift`, `MausFaceData.swift`).

Il punto difficile **non è la UI** ma **il porting dei 16 driver** (protocolli dedotti per
reverse engineering). Con la scelta "solo macOS" il harness Node non deve più servire altre
piattaforme, quindi l'obiettivo finale è **un'app interamente Swift, senza Node**. Si arriva
lì in due fasi pianificate (§3): prima l'app nativa sopra il harness attuale (release
rapida, parità garantita), poi il harness in Swift driver per driver, con il corpus di parità
come criterio di uscita.

---

## 1. Fotografia della repo (misurata oggi)

| Area | LOC (no test) | Note |
|---|---|---|
| `server/` | ~29.600 | `index.ts` 4.422 righe, router a mano, ~90 route + SSE |
| ↳ `server/drivers/` | 16 driver | Claude, Codex, Grok, GrokAgent, Gemini, Kimi, Droid, Cursor, OpenCode Go, Qwen, Hermes, Pi, DeepSeek Harness, **Local Endpoint**, Antigravity, BoxAgent |
| `src/` (React) | ~25.100 | Sidebar 1.686, store 1.882, ChatView 1.254, CursorAvatar 1.756, Settings ~3.000 |
| `electron/` | ~5.100 | utilityProcess per il harness, IPC (screen, picker, terminal, credenziali, companion, CUA, updater) |
| `companion/` | ~2.700 | sidecar mDNS + proxy per l'app iOS (porte 8810/8811) |
| `ios/` | ~9.600 | companion SwiftUI + `CompanionCore` |
| test | ~28.100 | vitest + node --test |

Persistenza: `~/.swarmebot/` — `config.json`, `messages.db` (`node:sqlite`, WAL, 0600),
`events/*.ndjson`, `native/*.ndjson`.

Proxy MCP stdio che il server fa lanciare ai CLI (`server/proxy-paths.ts`):
`permission`, `agents`, `computer`, `containerMcp`, `vpsContainerMcp`, `dweb`, `connectors`,
`phone`.

---

## 2. Perimetro

### 2.1 Cade (richiesto)

| Funzione | File principali | LOC ca. |
|---|---|---|
| Voce: TTS ElevenLabs, chiamate, dettatura, push-to-talk | `server/tts/*`, `CallView`, `GroupCallView`, `VoiceSettings`, `SpeakButton`, `lib/call`, `lib/group-call`, `lib/push-to-talk`, `lib/tts`, `electron/speech.mjs`, `speech-helper.swift` | ~3.700 (con Composio) |
| Connected apps (Composio) | `composio.ts`, `connector-proxy.ts`, `cloudflare/composio-broker`, `PluginsPanel`, `ConnectorCard`, route `/api/connectors*` | (incluso sopra) |

Effetti a cascata: `SendTurnInput.integrations.composio`, `capabilities.composioMcp`,
`SPAWNED_PROXIES.connectors`, le card "connection request" in chat, le chiavi Composio/
ElevenLabs in App Settings. In fase 1 basta **non esporle in UI**; in fase 2 non si portano.

### 2.2 Resta (parità richiesta)

- Tutti gli harness/driver, compreso **Local Endpoint** (LiteLLM/vLLM/OpenAI-compatible) con
  la continuità di sessione Hermes (`X-Hermes-Session-Id`, anche rinominato da LiteLLM come
  `llm_provider-x-hermes-session-id`), probe `/v1/capabilities`, recupero su 403.
- Permission broker (card Allow/Deny/domanda, always-allow, auto-approve), steer-queue,
  turn-watchdog, branching/edit, task per bot, reactions, search, export, pin/unread/hide.
- Gruppi/canali multi-bot con routing @mention, delegations, chief-of-staff, comms peer
  (`agents-proxy`).
- Computer: Box cloud, Local VM/container, VPS, **questo Mac** via Cua Driver, preview schermo.
- Routines (schedulate), webhooks ingress (127.0.0.1:8800), team library import/export,
  skill library, model picker con provider rail, effort, usage.
- Companion iOS (se si vuole mantenerlo: vedi §5.6).

### 2.3 Cade (piattaforme)

Tutto ciò che esiste solo per Windows/Ubuntu: `electron/` per intero (sostituito dalla shell
Swift), `cua-linux*.cjs`, `LinuxLocalControl.tsx`, `docs/linux-desktop.md`, gli script
`package:win`/`package:linux`, la skill `windows-release`, i rami `win32`/`linux` di
`EngineInstall.command` e di `env-path.ts`/`procs.ts`. Il codice server può assumere macOS
(Keychain, `launchctl`, percorsi `~/Library`), il che semplifica la fase 2.

### 2.4 Cade (deciso il 2026-10-13)

- Android phone tools (`phone-proxy`, `AndroidDevicePanel`, capability `phoneMcp`).
- `dweb` (`dweb-proxy`): ponte verso un demone esterno, attivo solo con la variabile `DWEB_URL`
  che l'app non imposta mai, senza UI.

In fase 1 restano nel harness Node senza essere esposti; in fase 2 non si portano. Con Composio
(§2.1), dei proxy MCP lanciati dai CLI restano da portare solo `computer` (con
`containerMcp`/`vpsContainerMcp`) e `agents`; `permission` è già portato.

---

## 3. Opzioni architetturali

| | A. UI SwiftUI + harness Node embedded | B. Tutto Swift (UI + harness) | **C. A ora, B per gradi** |
|---|---|---|---|
| Cosa si riscrive | Solo `src/` + shell `electron/` | Tutto | A, poi il harness driver per driver |
| Parità harness | **100% per costruzione** (stesso codice) | Da dimostrare col corpus golden | 100% in fase 1, verificata in fase 2 |
| Runtime incluso | Binario Node 24 firmato (~100 MB) | Nessuno | Node finché l'ultimo driver non è portato |
| Dimensione app | ~120–150 MB (oggi Electron ~250+) | ~20–40 MB | scende nel tempo |
| RAM a riposo | Swift UI + 1 processo Node | 1 processo | idem |
| Tempo a prima release | **~2–3 mesi-persona** | ~6–8 mesi-persona | 2–3 mesi, poi incrementale |
| Rischio | Basso | Alto (driver) | Basso, poi controllato |

**Raccomandazione: C, con la fase 2 confermata** (non più opzionale). Senza Windows/Ubuntu il
harness Node non ha altri clienti oltre all'app Mac (e al companion iOS, che parla HTTP e non
dipende dal linguaggio), quindi tenerlo significa solo portarsi dietro un runtime da ~100 MB.
L'app nativa arriva presto e senza rischio sugli harness; la rimozione di Node segue con un
criterio oggettivo di uscita (corpus di parità verde) invece di una riscrittura "big bang".

Si scarta B diretta perché per 4–6 mesi non ci sarebbe nulla di rilasciabile e i driver
andrebbero portati senza un'app reale su cui provarli.

Nota: il contratto HTTP+SSE tra UI e harness va **congelato e documentato** all'inizio della
fase 1. In fase 2 il harness Swift lo implementa in-process (stesse strutture, chiamate
dirette invece di HTTP) o, più semplicemente, continua a esporlo su 127.0.0.1 — la UI non
cambia in nessuno dei due casi.

---

## 4. Fattibilità tecnica per componente

Legenda rischio: 🟢 basso · 🟡 medio · 🔴 alto

### 4.1 Fase 1 — app nativa sopra il harness

| Componente | Oggi | In Swift | Rischio |
|---|---|---|---|
| Avvio harness | `utilityProcess.fork` di Electron | `Process` che lancia `Contents/Helpers/node` + `Resources/server/index.js`; porta libera, health-check `/api/health`, restart con backoff, kill dell'albero all'uscita | 🟢 |
| Client API + SSE | `src/state/store.tsx` | `CompanionCore` (già c'è) esteso con le route mancanti: config, instances, routines, webhooks, team library, local-computer, cli-test, decisions, groups PATCH… | 🟢 |
| Stato | reducer React | `@Observable` store che fa il fold degli eventi (già impostato in `CompanionCore/Store.swift`) | 🟢 |
| Lista chat / sidebar a sezioni | `Sidebar.tsx` | `List` con sezioni, context menu nativo (pin, unread, duplica, nascondi, elimina), drag per riordino | 🟢 |
| Transcript chat | `ChatView.tsx` + windowing | `ScrollView`+`LazyVStack` con `scrollPosition`/`defaultScrollAnchor(.bottom)` (macOS 14+); se le prestazioni su thread lunghi non bastano → `NSTableView` via `NSViewRepresentable` | 🟡 |
| Markdown + codice | react-markdown + GFM + shiki | `Textual` (successore di MarkdownUI, ora in maintenance) o renderer proprio su `swift-markdown` (cmark-gfm) partendo da `CompanionCore/Markdown.swift`; highlight con Highlightr (highlight.js su JavaScriptCore) o tree-sitter | 🟡 tabelle GFM, selezione testo su più messaggi |
| Card approvazione / domanda / opzioni | `ApprovalCard`, `OptionCard` | View dedicate, scorciatoie tastiera (⏎ consenti, ⎋ nega) | 🟢 |
| Composer | testo, allegati, immagini, @mention, model picker | `TextEditor`/`NSTextView` wrapper per invio con ⏎ e a capo con ⇧⏎, drop/paste immagini, popover menzioni | 🟡 (NSTextView serve per comportamento fine) |
| Model picker con provider rail | `ModelPicker.tsx` | Popover a due colonne | 🟢 |
| Inspector destro (Dettagli/Libreria/Computer) | `InspectorPanel`, `ComputerPanel` | `.inspector` + `Picker(.segmented)` | 🟢 |
| Preview computer cloud | iframe / viewer | `WKWebView` | 🟢 |
| Preview schermo locale | `desktopCapturer` | ScreenCaptureKit (permesso Screen Recording) | 🟢 |
| Controllo "questo Mac" | Cua Driver lanciato come MCP stdio dal harness | invariato (resta nel harness); l'app gestisce solo i permessi Accessibilità/Screen Recording | 🟢 |
| Avatar animati Maus | `CursorAvatar.tsx` (1.756) | riuso `MausAvatar.swift`/`MausFaceData.swift` dall'app iOS | 🟢 |
| Credenziali | `safeStorage` Electron | Keychain (`ios/App/Keychain.swift` già pronto) | 🟢 |
| Apri terminale per login CLI | `terminal-launch.mjs` | `NSWorkspace` + AppleScript verso Terminal/iTerm | 🟢 |
| Notifiche | Electron Notification | `UserNotifications`, badge Dock | 🟢 |
| Command palette, ricerca | `CommandPalette`, `SearchResults` | sheet con `.searchable`, ⌘K | 🟢 |
| Routines / Webhooks / Settings | pagine React | form SwiftUI `Form`/`Settings` scene | 🟢 (tanto lavoro, nessuna incognita) |
| Updater | electron-updater | **Sparkle 2** (appcast su swarmebot-releases) | 🟢 |

### 4.2 Fase 2 — harness in Swift

| Componente | In Swift | Rischio |
|---|---|---|
| Contratti (`contracts.ts`) | `enum RuntimeEvent` con associated values, `protocol ProviderAdapter`, `struct ModelCatalog` — traduzione quasi 1:1 | 🟢 |
| Registry + bus | `actor` + `AsyncStream` fan-out, tee su NDJSON | 🟢 |
| Spawn CLI (`procs.ts`, `env-path.ts`) | `Process` + `Pipe`, lettura a righe, kill del process group. **Attenzione:** un'app GUI non eredita il PATH della shell → riprodurre la risoluzione di `env-path.ts` (login shell `-lc`, nvm/homebrew/~/.local/bin) | 🟡 |
| ACP core (8 driver) | JSON-RPC 2.0 su stdio con `Codable` + `JSONSerialization` per i payload liberi; invarianti §3.1.1 del piano Flutter | 🟡 |
| Claude (stream-json, `--permission-prompt-tool`) | come sopra + MCP config temporaneo 0600 | 🔴 molte cicatrici |
| Codex app-server (due generazioni di approvazioni) | idem | 🔴 |
| Local Endpoint / DeepSeek Harness | `URLSession.bytes` per SSE OpenAI, header Hermes, probe | 🟢 |
| Proxy MCP stdio (permission, agents, computer…) | **piccolo eseguibile Swift** in `Contents/Helpers/swarmebot-mcp` con sottocomandi; parla MCP su stdio e inoltra al harness su unix socket. SDK MCP Swift disponibile, ma il protocollo usato è minimale e si può scrivere a mano | 🟡 |
| HTTP: webhooks 8800, endpoint `/api/internal/*`, companion | Hummingbird 2 o SwiftNIO; Bonjour nativo con `NWListener` (sostituisce `companion/mdns.ts`) | 🟢 |
| SQLite messaggi | GRDB.swift (WAL, 0600) | 🟢 |
| Routines | scheduler in-process; opzionale helper LaunchAgent (`SMAppService`) per eseguirle anche con app chiusa — miglioramento rispetto a oggi | 🟢 |
| Box / VPS / container computer | client REST + proxy MCP | 🟡 (volume, non complessità) |
| Parità | corpus record & replay di `~/.swarmebot/native/*.ndjson` come nel piano Flutter §3.2; ogni driver Swift passa il replay prima di sostituire quello Node | — |

### 4.3 Vincoli di piattaforma (bloccanti se ignorati)

- **Niente App Sandbox, niente Mac App Store.** L'app deve lanciare CLI arbitrari, leggere
  `~/.claude`, scrivere `~/.hermes/config.yaml`, usare cartelle di lavoro scelte dal bot.
  Distribuzione Developer ID + notarizzazione (come oggi la DMG).
- **Hardened Runtime**: il binario `node` incluso (fase 1) richiede
  `com.apple.security.cs.allow-jit` (V8) e va firmato come helper. I CLI esterni restano
  dell'utente e non sono interessati dalla firma.
- **Permessi TCC**: Screen Recording e Accessibilità per preview/controllo locale; vanno chiesti
  con le stesse regole esplicite di oggi (mai attivi di default).
- **Target minimo: macOS 14 Sonoma** (`@Observable`, `.inspector`, `scrollPosition`). Intel e
  Apple silicon con universal binary.

---

## 5. Grafica stile Grok Bot

### 5.1 Layout (dagli screenshot)

```
┌───────────────┬──────────────────────────────────┬──────────────┐
│ [🔍]     [+]  │                                  │      [⇪] [✕] │
│  ┌────────┐   │  messaggi bot: bolle grigio      │   (avatar)   │
│  │ avatar │   │  scuro, larghezza max ~560pt,    │   Nome bot   │
│  │  bot   │   │  orario centrato sopra il gruppo │  + etichetta │
│  └────────┘   │  ("Ieri 7:24", "Oggi 7:45")      │ Dettagli │   │
│ SEZIONE       │                                  │ Libreria │   │
│ ◉ Nome  [tag] │  card inline (domanda + scelta)  │ Computer     │
│   anteprima…  │                                  │              │
│ …             │                                  │  contenuto   │
│ [C] [Connetti]│  ( + | Scrivi a <bot>   🎙 ▮▮ )  │   del tab    │
└───────────────┴──────────────────────────────────┴──────────────┘
```

- `NavigationSplitView` a 2 colonne + `.inspector` per la colonna destra (chiudibile).
- Sidebar: in alto il bot corrente in evidenza (avatar grande in card), poi sezioni nominate
  dall'utente ("Datacenter", "Utility", "News", "Non assegnati"), riga = avatar 32pt
  + nome + **tag tipo** (Local AI, Server, Dev) + anteprima ultima riga.
- Composer a pillola in basso, ancorato, con `+` a sinistra; **si tolgono mic e onda vocale**
  (voce fuori perimetro). In basso a sinistra resta l'avatar utente; il pulsante "Connetti
  app" cade.
- Barra titolo trasparente (`.windowStyle(.hiddenTitleBar)`, toolbar unificata), semafori
  sopra la sidebar come nello screenshot.

### 5.2 Token (già definiti in `src/styles.css`, si portano in un `Theme.swift`)

| Token | Valore | Uso |
|---|---|---|
| app | `#070707` | sfondo finestra / colonna chat |
| panel | `#111111` | sidebar, inspector |
| card | `#262626` | bolle bot, card |
| raised / hover | `#2F2F2F` / `#3D3D3D` | riga selezionata, pulsanti |
| inset | `#191919` | campi, code block |
| hairline | `#333333` | separatori |
| ink / secondary | `#FCFCFC` / 60% | testo |
| accent | `#1084FE` | link, focus, selezione |
| bubble-user | `#5A5A5A` | messaggi utente |
| success / danger / warning | `#38D591` / `#FF5667` / `#FF9800` | stati |

Raggi 8/12 pt, animazioni `panel-in`/`msg-in` (0.18–0.24s, curva ease-out) → `spring`
equivalenti. Font: Inter come oggi oppure SF Pro (più nativo, si integra meglio).
Stile **piatto e opaco**: niente materiali vetro di sistema su sidebar/inspector, altrimenti
l'aspetto si allontana da Grok Bot.

### 5.3 Dettagli che fanno la differenza

Hover sulle righe, context menu nativi, scorciatoie (⌘N nuovo bot, ⌘K palette, ⌘1…9 bot,
⌘⌥I inspector, ⎋ interrompi turno), drag & drop file nel composer, Quick Look sugli allegati,
indicatore "sta lavorando" con chip di attività tool, menu Dock con bot non letti.

### 5.4 Cosa resta più debole che sul web

Selezione di testo continua su più messaggi (in SwiftUI è per singolo `Text`) e tabelle
Markdown molto larghe. Mitigazione: copia messaggio / copia conversazione come Markdown
(l'export esiste già), tabelle in `ScrollView` orizzontale.

### 5.5 Companion iOS

Vantaggio netto del nativo: macOS e iOS condividono `CompanionCore` e parte delle view
(avatar, markdown, card). Con Swift il sidecar `companion/` (mDNS, proxy 8810) diventa
`NWListener` + Bonjour nativi in fase 2, senza Node.

---

## 6. Stima

Mesi-persona per uno sviluppatore senior Swift, con assistenza AI. Intervalli, non promesse.

| Fase | Contenuto | Settimane-persona |
|---|---|---|
| 0 | Congelamento contratto HTTP/SSE, estensione `CompanionCore` a macOS, scaffold Xcode, firma/notarizzazione, Node embedded | 1–2 |
| 1a | Shell, sidebar, chat, composer, card approvazione, model picker, inspector | 4–5 |
| 1b | Settings (Engines, Local Endpoint, DeepSeek), routines, webhooks, team library, computer panel, onboarding | 3–4 |
| 1c | Rifinitura grafica, prestazioni transcript, Sparkle, beta interna | 1–2 |
| **Totale fase 1** | **App nativa in produzione, harness invariato** | **9–13** |
| 2a | Contratti, registry, bus, store GRDB, HTTP, proxy MCP Swift, corpus di parità | 4–6 |
| 2b | Driver API (Local Endpoint, DeepSeek, Grok) | 2–3 |
| 2c | ACP core + 8 driver | 4–5 |
| 2d | Claude, Codex, Antigravity, Pi | 4–6 |
| 2e | Computer (Box, VPS, container, Cua), companion nativo, rimozione Node | 3–4 |
| **Totale fase 2** | **Harness Swift, nessun runtime esterno** | **17–24** |

---

## 7. Rischi

| # | Rischio | Prob. | Mitigazione |
|---|---|---|---|
| R1 | Transcript lento su thread lunghi in SwiftUI | Media | Windowing (la logica `transcript-window.ts` esiste già), fallback NSTableView, benchmark in fase 1a su un thread computer-use reale |
| R2 | Markdown/codice meno ricchi di shiki | Media | Highlightr/tree-sitter; accettare temi limitati in v1 |
| R3 | Regressioni driver in fase 2 | Alta senza corpus | Nessun driver Swift sostituisce quello Node senza replay verde; i due possono convivere per instance |
| R4 | PATH dei CLI non trovato dall'app GUI | Media | Portare `env-path.ts` per primo, test con nvm/fnm/homebrew/asdf |
| R5 | I CLI cambiano protocollo durante il porting | Media | Fase 1 non ne è toccata; in fase 2 il log `native/` evidenzia il drift |
| R6 | ~~Divergenza con le build Windows/Ubuntu~~ | — | **Chiuso:** solo macOS. Durante la fase 1 l'app Electron Mac resta solo come fallback finché la nativa non è in produzione, poi si archivia |
| R7 | Somiglianza grafica con Grok Bot | — | Riprodurre layout e palette va bene; non usare nome, logo, mascotte o asset xAI (il README lo dichiara già) |

---

## 8. Prossimi passi proposti

1. ~~Decidere Windows/Ubuntu~~ → solo macOS (rev. 2).
2. Fase 0: documentare il contratto HTTP/SSE dal codice di `server/index.ts` e da
   `CompanionCore/Models.swift`, generare fixture SSE da sessioni reali.
3. Spike di 3–4 giorni prima di impegnarsi: finestra SwiftUI con sidebar + transcript che
   carica un thread reale da 2.000+ messaggi con markdown e codice, collegata al harness
   attuale. È il test che decide R1/R2.
4. Avviare la raccolta del corpus di parità (piano Flutter §3.2) **già durante la fase 1**:
   l'app nativa usa il harness Node reale, quindi ogni sessione di test produce log `native/`
   utili. Così la fase 2 parte con il corpus pronto.
5. Ordine dei driver in fase 2: Local Endpoint e DeepSeek (HTTP, rischio basso) → ACP core +
   Hermes/Cursor/Grok → Claude → Codex → resto. Driver Swift e Node convivono per instance
   finché l'ultimo non è portato.
