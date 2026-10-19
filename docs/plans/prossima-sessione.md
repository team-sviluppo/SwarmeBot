# Prossima sessione — come riprendere il port del motore Swift

Stato al 2026-10-14, master `44ca30e`.
Riferimenti: `docs/plans/2026-10-13-swift-native-macos-analisi.md` (piano), `docs/plans/fase-2-architettura.md`
(decisioni, avanzamento, verifiche, lezioni: **leggere le Lezioni prima di scrivere codice**).

## Prompt da incollare nella nuova sessione

Avviare Claude Code nella cartella di questa repo e incollare:

> Continua il port del motore Swift di SwarmeBot. Leggi `docs/plans/prossima-sessione.md`,
> `docs/plans/fase-2-architettura.md` (soprattutto Decisioni e Lezioni) e `git log --oneline -15`.
> Il motore Node di riferimento, in sola lettura, è la cartella `server/` del checkout Node (`SWARMEBOT_REPO`).
> Esegui i blocchi rimasti nell'ordine indicato, ognuno verificato con `parity/all.sh` e `swift test` prima del commit.

## Dove siamo

Fatto e alla pari con Node (`parity/all.sh`: 27 scenari, `swift test` verde):
- tutti i driver (Local Endpoint, Grok API, Claude, Codex, Pi, Antigravity, DeepSeek Harness, ACP ×8, boxAgent);
- core, canali multi-bot, comunicazione tra bot (`mcp-agents`), watchdog, chiamate ripetute;
- routine e webhook (ricevitore 127.0.0.1:8800), libreria team, avatar SVG, card;
- computer cloud Box: pannello, chi guida, poller dello schermo, `prepareComputer` collegato a `runOn`.

Fuori perimetro per decisione dell'utente (non portare): Composio/connected apps, voce/TTS, strumenti Android
(phone), dweb. Le route `/api/tts`, `/api/connectors*`, `connector-cards` rispondono 501 apposta.

## Blocchi rimasti, in ordine

