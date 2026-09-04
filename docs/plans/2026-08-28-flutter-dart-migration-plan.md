# Piano di migrazione SwarmeBot → Flutter + Dart (alto livello)

Data: 2026-08-28 · Rev. 6 · Stato: **bozza da analizzare** (nessuna implementazione avviata)

**Due vincoli, e vanno letti insieme perché tirano in direzioni opposte.**

1. **Parità degli harness.** Gli harness attuali (claude, cursor, codex, grok, gemini,
   kimi, droid, qwen, opencode-go, hermes, antigravity, pi, grok API, Local Endpoint)
   devono continuare a funzionare esattamente come oggi. Vedi §3 — è la sezione da
   leggere per prima.
2. **Greenfield, in una repo nuova.** `/Users/cristiano/Sviluppo/SwarmeBot-Flutter` è il
   progetto; `/Users/cristiano/Sviluppo/SwarmeBot` (questa) resta **solo come
   riferimento da leggere**. Nessun dato, file, formato o installazione preesistente va
   supportato. Vedi §2.4 e §2.5.

Il punto di tensione, e l'unico posto dove il greenfield **non** si applica: la *forma
degli eventi canonici* resta vincolata dal corpus di parità (§3.2), non da una migrazione
dati. Se si "riparte da zero" anche su `RuntimeEvent`, la strategia di verifica degli
harness si autodistrugge. Tutto il resto — persistenza, config, avatar, canali, routine —
è libero.

---

## 1. Fotografia della repo attuale

| Area | File | LOC (no test) | Ruolo |
|---|---|---|---|
| `server/` | 181 | ~25.900 | Harness server Node su `127.0.0.1` — il cuore del prodotto |
| ↳ di cui `server/drivers/` | 44 | ~6.400 | **I 14 harness. La parte a rischio.** |
| `src/` | 140 | ~23.500 | UI React 19 + Vite + Tailwind 4 |
| `electron/` | 37 | ~2.900 | Shell desktop, IPC nativo, updater, CUA, speech |
| `companion/` | 21 | ~2.700 | Bridge mDNS/proxy per l'app iOS |
| `ios/` | 30 | ~9.600 | Companion SwiftUI (fuori scope migrazione) |
| `cloudflare/` | — | — | Broker OAuth Composio (**cade**) |
| test | — | ~21.100 | Vitest + `node --test` |

Punti architetturali che contano per la migrazione:

- **`server/contracts.ts` (337 righe) è l'asset più prezioso.** Definisce un SPI driver
  (`ProviderDriver` → `ProviderInstance` → `ProviderAdapter`) e una union di `RuntimeEvent`
  canonici (~14 varianti) completamente disaccoppiati da Node. Si traduce in Dart quasi
  1:1 con `sealed class` + pattern matching, che è *più* espressivo dell'union TS.
- **`server/index.ts` (4.181 righe) è un router HTTP scritto a mano** su `node:http`
  (`if (method === ... && path === ...)`). ~33 route statiche + 10 famiglie regex, più SSE
  su `/api/events`. È il file che va spezzato, non tradotto.
- **Registry + bus** (`server/harness/{registry,bus}.ts`) implementano già la semantica
  "driver ignoto → shadow snapshot unavailable" (compat forward/backward della config) e
  il fan-in eventi con tee su NDJSON per thread. Da preservare come invariante.
- **Doppio log per thread**, ed è la chiave della strategia di parità (§3.2):
  `~/.swarmebot/events/<threadId>.ndjson` (eventi canonici) e
  `~/.swarmebot/native/<threadId>.ndjson` (**traffico di protocollo grezzo**, con
  `dir: "in"|"out"` e `source`, scritto da `drivers/native.ts`). Il commento nel file lo
  dice esplicitamente: *"protocol drift can be diagnosed by diffing the two"*.
- **Persistenza**: `~/.swarmebot/` con `config.json` (Zod), `messages.db` (`node:sqlite`,
  WAL, chmod 600), `events/`, `native/`. Nessun ORM.
- **Ogni driver spawna un CLI** (`server/procs.ts`) e parla un protocollo diverso — vedi
  l'inventario in §3.1. Più **MCP stdio proxy** generati dal server stesso
  (`server/proxy-paths.ts`) per permission broker e comms fra bot.

---

## 2. Perimetro: cosa resta e cosa cade

### 2.1 Cade (rimozione, non porting)

| Cosa | File coinvolti | LOC ca. |
|---|---|---|
| Computer use cloud (box.ascii.dev) | `box.ts`, `box-*.test.ts`, `computer-proxy.ts`, `remote-computer.ts`, driver `boxagent.ts` | ~2.400 |
| Computer in Docker / Local VM | `container-computer.ts`, `container-mcp.ts`, `local-vm-idle.ts`, `local-vm-lease.ts` | ~1.700 |
| Host control (macOS/Linux GNOME) | `local-computer.ts`, `computer-control.ts`, `computer-observation.ts`, `electron/cua*.{mjs,cjs}` | ~2.300 |
| VPS BYO | `vps-computer.ts`, `vps-container-mcp.ts`, `vps-routing.test.ts` | ~1.200 |
| Composio / connected apps | `composio.ts`, `connector-proxy.ts`, `cloudflare/composio-broker/` | ~900 |
| Android phone tools | `drivers/phone-proxy.ts`, `electron/android-device.mjs` | ~600 |
| UI relativa | `ComputerPanel`, `LocalScreenPreview`, `DesktopCapabilities`, `LinuxLocalControl`, `AndroidDevicePanel`, `PluginsPanel`, `ConnectorCard`, `CloudBackendPicker` | ~2.600 |

**Totale eliminato: ~11.700 LOC di server + ~2.600 di UI**, cioè ~45% del server e ~11%
della UI. Effetti a cascata da ripulire con cura:

- `SendTurnInput.integrations` perde `composio`, `computer`, `localComputer`, `phone`,
  `dweb` → resta solo `agents` (comms peer-to-peer fra bot).
- `ProviderAdapter.capabilities` perde `computerMcp`, `composioMcp`, `phoneMcp`,
  `localComputerMcp` → restano `sessionModelSwitch`, `agentsMcp`, `images`, `effortLevels`.
- `AppConfig` perde `composio`, `box`, `vps`.
- `approvalScope: "local-computer"` e tutto `peer-approval*.ts` / `auto-approve.ts`
  vanno rivalutati: il permission broker **resta** (serve ai CLI), ma senza lo scope host.
- `SPAWNED_PROXIES` si riduce da 8 a 2 voci: `permission` + `agents`.

> ⚠️ **Attenzione al vincolo di §3 qui.** Rimuovere le integrazioni tocca `spawnArgs`,
> `configureSession` e la costruzione del blocco `mcpServers` **dentro ogni driver**.
> Il rischio non è la rimozione in sé, è rompere il montaggio MCP del permission broker
> che vive nello stesso codice. La Fase 0 esiste per questo: farlo dove i test attuali
> ci sono ancora.

### 2.2 Resta e va portato

- Chat multi-bot stile messaging: bot, **canali/room multi-bot con Bot Master
  facoltativo e routing per @mention** (§8), task, branching, reactions, search,
  attachments, drafts, pin/unread/hide.
- Harness: registry, bus, thread-events, message-db, steer-queue, turn-watchdog,
  turn-context, repeat-detector, member-turn, delegations, chief-of-staff, decision-log.
- **Tutti i 14 driver** (§3.1) — nessun taglio, per vincolo esplicito.
- **Continuità sessione Hermes/LiteLLM** (§6).
- **Schedulazioni** (routines cron) **sempre per singolo bot** — mai su canale (§8.5),
  webhooks ingress, team library / import-export, skill library.
- Voice/TTS (ElevenLabs + speech-to-text) — v1 o v1.1, da decidere (§11 R5).
- Auto-updater desktop e canale release.

### 2.3 Fuori scope (da confermare)

Companion iOS + `companion/` mDNS bridge. Se l'app Flutter gira anche su iOS, il
companion Swift diventa ridondante: da decidere se sostituirlo con la stessa app Flutter
puntata a un harness remoto, o se congelarlo.

### 2.4 Greenfield: cosa NON portiamo dietro

L'app Flutter parte da zero. Niente import, niente migrazioni, niente lettura di formati
vecchi. La repo TypeScript diventa **riferimento in sola lettura**: si studia, non si
modifica.

