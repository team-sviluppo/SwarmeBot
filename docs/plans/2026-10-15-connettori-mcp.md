# Connettori (server MCP) — piano di implementazione

Stato: fasi 1 e 2 fatte (branch `feat/mcp-connectors`), vedi §12. Data: 2026-10-15.
Motore: solo Swift (`HarnessCore` / `HarnessDrivers`); il motore Node non riceve la funzione.

## 0. Obiettivo e decisioni prese

L'utente configura dei **connettori** (server MCP) una volta sola in SwarmeBot, li associa ai bot e li
accende o spegne per singola conversazione. Se cambia l'harness di un bot, i connettori restano
perché la configurazione, i segreti e il client MCP vivono in SwarmeBot.

| # | Decisione | Motivo |
|---|---|---|
| D1 | Trasporti **stdio** e **HTTP** (Streamable HTTP, poi SSE legacy) | gran parte dei server è stdio (`npx`/`uvx`); l'harness gira sul Mac |
| D2 | Autenticazione: header statici e variabili d'ambiente (fase 1), **OAuth 2.1** (fase 4) | l'OAuth è la parte più costosa e non serve per partire |
| D3 | Le harness CLI (Claude, Codex, ACP) montano un **proxy stdio di SwarmeBot** per ogni connettore: `swarme-harness mcp-connector <id>` | un solo OAuth, nessun segreto nei file di configurazione delle CLI, stdio garantito su ACP, pool e log centralizzati |
| D4 | **Local Endpoint**: SwarmeBot fa da client MCP e gestisce il loop dei tool OpenAI (`tools` / `tool_calls`) | funziona con qualsiasi endpoint OpenAI-compatible con function calling |
| D5 | **Hermes escluso automaticamente** dai tool lato client | verificato il 2026-10-15: Hermes ignora `tools` e usa i suoi tool lato server |
| D6 | Associazione per bot con **"attivo di default" per connettore**, interruttore per conversazione | il contesto pesa: i connettori pesanti partono spenti |
| D7 | Approvazione **sempre automatica** per i tool dei connettori | scelta dell'utente |
| D8 | Gruppi: ogni bot usa i propri connettori con i propri default; nessun interruttore di canale in v1 | scelta dell'utente |
| D9 | Companion iOS fuori perimetro | non serve più |
| D10 | Nome nel codice e nelle route: `mcp-connectors`, non `connectors` | `/api/connectors*` risponde già 501 per Composio (`Routes.swift:469-471`): niente ambiguità |

### Verifica Hermes (D5), 2026-10-15

`POST https://hermesagent.hextra.it/swarme/v1/chat/completions` (`default/dgx-default-strong`,
`stream:false`) con un tool finto `swarme_lookup_order` in `tools`: nessuna `tool_calls`,
`finish_reason: "stop"`. Il modello ha cercato il tool nel proprio catalogo lato server e ha risposto che
non esiste. `prompt_tokens: 36642` per una richiesta di una riga.
`GET /v1/capabilities` → **404**, quindi `probeHermes` non riconosce questo endpoint.
`GET /v1/models` → ogni modello ha `"owned_by": "hermes"`: è il segnale che useremo per singolo modello (§5.3).

## 1. Come si aggancia al codice esistente

Il motore monta già server MCP a ogni turno per due integrazioni (`agents`, `computer`); i connettori
seguono lo stesso percorso:

| Punto | Oggi | Con i connettori |
|---|---|---|
| `SendTurnInput` (`Contracts.swift:265`) | `agents: MCPServer?`, `computer: MCPServer?` | + `connectors: [MountedConnector]`, + `connectorGateway` per i driver in-process |
| `AdapterCapabilities` (`Contracts.swift:325`) | `agentsMcp`, `computerMcp`, … | + `connectors: ConnectorMount` (`.none` / `.mcp` / `.inline`) pubblicato in `/api/instances` |
| `Harness.startTurn` (`Harness.swift:~605-650`) | calcola `agents` e `computer` | + calcola l'insieme effettivo dei connettori (§4.3) |
| Claude (`Claude.swift:319-358`) | `--mcp-config` file 0600 + `--allowedTools` | + una voce per connettore, `mcp__<nome>` in `allowedTools` |
| Codex (`Codex.swift:620-631`, `mount`) | `-c mcp_servers.<nome>.*`, env per nome | + una chiamata `mount` per connettore |
| ACP (`ACPCore.swift:496-512`) | `mcpServers` in `session/new` / `session/load` | + `connector.server.acp(name:)` |
| Local Endpoint (`LocalEndpoint.swift`) | solo chat, nessun tool | loop dei tool in-process (§5) |
| Proxy (`swarme-harness/main.swift`) | `mcp-permission`, `mcp-agents`, `mcp-container`, `mcp-vps` | + `mcp-connector <id>` |
| Rotte interne (`Comms.swift:363`, `internalRoute`) | loopback + `commsToken` | + `/api/internal/mcp-connectors/*` |
| Segreti (`AppConfig.swift`, `SwarmeKit/Credentials.swift`) | Portachiavi + `secrets.json` 0600, chiavi fisse | + mappa dinamica di segreti per connettore |
| Override per conversazione (`Store.setTaskLibraryOff`, `PATCH /api/bots/:id/tasks/:tid`) | `libraryOff` | + `connectors` (override per connettore) |
| UI composer (`ComposerView.swift:105`, `LibraryChip`) | chip della libreria | + `ConnectorsChip` accanto |

