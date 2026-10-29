# Fase 2 — harness in Swift: architettura e avanzamento

Riferimento: `docs/plans/2026-10-13-swift-native-macos-analisi.md` §3, §4.2, §6, §8.
Contratto da rispettare: `docs/contract/http-sse.md` (congelato su SwarmeBot `1cd755d`).

## Decisioni

1. **Stesso contratto HTTP+SSE su 127.0.0.1.** Il motore Swift (`swarme-harness`) espone le
   stesse route e gli stessi frame del motore Node. L'app non cambia: `HarnessLauncher`
   avvia l'uno o l'altro.

2. **Convivenza per motore, non per istanza.** Il piano prevedeva driver Swift e Node
   affiancati *per istanza*. Farlo richiederebbe un ponte dentro il harness Node (repo
   SwarmeBot) oppure un host Node dei driver dentro quello Swift, e i driver Node dipendono
   dai proxy e dalle route interne del loro harness. Scelta più semplice e reversibile:
   - Impostazioni → Motore: **Node** (predefinito) oppure **Swift (anteprima)**;
   - nel motore Swift le istanze il cui driver non è ancora portato compaiono come *shadow*
     non disponibili ("non ancora disponibile nel motore Swift"), lo stesso meccanismo che
     il registry Node usa per i driver sconosciuti;
   - quando l'ultimo driver è portato, il motore Swift diventa il predefinito e Node si toglie.

3. **Dati: compatibili e protetti.** Il motore Swift legge e scrive lo stesso formato
   (`bots.json`, `groups.json`, `config.json`, `messages.db` SQLite WAL, `events/`, `native/`).
   I record sono oggetti JSON **ordinati che preservano i campi sconosciuti**: un campo che il
   motore Swift non conosce sopravvive a ogni scrittura.
   In anteprima lavora su una **copia** (`~/Library/Application Support/SwarmeBot/swift-engine`)
   creata alla prima accensione da `~/.swarmebot`: `messages.db` con `VACUUM INTO`, gli altri
   file copiati. Un motore incompleto non può quindi danneggiare i dati reali.

4. **Niente dipendenze di runtime.** HTTP su `Network.framework` (`NWListener`), SQLite di
   sistema (`import SQLite3`), JSON con parser/serializzatore propri (ordine delle chiavi
   preservato). Nessun Hummingbird o GRDB: meno superficie, build più rapida, nessuna
   versione da inseguire.

5. **Parità verificata, non dichiarata.** Ogni driver Swift passa lo stesso scenario del
   driver Node: un server finto (OpenAI SSE, ACP, stream-json…) guida entrambi, e la
   sequenza normalizzata di `RuntimeEvent` deve coincidere (`parity/`). I log `native/` reali
   restano un corpus da riprodurre in un secondo momento.

## Struttura