Cade quindi tutta la macchineria di compatibilità, che è più di quanto sembri:

| Cosa cade | Dove sta oggi |
|---|---|
| Migrazione one-shot dalla vecchia data dir (`~/.openmausbot`, `~/.opengrokbot`) | `config.ts:157` `LEGACY_DATA_DIRS` |
| Import lazy dei transcript JSON `messages-<threadId>.json` in SQLite, con backup `.imported` | `message-db.ts:78–124`, `store.ts:517–526`, `store.ts:604–642` |
| Righe legacy senza `parentId` concatenate per ordine d'array | `store.ts:642` |
| `RoutineFile { version: 1 }` e i campi tenuti opzionali "so version-1 files migrate in place" | `routines.ts:54,80,566` |
| `TeamLibrary { version: 1 }` | `team-library.ts:25,101` |
| `alwaysAllow` con conversione dei nomi tool legacy (solo se non ambigui) | `store.ts:478–492` |
| `computer: "cloud"\|"vm"\|"local"\|"off"` con "unset/legacy values migrate to off" | `store.ts:268` — cade comunque col computer use |
| `EXTERNAL_SECRET_FIELDS`: rimozione del campo invece di tombstone `""`, perché la shell rileggeva `""` come "credenziale cancellata" | `config.ts:274` |
| `PRODUCT_FLEET_ADDITIONS` / `CUSTOM_ONLY`: la logica che fa vedere i motori nuovi alle config di prodotto già esistenti, distinguendole da una mappa di test | `config.ts:443–503` |
| `normalizeGroupDefaultResponder`: fallback "primo membro come lead" per i canali senza il campo | `store.ts:369–392` — vedi §8.2 |
| Import dei team file con `defaultResponder: everyone` | `team-manifest.ts` — vedi §8.3 |
| `resumeCursors` legacy mirror che segue il task attivo | `store.ts:895,1016` |
| Dicebear import + sprite sheet | `dicebear-import.ts`, `sprite-sheet.ts` — cadono comunque con §7 |

Tre conseguenze pratiche che vale la pena rendere esplicite:

- **La persistenza Dart può avere lo schema che vuole.** Non deve leggere `messages.db`
  né `config.json` attuali. Lo schema SQLite si può normalizzare (l'albero dei messaggi
  con `parentId` sempre presente, invece di due regimi), e la config può essere un unico
  documento tipizzato invece di un merge con env fallback.
- **Nuova data dir.** L'harness Dart usa la propria (es. `~/.swarmebot-dart` in sviluppo,
  poi la directory definitiva). Non è solo igiene: è ciò che rende possibile la doppia
  esecuzione di §3.3 senza che due processi si contendano lo stesso SQLite e lo stesso
  `config.json`.
- **Ciò che resta vincolato è solo la forma degli eventi canonici** (§3.2). Non per
  compatibilità dati, ma perché il corpus golden è il metro di misura degli harness. Il
  comparatore legge il formato vecchio; il prodotto no.

---

### 2.5 Le due repo e i loro ruoli

| Repo | Ruolo | Regole |
|---|---|---|
| `/Users/cristiano/Sviluppo/SwarmeBot` | **Riferimento in sola lettura.** Il codice da studiare, e la sorgente del corpus golden di §3.2 | Non si modifica, non si aggiorna, non si fanno commit di migrazione. Resta al commit congelato (§ Fase 0). Si *esegue* — per registrare il corpus e per la doppia esecuzione di §3.3 — ma non si tocca |
| `/Users/cristiano/Sviluppo/SwarmeBot-Flutter` | **Il progetto.** Monorepo Dart + app Flutter (§4.1) | Tutto il codice nuovo, i test, il corpus golden come fixture versionata, e **questo piano stesso**, che va spostato qui: è il documento del progetto nuovo, non del vecchio |

Conseguenze operative:

- **Il corpus golden vive nella repo nuova** (es. `parity/corpus/<harness>/<scenario>/`),
  anche se è *generato* eseguendo la repo vecchia. È un asset di test del progetto nuovo:
  se sta nella repo di riferimento, la regola "non si modifica" si rompe al primo giorno.
- **Gli artefatti della Fase 0** (SHA congelato, versioni dei CLI, lista delle esclusioni)
  sono documenti della repo nuova, non della vecchia.
- Il **comparatore di parità** è l'unico componente Dart che deve saper leggere i formati
  della repo vecchia (`events/*.ndjson`, `native/*.ndjson`). Vive in
  `packages/swarmebot_parity/` ed è deliberatamente isolato lì: nessun altro package ha
  il diritto di conoscere il formato vecchio (§2.4).
- **Data dir separate anche a runtime**: l'harness di riferimento continua a usare
  `~/.swarmebot`, quello nuovo la propria (§2.4). È ciò che rende possibile eseguirli in
  parallelo (§3.3).

### 2.6 Stato dell'ambiente

Verificato sulla macchina il 2026-08-28:

| | Stato | Implicazione |
|---|---|---|
| Cartella `SwarmeBot-Flutter` | esiste, **vuota** | pronta per lo scaffold |
| **Dart SDK** | **3.13.2 (stable)**, `/opt/homebrew/bin/dart` | ✅ basta per le Fasi 0–4 |
| **Flutter SDK** | ⚠️ **non installato** | blocca la Fase 5, non prima |
| Repo di riferimento | `main`, commit `db998f3`, working tree pulito | pronta per il congelamento |

**Osservazione che conta per la pianificazione: le Fasi 0–4 — contratti, infrastruttura di
parità, harness core, tutti e 14 i driver, feature server — sono Dart puro e possono
partire subito con la toolchain già presente.** Sono ~60% del progetto. Flutter serve solo
dalla Fase 5, cioè fra 8–11 settimane: c'è tutto il tempo per installarlo, e va fatto
prima della Fase 5, non prima della Fase 0.

---

## 3. Vincolo primario: parità degli harness

Questa è la parte del progetto che può fallire. Tutto il resto — UI, router HTTP, store,
persistenza — ha un contratto osservabile e si verifica banalmente. I driver invece
parlano protocolli **non documentati, dedotti per reverse engineering da versioni
specifiche dei CLI**, e ogni riga di quel codice è la cicatrice di un bug reale. Un port
"ragionevole" produce un harness che funziona nel 90% dei casi e fallisce esattamente
dove il codice attuale ha imparato a non fallire.

### 3.1 Inventario dei 14 harness

| Driver | LOC | Protocollo | Meccanismo di continuazione | Quirk da non perdere |
|---|---|---|---|---|
| **ACP core** | 719 | JSON-RPC 2.0 su stdio | `session/load` con sessionId | vedi §3.1.1 — condiviso da 8 driver |
| `grokAgent` | 262 | ACP | idem | slug inject su argv, **`spawnArgs` non deve chiamare `ensureGrokInjectSlug`** |
| `cursorAgent` | 349 | ACP | idem | `CURSOR_API_KEY`/`CURSOR_AUTH_TOKEN` come alternativa al login |
| `geminiAgent` | 106 | ACP (`--experimental-acp`) | idem | usage sotto `result._meta` e non `result.usage`; probe `oauth_creds.json` valido solo se il token *sembra vivo* |
| `kimiAgent` | 197 | ACP | idem | unico `authMethod` è `{id:"login", type:"terminal"}` |
| `droidAgent` | 252 | ACP (`exec -o acp`) | idem | modello e mode passano da `configureSession`, **non** da `spawnArgs` |
| `qwenAgent` | 113 | ACP (`--acp`) | idem | custom-only |
| `opencodeGo` | 253 | ACP (`acp`) | idem | auth valida se `key` **oppure** `access` **oppure** `refresh`; cancella 8 env var prima dello spawn |
| `hermesAgent` | ~150 | ACP | idem | **scrive `~/.hermes/config.yaml`** (upsert non distruttivo); `session/set_model custom:<host>:<model>` |
| **`claudeAgent`** | 784 | stream-json bidirezionale | `--resume <sessionId>` | vedi §3.1.2 |
| **`codex`** | 580 | app-server, JSON newline-delimited | conversationId | vedi §3.1.3 |
| `antigravityAgent` | 461 | CLI proprietaria | `--conversation <id>` | `accept-edits` come argomento posizionale se non full-auto |
| `piAgent` | 569 | protocollo proprio | — | |
| `grok` (API) | ~200 | HTTP `api.x.ai/v1` | transcript replay | driver API-key, registrato ma fuori dalla flotta default |
| `localEndpoint` | 437 | HTTP OpenAI-compatible | **session id Hermes o transcript replay** | vedi §6 |