Driver **esclusi in v1**: Pi, Antigravity, Grok, DeepSeek Harness, boxAgent (capability `.none`). Grok e
DeepSeek potranno riusare il loop in-process del Local Endpoint in una fase successiva (§9). boxAgent gira
su una macchina remota e non può raggiungere processi stdio sul Mac.

## 2. Modello dati

### 2.1 Connettore — `~/.swarmebot/mcp-connectors.json`

Come gli altri record del motore, è un oggetto JSON: i campi sconosciuti sopravvivono a ogni scrittura.

```json
{
  "id": "github",
  "name": "GitHub",
  "transport": "stdio",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-github"],
  "cwd": null,
  "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": { "secret": true } },
  "url": null,
  "headers": {},
  "auth": "none",
  "enabled": true,
  "tools": { "mode": "all", "names": [] },
  "toolTimeoutSeconds": 120,
  "lastCheck": { "at": "…", "ok": true, "tools": [{ "name": "create_issue", "description": "…", "readOnly": false }],
                 "schemaChars": 18234, "error": null },
  "createdAt": "…"
}
```

- `id`: slug `^[a-z][a-z0-9_]{1,23}$`, univoco, immutabile. È anche il nome di montaggio nelle CLI
  (`mcp__github__create_issue`): corto, perché Claude limita i nomi dei tool a 64 caratteri.
  **Riservati**: `agents`, `computer`, `ogb`, `swarme`, `import` (è una rotta).
- `transport`: `stdio` | `http`. Con `http`: `url` (https; http solo per loopback, `.local` e IPv4
  private 10/8, 172.16/12, 192.168/16) e `headers`.
- Valori di `env` e `headers`: stringa in chiaro **oppure** `{ "secret": true }`. Il valore vero sta nei
  segreti (§2.4) e l'API restituisce solo `{ "secret": true, "set": true|false }`.
- `auth`: `none` | `headers` | `oauth` (fase 4; con `oauth` si aggiunge un blocco `oauth` con issuer,
  client id e scope, mai i token).
- `tools.mode`: `all` | `allow` | `deny` con la lista `names`: il filtro dei tool vale per tutti i bot.
- `lastCheck`: risultato dell'ultimo "Prova connessione". `schemaChars` serve a stimare il costo in
  contesto (≈ caratteri/4 token) mostrato nella UI.

### 2.2 Associazione al bot — campo `connectors` nel record del bot

```json
"connectors": [ { "id": "github", "defaultOn": true }, { "id": "notion", "defaultOn": false } ]
```

Validata in `PUT /api/bots/:id` (`Routes.swift:~520-560`): id esistenti, niente duplicati, massimo 20.

### 2.3 Override per conversazione — campo `connectors` nel task

```json
"connectors": { "notion": true, "github": false }
```

Contiene solo le scelte diverse dal default; se una chiave manca vale `defaultOn`. Si imposta con
`PATCH /api/bots/:id/tasks/:threadId`, accanto a `libraryOff`, tramite un nuovo
`Store.setTaskConnectors`. Una mappa e non una lista di "spenti", perché un connettore con
`defaultOn: false` deve potersi **accendere**.

### 2.4 Segreti

**Deciso in fase 1 (deviazione dal piano iniziale):** i segreti dei connettori stanno in
`~/.swarmebot/mcp-connector-secrets.json` (0600), letto e scritto solo dal motore; l'app li manda una
volta sola, sul loopback, nel corpo di `POST`/`PUT` e non li rilegge mai.