| Target | Contenuto |
|---|---|
| `HarnessCore` | `JSON`, contratti (`RuntimeEvent`, `ProviderAdapter`, `ProviderDriver`), `Redact`, `DataPaths`, `EventBus` con tee NDJSON, `Registry`, `AppConfig`, `MessageDB` (SQLite), `Store`, `Fold` (eventi → messaggi), `AutoApprove`, `TurnEngine`, `HTTPServer`, `SSEHub`, `Routes` |
| `HarnessCore` (CLI) | `CLIProcess` (posix_spawn in un process group proprio, kill dell'albero, segnali ripristinati), `PermissionBroker` (socket unix per turno), `PermissionProxy` (server MCP stdio: `swarme-harness mcp-permission <socket>`) |
| `HarnessCore` (DSH) | `DSHClient` (Host API: unary HTTP, `respond`, downlink WebSocket `events.mux`/`events.host`, trasporto diretto o paired con cookie), `DeepSeekSettings` (config, pairing, gestione modelli, route `/api/instances/:id/deepseek-harness…`) |
| `HarnessCore` (computer) | `Box` (client REST di box.ascii.dev: trova/crea/sveglia/addormenta, console, screenshot, desktop VNC→WebRTC), `RemoteComputer` (comandi di bootstrap e risveglio di Cua Driver, identici byte per byte al Node), `ComputerControl` (chi guida, richiesta d'aiuto, `/api/internal/computer-control`, poller dello schermo), `Computers` (computer del turno, route del pannello) |
| `HarnessDrivers` | driver portati: `LocalEndpoint`, `BoxAgent` (Computer), `Grok` (API xAI), `Claude`, `Codex`, `Pi`, `Antigravity`, `DeepSeek/DeepSeekHarness`, `ACP/ACPCore` (runtime JSON-RPC) + `ACP/ACPDrivers` (Grok, Gemini, Kimi, Droid, Cursor, OpenCode Go, Qwen, Hermes) |
| `swarme-harness` | eseguibile: `OMB_PORT`, `OMB_DATA_DIR`, stesse variabili del motore Node |
| `HarnessCoreTests` | unità + integrazione HTTP sul motore Swift + parità |

## Avanzamento (ordine del piano §8)

| Passo | Stato |
|---|---|
| 2a core: JSON ordinato, contratti, redazione, bus + NDJSON, registry con shadow, config (flotta, credenziali, salvataggio), `messages.db`, Store, fold, turni 1:1, coda, rami, approvazioni con auto mode/always-allow, decision log, memoria, HTTP/SSE con resume, ~45 route | **fatto** |
| 2b driver API: **Local Endpoint** (catalogo, continuità Hermes, recupero 403, interrupt) | **fatto, parità verificata** |
| Canali multi-bot: gestione (crea, modifica, elimina, letti) | fatto |
| 2e **Turni di canale** (risponditore predefinito, @menzioni, @everyone, catena di un passo, un membro alla volta, timeout, cursore per membro, cartella della stanza) e **comunicazione tra bot** (server MCP `agents` = `swarme-harness mcp-agents`, `/api/internal/*` con token, `ask_bot`, `delegate_bot` con coda persistente, approvazione tra bot, canale A⇄B e chip, Chief of Staff, turni non presidiati), **watchdog** dei turni bloccati, chip delle **chiamate ripetute** | **fatto, parità verificata** |
| Scelta motore nell'app, copia dati di anteprima, `swarme-harness` nel bundle | fatto |
| 2d **Claude** (stream-json, resume, broker permessi + `ask_user`, catalogo da settings e dal binario, modelli locali iniettati, interruzione) | **fatto, parità verificata** |
| 2b **Grok (API xAI)** | **fatto, parità verificata** |
| 2b **DeepSeek Harness** (sessioni create/riprese, `selectModel` che deve tornare identico, prompt in coda con frame trattenuti fino all'accettazione, baseline delle richieste rigiocate, barriera di resume, turni host ritirati dopo un'interruzione, approvazioni e domande, perdita dello stream, cursore `dsh1:` con persona consegnata) e route di impostazioni (connessione, pairing, discover, upsert diretti e paired) | **fatto, parità verificata** |
| DSH: `steer()` dell'adapter | non portato: il harness Node non lo chiama mai (la regola sul modello fuori catalogo nei turni di canale è in `Rooms.swift`) |
| 2c **ACP core** + Grok, Gemini, Kimi, Droid, Cursor, OpenCode Go, Qwen, Hermes (auth, session/new\|load con replay scartato, set_model/set_mode/set_config_option, permessi fail-closed, richieste sconosciute respinte, session/cancel, scrittura delle config dei CLI per i modelli locali) | **fatto, parità verificata** |
| ACP: server MCP `agents` per sessione | **fatto** (il server `computer` è nella riga del computer locale) |
| 2d **Codex** (app-server JSON-RPC, approvazioni nuove e legacy, domande, catalogo `model/list` + ~/.codex, provider locali via `-c`), **Pi** (RPC proprio, sessione per file, `set_model`, richieste UI), **Antigravity** (print mode, `--conversation`, watchdog) | **fatto, parità verificata** |
| Claude: server MCP `agents` | **fatto**; da fare: server `computer`, immagini, `generateText` (Composio, phone e dweb fuori perimetro: non si portano, piano §2.1 e §2.4) |
| 2e **Routine** (una volta / ogni giorno a HH:MM nei giorni scelti, recupero entro 12 h altrimenti "missed", esecuzione manuale, task staccati, annullamento, visto) e **webhook** (URL-capability con segreto solo come SHA-256, listener separato su 127.0.0.1:8800 / `OMB_WEBHOOK_PORT`, idempotenza per delivery id, filtro per tipo di evento, limite di frequenza e di run pendenti, cattura di verifica, rotazione, payload dietro il blocco UNTRUSTED, turno non presidiato); `runOn: "cloud"` sceglie il motore `boxAgent` se c'è | **fatto, parità verificata** |
| 2e **Team** (export, import add/replace/project con nomi numerati e campi privilegiati scartati, validatore del manifest con gli stessi messaggi di zod, catalogo e link GitHub via URLSession), **avatar** (SVG validato con le regole del motore Node, immagini raster e sprite sheet, PATCH che può solo cancellare), **card** (`PATCH /api/bots/:id/cards/:mid`) | **fatto, parità verificata** (le route di rete solo nei rifiuti: gli URL del catalogo e di GitHub sono fissi nel Node) |
| 2e **Routine a intervallo** (`schedule: {type:"interval", every, unit: minutes|hours}`, da 5 minuti a 7 giorni; solo Swift, il Node non la conosce, quindi niente scenario di parità): prima esecuzione dopo un periodo, poi sulla griglia senza deriva, nessuna run nuova finché la precedente non è finita, editor a tre modi nell'app | **fatto**; verificato con test unitari (`IntervalRoutineTickTests`, validazione, calcolo) e dal vivo su un motore di test (POST valido/invalido, run scaduta → una run, `nextRunAt` sulla griglia). Non verificato: l'editor nell'app (non aperto), un'attesa reale di più periodi |
| `/api/tts`, `/api/connectors*`, `connector-cards` | 501 per scelta: voce e Composio non fanno parte dell'app nativa |
| 2e **Computer cloud Box**: route del pannello (stato, provision, join, sleep, exec, screenshot, remove→409), **chi guida** (take/release/dismiss-help, frame `computer-control`, endpoint interno per i proxy con notifica `takeover`), **poller dello schermo** (frame `screen`, schermata finale in chat solo se il turno ha toccato lo schermo), driver **boxAgent**, computer del turno per le esecuzioni cloud (`prepareComputer`, collegato a `runOn` delle routine) | **fatto**; route e controllo alla pari, boxAgent con test unitario |
| 2e computer: VM locale (stato, lease, `mcp-container` verso Cua) montata come server MCP `computer` su Claude, Codex e ACP; `computerMcp` / `localComputerMcp` | **fatto per la VM, parità verificata** con un `docker` finto. Ancora fuori: il proxy REST del box (`computer-proxy`, azioni e browser semantico), il ciclo di vita VPS e Cua sul Mac (`local-computer`) |

| Companion iOS (pairing del telefono, porte 8810/8811, Bonjour) | non si porta: decisione dell'utente del 2026-10-14. `CompanionCore` resta, è il client dell'app Mac verso il motore, non il sidecar del telefono |

## Verifica

- `swift test --filter HarnessCoreTests` — JSON (ordine, campi sconosciuti, escape), redazione,
  auto-approve, host locali, Store (campi sconosciuti sopravvivono, rami, patch con null, redazione).
- `parity/compare.sh` e `SCENARIO=advanced parity/compare.sh` — lo stesso scenario sui due motori
  contro un endpoint OpenAI finto; tracce normalizzate identiche: **33 frame** (base: streaming,
  sessione Hermes, uso token, notifiche, titolo task) e **98 frame** (avanzato: modifica e nuovo
  ramo, cambio versione, messaggio accodato e drenato, interruzione a metà streaming con risposta
  parziale). Anche le richieste ricevute dall'endpoint coincidono (header di sessione, replay).
- `DRIVER=claude parity/compare.sh` — un `claude` finto (`parity/fake_claude.py`) che fa davvero il giro MCP
  attraverso il proxy dei permessi indicato in `--mcp-config`: **103 frame** identici (streaming e ragionamento,
  rumore dei subagenti scartato, chip strumento, resume con `--resume`, card di permesso approvata, domanda con
  scelte e risposta, interruzione a metà con risposta parziale, costo e uso del task, chiave API mai passata).
- `DRIVER=acp:<driverKind> parity/compare.sh` — un agente ACP finto (`parity/fake_acp.py`): **87 frame** identici per
  ciascuno degli 8 harness (auth, resume con `session/load` e replay da ignorare — anche un chunk non marcato prima
  del prompt —, richiesta sconosciuta dal server, card di permesso, chip strumento ok/fallito, uso token, interruzione).
  Con `ACP_MODEL=local_endpoint::fake/echo-1` i sei harness che scrivono la config del CLI (Hermes YAML, Kimi/Grok TOML,
  Qwen/Droid/OpenCode JSON) producono **file identici byte per byte** a quelli del motore Node (HOME privata).
- `DRIVER=grok|codex|pi|agy parity/compare.sh` — finti `codex app-server`, `pi --mode rpc` e `agy --print`
  (`parity/fake_*.py`); Grok API sul finto endpoint OpenAI. Codex 138 frame (permesso nuovo approvato, legacy
  negato, domanda, interruzione), Pi 105, Antigravity 63, Grok 30/91.
- `DRIVER=claude SCENARIO=rooms parity/compare.sh` — due bot (Alfa, Beta) sul finto `claude`, che usa davvero il server
  `agents`: `ask_bot` (turno di Beta dentro quello di Alfa), `delegate_bot` (Beta parte dopo il turno di Alfa),
  approvazione tra bot con card, poi una stanza con risponditore predefinito, @menzione e catena di un passo.
  **311 frame** identici, trascrizioni di bot e stanze comprese (canale `Alfa ⇄ Beta`).
- `DRIVER=dsh parity/compare.sh` — un Host DSH finto (`parity/fake_dsh.py`: HTTP + WebSocket RFC 6455 scritti a mano,
  pairing e plugin di gestione paired): **135 frame** identici, compresi effort che deve tornare identico, approvazione,
  domanda a scelta, interruzione con `turn/end` tardivo ignorato, e poi le route di impostazioni (16 chiamate, errori
  inclusi: 400/404/409/415, pairing rifiutato e riuscito, discover paired) e un turno dopo il pairing che riprende la
  sessione dal cursore attraverso `/remote/api` con il cookie. Le richieste ricevute dall'Host coincidono.
- `SCENARIO=team parity/compare.sh` — team, avatar e card: **50 chiamate HTTP** con le risposte intere (id casuali e
  timestamp normalizzati) e i **51 frame** che causano, identici; più gli 84 frame dello scenario base. Avatar SVG valido,
  rifiutato (handler, riferimento esterno, non SVG, troppo grande, content-type sbagliato), PNG sprite sheet e foto,
  raster vuoto e troppo grande, PATCH di riga e cancellazione; card risposte/chiuse e 404; export con nome predefinito,
  scelto e troppo lungo; `team-library/github` nei suoi rifiuti prima di ogni fetch; import rifiutati (modo, JSON
  invalido, manifest sbagliati, cartella relativa o inesistente), poi add con un membro ostile, project con cartella e
  stanza, legacy `openmaus.team` v1, replace. I fetch veri non entrano nella parità: il Node non permette di puntare il
  catalogo o GitHub altrove. `Tests/Fixtures/team-avatar.json` (generato da `team-avatar.mts` col motore Node) dà le
  risposte di riferimento a 71 manifest, 46 SVG, 34 link GitHub e 29 cataloghi per i test unitari.
- `parity/all.sh` — tutta la matrice: 27 scenari.
- `DRIVER=claude SCENARIO=computer parity/compare.sh` — Box finto (`parity/fake_box.py`, `OMB_BOX_API`): pannello
  completo (provision con creazione/rinomina/attesa/bootstrap/desktop, exec, screenshot via artifacts, join, sleep,
  remove→409, nuovo provision che sveglia invece di ricreare) e controllo (take idempotente, dismiss, release, azione
  sbagliata→400): **106 frame** e richieste al provider identiche, comandi compresi (confrontati per sha256).
- boxAgent: il driver Node ha l'URL dell'API cablato e non si può puntare a un finto; il driver Swift accetta
  `OMB_BOX_API` ed è verificato da `BoxAgentTests` contro lo stesso Box finto (crescita del testo, chip, chiusura).
- `parity/all.sh` — tutta la matrice: 25 scenari.
- CLI reali su questa macchina (solo stato e catalogo, nessun turno): `claude` 2.1.296, `cursor-agent` (259 modelli),
  `opencode` 1.18.19 (39 modelli) — `/api/instances` identico tra i due motori.
- `DRIVER=claude SCENARIO=automations parity/compare.sh` — **196 frame** identici: errori di validazione (500 per le
  routine, 400 per i webhook, come nel Node), esecuzione manuale, run lenta annullata mentre gira, consegna accettata e
  poi duplicata, JSON rotto, segreto sbagliato, evento filtrato, rotazione; anche gli elenchi finali di routine, run,
  webhook e tentativi coincidono (id, orari e segreti normalizzati).
- I test di integrazione della fase 1 (`scripts/integration-test.sh`) girano anche contro il
  motore Swift: bot, canali e task passano; routine e webhook rispondono 501 come atteso.

## Lezioni

- Codex (2026-10-29): `account/rateLimits/*` fornisce la quota dell'abbonamento anche fuori
  da un turno; la finestra primaria non è necessariamente di cinque ore. Il costo del task è
  una stima API Standard dai token, marcata come tale e distinta dall'addebito dell'abbonamento.
  Vedere [Costo e utilizzo Codex](2026-10-29-utilizzo-codex.md).

- `generateText` esiste sui driver Node (titoli e nomi) ma il harness non lo chiama da nessuna parte. Non è stato portato: non c'è un chiamante da far coincidere.
- Nel Node le validazioni delle routine lanciano `Error` senza status: le route rispondono **500**, non 400. Lo si
  replica (lo scenario `automations` lo controlla); i webhook invece rispondono 400.
- La VM locale risulta pronta solo se l'inspect del container soddisfa gli stessi limiti del Node (memoria, capability, mount di `vm-home`, viewer in loopback). Lo scenario `computer` lo ottiene da un `docker` finto e poi fa chiamare al finto `claude` lo strumento `ping` del server MCP `computer`.
- Nel motore Node un box viene montato solo per le esecuzioni cloud (`runOn: "cloud"`, cioè le routine): in un turno
  1:1 `wants` vale `vm` oppure `off`. Il driver boxAgent in chat diretta risponde quindi "no computer yet" in entrambi i
  motori; `prepareComputer(runOn:)` è pronto per le routine.

- Creare un bot (`POST /api/bots`) gli assegna la selezione predefinita *del momento* (un frame `bot` in più),
  non quella calcolata all'avvio: i motori disponibili cambiano. Trovato dallo scenario `rooms`.
- DeepSeek Harness: `reloadProviders` del motore Swift annunciava sempre un frame `config`; il Node lo fa solo per
  `PUT /api/config`. Ora `reloadProviders(announce:)`; il salvataggio delle impostazioni DSH non annuncia.
- Due `compare.sh` lanciati insieme scrivono nella stessa `$TMPDIR/swarme-parity`: per lavorare in parallelo serve un
  `TMPDIR` proprio, ma corto — il socket del broker dei permessi vive nella data dir e `sun_path` ha 104 byte.

- Regole del harness che dipendono dal driver, trovate con Grok API: i driver a replay del transcript (`grok`) non
  ricevono il preambolo "joining mid-thread"; `grok` e `boxAgent` non hanno cartella di lavoro né memoria nel prompt;
  un prompt di sistema vuoto non viene passato affatto.
- Il wire distingue "chiave assente" da `null`: Codex manda `tokens: null`, Pi omette `cost`. Il contratto Swift
  ora lo rappresenta (`itemUpdated(tokens: JSON?)`, `RuntimeEvent.costAbsent`).

- **Bug del motore Node trovato dalla parità**: `ensureGrokInjectSlug` scrive `~/.grok/config.toml` senza creare
  `~/.grok`; se la cartella manca l'invio fallisce senza alcun evento e il bot resta "working". Il motore Swift crea
  la cartella. Nella pratica chi ha Grok collegato ha già `~/.grok`; lo scenario la pre-crea per confrontare il resto.

- Team e avatar: `Object.assign` del Node scrive `null` come valore (`mascotAvatarImage: null`), e i client che fondono
  i frame `bot` ne hanno bisogno per togliere l'immagine; `Store.patchBot(keepingNulls:)` lo fa per i campi
  dell'avatar. `wireBot` del Node sposta `tasks` in fondo (`{...rest, tasks}`): dopo un patch il motore Swift lo lasciava
  prima dei campi nuovi. Le regex del validatore SVG sono JavaScript, non ICU: `/i` di ICU piega `ſcript` in `script`,
  il suo `\s` non ha `\v` né U+FEFF e il suo `\b` considera `é` una lettera; si piega a mano solo l'ASCII.

- **`dispatchMain()` parcheggia il thread principale**: la coda main gira su un worker, quindi
  `MainActor.assumeIsolated` dentro un blocco `DispatchQueue.main` va in trap e un `Timer` sul run loop
  principale non scatta mai (il keepalive SSE non partiva). Per tornare al main actor: un `AsyncStream`
  consumato da un solo `Task { @MainActor }` (mantiene l'ordine), timer con `Task.sleep`.
- **I segnali ignorati sopravvivono a `exec`.** Il motore ignora SIGTERM per chiudersi in modo pulito: senza
  `POSIX_SPAWN_SETSIGDEF` ogni CLI lanciato lo ereditava e l'interruzione di un turno non lo fermava. Trovato
  dalla parità (il turno "LENTO" arrivava in fondo).
- `return .none` in una funzione che restituisce `Continuity?` è `nil`, non `Continuity.none`: il probe Hermes
  non marcava mai un endpoint come "non Hermes". Il compilatore lo segnalava come warning.

- `JSON` è `ExpressibleByNilLiteral`: in un ternario `cond ? nil : value` il `nil` diventa
  `JSON.null` e la chiave viene *scritta* invece che rimossa. Usare `Optional<JSON>.none`.
  Scoperto dal test di parità (`queued: null` nel motore Swift).
- L'ordine dei frame conta: il motore Node passa il bot a "working" prima di fissare la cartella
  del task; invertirli cambiava la sequenza vista dai client.
- pi/omp chiude un turno fallito con `turn_end`/`agent_end` e `stopReason: "error"` (il motivo in
  `message.errorMessage`), senza testo: trattarlo come "end_turn" lasciava in chat una risposta vuota. Trovato
  su un server vero con un 403 di LiteLLM (2026-10-20); scenario `RIFIUTO` in `parity/fake_pi.py`.
- Divergenza voluta dal Node (2026-10-21): ogni esecuzione di routine apre la sua chat come chat attiva del bot,
  titolo `[AUTOMAZIONE] <nome>`. Il Node attivava solo i webhook: con le routine il risultato finiva in una chat
  nascosta nell'elenco e il pallino blu sul bot non bastava a trovarla. Lo scenario `automations` (non rieseguito:
  manca il checkout Node) dovrebbe divergere sul titolo della chat e sul `threadId` attivo del bot.

## Non verificato dal vivo

- Box reale (ascii.dev) e boxAgent: verificati contro `parity/fake_box.py`, non contro il provider (serve un token `box_`).
- VM locale, Cua Driver e una VPS: la parità usa `parity/fake_docker.py`. Non è stato provato un demone Docker, un'immagine Cua né una macchina SSH.
- `POST /api/local-computer/pull` scarica l'immagine base; il Node costruisce anche il Dockerfile derivato con le wheel verificate. Quel build non è alla pari.