#### 3.1.1 ACP core — invarianti

1. **ACP non ha `turn/completed`**: il *result* della RPC `session/prompt` è il segnale di
   completamento e porta `stopReason` + usage. Chi cerca una notifica aspetta per sempre.
2. **Usage sta sotto `result.usage` OPPURE `result._meta`** (gemini): leggere entrambi.
3. **Permessi fail-closed**: `session/request_permission` viene approvato solo se
   l'agente ha offerto esplicitamente un'opzione di `kind` `allow`. **L'ordine delle
   opzioni non è un contratto di sicurezza.** Se non c'è opzione adatta si cancella la
   richiesta invece di indovinare.
4. **`session/load` rimanda la history come normali notifiche `session/update`**: doppio
   gate — niente si emette prima che il prompt sia stato inviato (`state.promptSent`), e
   gli update con `_meta.isReplay === true` si scartano.
5. **`session/set_config_option` va fra `session/new`/`session/load` e il primo
   `session/prompt`**: alcuni CLI ignorano argv e prendono modello/mode solo qui.
6. **`initialize._meta.modelState.currentModelId` è il default del CLI, non la scelta
   dell'utente** — non va confuso con la selezione.
7. Metodi server→client sconosciuti ricevono `-32601`, non silenzio.
8. Tre timeout distinti (init, new-session, session-config) e `session/cancel` in
   interrupt.

#### 3.1.2 Claude Code — invarianti

- `--output-format stream-json --input-format stream-json --verbose` — **`--verbose` è
  obbligatorio** perché stream-json lo pretende.
- **Il prompt va su stdin come messaggio stream-json, mai su argv** (ARG_MAX).
- `--resume <sessionId>` se c'è un cursore, altrimenti `--session-id <nuovo>`.
- Permission broker: `--permission-prompt-tool mcp__ogb__approve` + un MCP server
  spawnato (`permission-proxy`) che parla su **unix socket** col broker nel server, +
  file MCP temporaneo a **0600** + `--allowedTools`.
- Auth: `claude auth status --json` → `loggedIn`. **Lo storage delle credenziali non va
  ispezionato** (Keychain su macOS, file altrove, backend futuri; e la presenza non
  implica validità).
- `stripWorkspaceCredentialEnv`: una `ANTHROPIC_API_KEY` ereditata fa fatturare
  pay-as-you-go un utente in abbonamento. Env del probe auth e env del turno devono
  essere **identici**, altrimenti setup dichiara un login che il turno rimuove.
- `generateText` = `-p <prompt> --model claude-haiku-4-5 --output-format text`.

#### 3.1.3 Codex — invarianti

- `app-server`, JSON newline-delimited. `turn/completed` qui **esiste** davvero.
- **Due generazioni di approvazioni in parallelo**, con result shape diversa:
  moderne (`item/fileChange/requestApproval`, `item/tool/requestUserInput`) →
  `{decision: "accept"}`; legacy (`execCommandApproval`, `applyPatchApproval`) →
  `{decision: "approved"}`. Vanno supportate entrambe.
- **L'app-server non esce da solo**: al `turn.completed` bisogna chiamare `stop()`
  esplicitamente, altrimenti si accumulano processi.
- Il token `total` è "il thread fino a qui", non il turno.
- MCP server e provider locali si configurano con flag `-c key=json`, senza toccare il
  `config.toml` dell'utente.

### 3.2 Strategia di parità: record & replay dei log nativi

Questo è il motivo per cui il vincolo è **verificabile** e non solo sperato.

L'app registra già, per ogni thread e ogni turno, il traffico di protocollo grezzo in
`~/.swarmebot/native/<threadId>.ndjson`, in entrambe le direzioni, con timestamp. Cioè:
**esiste già un corpus di sessioni reali di ogni harness.** Il piano lo usa come golden
master.

```
                    ┌── events/*.ndjson  (eventi canonici)   ─┐
Sessione reale ─────┤                                          ├──► golden pair
 (harness Node)     └── native/*.ndjson  (protocollo grezzo)  ─┘
                                    │
                                    │ replay come CLI finto
                                    ▼
                          Driver Dart sotto test
                                    │
                                    ▼
                       eventi canonici prodotti  ──► diff ──► PASS/FAIL
```

Procedura:

1. **Fase di raccolta (prima di scrivere una riga di Dart).** Uno script esercita ogni
   harness su una batteria di scenari: turno semplice, turno con streaming di reasoning,
   turno con tool call, turno con richiesta di permesso approvata, negata, e andata in
   timeout, turno con domanda all'utente, interrupt a metà, resume su un thread
   esistente, cambio modello in sessione, errore di auth, CLI assente, CLI che muore a
   metà turno. Si archivia la coppia `native` + `events` come fixture versionata.
2. **Un replayer** che, dato un `native/*.ndjson`, si comporta da CLI: emette le righe
   `dir:"out"` (CLI→harness) e verifica che il driver mandi le `dir:"in"` attese.
3. **Il test di parità** confronta gli eventi canonici prodotti dal driver Dart con
   `events/*.ndjson` del golden, ignorando solo i campi non deterministici (`eventId`,
   `createdAt`, `turnId`, `requestId`) tramite normalizzazione.

Tre note pratiche:

- `appendNative` passa i messaggi per `redactSecrets`: i valori sono mascherati, la
  *forma* resta intatta. Va bene per la parità di protocollo, ma il replayer deve
  tollerare valori mascherati dove il driver si aspetta un token — e i test che dipendono
  dal contenuto di un segreto vanno costruiti a mano, non dal corpus.
- Il corpus è timestampato: si può verificare anche l'**ordine** degli eventi, non solo
  l'insieme. L'ordine è un contratto reale (la UI streamma delta).
- I 5 fake CLI esistenti (`fake-acp-cli` 408 righe, `fake-claude-cli` 158,
  `fake-codex-app-server` 151, `fake-pi-cli` 160, `fake-agy-cli` 36) vanno portati in
  Dart **prima** dei driver corrispondenti: sono la specifica eseguibile del protocollo,
  scritta da chi l'ha decodificato.

### 3.3 Doppia esecuzione durante la transizione

Harness Node e harness Dart girano su **porte diverse e data dir diverse** (§2.4): il
greenfield qui è un vantaggio, perché due harness sullo stesso `~/.swarmebot` si
contenderebbero SQLite e config. Per tutta la Fase 3 si tiene il vecchio come riferimento
vivo: stesso prompt, stesso CLI, stesso bot ricreato a mano nella nuova dir, due harness,
diff degli eventi canonici normalizzati. È il test che nessuna suite sintetica
sostituisce, perché usa i CLI **veri** nelle versioni **installate oggi**.

### 3.4 Cosa NON fare

- **Non riscrivere i driver "meglio".** Nessuna ristrutturazione, nessun consolidamento
  dei quirk, nessuna astrazione nuova durante il port. I commenti vanno portati con il
  codice: sono la documentazione dei protocolli che nessun altro possiede.
- **Non aggiornare i CLI durante il porting.** Le versioni installate sono parte del
  golden master. Un aggiornamento di `claude` a metà Fase 3 rende indistinguibile un bug
  di porting da una deriva di protocollo upstream.
- **Non toccare `contracts.ts` oltre la rimozione delle integrazioni.** Ogni cambio di
  forma degli eventi invalida il corpus.

---

## 4. Architettura target

```
┌───────────────────────────────────────────────────────────┐
│  swarmebot_app  (Flutter — macOS / Windows / Linux / iOS) │
│  Riverpod · go_router · SSE client · Mascot renderer      │
└──────────────────────────┬────────────────────────────────┘
                           │ HTTP + SSE su 127.0.0.1:8799
                           │ (identico all'attuale contratto)
┌──────────────────────────▼────────────────────────────────┐
│  swarmebot_harness  (Dart VM — shelf)                     │
│  registry · bus · store · message-db · drivers · broker    │
└──────────────────────────┬────────────────────────────────┘
                           │ Process.start / stdio JSON-RPC / HTTP
                  ┌────────┴────────┬──────────────┐
              CLI agent          MCP proxy     endpoint
            (claude, acp…)    (permission,   OpenAI-compat
                               agents)       (Hermes/LiteLLM…)
```