- Perché non in `secrets.json`: sia l'app (`CredentialStore.environment`) sia il motore
  (`AppConfig.readSecrets`) lo leggono come `[String: String]` piatto e lo mettono nell'ambiente delle
  harness; una mappa annidata ne romperebbe la lettura intera, e chiavi piatte finirebbero nell'env.
- Perché niente copia nel Portachiavi per ora: il motore deve ritrovarli dopo un riavvio senza l'app
  (per questo esiste già `secrets.json`, con la stessa protezione 0600). Una copia nel Portachiavi si può
  aggiungere dopo senza cambiare formato.
- Formato: `{id: {env: {NOME: valore}, headers: {Nome: valore}}}`; eliminare un connettore elimina i
  suoi segreti; i token OAuth (fase 4) andranno qui (`oauth: {access, refresh, expiresAt}`).
- I valori non compaiono mai in `mcp-connectors.json`, nelle risposte API (solo `{secret, set}`) né nei
  log: lo stderr dei server passa da `Redact.text` e dalla sostituzione esplicita dei valori noti.

## 3. Client MCP nel motore

### 3.1 `MCPClient` (nuovo, `HarnessCore/MCPClient.swift`)

- JSON-RPC 2.0 con `initialize` (versione proposta `2025-06-18`, accetta `2025-03-26`), poi
  `notifications/initialized`, `tools/list` (paginato con `cursor`), `tools/call`, `ping` e
  `notifications/cancelled` per i turni interrotti.
- **stdio**: `CLIProcess` (gruppo di processi proprio, `killTree` chiude anche i figli di `npx`), PATH
  della shell di login (`EnvPath.swift`), `cwd` del connettore o la home, env = ambiente del motore
  **senza** le chiavi del workspace (`WorkspaceCredentials.strip`) né le variabili `OMB_*`/`OGB_*`, più i
  valori del connettore. Un messaggio JSON per riga. stderr va in
  `~/.swarmebot/logs/mcp/<id>.log` (1 MB, poi ruotato in `.1`): nella cartella dati del motore, così i
  test con `OMB_DATA_DIR` non scrivono in `~/Library/Logs`.
- **Streamable HTTP**: `POST` con `Accept: application/json, text/event-stream`; gestisce sia risposte
  JSON sia SSE e l'header `Mcp-Session-Id` (con nuovo `initialize` se il server risponde 404); invia
  `MCP-Protocol-Version` dopo l'`initialize`.
- **SSE legacy** (`GET` → evento `endpoint` → `POST`) nella fase 5: si prova solo se il `POST` risponde
  405/404 all'`initialize`.
- Timeout: `initialize` 30 s (stdio 60 s, perché `npx` a freddo è lento), `tools/call`
  `toolTimeoutSeconds` (default 120, massimo 900).

### 3.2 `MCPConnectorPool` (nuovo)

- Un client per connettore, condiviso da tutti i bot e i thread, avviato alla prima richiesta e
  chiuso dopo 10 minuti di inattività o all'arresto del motore.
- Tiene in cache la lista dei tool e la invalida su `notifications/tools/list_changed`, su modifica del
  connettore e alla riconnessione.
- Se il processo cade, lo riavvia **una volta** alla chiamata successiva. Se fallisce di nuovo, il tool
  restituisce un errore leggibile ("connettore GitHub non raggiungibile: …") e il turno continua.
- Applica il filtro `tools.mode` e restituisce le definizioni già filtrate.
- Rischio accettato in v1: un server stdio con stato (browser automation, sessioni) è condiviso tra turni
  concorrenti. Un'opzione `isolation: "perThread"` arriva nella fase 5 se serve.

### 3.3 `ConnectorGateway`

È la faccia che vedono i driver, legata a un turno: `bot`, `thread` e insieme effettivo **fotografato
all'inizio del turno**.

```swift
@MainActor public final class ConnectorGateway: Sendable {
    func tools() async -> [ConnectorTool]          // { connectorId, name, description, inputSchema, readOnly }
    func call(connectorId: String, tool: String, arguments: JSON) async -> ConnectorResult  // { ok, content: [JSON], text }
}
```

Lo usano sia il Local Endpoint (in-process) sia le rotte interne chiamate dal proxy.

## 4. Montaggio sulle harness CLI