### 1. Computer locale (il più grande)
Sorgenti Node: `server/computer-proxy.ts` (~1.070 righe), `container-computer.ts`, `container-mcp.ts`,
`local-vm-lease.ts`, `vps-computer.ts`, `vps-container-mcp.ts`, `local-computer.ts`, `remote-computer.ts`,
`mcp-bridge.ts`, più in `server/index.ts` il ramo `vm`/`vps` di `startTurn` (frasi del prompt di sistema, lease,
`activeVpsThreads`, timer d'inattività della VM) e le route `/api/local-computer*` e il ramo VPS di
`/api/bots/:id/computer*` (oggi 501 o stub in `Routes.swift`).
- Server MCP come sottocomandi del binario (`swarme-harness mcp-computer`, `mcp-container`, `mcp-vps`), sul modello
  di `PermissionProxy.swift` / `AgentsProxy.swift`, smistati in `Sources/swarme-harness/main.swift`.
- Aggiungere `computer: MCPServer?` a `SendTurnInput` e montarlo come fa Node in Claude (`--mcp-config`,
  `mcp__computer` pre-autorizzato tranne lo scope `local-computer`, che passa dal broker con
  `approvalScope: "local-computer"`; `bypassPermissions` rifiutato), ACP (`mcpServers`), Codex (`-c mcp_servers.computer`);
  poi attivare `computerMcp`/`localComputerMcp` nelle capacità come in Node.
- Docker, Cua e una VPS reali non sono disponibili: servizi finti per la parità (es. un `docker` finto messo primo
  nel PATH, se Node lo invoca); elencare nel documento cosa non è verificato dal vivo.
- Parità: estendere `SCENARIO=computer` in `parity/run_scenario.py` e `parity/fake_claude.py` (un trigger che chiama
  uno strumento del server MCP chiamato `computer`).

### 2. Companion iOS
Sorgente Node: `companion/` del checkout Node (sidecar mDNS + proxy sulle porte 8810/8811) e come
lo avvia `electron/`. Client da non cambiare: `SwarmeBot/ios/` (`CompanionCore`).
- Bonjour con `NWListener` (stesso tipo di servizio e record TXT), stesso pairing e stesse regole di sicurezza
  (token, restrizioni LAN/loopback, filtro header, limiti del body), proxy verso il harness.
- Decidere se vive nel motore o in `SwarmeKit` (avviato dall'app) seguendo come lo avvia oggi Electron; motivarlo.
- Verifica: script python sotto `parity/` che fa le stesse richieste al sidecar Node e a quello Swift (pairing,
  qualche chiamata, uno stream SSE) e confronta; mDNS con `dns-sd -B`. Un iPhone vero va provato a mano.

### 3. Rifiniture dei driver
- Immagini negli input dei turni (`images` nelle capacità; Node le passa a Claude/Codex/ACP) e `generateText`
  (Node lo usa per titoli/nomi: verificare dove lo chiama il harness prima di portarlo).

### 4. Togliere Node
- Motore Swift come predefinito in Impostazioni › Motore (oggi: Node predefinito, Swift in anteprima su una
  **copia** dei dati in `~/Library/Application Support/SwarmeBot/swift-engine`).
  **Decisione dell'utente (2026-10-14): il motore Swift lavora sui dati reali in `~/.swarmebot`**, non più sulla
  copia (il formato è lo stesso). Prima del primo avvio sui dati reali fare un backup completo di `~/.swarmebot`
  (con `messages.db` copiato via `VACUUM INTO`, come fa oggi la copia di anteprima) e dirlo all'utente;
  non far girare mai i due motori insieme sulla stessa cartella.
- Togliere dal bundle `Contents/Helpers/node` e `Resources/server` (`scripts/bundle-app.sh --with-harness`),
  e da `HarnessLauncher` i rami che avviano Node.
- Provare dal vivo almeno un turno vero per motore installato (oggi verificati solo stato e catalogo con
  `claude`, `cursor-agent`, `opencode`, `pi`). **Consenso dato dall'utente (2026-10-14)** ai test con turni reali sui
  suoi abbonamenti: prompt brevi e modelli economici dove si può scegliere, e riportare cosa è stato speso
  (costo/token mostrati dal motore).

## Come lavorare (regole imparate in queste sessioni)

- **Verifica**: `swift build`, `swift test`, `parity/all.sh` (stesso scenario sui due motori con CLI e server finti;
  le tracce SSE normalizzate devono coincidere). Ogni blocco aggiunge il suo scenario a `parity/all.sh`.
- **Lavoro in parallelo**: un worktree per blocco (`git worktree add ../SwarmeBotSwift-<tema> -b feat/<tema>`) e un
  `TMPDIR` privato e **corto** per ogni `compare.sh` (`TMPDIR=/tmp/swX/ parity/all.sh`): la cartella
  `$TMPDIR/swarme-parity` è condivisa e il socket del broker nella data dir ha il limite di 104 byte.
  I conflitti di merge capitano in `Harness.swift` (`startTurn`), `Routes.swift`, `parity/run_scenario.py`, `all.sh`
  e nel documento di fase 2: risolverli tenendo entrambe le parti.
- **Concorrenza**: il motore gira sotto `dispatchMain()`; mai `MainActor.assumeIsolated` in blocchi
  `DispatchQueue.main` (trap), niente `Timer` sul run loop (non scatta). Usare `Task { @MainActor }`/`AsyncStream`.
- **Processi**: lanciare i CLI con `CLIProcess` (process group proprio, segnali ripristinati).
- **Wire**: stesso ordine delle chiavi e stessi testi d'errore del Node; distinguere chiave assente da `null`.
- Se Node ha un bug, non copiarlo: tenere la parità sistemando lo scenario e annotarlo nelle Lezioni.
- Commit in italiano nello stile di `git log`, chiusi da
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Niente push senza chiedere.