### 4.1 Monorepo Dart

```
/Users/cristiano/Sviluppo/SwarmeBot-Flutter/
  packages/
    swarmebot_contracts/   # sealed RuntimeEvent, SPI driver, DTO condivisi (pure Dart)
    swarmebot_harness/     # server: shelf router, registry, bus, store
    swarmebot_drivers/      # i 14 driver + acp/core
    swarmebot_parity/       # replayer, comparatore, fake CLI in Dart  ← §3.2
    swarmebot_mcp/          # client+server MCP stdio minimale
  apps/
    swarmebot_app/          # Flutter: UI + supervisione processo harness
    swarmebot_proxies/      # entrypoint AOT dei proxy spawnati (permission, agents)
  parity/corpus/            # fixture golden registrate dalla repo di riferimento (§2.5)
  docs/                     # questo piano, SHA congelato, versioni CLI, esclusioni
```

`swarmebot_parity` è **l'unico package autorizzato a conoscere i formati della repo
vecchia** (§2.5). Isolarlo lì è ciò che impedisce al formato legacy di rientrare nel
prodotto dalla porta di servizio.

`swarmebot_contracts` è condiviso fra app e harness: **la duplicazione dei tipi
frontend/backend che oggi esiste** (`src/state/store.tsx` ridichiara `Message`, `Bot`,
`Group`, `Task`, `ModelSelection` in parallelo a `server/store.ts`) **sparisce**. È il
guadagno strutturale più grosso della migrazione a un unico linguaggio.

### 4.2 Come l'app avvia l'harness

Tre opzioni, in ordine di preferenza:

1. **Processo separato AOT** (`dart compile exe`, spawnato dall'app come oggi Electron fa
   `utilityProcess.fork`). Mantiene l'isolamento crash, il `server.log`, il probe
   `/api/health` con identity-check per PID, e permette a un client remoto (iOS) di
   puntare allo stesso harness. **Raccomandata.**
2. Isolate dentro il processo Flutter. Meno file da firmare, ma un crash del driver si
   porta via la UI e perdi il modello "harness condiviso in rete".
3. In-process senza isolate. Da escludere: il polling stdio dei driver bloccherebbe l'UI.

### 4.3 Sostituzione delle API native Electron

Il preload Electron oggi espone 30 canali; dopo la potatura di §2.1 ne restano ~8.

| Oggi (`window.ogb.*`) | Domani |
|---|---|
| `setCredential` (safeStorage) | `flutter_secure_storage` (Keychain / DPAPI / libsecret) |
| `openExternal`, `pickFolder` | `url_launcher`, `file_selector` |
| `openInstallTerminal` | `Process.run` con l'apri-terminale per piattaforma |
| `getPathForFile`, drag&drop | `super_drag_and_drop` / `desktop_drop` |
| `speechStart/Stop/Finish` | plugin STT nativo o l'helper Swift esistente riusato |
| updater | updater custom su `latest.yml` esistente |
| `getCapabilities`, `localControl`, `androidDevice`, `desktopViewer`, `companion` | **eliminati** con il computer use |

---

## 5. Nuova sezione "Local Inference" (config esplicita, non discovery)

Requisito: **niente discovery automatico**, una sezione dedicata dove configurare
url/api-key per provider e attivarli/disattivarli.

Oggi `server/drivers/local-inject.ts` ha una `LOCAL_HOSTS` **hardcoded** (oMLX, Ollama,
EXO, LM Studio, Unsloth, vllm_api, Local Endpoint) con chiavi placeholder tipo `"ollama"`
e probe automatico a 1200 ms su ogni refresh del picker (`probeLocalInjects`).

### Modello dati nuovo

```dart
class LocalProvider {
  String id;              // slug utente, non più costante di build
  String label;
  String baseUrl;         // normalizzato: origin nudo → +/v1
  String? apiKeyRef;      // riferimento al secure storage, non il valore
  bool enabled;           // interruttore esplicito
  LocalProviderKind kind; // openaiCompatible | ollamaNative | hermesAgent
  ProbeResult? lastProbe; // esito e timestamp dell'ultimo test manuale
}
```

Persistito in `config.json` sotto `localProviders: []`, chiavi nel secure storage.

Conseguenze:

- `LOCAL_HOSTS` costante → lista utente. I preset (Ollama :11434, LM Studio :1234,
  vLLM :8000, oMLX :8080) diventano **template di creazione**, non host attivi.
- Il probe diventa: (a) manuale, con bottone "Test connection" che mostra modelli trovati
  e loaded; (b) al massimo un refresh cache dei modelli quando l'utente apre il picker,
  **solo sui provider `enabled`**.
- `encodeInjectId(host, model)` → `"<providerId>::<model>"` **resta come formato**: è già
  quello che viaggia in `ModelSelection.model` e che i driver decodificano. Cambiarlo
  romperebbe la parità di §3. `decodeInjectId` valida contro la lista utente invece che
  contro `HOST_BY_ID`.
- Gli injector per driver restano **identici nel comportamento** e vanno portati uno a
  uno: `applyOpenAIInject` (env `OPENAI_BASE_URL/KEY`), `applyClaudeInject` (env
  `ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY/MODEL`), `codexLocalProviderArgs` (flag `-c
  model_providers.*` + segreto passato per nome-di-env, mai su argv),
  `ensureGrokInjectSlug`, `ensureHermesInjectProvider` (**scrive
  `~/.hermes/config.yaml`**). Quest'ultimo è l'unico che tocca file di terzi: da
  riscrivere in Dart con `package:yaml` preservando l'upsert non distruttivo del blocco.
- Si può togliere il caso speciale `readUnslothKey` (lettura di
  `~/.unsloth/studio/auth/agent_api_key.json`): con la config esplicita non serve più.
- Sopravvive il fatto che `CODEX_RESERVED_PROVIDERS` (`openai`, `ollama`, `lmstudio`) non
  vanno riconfigurati su Codex: sono nomi già suoi.

### UI

`Settings → Local Inference`: lista provider con toggle, badge stato
(configurato / raggiungibile / errore + motivo), conteggio modelli, editor url+key,
"Add provider" da preset o custom. Sostituisce `ApiKeys.tsx` per la parte locale.

---

## 6. Continuità sessione Hermes / LiteLLM (da preservare 1:1)

È la parte più delicata e con la logica meno ovvia del codice. Sta in
`server/drivers/local-endpoint.ts` e va portata **con i suoi commenti**.

Macchina a stati `Continuity`:

| Stato | Come ci si arriva | Comportamento sul turno |
|---|---|---|
| `session(header)` | `/v1/capabilities` risponde `platform == "hermes-agent"` e `auth.required` | manda solo system + ultimo messaggio, header sessione presente |
| `unknown` | `/v1/capabilities` 404/errore — **il caso più comune in produzione** (LiteLLM davanti a Hermes 404-a tutto ciò che non è OpenAI) | *hedge*: manda l'header sessione **e** il transcript completo |
| `none` | 403 su una continuation, o `platform` diverso | transcript completo, nessun header |

Dettagli da non perdere:

- Header `X-Hermes-Session-Id`, letto da `features.session_continuity_header` invece che
  hardcodato, così un rename upstream viaggia con il probe.
- LiteLLM rinomina gli header di risposta con prefisso `llm_provider-`, quindi l'echo
  della sessione va cercato sia sotto il nome nudo che sotto
  `llm_provider-x-hermes-session-id` (`sessionEcho`).
- Il session id **lo generiamo noi** (`swarme-<uuid>`), non lo lasciamo derivare a Hermes:
  la sua `_derive_chat_session_id` hasha system prompt + primo messaggio utente, quindi due
  task che iniziano con le stesse parole collassano nella stessa sessione e un thread
  ribranchato riscrive nel ramo abbandonato. La forma (`swarme-…`, nessun separatore,
  nessun `..`, sotto i 256 caratteri) passa la guardia di Hermes.
- Il 403 su continuation è l'**unico** errore da cui `sendTurn` recupera: degrada a
  `none` e ripete il turno con il transcript completo.