### 4.1 Proxy `swarme-harness mcp-connector <id>` (nuovo `ConnectorProxy.swift`)

Segue lo schema di `AgentsProxy.swift`: stdout è il canale MCP e non ci si stampa nient'altro.

- L'id del connettore è in **argv**: non è un segreto, ed evita la collisione delle variabili d'ambiente
  quando Codex monta più connettori (`Codex.mount` mette i valori nell'env condiviso del figlio).
- Env condiviso, uguale per tutti i connettori del turno: `OMB_HARNESS_URL`, `OMB_COMMS_TOKEN`,
  `OMB_BOT_ID`, `OMB_THREAD_ID`.
- Risponde localmente a `initialize`, con `serverInfo.name` uguale al nome del connettore e le
  `instructions` del server reale se ce ne sono.
- `tools/list` → `GET /api/internal/mcp-connectors/<id>/tools?botId&threadId`.
- `tools/call` → `POST /api/internal/mcp-connectors/<id>/call`; la risposta MCP passa così com'è
  (`content`, `isError`, `structuredContent`).
- Il timeout HTTP verso il motore è uguale a `toolTimeoutSeconds` + 10 s.

Rotte interne (`Comms.internalRoute`, solo loopback + `commsToken`): verificano che il connettore sia
nell'insieme effettivo di **quel** bot e thread. Un bot non può chiamare un connettore che non gli è
stato dato, nemmeno conoscendone l'id.

### 4.2 Driver

- **Claude**: `mcpServers[id] = proxy.json`, `allowed.append("mcp__\(id)")` (D7: sempre automatico).
- **Codex**: `args += Codex.mount(&env, name: id, proxy)`; `default_tools_approval_mode="auto"` c'è già.
- **ACP**: `servers.append(proxy.acp(name: id))`. Se l'agente chiede il permesso con
  `session/request_permission` per un tool di un connettore, si risponde **allow** in automatico. Il tool
  si riconosce dal `toolCall` (titolo o `rawInput`, `mcp__<id>__…` o il formato dell'agente).
  **Da verificare agente per agente** con `fake_acp.py` e con gli agenti reali installati. Se un agente non
  permette di riconoscerlo, ripiego: la card di approvazione normale (documentato, non bloccante).
- Capability: `connectors = .mcp` su Claude, Codex e ACP, `.inline` su Local Endpoint, `.none` sugli altri.

### 4.3 Insieme effettivo (in `startTurn`)

```
effettivi = bot.connectors
            ∩ connettori con enabled == true
            filtrati per (task.connectors[id] ?? defaultOn)
            vuoto se instance.adapter.capabilities.connectors == .none
            per .inline: vuoto se il modello scelto non accetta tool lato client (§5.3)
```

Nei gruppi (D8) non c'è un task del bot, quindi valgono solo i `defaultOn`. Nei turni tra bot
(`ask_bot`, `delegate_bot`) il bot chiamato usa i propri connettori con i propri default.

**Regola anti-regressione**: se l'insieme è vuoto, nessun driver deve cambiare nulla (argv, file
`mcp.json`, `mcpServers`, corpo della richiesta). `parity/all.sh` deve restare identico.

### 4.4 Prompt di sistema

Non serve testo aggiuntivo: le CLI vedono i tool da MCP. Per il Local Endpoint le descrizioni vanno nel
campo `tools`. Al massimo una riga del tipo "Hai accesso ai connettori: GitHub, Notion" quando
l'insieme non è vuoto: da decidere guardando i test reali, non subito.

## 5. Local Endpoint: loop dei tool

### 5.1 Richiesta

- `tools`: per ogni tool del gateway,
  `{"type":"function","function":{"name": "<id>__<tool>","description","parameters": inputSchema}}`.
  I nomi vengono normalizzati a `^[a-zA-Z0-9_-]{1,64}$`; se si supera il limite, si tronca e si aggiunge
  un hash di 6 caratteri. Una tabella per il turno riporta ogni nome al connettore e al tool originali.
- `tool_choice` non si manda (vale il default `auto`). Nessun `parallel_tool_calls` esplicito.

### 5.2 Ciclo

1. Stream come oggi. In più si accumulano i `delta.tool_calls[]` **per `index`** (`id` e
   `function.name` arrivano nel primo frammento, `function.arguments` a pezzi).
2. Se `finish_reason == "tool_calls"` o ci sono chiamate accumulate:
   - si aggiunge `{"role":"assistant","content": <testo o null>,"tool_calls":[…]}`;
   - si eseguono le chiamate tramite il gateway, fino a 4 in parallelo; argomenti non validi in JSON →
     risultato d'errore al modello, senza chiamare il server;
   - per ogni chiamata si emette `itemStarted(itemType: "tool", title: "<Nome connettore> · <tool>")`
     e poi `toolCompleted(ok:)`, gli stessi eventi di Claude e Codex, così la UI li mostra già;
   - si aggiunge `{"role":"tool","tool_call_id": id,"content": testo}`;
   - nuovo giro.
3. Limite di **20 giri** per turno. Superato il limite si fa un ultimo giro **senza** `tools`, chiedendo
   di concludere, e si mostra un'attività di avviso.
4. Contenuto dei risultati MCP: gli elementi `text` vengono concatenati; `structuredContent`, se non c'è
   testo, diventa JSON compatto; `image` e `resource` diventano un segnaposto
   (`[immagine dal connettore omessa]`; le immagini nella fase 5). Massimo **40.000 caratteri** per
   risultato, con la nota "…troncato".
5. `isError` del server → `toolCompleted(ok:false)` e il testo d'errore va comunque al modello.
6. Uso dei token: somma su tutti i giri, un solo `tokenUsage` alla fine.
7. Interruzione: `cancel()` del task annulla la richiesta HTTP in corso e manda `notifications/cancelled`
   alle chiamate MCP aperte.
8. `textCompleted`: il testo di tutti i giri concatenato (come oggi: un messaggio del bot per turno).

### 5.3 Quando non mandare i tool (D5)

Per singolo modello, nell'ordine:

1. il modello in `/v1/models` ha `owned_by == "hermes"` → no. Serve che `LocalHosts.probe` conservi
   `owned_by` in `ModelOption`, come nuovo campo opzionale `clientTools: Bool?`;
2. `probeHermes` ha restituito `.session` (endpoint Hermes dichiarato) → no per tutti i modelli;
3. il modello è segnato `toolsUnsupported` (sotto) → no;
4. altrimenti sì.

Un **400** a una richiesta con `tools` fa ripetere il turno una volta senza `tools`. Il modello resta
segnato `toolsUnsupported` in memoria fino al riavvio o al prossimo `refreshModels`, e in chat compare
un'attività: "questo modello non supporta i tool: connettori disattivati".

La UI legge l'esclusione (capability e modello) e mostra il chip dei connettori disattivato con il motivo
("questo endpoint usa i suoi tool").

### 5.4 Continuità e cronologia

- I modelli Hermes non ricevono mai tool, quindi le regole sull'header di sessione restano intatte.
  Con un endpoint `.unknown` il loop rimanda comunque l'intero ramo, come oggi.
- **Tra un turno e l'altro** si rimanda solo il testo (`turn.transcript`, come oggi): le chiamate ai tool
  dei turni precedenti non vengono ripetute nel contesto. È una scelta: meno token. Il modello vede le
  conclusioni, non i risultati grezzi. Da rivedere se nei test reali si nota che il modello "dimentica"
  troppo.
- `NativeLog` registra richieste e risposte dei tool con i segreti oscurati.

## 6. API HTTP (da aggiungere a `docs/contract/http-sse.md`)

| Metodo e percorso | Uso |
|---|---|
| `GET /api/mcp-connectors` | elenco, segreti mascherati, con `lastCheck` |
| `POST /api/mcp-connectors` | crea (valida id, trasporto, URL, nomi riservati); `?secretStorage=external` come `PUT /api/config` |
| `PUT /api/mcp-connectors/:id` | modifica (i segreti omessi restano, `null` li cancella); invalida il pool |
| `DELETE /api/mcp-connectors/:id` | elimina, toglie l'id da tutti i bot e i task, cancella i segreti |
| `POST /api/mcp-connectors/:id/test` | connette, `tools/list`, aggiorna `lastCheck`, restituisce i tool e la stima in token |
| `POST /api/mcp-connectors/import` | accetta `{"mcpServers":{…}}` (formato di Claude Desktop e `.mcp.json`), crea i connettori; i valori di `env` e `headers` diventano segreti se il nome contiene KEY, TOKEN, SECRET, PASSWORD o AUTH |
| `PUT /api/bots/:id` | + campo `connectors` |
| `PATCH /api/bots/:id/tasks/:threadId` | + campo `connectors` (override) |
| `GET /api/instances` | `capabilities.connectors`; i modelli espongono `clientTools` |
| interne | `GET /api/internal/mcp-connectors/:id/tools`, `POST /api/internal/mcp-connectors/:id/call` |

SSE: una modifica ai connettori emette `{"kind":"mcpConnectors"}` e l'app ricarica l'elenco. Le modifiche
ai bot e ai task passano già dal frame `bot`.

## 7. Interfaccia (app SwiftUI)

1. **Impostazioni › Connettori** (nuova scheda in `SettingsView`):
   - elenco con stato (attivo, ultimo test, numero di tool, stima in token);
   - "Aggiungi": foglio con nome, id (suggerito dal nome), trasporto stdio/HTTP. Per stdio: comando,
     argomenti, righe di env con interruttore "segreto". Per HTTP: URL e righe di header con interruttore
     "segreto";
   - "Importa JSON": incolli `mcpServers` da Claude Desktop o `.mcp.json`;
   - "Prova connessione": elenco dei tool con le caselle per il filtro;
   - avviso visibile per stdio: "esegue `<comando>` sul tuo Mac con i tuoi permessi".
2. **Impostazioni del bot** (`BotSettings`): sezione "Connettori" con l'elenco globale, una casella
   "usa" e un interruttore "attivo di default". Nota se l'harness corrente del bot non li supporta.
3. **Composer**: `ConnectorsChip` accanto a `LibraryChip`. Popover con un interruttore per connettore
   (stato effettivo della conversazione), stima dei token degli attivi e "ripristina default". Chip
   disattivato, con il motivo, se harness o modello non li supportano.
4. Attività dei tool: già visualizzate dagli eventi `item.*`; il titolo mostra il nome del connettore.

## 8. Sicurezza

- Solo l'utente crea connettori: nessuna rotta interna, nessun tool di bot e nessun import di team li
  crea. Lo stdio è esecuzione di codice per definizione, quindi la UI mostra sempre comando e argomenti.
- Le rotte interne verificano bot, thread e insieme effettivo (§4.1).
- Nessun segreto in argv, nei file `mcp.json` delle CLI o nei log.
- **Approvazione automatica (D7)**: un risultato di un tool (pagina web, email, issue) può contenere
  istruzioni che spingono il modello a usare altri tool che scrivono. Rischio accettato. Le mitigazioni
  disponibili sono il filtro `deny` sui tool che scrivono e, in fase 5, una policy opzionale
  "solo lettura automatica" per connettore.
- Esportazione e import di team (`TeamManifest`, `TeamLibrary`): si esporta solo `connectors` del bot
  (id e default). All'import gli id mancanti vengono mostrati come "connettori da configurare" e non
  creati.

## 9. Fasi

Ogni fase si chiude con `swift build`, `swift test`, `parity/all.sh` verdi e un commit.

### Fase 1 — Archivio e client (nessun effetto sui turni)
- `MCPConnectors` (archivio, validazione, segreti, maschere), `MCPClient` (stdio + Streamable HTTP),
  `MCPConnectorPool`.
- Rotte `/api/mcp-connectors*` (CRUD, test, import), segreti dal Portachiavi in `Credentials`.
- UI Impostazioni › Connettori.
- **Fatto quando**: aggiungo `@modelcontextprotocol/server-everything` (stdio) e un server HTTP reale, la
  prova elenca i tool e i segreti non compaiono in `mcp-connectors.json`, in `config.json` o nei log.

### Fase 2 — Bot, conversazione e harness CLI
- Campi `connectors` su bot e task, insieme effettivo in `startTurn`, `ConnectorGateway`.
- `ConnectorProxy` + rotte interne, montaggio in Claude, Codex e ACP, capability `.mcp`.
- UI: sezione nelle impostazioni del bot, `ConnectorsChip`.
- **Fatto quando**: un bot Claude e uno Codex usano un tool di un connettore senza approvazione; spento
  nella chat, il connettore non compare nel turno successivo; con insieme vuoto `parity/all.sh` è identico.

### Fase 3 — Local Endpoint
- Loop dei tool (§5), esclusione di Hermes per modello, fallback sul 400, capability `.inline`.
- **Fatto quando**: con un modello non Hermes il bot chiama un tool, riceve il risultato e risponde; con
  `default/dgx-default-strong` su Hermes il chip è disattivato e la richiesta non contiene `tools`.

### Fase 4 — OAuth
- Scoperta (401 + `WWW-Authenticate` → `/.well-known/oauth-protected-resource` → metadati del server di
  autorizzazione), registrazione dinamica del client (RFC 7591) o client id manuale, PKCE, `resource`
  (RFC 8707).
- Login dall'app: il browser di sistema o `ASWebAuthenticationSession`, con callback sulla rotta di
  loopback del motore `/oauth/mcp/callback`.
- Refresh prima della scadenza e su 401, poi un nuovo tentativo. Stato "da ricollegare" nella UI se il
  refresh fallisce.

### Fase 5 — Facoltativa
- SSE legacy, isolamento `perThread`, immagini nei risultati verso i modelli che vedono immagini, policy
  "solo lettura automatica", loop in-process anche per Grok e DeepSeek.

## 10. Verifica

Il motore Node non ha questa funzione, e il suo checkout non è più sul disco: `parity/compare.sh` e
`parity/all.sh` non si possono eseguire. Al loro posto **`parity/swift-vs-ref.sh`** esegue gli stessi 27
scenari sul motore Swift di un worktree di riferimento (`git worktree add ../sb-main main`) e su quello
del branch, e confronta le tracce byte per byte: è la prova che con i connettori spenti i turni non
cambiano. Per il resto si verifica con:

- **`parity/fake_mcp.py`** (nuovo): server MCP finto, in modalità stdio e HTTP (risposte JSON e SSE,
  `Mcp-Session-Id`, paginazione di `tools/list`, `list_changed`). Tool: `echo`, `slow` (per
  l'interruzione), `fail` (`isError`), `big` (troncamento), `image`.
- **Test unitari** (`Tests/HarnessCoreTests/MCPConnectorsTests.swift`):
  - validazione: id riservati, URL, import JSON;
  - segreti mascherati e mai scritti;
  - matrice dell'insieme effettivo (bot × enabled × default × override × capability × modello);
  - rotte interne: un bot non autorizzato riceve 403.
- **Driver**:
  - `fake_claude.py` esteso, con un trigger che chiama `mcp__<id>__echo` tramite il vero proxy;
  - argv di Codex (`mcp_servers.<id>.*`, nessun segreto in argv);
  - `mcpServers` di ACP e permesso automatico in `fake_acp.py`.
- **Local Endpoint**: `fake_openai.py` esteso con:
  - `tool_calls` in streaming a frammenti, due chiamate in parallelo, catena di 3 giri, limite dei 20 giri;
  - 400 su `tools` → ripetizione del turno senza tool;
  - `owned_by: "hermes"` → richiesta senza `tools`.
- **Regressione**: `parity/all.sh` invariato (i turni senza connettori non cambiano).
- **Dal vivo**: `server-everything` stdio, un server HTTP reale con header e una chiamata reale a un
  modello non Hermes, più la richiesta su Hermes per controllare che non contenga `tools`.

## 11. Punti aperti (non bloccanti)

1. **Endpoint non Hermes per il test dal vivo della fase 3**: quale URL e modello (LiteLLM diretto verso un
   modello, vLLM, OpenAI)? Lo stesso `…/swarme/v1` espone oggi solo modelli `owned_by: hermes`.
2. **Agenti ACP reali**: il riconoscimento dei tool dei connettori in `session/request_permission` va
   verificato su ogni agente installato (§4.2).
3. **Riga nel prompt di sistema** sui connettori disponibili (§4.4): decidere dopo i primi test reali.
4. `docs/plans/prossima-sessione.md` elenca ancora il companion iOS come blocco del port: va aggiornato,
   visto che non serve più.

## 12. Avanzamento

### Fase 1 — fatta (2026-10-15)

- Motore: `MCPClient.swift` (stdio + Streamable HTTP, sessione rinnovata una volta su 404, risposte JSON
  e SSE, `ping`, `notifications/cancelled`, timeout), `MCPConnectors.swift` (archivio, validazione,
  segreti, import, pool con riavvio una tantum e chiusura dopo 10 minuti di inattività),
  `MCPConnectorRoutes.swift` (`/api/mcp-connectors*`, frame SSE `mcpConnectors`). Il pool si ferma in
  `Harness.shutdown`.
- App: `CompanionCore/MCPConnectors.swift` (modelli e chiamate), frame `mcpConnectors`,
  `AppModel.mcpConnectors` con le azioni, scheda Impostazioni › Connettori
  (`Views/ConnectorsSettings.swift`): elenco, editor stdio/HTTP con righe env/header segrete, filtro
  degli strumenti con stima dei token, prova connessione, import JSON.
- Test: `Tests/HarnessCoreTests/MCPConnectorsTests.swift` (9 test) con `parity/fake_mcp.py`
  (stdio e HTTP); `swift test` verde (97 + 112 + 12, 3 saltati come prima).
- Regressione: `parity/swift-vs-ref.sh` contro `main`, 27 scenari su 27 identici.
- Dal vivo, su un motore temporaneo (porta 18899, `OMB_DATA_DIR` temporanea):
  `npx -y @modelcontextprotocol/server-everything` → 13 strumenti in 6 s a freddo;
  `https://mcp.deepwiki.com/mcp` → 3 strumenti in 2 s. I segreti di prova compaiono solo in
  `mcp-connector-secrets.json`; nessun processo `npx` rimasto dopo la prova.
- **Non verificato**: la scheda Impostazioni › Connettori è compilata ma non provata a mano.

### Fase 2 — fatta (2026-10-15)

- Motore:
  - `ConnectorTurns.swift`: insieme effettivo (`Harness.activeConnectors`); grant per turno (token
    casuale nell'env dei proxy, revocato al `turn.completed` del thread, scartato dopo 24 h se il turno
    non si è mai chiuso); avvio anticipato dei server mentre la CLI parte; rotte interne
    `/api/internal/mcp-connectors/<id>/tools|call` (403 senza grant valido per quel connettore; un
    errore del server diventa `isError` per il modello, non un errore di protocollo);
  - `ConnectorProxy.swift` (`swarme-harness mcp-connector <id>`);
  - `startTurn` e i turni dei canali passano `SendTurnInput.connectors`; nei canali valgono i default
    di ogni bot (D8);
  - capability `connectors` in `/api/instances`: `mcp` su Claude, Codex e ACP, `none` sugli altri;
  - Claude: `mcp__<id>` in `--allowedTools`. Codex: `-c mcp_servers.<id>.*`, con
    `default_tools_approval_mode="auto"` già presente. ACP: `mcpServers`, più il permesso automatico
    quando `toolCall.title` (o `_meta.toolName`) nomina un connettore **di quel turno**
    (`mcp__<id>__`, `<id>__`, `<id>/`, `(<id> MCP Server)`);
  - `PATCH /api/bots/:id` accetta `connectors` (id esistenti, senza doppioni, massimo 20);
    `PATCH /api/bots/:id/tasks/:tid` accetta `connectors` come mappa id → bool;
  - `DELETE` di un connettore lo toglie da tutti i bot e i task (`Store.forgetConnector`).
- App: `Bot.connectors`, `BotTask.connectors`, `InstanceCapabilities.connectors`; card «Connettori» in
  Dettagli (usa / acceso nelle nuove chat, stima dei token); `ConnectorsChip` accanto alla libreria
  (interruttori della chat, «Ripristina predefiniti», token degli attivi). Finché l'elenco dei motori
  non è arrivato, la chip non afferma che il motore non supporta i connettori.
- Test:
  - `MCPConnectorsTests` sale a 12: matrice dell'insieme effettivo, grant (403, revoca),
    riconoscimento dei tool su ACP; `swift test` verde (100 + 112 + 12);
  - `parity/connectors_e2e.py`, sul motore vero con i CLI finti estesi (`CONNETTORE <id> <testo>` in
    `fake_claude.py`, `fake_codex.py`, `fake_acp.py`): Claude, Codex, ACP gemini e kimi chiamano `echo`
    attraverso proxy e pool; il segreto arriva al server; gli interruttori della chat cambiano il server
    montato; un connettore disattivato non viene mai montato; l'eliminazione pulisce bot e task.
- Regressione: `parity/swift-vs-ref.sh`, 27 scenari su 27 identici a `main`.
- UI vista dal vivo (bundle di sviluppo collegato a un motore temporaneo): la chip mostra `1/2` con un
  connettore acceso e uno spento di default. **Non viste**: il popover della chip e la card in Dettagli
  (lo snapshot fotografa solo la finestra com'è).
- **Rimandato**: esportare e importare i team con i connettori (§8). Oggi l'export dei team non porta
  `connectors`, quindi un team importato parte senza connettori, che è il comportamento sicuro.
- **Da verificare con gli agenti ACP reali**: il titolo con cui ciascun agente chiede il permesso per
  un tool MCP (§11.2). Se non viene riconosciuto, compare la normale card di approvazione.