- Timeout probe 5000 ms (contro i 1200 del probe modelli) perché un Local Endpoint è
  spesso remoto, non su loopback.
- **Nota dalla memoria di progetto**: gli header sono bidirezionali solo con
  `stream:false`; sulla SSE l'echo di `X-Hermes-Session-Id` non torna mai. Il client Dart
  non può assumere di leggere la sessione da una risposta streaming.

Il `resumeCursor` (opaco nei contratti, qui = session id Hermes) è già il meccanismo
generico di continuazione, condiviso con `--resume <sessionId>` di Claude Code e
`--conversation` di Antigravity: in Dart diventa un campo tipizzato per driver dentro una
`sealed class ResumeCursor`.

---

## 7. Avatar dei bot: due sole modalità

Oggi ci sono **quattro** percorsi avatar sovrapposti:

1. `CursorAvatar.tsx` — **1.746 righe**: mascot SVG procedurale con 39 stati animati
   (`sleeping`…`celebrate`, `orbit`, `radar`, `progress`), espressioni, sguardo, blink,
   gradienti, silhouette con clip-path.
2. `DicebearAvatar.tsx` + `@dicebear/*` — avatar generati.
3. `SpriteSheetAvatar.tsx` + `sprite-sheet.ts` — upload di sprite sheet 9×8 con
   rilevamento frame "inked" dai pixel RGBA.
4. `still-avatars.ts` — foto statiche.

Target richiesto: **immagine statica caricata dall'utente** *oppure* **Mascot in stile
Grok Bot**. Quindi:

- **Cade**: Dicebear (e le due dipendenze npm), sprite sheet + `dicebear-import.ts`
  server-side, la parte di `store.ts` che modella `MausColor` come tassonomia chiusa.
- **Resta, riscritto**: il mascot. Due strade:

  | Approccio | Pro | Contro |
  |---|---|---|
  | **A. `CustomPainter` Flutter** (path Bézier portati dalle `d=` SVG + `AnimationController`) | zero dipendenze, 60 fps nativi, controllo totale, si integra con lo stato bot | è la riscrittura più costosa del progetto UI (~1.700 righe di geometria) |
  | **B. Rive / Lottie** | mascot fatto da un designer, non da codice; file sostituibile senza rebuild | asset binario da produrre, meno espressività programmatica sui 39 stati, dipendenza runtime |

  **Raccomandazione: A per silhouette + volto** (sono pochi path; la complessità sta nella
  logica di espressione, non nel disegno), riducendo il vocabolario da 39 stati a un set
  utile (~10–12: idle, listening, thinking, working, happy, confused, alerting, sleeping,
  celebrate, error). Il resto è cruft accumulato.

- Il modello dati diventa `BotAvatar = StaticImage(path) | Mascot(palette, silhouette)`,
  una `sealed class`, con un solo endpoint di upload (`POST /api/bots/:id/picture`, oggi
  bivalente foto/sprite-sheet: si semplifica).

---

## 8. Canali multi-bot, Bot Master e schedulazioni

Decisioni prese (rev. 3 → rev. 4), tutte confermate come definitive:

| # | Decisione |
|---|---|
| D1 | **Canale nuovo: nessun master di default** |
| D2 | **La modalità `everyone` non serve** — si rimuove |
| D3 | **Le schedulazioni restano sempre per singolo bot, mai su canale** |
| D4 | **Il Bot Master deve conoscere i membri del canale e il loro ruolo**, nel proprio system prompt, per poter taggare e delegare |

### 8.1 Il routing esiste già — è `GroupDefaultResponder`

La semantica master/mention è **già implementata e in produzione**, in `server/store.ts`.
Non è una feature da progettare: è un item di parità, che le decisioni sopra
*semplificano*.

```ts
export type GroupDefaultResponder =
  | { kind: "member"; botId: string }   // ← il Bot Master
  | { kind: "everyone" }                // ← D2: da rimuovere
  | { kind: "mentions" };               // ← nessun master; D1: nuovo default
```

Regole di risoluzione dopo D2 (`roomResponders`), in ordine:

1. `@mention` esplicite → **solo** quei bot.
2. Altrimenti il default responder: `member` → il master; `mentions` → **nessuno** (il
   messaggio resta nel canale senza risposta, ed è il comportamento corretto).

Dettagli del parser mention che sono contratto e vanno portati identici:

- Un `@` preceduto da un carattere non-whitespace è ignorato: `user@host` non è un tag.
- I candidati sono ordinati **per lunghezza di nome decrescente**, così `@botanalyst` non
  viene catturato da un bot che si chiama `bot`.
- Il carattere dopo il nome non può essere alfanumerico, altrimenti il tag non conta.
- I bot `hidden` non sono mai destinatari.
- Match case-insensitive.

**La logica è duplicata a mano** fra `server/store.ts` (`mentionedBots`,
`roomResponders`) e `src/lib/group-routing.ts` (`mentionedMembers`,
`roomRespondersForComposer`), con un commento che chiede di tenerle allineate. Nel
monorepo Dart va **una sola implementazione in `swarmebot_contracts`**, usata da harness e
UI: è il caso più netto, in tutto il codice, del guadagno del linguaggio unico.

### 8.2 D1 — nessun master di default

Oggi `normalizeGroupDefaultResponder` fa l'opposto: promuove il **primo membro** a lead
quando il campo è assente. Era retrocompatibilità per i canali vecchi che senza il campo
"mandavano nel vuoto" — e con il greenfield (§2.4) **quel caso non esiste più**.

Risultato: la funzione si semplifica in una riga. Il campo si scrive sempre
esplicitamente alla creazione, il default è `{kind:"mentions"}`, e non c'è nessun ramo
"campo assente" da gestire. Sparisce il problema, non solo il codice.

### 8.3 D2 — rimozione di `everyone`

Non è solo un caso di union: `everyone` ha diramazioni in 9 file, e due meritano
attenzione.

| File | Cosa contiene |
|---|---|
| `server/store.ts` | il caso della union, `normalizeGroupDefaultResponder`, e il ramo `@everyone` in `roomResponders` (regex `/(?:^|\s)@everyone\b/i`) |
| `server/index.ts:3024` | il PATCH del canale che accetta `kind:"everyone"` |
| `server/team-manifest.ts` | lo schema e il tipo del **formato dei team esportati**. Col greenfield non serve accettare `everyone` in import: il caso si elimina, non si normalizza |
| `src/lib/group-routing.ts` | `effectiveDefaultResponder`, i due hint di UI, il ramo `@everyone` |
| **`src/lib/group-call.ts`** | ⚠️ il **riconoscimento vocale**: "everyone", "everybody", "all" vengono tradotti in `@everyone`. Va rimosso lì e in `GroupCallView.tsx` (due stringhe di suggerimento) |
| `src/components/Composer.tsx` | la voce `__everyone__` nell'autocomplete delle mention |
| `src/components/GroupView.tsx` | il picker della modalità di risposta |

Col greenfield non c'è nessun canale persistito da normalizzare: `everyone` si elimina e
basta. Era l'ultima domanda aperta di questo capitolo, e il greenfield l'ha chiusa.

### 8.4 D4 — il Bot Master conosce i membri e i loro ruoli

**Anche questo esiste già**, e va riconosciuto per non riscriverlo. In `server/index.ts`,
la costruzione del system prompt di ogni turno di canale:

```ts
const roster = group.memberIds
  .map((id) => store.bot(id))
  .filter((b) => Boolean(b))
  .map((b) => `@${b.name}${b.title ? ` (${b.title})` : ""}`)   // ← nome + RUOLO
  .join(", ");

const system = [
  `You are ${bot.name}, a bot in the room "${group.name}" in SwarmeBot.`,
  bot.description?.trim() && `About: ${bot.description.trim()}`,
  `Room members: ${roster}, and ${userName} (the human).`,
  group.bulletin.trim() && `Room bulletin (shared instructions for everyone):\n…`,
  `Reply as yourself, briefly and conversationally. To bring a teammate in, mention them
   like @Name — they'll see the conversation and respond.`,
].filter(Boolean).join("\n");
```

Quindi il roster con **nome + titolo** e l'istruzione esplicita a delegare taggando
`@Name` ci sono già. `BotRecord.title` è il campo che porta il ruolo, e
`BotRecord.description` la descrizione lunga.

Restano **quattro divari reali**, e sono la sostanza del lavoro su D4:

1. ⚠️ **Bug: il roster non filtra i bot `hidden`, il routing sì.**
   `roster` filtra solo `Boolean(b)`, mentre `mentionedBots`/`roomResponders` filtrano
   `!member.hidden`. Conseguenza: il master legge nel proprio prompt un membro nascosto,
   lo tagga per delegargli un compito, e **nessuno risponde** — il turno si chiude in
   silenzio e il compito si perde. Va allineato al filtro del routing. È un bug di oggi,
   non della migrazione: **da correggere in Fase 0**, dove i test attuali ci sono ancora.

2. **Il master non sa di essere il master.** Il prompt gli dice chi c'è e come taggare,
   ma non gli dice che *lui* risponde per default e che **gli altri non risponderanno se
   non taggati**. Con D1 (nessun master di default) questa informazione diventa
   necessaria: un master che non sa di essere l'unico risponditore non capisce che
   delegare richiede un tag — è l'unico modo per far agire un altro membro. Da aggiungere
   una riga condizionale al ramo `member` del default responder.

3. **Il ruolo è solo il `title`.** Se "con che ruolo" deve includere la descrizione del
   bot, va aggiunta al roster. Costo: token nel system prompt di *ogni* turno di canale, su
   ogni membro, moltiplicato per il numero di membri. **Raccomandazione: `title` sempre,
   `description` troncata (es. 120 caratteri) solo nel prompt del master**, che è l'unico
   che deve decidere a chi delegare. Gli altri membri non hanno bisogno di sapere i
   dettagli dei peer per rispondere quando taggati.

4. **Il roster è identico per tutti i membri.** Con D4 il prompt diverge: il master riceve
   roster arricchito + regola di routing + mandato a delegare; un membro non-master riceve
   il roster essenziale e **non** l'invito a "bring a teammate in" (oggi ce l'hanno tutti,
   e in un canale in `mentions` è un invito a un'azione che non produce nulla se il
   destinatario non è taggato correttamente).

Nota architetturale: esiste già un secondo canale per la stessa informazione — l'MCP
`agents` (`list_bots` / `ask_bot`, `drivers/agents-proxy.ts`), che sopravvive alla
potatura di §2.1 ed è l'unica integrazione che resta. È un *tool* che il bot può chiamare;
D4 chiede invece l'informazione **nel prompt**, cioè disponibile senza spendere un giro di
tool. Le due cose sono complementari e non si escludono: il roster nel prompt dice *chi
c'è*, `ask_bot` serve a parlare con un bot **fuori** dal canale. Da non confondere in
fase di implementazione: dentro il canale si delega taggando, non con `ask_bot`.

### 8.5 D3 — schedulazioni sempre per singolo bot

`server/routines.ts` ha già esattamente questa forma (`Routine.botId`, nessun `groupId`),
quindi D3 **non richiede lavoro**: è un port 1:1, e cade la `sealed class RoutineTarget`
che la rev. 3 prevedeva come assicurazione. Cade anche la Fase 7.

Resta comunque una semplificazione obbligata su `Routine`, indipendente da D3: **`runOn:
"maus" | "cloud"` perde il caso `cloud`**, che eseguiva l'agente dentro la Box VM del bot
e muore con il computer use (§2.1). Col greenfield non ci sono receipt storici da
rileggere, quindi il campo **sparisce del tutto** invece di sopravvivere come input
normalizzato — e con lui `RoutineFile { version: 1 }` e i campi tenuti opzionali per far
migrare i file v1 in place (§2.4).

### 8.6 Vincoli dei turni di canale da non perdere

- **Un turno per canale alla volta**: `GroupRecord.busyBotId` serializza. È in-memory, non
  persistito, e c'è già codice che gestisce un'approvazione che sopravvive al proprio turno.
- **Watchdog di stallo** per turno di canale (`RoomTurnStallRegistry`,
  `roomTurnTimeoutMinutes`, default 5 min, range 1–1440) con messaggio dedicato.
- **Bulletin**: le istruzioni condivise del canale entrano nel system prompt di *ogni*
  membro.
- **`pinnedCwd`**: la cartella del canale si fissa al primo turno che dispatcha e non si
  muove più (`pinGroupCwd`); i membri off-host saltano la cartella ma non decidono il pin.
- **Mention a catena**: il testo della risposta di un membro viene ripiegato e **ri-routato**
  dopo il turno, così un `@Nome` scritto *dal master* mette in carico il collega. È il
  meccanismo su cui poggia tutta la delega di D4 — se si rompe, D4 non funziona anche con
  il prompt perfetto.
- **`memberTurnSelection`**: un turno di canale deve copiare `model` (+ `effort`) dalla
  selezione del bot. Il commento nel file è una lista di sintomi reali: un `model`
  mancante manda Hermes su OpenRouter con HTTP 401, uccide Qwen con "Internal error", e fa
  girare Grok sul suo default cloud in silenzio. Rientra nella parità di §3.
- I canali `dm` (auto-creati per gli scambi bot⇄bot) forzano `mentions` e non hanno
  master: da preservare.

### 8.7 Dove atterra il lavoro

Con il greenfield nulla di questo capitolo si fa più in TypeScript: sono tutte cose che
**semplicemente non si portano**, oppure si scrivono già giuste in Dart.

| Attività | Fase | Note |
|---|---|---|
| Routing @mention unificato + `GroupDefaultResponder` senza `everyone` | **1** | una sola implementazione condivisa; default `mentions` |
| Routine sempre per bot, `runOn` senza `cloud`, nessun `version: 1` | **1** | forma dei DTO, zero migrazione |
| Roster filtrato come il routing (§8.4 §1) | **4** | il bug non si riproduce: nasce col filtro giusto |
| Prompt differenziato master/non-master (§8.4 §2–4) | **4** | insieme al resto del routing di canale |
| UI: canale con Bot Master facoltativo (default nessuno), editor membri, bulletin, hint | **5.5** | il picker non ha mai avuto `everyone` |

Da tenere presente: **il bug del roster `hidden` non va "corretto", va non-introdotto.**
È l'unico punto di questo capitolo dove il greenfield chiede attenzione attiva invece di
farci risparmiare lavoro — è facile riportarlo copiando il codice di riferimento senza
accorgersene, ed è per questo che sta fra gli invarianti (§12.12).

---

## 9. Stack Dart/Flutter proposto

| Ruolo | Oggi | Domani | Note |
|---|---|---|---|
| HTTP server | `node:http` a mano | `shelf` + `shelf_router` | il router regex fatto a mano sparisce |
| SSE | scritto a mano su `res.write` | shelf handler custom | ~50 righe, nessun package serve |
| DB | `node:sqlite` | `package:sqlite3` | più vicino all'SQL attuale di `drift`; `chmod 600` + WAL si replicano |
| Validazione config | Zod | validatori a mano + `json_serializable` | Zod non ha equivalente 1:1; i messaggi di `schemaIssue` vanno riscritti |
| Spawn CLI | `child_process` | `Process.start` | vedi R4: `killCliTree` va rifatto |
| **JSON-RPC stdio (ACP, Codex)** | a mano in `acp/core.ts` | `package:json_rpc_2` su `StreamChannel` | ⚠️ da valutare con cura: `json_rpc_2` gestisce correlazione ed errori, ma il codice attuale ha timeout per-fase e gestione `-32601` propria. Se l'astrazione non combacia, **scrivere a mano è la scelta giusta** — la parità vale più dell'eleganza |
| Unix socket broker | `node:net` | `ServerSocket`/`Socket` unix domain | su Windows oggi named pipe: verificare parità |
| State UI | React reducer (~1.600 righe) | Riverpod + `sealed` actions | il reducer si mappa bene su notifier + pattern matching |
| Markdown | `react-markdown` + `remark-gfm` | `flutter_markdown` o renderer custom | highlighting: `shiki` → `re_highlight`/`flutter_highlight` |
| Tema/skin | 4 blocchi CSS `data-skin` | 4 `ThemeExtension` | `skins.ts` si traduce quasi direttamente |
| Cron routines | scheduler a mano | `cron` package o timer su isolate | |
| Secure storage | Electron `safeStorage` | `flutter_secure_storage` | migrazione non richiesta (R1 chiuso) |
| Packaging | electron-builder | `flutter build` + `msix`/`create_dmg`/`flutter_distributor` | firma e notarizzazione macOS da ricostruire |

---

## 10. Fasi

Ogni fase è **verificabile in isolamento** e lascia il prodotto in uno stato dimostrabile.
Le fasi 1.5 e 3 sono il cuore del progetto: insieme sono ~40% dell'effort.

### Fase 0 — Congelamento del riferimento (2–3 giorni)
Il greenfield (§2.4) **elimina la fase di potatura** che le rev. 1–4 prevedevano: non si
modifica più la codebase TypeScript, perché non si porta nulla di ciò che verrebbe
rimosso. Al suo posto, il lavoro che rende il riferimento affidabile:

- **Scaffold della repo nuova** in `/Users/cristiano/Sviluppo/SwarmeBot-Flutter`:
  `git init`, workspace Dart (`pubspec.yaml` con `workspace:`), i package vuoti di §4.1,
  e questo piano spostato in `docs/`.
- **Commit di riferimento congelato**: `db998f3` su `main`
  (*"fix local inject label"*, 2026-08-27), working tree pulito. Da lì si legge, e non si
  aggiorna durante la migrazione.
- **Versioni dei CLI registrate** (`claude`, `cursor-agent`, `codex`, `grok`, `gemini`,
  `kimi`, `droid`, `qwen`, `opencode`, `hermes`, `agy`, `pi`) — è il prerequisito di R0.
- **Lista esplicita delle esclusioni**: i file di §2.1 e la macchineria di §2.4, elencati
  per nome. Serve perché con il greenfield non c'è più un typecheck che segnala una
  cascata: l'unica difesa è una lista letta a mano prima di ogni port.
- **Nuova data dir** decisa e isolata, così la doppia esecuzione di §3.3 è possibile dal
  primo giorno. Proposta: `~/.swarmebot-flutter` in sviluppo.
- **Flutter SDK**: *non* serve adesso (§2.6). Va installato prima della Fase 5.

*Uscita: repo nuova inizializzata e vuota, riferimento che non si muove più sotto i piedi.*

> ⚠️ Il prezzo del greenfield: le semplificazioni sui canali (§8) e il bugfix del roster
> `hidden` **non** si fanno più in TypeScript coi test esistenti, ma direttamente in
> Dart. Si guadagna una settimana e si perde la rete di sicurezza. Accettabile perché
> sono sottrazioni e un filtro di una riga — non lo sarebbe per i driver, che è esattamente
> perché quelli hanno il corpus golden di §3.2.

### Fase 1 — `swarmebot_contracts` (3–5 giorni)
Port di `contracts.ts` + i DTO di `store.ts` in Dart puro, con `sealed class` per
`RuntimeEvent`.

**La forma degli eventi canonici resta quella attuale** — è l'unico vincolo che il
greenfield non tocca (§2.4), perché il corpus golden li confronta. Ma non serve
compatibilità *byte per byte* sulla persistenza: basta che il **comparatore** di §3.2
sappia leggere il formato vecchio e normalizzare entrambi i lati. Il prodotto non legge
mai un file scritto dall'app Node.

Tutto il resto è libero e va ripulito adesso, non portato: schema SQLite normalizzato
(`parentId` sempre presente, un solo regime di albero), config come documento tipizzato
unico, e **una sola implementazione** di `GroupDefaultResponder` + routing @mention
condivisa fra harness e UI (§8.1), che oggi è duplicata a mano in due file.

*Uscita: round-trip dei `RuntimeEvent` verificato contro NDJSON reali presi dalla
macchina — come fixture di test, non come formato di produzione.*

### Fase 1.5 — Infrastruttura di parità (1,5–2 settimane) ⭐
**Prima di qualsiasi driver.** Raccolta del corpus golden su tutti i 14 harness
(§3.2 punto 1), replayer, normalizzatore, comparatore, porting in Dart dei 5 fake CLI.
Va fatta *finché l'harness Node funziona*: è la finestra in cui il golden master si può
generare.
*Uscita: `dart test` esegue il corpus contro un driver-stub e riporta un diff leggibile.
Zero driver ancora scritti, ma il metro di misura esiste.*

### Fase 2 — Harness core in Dart (2–3 settimane)
`shelf` router, registry (con la semantica shadow-snapshot), event bus + tee NDJSON,
`Store`, `message-db` su `sqlite3`, config + secure storage, SSE `/api/events`,
thread-events, steer-queue, turn-watchdog.
**Un solo driver**, il più semplice: `localEndpoint` (HTTP puro, zero spawn) — che è anche
quello che porta subito Hermes/LiteLLM (§6).
*Uscita: la UI React esistente punta al server Dart e funziona* — il test di parità
end-to-end più forte disponibile, e va sfruttato per tutte le fasi 2–4.
Due precisazioni sotto greenfield: la UI React è un **rig di test in sola lettura**, non
si modifica; e i pannelli delle feature rimosse (§2.1) risponderanno 404 — è atteso, non
un difetto del rig. I dati di prova si ricreano a mano nella nuova data dir (§2.4).

### Fase 3 — I 14 driver (4–6 settimane) ⭐
Ogni driver segue lo stesso ciclo: **fake CLI Dart → port → corpus golden verde →
doppia esecuzione contro il CLI vero (§3.3) → chiuso.** Nessun driver si considera fatto
senza tutti e quattro i passi.

Ordine:
1. `acp/core` — sblocca 8 driver in un colpo. Il pezzo singolo più delicato (§3.1.1).
2. hermes → qwen → gemini → kimi → droid → cursor → grok → opencode-go
   (dal più semplice al più pieno di quirk).
3. `claudeAgent` + permission broker su unix socket + proxy MCP AOT (§3.1.2).
   È il sottoprogetto dentro la fase: `dart compile exe` per ogni entrypoint, e la
   lezione di `proxy-paths.ts` (path risolti dalla root del server, mai relativi al
   modulo — ha rotto la 0.1.24 in silenzio con `/api/health` verde) va replicata come
   invariante testata.
4. `codex` (§3.1.3), poi `antigravity`, `pi`, `grok` API.

*Uscita: parità driver completa e dimostrata, sempre con la UI React davanti.*

### Fase 4 — Feature server residue (1–2 settimane)
Schedulazioni (con `runOn: "cloud"` rimosso, §8.3), webhooks ingress, team
library/import-export, skill library, delegations, chief-of-staff, decision-log, search,
attachments, TTS — **tutte senza i rami di import/migrazione** di §2.4, che è ciò che le
rende più corte del loro equivalente TypeScript. Include il routing dei canali
(`roomResponders`, `busyBotId`, watchdog di stallo, bulletin, `pinnedCwd`, mention a
catena, `memberTurnSelection` — §8.6), il **system prompt differenziato
master/non-master** con roster e ruoli (§8.4 §2–4), e le semplificazioni di §8 che la
Fase 0 non fa più: nessun `everyone`, default senza master, `Routine` con il solo
`runOn: "maus"`, roster filtrato come il routing.
*Uscita: il riferimento TypeScript non serve più a nessuno tranne al comparatore di
parità.*

### Fase 5 — App Flutter (4–6 settimane)
In ordine di rischio decrescente:
1. Shell + tema/skin + supervisione processo harness + SSE client + Riverpod store.
2. Sidebar, ChatView, Composer, markdown, approval/question card, streaming.
3. Model picker con rail engine + sezione **Local Inference** (§5).
4. **Mascot** (§7) + upload immagine statica.
5. **Canali multi-bot**: creazione con Bot Master facoltativo (default: nessuno),
   editor membri, bulletin, hint del composer che dice chi risponde. Il picker della
   modalità di risposta perde la voce `everyone` (§8.3).
6. Task picker, pagina schedulazioni, settings completo, onboarding, search,
   command palette, inspector.
*Uscita: l'app Flutter sostituisce quella React contro lo stesso harness.*

### Fase 6 — Packaging e release (1–2 settimane)
Bundle harness AOT + proxy dentro l'app, firma/notarizzazione macOS, installer Windows,
`.deb`, auto-update.

**Stima totale: 14–20,5 settimane** a una persona. Evoluzione fra le revisioni:

| Rev. | Stima | Cosa l'ha mossa |
|---|---|---|
| 1 | 15–21 | — |
| 2 | 16–23 | +1,5–2: Fase 1.5, prezzo del vincolo di parità |
| 3 | 17–24,5 | +1–1,5: Fase 7, schedulazioni su canale |
| 4 | 16–23,5 | −1–1,5: D3 elimina la Fase 7 |
| **5** | **14–20,5** | **−1: Fase 0 da potatura a congelamento. −1–2: nessun ramo di import/migrazione in Fasi 1, 2, 4** |

Il greenfield è la singola decisione che ha ridotto più lavoro di tutte. La Fase 5 è
parallelizzabile con la 3 appena i contratti sono fermi; la 1.5 non è comprimibile senza
rinunciare alla verifica.

---

## 11. Rischi e decisioni aperte

| # | Rischio | Impatto | Stato |
|---|---|---|---|
| **R0** | **Deriva di protocollo durante il porting.** Un CLI che si aggiorna a metà Fase 3 rende indistinguibile un bug di port da un cambio upstream. | **alto** | Congelare le versioni CLI usate per il golden master; documentarle nel corpus; aggiornare solo *dopo* la parità raggiunta, e in quel momento rieseguire il corpus su Node **e** Dart per attribuire la differenza. |
| R1 | Migrazione dei segreti safeStorage → flutter_secure_storage | — | ✅ **Annullato dal greenfield**: non c'è nulla da migrare, le chiavi si reinseriscono. |
| R2 | Continuità auto-update da electron-updater | — | ✅ **Annullato dal greenfield**: la nuova app è un'installazione nuova. |
| R3 | **Nessun equivalente Zod.** La validazione config produce messaggi precisi (`schemaIssue`) su cui la UI si appoggia. | medio | Validatori a mano nel package contracts, con test sui casi reali di `config.test.ts`. |
| R4 | **`kill-tree` su Windows.** `killCliTree` gestisce alberi di processo; Dart non ha equivalente. | **alto** | `taskkill /T /F` su Windows, process group su POSIX. Test dedicati: è la fonte classica di CLI zombie — cfr. i due plan del 2026-08-18 in `docs/plans/`, entrambi su teardown di turni Claude. Rientra nella parità. |
| R5 | Voice/TTS in scope v1? Lo STT usa un helper Swift firmato dentro l'app. | medio | **Decisione richiesta**: rinviare a v1.1 è ragionevole. |
| R6 | Companion iOS: l'app Flutter su iOS renderebbe ridondanti `companion/` + `ios/`, ma pairing mDNS e Live Activities sono lavoro Swift già fatto. | medio | **Decisione richiesta**: congelare, sostituire, o mantenere in parallelo. |
| R7 | **Perdita dei test.** ~21.100 righe di Vitest non si traducono automaticamente, e il greenfield toglie anche la rete di sicurezza che la Fase 0 della rev. 4 offriva (typecheck sulle cascate). | **alto** | Mitigato dalla Fase 1.5: il corpus golden copre i driver, che sono la parte non verificabile a occhio. Per il resto, portare per primi i test di `contracts`, `store`, `local-inject`, `local-endpoint` — leggendoli come specifica, non traducendoli. |
| **R11** | **Il greenfield fa "ripartire da zero" anche dove non deve.** Due punti: la forma dei `RuntimeEvent` (vincolata dal corpus, §2.4) e gli invarianti di §12, che non sono formato ma comportamento. Riscriverli "meglio" è la trappola. | **alto** | §2.4 e §12 sono espliciti su cosa resta vincolato. La lista di esclusioni della Fase 0 va letta prima di ogni port, perché senza typecheck non c'è nient'altro che segnali l'errore. |
| R8 | Vocabolario mascot da 39 stati: ridurlo è scelta di prodotto. | basso | **Decisione richiesta**: quali stati sopravvivono. |
| R9 | Maturità desktop Flutter su Linux (drag&drop, libsecret, tray). | medio | Prototipo Linux in Fase 5.1, non a fine progetto. |
| R10 | **`json_rpc_2` potrebbe non combaciare** con i timeout per-fase e la gestione errori di `acp/core.ts`. | medio | Spike di 2 giorni in apertura di Fase 3. Se non combacia, JSON-RPC a mano: 300 righe, e la parità vale più del riuso. |

---

## 12. Invarianti da non cambiare

Oltre a quelli dei driver (§3.1.1–3.1.3), ognuno di questi è la cicatrice di un bug reale
ed è documentato con un commento nel codice attuale. **Il greenfield non li tocca**: sono
invarianti di comportamento, non di formato — è la distinzione che conta quando si
riparte da zero, perché "nessuna compatibilità dati" non significa "nessuna lezione
appresa".

1. **Driver ignoto → shadow snapshot unavailable**, mai un errore di startup. Non è
   retrocompatibilità col passato (che il greenfield ha eliminato): è compatibilità fra
   versioni *future* dell'app Dart, e serve esattamente come prima.
2. **Un adapter può emettere eventi solo per il proprio `driverKind`** (guardia nel bus).
3. **`turn.completed.usage` è l'unica cifra accumulabile**; `thread.token-usage.updated`
   è un indicatore live con semantica diversa per driver e non va mai sommato.
4. **Il DB dei transcript a 0600**, creato con quei permessi e riparato se un umask
   permissivo li ha allargati.
5. **Redazione dei segreti** prima di scrivere `events/` e `native/` (sono file che la
   gente incolla nelle bug report) — mascherando i valori e preservando la forma.
6. **I path dei proxy si risolvono dalla root del server**, mai relativi al modulo
   (bundling/AOT li sposta: ha già rotto la 0.1.24 in silenzio).
7. **Il gate loopback-host + loopback-origin viene prima di ogni route** (DNS rebinding /
   CSRF).
8. **`generateText` è opzionale** sul `ProviderInstance` e serve a titoli/riassunti: non
   va confuso con un turno.
9. **`RequestOutcome.unavailable` è il default fail-closed**: nessun risponditore,
   nessuna azione. Un ask che non c'è più non solleva, restituisce `unavailable` e il
   chiamante lo tratta come deny.
10. **Nei canali le @mention esplicite vincono sempre sul Bot Master**, e un canale
    senza master non risponde a nessuno se non c'è un tag — il silenzio è il
    comportamento corretto, non un bug (§8.1).
11. **Un turno per canale alla volta** (`busyBotId`): una delega accoda, non
    parallelizza (§8.6).
12. **Il roster nel system prompt e il routing devono filtrare gli stessi bot.** Se il
    prompt nomina un membro che il routing scarta, il master delega nel vuoto (§8.4 §1).
13. **Le mention a catena sono il meccanismo della delega**: la risposta di un membro
    viene ri-routata dopo il turno, ed è così che un `@Nome` scritto dal master mette in
    carico il collega. Senza questo, D4 non funziona nemmeno con il prompt perfetto.

---

## 13. Domande da chiudere prima di iniziare

1. **Voice/TTS: v1 o v1.1?** (R5)
2. **iOS companion: congelare o rimpiazzare con l'app Flutter?** (R6)
3. **Mascot: quali stati e quale approccio** (CustomPainter vs Rive)? (R8, §7)
4. **Il modello "harness come processo separato raggiungibile in LAN" resta un
   requisito** (abilita l'app mobile) o l'harness può diventare un isolate interno? (§4.2)
5. Esiste un ambiente dove si possono esercitare **tutti** i 14 CLI (login validi,
   quote disponibili) per generare il corpus golden della Fase 1.5? Se un harness non è
   esercitabile, la sua parità non è verificabile e va dichiarato tale.
7. **Nome della nuova data dir runtime** (§2.4) — la repo è decisa
   (`SwarmeBot-Flutter`), la data dir no. Proposta: `~/.swarmebot-flutter` in sviluppo,
   con il nome definitivo scelto prima della Fase 6. Va fissata una volta: cambiarla dopo
   è la sola migrazione che il greenfield non ci risparmia.

6. **Il ruolo nel prompt del master è solo il `title` o anche la `description`?**
   (§8.4 §3) Raccomandato: `title` per tutti, `description` troncata solo per il master.

> Le domande 1–4 e 6 non bloccano l'inizio: la Fase 0 e la Fase 1 procedono comunque.
> **La domanda 5 sì** — è il prerequisito della Fase 1.5, e quindi della Fase 3.
