# Contratto HTTP + SSE tra UI e harness (congelato)

> Fase 0 del piano `SwarmeBot/docs/plans/2026-10-13-swift-native-macos-analisi.md`.
> Fonte di verità: `SwarmeBot/server/index.ts` @ `1cd755d` (router scritto a mano), `server/store.ts`,
> `server/contracts.ts`, `server/config.ts`, `server/routines.ts`, `server/webhooks.ts`, `harness/registry.ts`.
> Incrociato con il client React (`src/state/store.tsx`, componenti) e con `ios/Sources/CompanionCore`
> (`Client.swift`, `Models.swift`, `Frames.swift`, `SSE.swift`).
>
> Legenda colonne: **React** = chiamata dal client React attuale; **CC** = CompanionCore (`Client.swift`):
> ✅ implementato, ❌ mancante, ◐ implementato parzialmente (campi mancanti). **FP** = fuori perimetro
> (voce/TTS e Composio/connectors vengono abbandonati nella versione nativa).

---

## 1. Trasporto

### 1.1 Indirizzo e porta

- Il server ascolta **solo su `127.0.0.1`** (IPv4, `server.listen(PORT, "127.0.0.1")`). Usare `127.0.0.1`, non `localhost`
  (che può risolvere prima a `::1`, dove nessuno ascolta).
- `PORT = Number(OMB_PORT || OGB_PORT || 8799)`.
- L'app Electron pacchettizzata prova in ordine **8799 → 18799 → 28799** (due passate, 2,5 s di attesa tra le passate),
  e per ogni porta fa polling su `GET /api/health` (40 tentativi × 500 ms).
- Secondo listener, separato, per i **webhook in ingresso**: `WEBHOOK_PORT = OMB_WEBHOOK_PORT || PORT + 1`
  (quindi 8800/18800/28800). Espone solo `GET /health` → `{app:"swarmebot-webhooks", ready:true}` e
  `POST /hooks/:endpointId[/:secret]` (`endpointId` = `wh_[A-Za-z0-9_-]+`; secret nel path o come bearer) →
  202 `{accepted:true, runId?, deliveryId, duplicate, captured?, ignored?}`. Non è API della UI.
- Il sidecar companion (iOS) sta su **8810** e fa da proxy con allowlist (`companion/src/routes.ts`) + bearer di
  dispositivo. CompanionCore oggi parla **col sidecar, non con l'harness**: `POST /api/pair` esiste solo lì.
  Un client macOS nativo parlerà direttamente con l'harness su loopback, senza bearer.

### 1.2 Variabili d'ambiente lette dall'harness al boot

| Var | Uso | Chi la imposta oggi |
|---|---|---|
| `OMB_PORT` (legacy `OGB_PORT`) | porta HTTP principale | Electron (`startServerOn`) |
| `OMB_WEBHOOK_PORT` | porta ingress webhook (default `PORT+1`) | — |
| `OMB_STATIC_DIR` | se presente, l'harness serve anche la UI buildata (SPA fallback su `index.html`); `/api/health.static` diventa `true` | Electron → `resources/ui` |
| `OMB_RESOURCES_PATH` | risorse pacchettizzate (es. `android-platform-tools` per il phone proxy) | Electron |
| `OMB_SKILLS_DIR` | root delle skill bundle (`<dir>/<name>/{manifest.json,SKILL.md}`); default `cwd/skills` | Electron → `resources/skills` |
| `OMB_USER_DATA` | userData dell'app (usato da `local-computer.ts`) | Electron → `app.getPath("userData")` |
| `OMB_DATA_DIR` | data dir (default `~/.swarmebot`; migra da `~/.openmausbot`/`~/.opengrokbot`). Contiene `config.json`, `bots.json`, `groups.json`, `events/`, `native/` | test/soak |
| `OMB_TURN_STALL_MS` | watchdog di stallo turno (min 60 s, default 20 min) | — |
| `OMB_EXTRA_PATH` | PATH aggiuntivo per trovare le CLI | — |
| `OMB_ADB_PATH`, `PH_ANDROID_SERIAL` | phone proxy | — |
| `OMB_BOX_API`, `OMB_COMPOSIO_API`, `OMB_COMPOSIO_BROKER_URL`, `OMB_COMPOSIO_BROKER_TOKEN`, `OMB_COMPOSIO_TOOLKITS_API`, `OMB_ELEVENLABS_API`, `DWEB_URL` | override endpoint esterni | Electron (broker Composio) |
| **Credenziali** (vincono su `config.json`): `XAI_API_KEY`, `COMPOSIO_API_KEY`, `BOX_TOKEN`, `OPENCODE_API_KEY`, `LOCAL_ENDPOINT_AUTH_KEY`, `OMB_TTS_KEY` | `loadConfig()` sovrascrive il valore del file con l'env; `syncCredentialEnv` tiene l'env allineato dopo ogni save | Electron (`workspaceCredentialEnv`, store cifrato OS) |
| `LOCAL_ENDPOINT_BASE_URL` | scritto dall'harness stesso (`syncEndpointEnv`) per i driver | harness |

Variabili che l'harness **passa** ai processi figli (non lette al boot): `OMB_HARNESS_URL`, `OMB_BOT_ID`,
`OMB_THREAD_ID`, `OMB_COMMS_TOKEN`, `OMB_TURN_DEPTH`, `OMB_CONTROL_URL`, `OMB_CONTROL_TOKEN`, `ELECTRON_RUN_AS_NODE=1`
(il proxy agents/phone gira come `process.execPath` + `ELECTRON_RUN_AS_NODE`: un host Swift dovrà fornire un `node`).

### 1.3 Gate di sicurezza

1. **Host loopback** obbligatorio su ogni richiesta: header `Host` deve essere `localhost[.]`, `127.x.x.x`, `[::1]`
   (con porta numerica opzionale), altrimenti **403** `{error:"forbidden: loopback host required"}` (anti DNS-rebinding).
2. **Origin**: se presente deve essere `http(s)://` su host loopback, altrimenti **403** `{error:"forbidden: cross-origin request"}`.
   Senza `Origin` (URLSession, curl) passa. Nessun header CORS emesso.
3. **Content-Type JSON obbligatorio (415)** sulle mutazioni "pericolose": `POST /api/local-computer/*`,
   `POST /api/cli-test`, `PATCH /api/instances/:id`, scritture `deepseek-harness`, `POST /api/bots/:id/computer/control`,
   `POST /api/bots/:id/computer/{provision|join|sleep|exec|screenshot|remove}`. Va mandato
   `Content-Type: application/json` **anche senza body**.
4. **Route interne** `/api/internal/*`: `Authorization: Bearer <COMMS_TOKEN>` (24 byte random hex rigenerati a ogni
   boot, confronto constant-time) → altrimenti **401** `{error:"unauthorized"}`. Il token è passato solo ai proxy figli.
   La UI non le chiama mai.
5. Body JSON: max 1 000 000 byte (413 `body too large`), JSON invalido → 400. Body raw (immagini) con limiti propri.

### 1.4 Convenzioni di risposta

- Errori: sempre JSON `{error: string}` (messaggi pensati per l'utente). DeepSeek Harness: `{code, error}`.
- Route sconosciuta: 404 `{error:"no route: <METHOD> <path>"}`.
- Comandi asincroni (avvio turno) rispondono **202**; lo stato arriva via SSE.
- `GET /api/health` → `200 {app:"swarmebot", pid:<process.pid>, static:<Boolean(OMB_STATIC_DIR)>}`.
  Electron considera il figlio "suo" solo se `app==="swarmebot" && pid===proc.pid && static`; se la porta risponde
  ma il pid non coincide passa alla porta successiva. Un host Swift deve replicare il check (senza `static` se non
  serve la UI web).

---

## 2. Tabella delle route

Path param: `:id`/`:botId`, `:gid` (room), `:tid` (threadId), `:mid` (messageId) = `[\w-]+`.
Shape ricorrenti: **WireBot** = `BotRecord` senza `resumeCursors`, con `tasks[]` = `TaskRecord` senza
`resumeCursors`/`lastInstanceId`. **PublicBot** = WireBot + `messages[]` + `activeLeafId` + `tasks[]`.
**WireGroup** = `GroupRecord` senza `memberResumeCursors`. Vedi §4.

### 2.1 Bot

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| GET | `/api/bots` | query `messages=n` (0..200, opzionale) | `{bots: PublicBot[] (+hasMore se paginato), groups: (WireGroup+messages[]+hasMore?)[], computerControl: {[botId]: {held, helpReason}}}`. Senza `messages` = transcript completo; con `messages` = ultimi n, i `screen` ridotti a `{…,hasImage:true}` senza `png/mime` | ✅ (senza query) | ✅ (`fleet(messages:50)`, ignora `computerControl`) |
| POST | `/api/bots` | — | 201 `{bot: WireBot+messages+activeLeafId}` (nome/colore/greeting scelti dal server, modelSelection = default) | ✅ | ✅ |
| PATCH | `/api/bots/:id` | uno o più tra: `name`(≤100, non vuoto) `title`(≤200) `description`(≤8000) `notifications` `modelSelection{instanceId,model,effort?}` `unread` `computer`(**solo `"vm"`/`"off"`**) `cloudBackend`(`box`/`vps`, 409 se bot busy/VPS attivo) `color` `mascotExpression` `mascotSilhouette` `pinned` `hidden`(400 se chief of staff) `speakReplies` `voice` `mascotAvatarSvg`(solo null/"" per cancellare) `mascotAvatarImage`(solo clear) `mascotAvatarSheetRow`(0–8\|null) `pinnedMessageId`(id\|null\|"") `section`(≤60\|null) `composio`(bool) `chiefOfStaff`(bool) `cwd`(validato) `autoApprove`(bool) `codeMode`(bool) `approvePeerComms`(bool) `alwaysAllow`(string[], dedup, max 200). `effort` validato contro `effortLevelsForModel` dell'istanza (400) | `{bot: WireBot}` (+ frame `bot` via store) | ✅ | ❌ |
| DELETE | `/api/bots/:id` | — | `{ok:true}` (interrompe turno, disabilita routine/webhook del bot, cancella log eventi) | ✅ | ❌ |
| POST | `/api/bots/:id/read` | — | `{bot: WireBot}` + frame `bot` | ❌ (usa PATCH `unread:false`) | ✅ |
| POST | `/api/bots/:id/avatar/upload` | **body raw**: `image/svg+xml` (validato, max `MAX_AVATAR_SVG_BYTES`) oppure immagine raster (max `AVATAR_IMAGE_MAX_BYTES`; sprite sheet 9×8 riconosciuto → `mascotAvatarSheetRow:0`) | `{bot: WireBot}` | ✅ | ❌ |
| POST | `/api/bots/:id/always-allow` | `{allowKey}` (deve stare su una card pending del bot, altrimenti 409) | `{bot}` + frame `bot` | ✅ | ✅ |
| GET | `/api/bots/:id/memory` | — | `{text, truncated, topics:[{name, bytes}]}` | ✅ | ❌ |
| PUT | `/api/bots/:id/memory` | `{text}` (cap `MEMORY_FILE_MAX_BYTES`) | `{ok:true, truncated}` | ✅ | ❌ |
| GET | `/api/bots/:id/memory/topics/:name` | name percent-encoded, singolo segmento `.md` | `{name, text}` | ✅ | ❌ |

#### Code mode (Swift desktop)

- `GET /api/threads/:tid/git`: `{repo, folder?, root?, branch?, detached?, changes:[{path,name,status,bytes}]}`. `folder` è la cartella effettiva del task anche fuori da un repository.
- `GET /api/threads/:tid/git/branches`: `{branches:[{ref,name,remote}]}`; branch locali e riferimenti remoti già presenti, esclusi gli alias simbolici come `origin/HEAD`.
- `POST /api/threads/:tid/git/checkout`: `{ref}` completo restituito dall'elenco; risponde con lo stato Git aggiornato. I branch remoti riusano un branch locale che li traccia oppure ne creano uno con tracking. Nessun force/reset/stash; conflitti con modifiche locali e bot al lavoro nello stesso repository restituiscono 409.

In Code mode il chip del branch apre un selettore ricercabile. Accanto, **Apri terminale / Open terminal** apre una shell nella cartella effettiva del task; i motori remoti richiedono un'identità SSH configurata su questo Mac.

### 2.2 Room (groups)

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| POST | `/api/groups` | `{memberIds: string[] (≥1 bot esistente), name?, cwd?}` (`cwd`: cartella assoluta esistente, altrimenti 400; diventa la cartella di lavoro di tutti i membri) | 201 `{group: WireGroup + messages:[]}` | ✅ | ✅ |
| PATCH | `/api/groups/:gid` | `name` `bulletin` `unread` `memberIds[]` `defaultResponder{kind:"everyone"\|"mentions"\|"member", botId?}` (400 se invalido) `cwd` (400 se `dm`, 409 se `pinnedCwd` già fissato) `pinnedMessageId` | `{group: WireGroup}` | ✅ | ❌ |
| DELETE | `/api/groups/:gid` | — | `{ok:true}` | ✅ | ❌ |
| POST | `/api/groups/:gid/read` | — | `{group}` + frame `group` | ❌ (usa PATCH) | ✅ |
| POST | `/api/groups/:gid/messages` | `{text}` | 202 `{ok:true}` (turno di room asincrono, sequenziale per membro) | ✅ | ✅ |
| POST | `/api/groups/:gid/interrupt` | — | `{ok:true}` (chiude le approval aperte) | ✅ | ❌ |

#### Canali misti (solo Swift, `HarnessCore/MixedRooms.swift`)

Un canale vive su un host (un motore, o il telefono); i membri di altri motori sono **ospiti**. Per il turno di un
ospite l'host chiama il motore dell'ospite, che tiene una **stanza specchio** del canale.

| Metodo | Path | Request | Risposta |
|---|---|---|---|
| PUT | `/api/peer-engines` | `{name?, engines: [{id, name, url, token}]}`: sostituisce l'elenco (`url` = chat URL del motore). Solo in memoria. **Solo locale** (501 da remoto) | `{engines: [{id, name}]}`; 400 se manca id/url/token |
| GET | `/api/peer-engines` | — | `{engines: [{id, name}]}` (mai i token) |
| POST | `/api/guest-turns` | `{conversationId (1..128, [\w:.-]), name, botId, roster: string[], userName?, hostName?, messages: [{id, role:"user"\|"bot", name, color?, text, ref?}] (ultimi 60)}` | sincrono, a turno finito: 200 `{text, messageId}`; 409 `{busy:true, error}` se il bot o lo specchio sono occupati; 404 bot assente; 502 con il chip d'errore se il bot non ha risposto |
| POST | `/api/guest-turns/interrupt` | `{conversationId}` | `{ok:true}`; 404 se lo specchio non c'è |

- `POST /api/groups` accetta `guests: [{peerId, botId, name, color?, title?}]`: sono tenuti solo i `peerId` presenti in
  `/api/peer-engines`. `memberIds` può essere vuoto se ci sono ospiti. `PATCH` accetta `guests` (lista intera; `[]` li
  toglie; 400 su uno specchio).
- Un ospite è il membro `peer:<peerId>:<botId>`: vale in `defaultResponder.botId`, `busyBotId` e `from.botId` dei
  suoi messaggi (`from: {botId, name, color}`, più `guestRef` = `messageId` dell'ospite).
- **Specchio** (sul motore dell'ospite): una room con `guest: {conversationId, deviceId, hostName?, userName?,
  roster}`, una per dispositivo chiamante e `conversationId`.
  - Copia i messaggi dell'host una volta sola (`hostId` sui messaggi copiati; `ref` evita di ricopiare le risposte
    dell'ospite).
  - Non diventa mai `unread` e non fa catene di menzioni (le fa l'host).
  - `POST /api/groups/:gid/messages` risponde 409 ("this channel is written from where it lives").
- Ogni membro lavora nelle cartelle del proprio motore: `cwd` della room vale solo per i bot dell'host.

### 2.3 Thread e messaggi

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| POST | `/api/bots/:id/messages` | `{text}` | 202 `{ok:true}`; se il bot è busy: 202 `{ok:true, queued:true, messageId}` (messaggio con `queued:true`, inviato al settle) | ✅ | ✅ |
| POST | `/api/bots/:id/notes` | `{text}` (1..500) | 201 `{message}`: una riga `kind:"activity"` con solo `text`, scritta nella chat del bot senza avviare un turno; 400 se vuoto/troppo lungo, 404 se il bot non esiste. La usa il Mac quando un messaggio con `@altro-bot` passa la chat a quel bot | — (solo Swift) | ❌ |
| POST | `/api/bots/:id/messages/:mid/edit` | `{text}` | 202 `{ok:true}` (fork del thread + nuovo turno; 409 se busy o istanza assente; 404 se non è un messaggio utente `text`) | ✅ | ✅ |
| POST | `/api/bots/:id/active-branch` | `{messageId}` | `{activeLeafId}` (409 se busy) | ✅ | ✅ |
| PATCH | `/api/bots/:id/cards/:mid` | `{answered?, dismissed?}` | `{message}` | ✅ | ❌ |
| POST | `/api/bots/:id/respond` | `{requestId, behavior:"allow"\|"deny"\|"answer", message?, selected?:string[], custom?:string}` | `{ok:true, outcome}`; 409 `{ok:false, outcome:"retryable", error}` | ✅ | ❌ (CC usa la variante per thread) |
| POST | `/api/threads/:tid/respond` | come sopra (vale anche per room) | come sopra; 404 se nulla in attesa | ✅ | ◐ (manca `selected`, `custom`) |
| POST | `/api/bots/:id/interrupt` | — | `{ok:true}` (se c'è una routine run attiva la cancella; interrompe anche la room dove il bot parla) | ✅ | ✅ |
| GET | `/api/threads/:tid/messages` | `limit` (default 50, max 200), `before=<mid>` **o** `around=<mid>` | `{messages (slim), hasMore}`; 404 se `before`/`around` non esiste | ❌ | ✅ |
| GET | `/api/threads/:tid/messages/:mid/image` | — | bytes `image/png\|jpeg`, `cache-control: immutable` | ❌ | ✅ |
| POST | `/api/threads/:tid/messages/:mid/reactions` | `{emoji (≤8 char), by?: "user"\|botId}` | `{message}` (toggle) | ✅ | ✅ |
| GET | `/api/threads/:tid/events` | `limit` (>0; default 300, max 2000) | `{entries: ({kind:"runtime",at,data:RuntimeEvent}\|{kind:"native",at,data:{at,dir:"in"\|"out",source,msg}})[], total:{runtime,native}}` (Inspector) | ✅ | ❌ |
| POST | `/api/attachments` | **body raw** immagine, `Content-Type: image/*` (max `IMAGE_MAX_BYTES`) | 201 `{path, mime, bytes}` (il path finisce nel prompt come `<attached-image path="…"/>`) | ✅ | ❌ |
| GET | `/api/attachments/:name` | — | bytes, `nosniff`, immutable | ✅ | ❌ |
| POST | `/api/threads/:tid/files` | `{paths: string[]}` (max 20: link, percorsi assoluti, `~/…`, `file://…` o relativi alla cartella della chat) | `{files: {ref, path, name, bytes}[]}`, solo i file regolari che esistono; 404 se il thread non è di un bot né di una room. Da un client remoto solo i file dentro le cartelle della chat (task, bot, room, workspace dei membri; symlink risolti) o nominati da uno strumento di quella chat | — (solo Swift) | ❌ |
| GET | `/api/threads/:tid/files/content` | `path` (come sopra) | bytes `application/octet-stream`, `nosniff`, `no-store`; 404 se non raggiungibile, 413 oltre 50 MB | — (solo Swift) | ❌ |
| GET | `/api/threads/:tid/git` | — | `{repo:false}` se la cartella della chat (la prima tra task, bot, workspace) non è in un work tree git; altrimenti `{repo:true, root, branch, detached, changes: {path, name, status, bytes}[]}` con `status` `M`/`A`/`D`/`R`/`?` (file con modifiche non committate sotto la cartella, max 200, `path` assoluto). `branch` è lo short sha se `detached`. Sola lettura (`GIT_OPTIONAL_LOCKS=0`). 404 se il thread non è di un bot né di una room | — (solo Swift) | ❌ |

### 2.4 Task (contesti separati di un bot)

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| POST | `/api/bots/:id/tasks` | `{title?}` | 201 `{bot: PublicBot, task}` + frame `bot` (409 se busy) | ✅ | ✅ |
| POST | `/api/bots/:id/tasks/:tid` | — (switch) | `{bot: PublicBot}` + frame `bot` | ✅ | ✅ |
| PATCH | `/api/bots/:id/tasks/:tid` | `{pinned?: bool, title?}` | `{bot: PublicBot, task}` | ✅ | ◐ (solo `title`) |
| DELETE | `/api/bots/:id/tasks/:tid` | — | `{bot: PublicBot}` (409 se running o pinned; 400 se ultimo task) | ✅ | ✅ |

### 2.5 Istanze, modelli, CLI

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| GET | `/api/instances` | — (riscansiona PATH) | `{instances: InstanceDescription[]}` (§4.4) | ✅ | ◐ (decodifica solo `instanceId, driverKind, displayName, snapshot{state,reason,authenticated,version}, models{default, options[{id,label}]}`) |
| PATCH | `/api/instances/:id` | JSON obbligatorio. `{cli?: string ("" = default driver), pickerVisible?: bool\|null}` (almeno uno). `cli` ricarica i provider (uccide i turni in volo), `pickerVisible` no | `{instances}`; 404 istanza ignota; 409 se un'altra update è in corso | ✅ | ❌ |
| GET | `/api/cli-candidates` | `name=<binario>` | `{candidates: string[]}` (path assoluti in ordine di PATH) | ✅ | ❌ |
| POST | `/api/cli-test` | JSON obbligatorio. `{cli, driver?}` | `{ok, version?, message?, install?}` | ✅ | ❌ |
| GET | `/api/instances/:id/deepseek-harness` | — | `{connection:{instanceId, transport:"direct"\|"paired", baseUrl, paired, hasDeviceCredential, agentPreset?}, modelManagement}` | ✅ | ❌ |
| PATCH | `/api/instances/:id/deepseek-harness` | `{baseUrl?, transport?, agentPreset?\|null}` | `{saved, connection}` | ✅ | ❌ |
| POST | `/api/instances/:id/deepseek-harness/pair` | `{pairingLink}` | `{paired:true}` | ✅ | ❌ |
| POST | `/api/instances/:id/deepseek-harness/discover` | `{provider}` | candidati modello | ✅ | ❌ |
| POST | `/api/instances/:id/deepseek-harness/upsert` | `{provider, model:{…contextWindow?, maxTokens?}}` | risultato upsert (+refresh catalogo) | ✅ | ❌ |

La **selezione del modello per bot** non ha una route dedicata: si fa con `PATCH /api/bots/:id {modelSelection:{instanceId, model, effort?}}`.

### 2.6 Config / impostazioni app

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| GET | `/api/config` | — | `ConfigStatus` (§4.5; mai segreti, solo booleani) | ✅ | ◐ (solo `composio`, `box`, `tts`, `profile`) |
| PUT / PATCH | `/api/config` | `ConfigPatch`: `xai{key,url}` `composio{apiKey,userId,sessionId}` `box{token}` `vps{sshAlias}` `opencodeGo{apiKey}` `localEndpoint{apiKey,baseUrl}` `tts{key,voice}` `profile{name,email}` `rooms{turnTimeoutMinutes:1..1440}` (zod; `instances`/`pickerVisibility` NON ammessi). Query `secretStorage=external`: le credenziali in `EXTERNAL_SECRET_FIELDS` non vengono scritte su `config.json` (le tiene il chiamante cifrate) ma solo nell'env del processo | `ConfigStatus` + frame `config`. 400 "nothing to save"/validazione; 400 se box token o chiave Composio/TTS rifiutati dal provider; 409 se busy o cambio alias VPS con turni VPS attivi. Ricarica la flotta salvo patch solo di `profile/tts/vps/rooms` | ✅ | ❌ |

### 2.7 Routine

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| GET | `/api/routines` | `from?`, `to?` (epoch ms, filtro runs) | `{routines: Routine[], runs: RoutineRun[]}` | ✅ | ❌ |
| POST | `/api/routines` | `RoutineInput {name, prompt, botId, runOn?:"maus"\|"cloud", enabled?, schedule:{type:"once",at}\|{type:"daily",time:"HH:MM",weekdays:number[]}\|{type:"interval",every:number,unit:"minutes"\|"hours"\|"days"}, durationMinutes?}` (`interval` is Swift-only, added after the Node engine: 5 min – 7 days, integer `every`, `unit` defaults to `minutes`) | 201 `{routine}` + frame `routine` | ✅ | ❌ |
| PATCH | `/api/routines/:id` | `Partial<RoutineInput>` | `{routine}` / 404 | ✅ | ❌ |
| DELETE | `/api/routines/:id` | — | `{ok:true}` + frame `routine.deleted` | ✅ | ❌ |
| POST | `/api/routines/:id/run` | — | 201 `{run}` | ✅ | ❌ |
| POST | `/api/routine-runs/:runId/cancel` | — | `{run}` / 404 | ✅ | ❌ |
| POST | `/api/routine-runs/:runId/seen` | — | `{run}` / 404 | ✅ | ❌ |

Ogni esecuzione (pianificata, "Esegui ora" o webhook) crea una chat intitolata `[AUTOMAZIONE] <nome>` e la rende la chat attiva del bot (frame `bot` con il nuovo `threadId`); a fine turno il bot resta `unread`. Il Node attivava solo le chat dei webhook e usava il nome nudo.

### 2.8 Webhook (gestione)

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| GET | `/api/webhooks` | — | `{webhooks: WebhookTrigger[], attempts: WebhookAttempt[], ingress:{available, baseUrl, error?}}` | ✅ | ❌ |
| POST | `/api/webhooks` | `WebhookTriggerInput {name, prompt, botId, runOn?, enabled?, verificationPending?, eventTypes?: string[]}` | 201 `{webhook, ingress, credential:{endpointUrl, secret, url}}` (il secret si vede solo qui e su rotate) | ✅ | ❌ |
| PATCH | `/api/webhooks/:id` | campi di `WebhookTriggerInput` | `{webhook}` | ✅ | ❌ |
| DELETE | `/api/webhooks/:id` | — | `{ok:true}` | ✅ | ❌ |
| POST | `/api/webhooks/:id/rotate` | — | `{webhook, ingress, credential}` | ✅ | ❌ |
| POST | `/api/webhooks/:id/test` | payload JSON arbitrario (default `{event:"swarme.test", message:"Test webhook delivery"}`) | 202 `{runId?, deliveryId, duplicate, captured?, ignored?}` | ❌ | ❌ |

### 2.9 Team library / import-export

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| POST | `/api/teams/export` | `{name?}` | `TeamManifestV2 {format, version, team:{name, description?, members:[{key,name,title,description,appearance:{color,mascotExpression?,mascotSilhouette?,mascotAvatarSvg?}}]}}` | ✅ | ❌ |
| POST | `/api/teams/import` | query `mode=add\|replace\|project`, `cwd?` e `room?` (solo `project`); body = manifest | 201 `{bots: PublicBot[], archivedBots, archived:[{id,chiefOfStaff}], group?}` | ✅ | ❌ |
| GET | `/api/team-library/catalog` | — | `{format:"swarme.catalog", version:1, repositoryUrl, teams:[{slug,name,summary,category,manifest,readme,members,skills[],requires:{apps[]}}]}` (502 se irraggiungibile) | ❌ | ❌ |
| GET | `/api/team-library/teams/:slug` | — | manifest | ❌ | ❌ |
| POST | `/api/team-library/github` | `{url}` | manifest | ✅ | ❌ |

### 2.10 Skill

**Nessuna route HTTP.** Le skill bundle sono caricate al boot da `OMB_SKILLS_DIR` (`loadBundledSkills`) e
selezionate per turno lato server (`selectBundledSkills(text, capabilities)`), iniettate nel system prompt;
`phoneMcp` attiva l'integrazione phone. Per il client nativo l'unico contratto è la variabile d'ambiente.

**Solo Swift (2026-10-21): skill universali** (`docs/plans/2026-10-21-skill.md`), una cosa diversa dalle
skill bundle di Node.

| Metodo | Path | Request | Risposta |
|---|---|---|---|
| GET | `/api/skills` | — | `{skills: [Skill]}` |
| POST | `/api/skills` | `{files: [{path, content (base64), executable?}], replace?}` | 201 `{skill}`; 409 se esiste senza `replace`; 413 oltre 8 MB |
| GET | `/api/skills/:name` | — | `{skill, content}` (testo di `SKILL.md`) |
| PUT | `/api/skills/:name` | `{content}` | `{skill}` (riscrive solo `SKILL.md`, il `name` non cambia) |
| DELETE | `/api/skills/:name` | — | `{ok: true}`; la toglie da `bot.skills` e `task.skills` |
| GET | `/api/skills-folder` | — | `{folder, defaultFolder, custom}` |
| PUT | `/api/skills-folder` | `{folder: string\|null}` | come GET (null torna al default) |

`Skill` = `{id, name, description, files: [path], bytes, tokens, hasScripts, updatedAt}`. Sul bot:
`PATCH /api/bots/:id` con `skills: [{id, defaultOn}]`; sulla chat: `PATCH /api/bots/:id/tasks/:tid` con
`skills: {name: bool}` (solo le differenze dal default del bot). Ogni modifica manda il frame `skills`.

**Solo Swift (2026-10-25): vault dei secret** (`docs/plans/2026-10-25-vault.md`). Nessuna risposta
contiene mai un valore. Su un motore remoto (richiesta con device token) le scritture rispondono 403
`the vault of a remote engine is changed from the Mac that administers it`: lì il vault si scrive via ssh
con `swarme-harness vault set|unset|grant|list` (dati in JSON su stdin).

| Metodo | Path | Request | Risposta |
|---|---|---|---|
| GET | `/api/vault` | — | `{locked, encrypted, secrets: [VaultSecret], grants: {botId: {secrets: [{name, mode}], note}}, support: {safe: [driverKind], env: [driverKind]}}` |
| POST | `/api/vault/secrets` | `{name, preset?, description?, hint?, value}` | 201 `{secret}`; 400 nome non valido o riservato; 409 se esiste o se il vault è bloccato |
| PATCH | `/api/vault/secrets/:name` | `{preset?, description?, hint?, value?}` | `{secret}`; 404 |
| DELETE | `/api/vault/secrets/:name` | — | `{ok: true}`; toglie anche le concessioni che lo nominano |
| PUT | `/api/vault/grants/:botId` | `{secrets: [{name, mode: "safe"\|"env"}], note?}` | `{grants}`; 404 bot sconosciuto |
| POST | `/api/internal/secrets/run` | header `x-secrets-grant`; `{command, secrets: [name], timeout_sec?}` | `{exitCode, stdout, stderr, timedOut, truncated}` con i valori mascherati; 403 grant o secret non concesso. Solo loopback + boot token (helper `mcp-secrets`) |

`VaultSecret` = `{name, preset: "generic"|"github"|"huggingface"|"npm", description, hint, createdAt, updatedAt, set}`.
Ogni modifica manda il frame `vault`. I valori noti del vault sono mascherati (`«secret NAME»`) nei messaggi
salvati, nei frame `runtime` e nel log eventi.

### 2.11 Computer: Local VM, Box, VPS, controllo

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| GET | `/api/local-computer` | — | `ContainerComputerStatus {platform, runtime, available[], daemonUp, image, imageMatches, managed, container:"running"\|"stopped"\|"missing", network, security, persistence, desktopReady, desktop_error, ready, problem, image_ref, image_id, base_image_ref, driver_version, container_name, workspace_path, workspace_guest_path, …} + commands + idle_timeout_ms` | ✅ | ❌ |
| POST | `/api/local-computer/{pull\|run\|start\|stop\|remove}` | JSON obbligatorio | stesso shape; 409 se un'altra azione è in corso o la VM è in uso (stop/remove/run) | ✅ | ❌ |
| POST | `/api/local-computer/screenshot` | — | `{image}` | ✅ | ❌ |
| POST | `/api/local-computer/interrupt` | JSON obbligatorio | `{ok:true}` (interrompe ogni bot con `computer==="local"`) | ✅ | ❌ |
| GET | `/api/bots/:id/computer` | — | Box: `{backend:"box", configured, box:{boxId,state,desktopAvailable}\|null}`; VPS: `{backend:"vps", …VpsComputerStatus}` | ✅ | ❌ |
| GET | `/api/bots/:id/computer/control` | — | `{held, helpReason, heldSinceMs}` | ✅ | ❌ |
| POST | `/api/bots/:id/computer/control` | JSON obbligatorio, `{action:"take"\|"release"\|"dismiss-help"}` | snapshot + frame `computer-control` | ✅ | ❌ |
| POST | `/api/bots/:id/computer/{provision\|join\|sleep\|exec\|screenshot\|remove}` | JSON obbligatorio; `exec`: `{command}` | Box: `provision`/`join` → `{boxId, machineName, reused, state, joinUrl}`; VPS: `join`/`exec` → 409, `remove`→ solo VPS | ✅ | ◐ (`join` soltanto, **senza Content-Type** → vedi §5) |

### 2.12 Ricerca, export, decisioni, salute

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| GET | `/api/search` | `q`, `limit` (1..100, default 40) | `{hits:[{threadId, messageId, at, role, kind, snippet, matchStart, matchLength, from?, botId?\|groupId?, name, task?, onActivePath}]}` | ✅ | ✅ (manca `from`) |
| GET | `/api/threads/:tid/export` | `format=markdown\|json` | allegato (`content-disposition`): markdown, oppure JSON `{name, threadId, messages}` (ramo visibile, senza pixel) | ✅ | ✅ |
| GET | `/api/decisions` | `limit` (default 200) | `{decisions:[{at, threadId, requestId?, botId?, botName?, tool?, summary?, decision:"auto-approved"\|"card-shown"\|"user-approved"\|"user-denied", source, rule?, unattended?}]}` | ❌ | ❌ |
| GET | `/api/health` | — | `{app:"swarmebot", pid, static}` | (Electron) | ❌ |
| GET | `/*` (non `/api/`) | — | file da `OMB_STATIC_DIR`, SPA fallback | — | — |

#### Plugin (solo Swift, `HarnessCore/Plugins.swift`)

Il motore dichiara i plugin collegati in compilazione, così un client mostra l'interfaccia di un plugin solo se il motore lo ha (piano `docs/plans/2026-10-28-code-mode-t3.md` §12). Un motore senza plugin risponde `{plugins: []}`.

| Metodo | Path | Request | Risposta |
|---|---|---|---|
| GET | `/api/plugins` | — | `{plugins:[{id, name, version, enabled, requires?}]}`; `enabled` è falso se l'utente l'ha spento o se manca un plugin richiesto |
| PUT | `/api/plugins/:id` | JSON obbligatorio, `{enabled}` | come il GET; 404 per un plugin sconosciuto, 400 se `enabled` non è un booleano. La scelta resta in `<data>/plugins.json` |

Un plugin spento non serve le sue route (404 come se non ci fossero), non è ascoltato dai turni e i suoi flag su bot e canali non vengono accettati; i dati già scritti restano. Le route che un plugin aggiunge si documentano con il plugin, non qui; le mutazioni (POST/PUT/PATCH) di un plugin richiedono `content-type: application/json` come quelle del nucleo.

### 2.13 Route interne (bearer `COMMS_TOKEN`, non per la UI)

| Metodo | Path | Request | Risposta |
|---|---|---|---|
| GET | `/api/internal/agents` | `self?` | `{bots:[{id,name,model,busy,title?,description?}]}` (esclusi hidden e self) |
| POST | `/api/internal/ask-bot` | `{fromBotId, toBotId, message, depth?, fromThreadId?}` | `{botName, text}` \| `{busy:true}` \| `{error}` (sincrono, ceiling 4 min, max 1 hop) |
| POST | `/api/internal/delegate-bot` | `{fromBotId, toBotId, message, reason?, depth?, fromThreadId?}` | `{queued:true, message}` \| `{error}` |
| GET/POST/DELETE | `/api/internal/computer-control?botId=` | POST `{reason}`, DELETE `{requestId}` | `{held, helpOpen, requestId?}` |
| POST | `/api/internal/connectors/mcp` | relay MCP Composio (header `mcp-session-id`) | **FP** |
| POST | `/api/internal/connectors/request` | `{botId, threadId, resumeKey, slugs[]}` | `{messageIds}` — **FP** |

### 2.14 Fuori perimetro (voce, Composio)

| Metodo | Path | Request | Risposta | React | CC |
|---|---|---|---|---|---|
| POST | `/api/tts/prepare` | `{text, voiceId?}` | `{ready, utterances[]}` | ✅ | ❌ FP |
| GET | `/api/tts/voices` | — | `{voices[], error?}` | ✅ | ❌ FP |
| POST | `/api/tts/speak` | `{text (≤500), voiceId?}` | audio bytes; 409 se voce non configurata | ✅ | ❌ FP |
| GET | `/api/connectors/catalog` | — | `{configured, mode, source, cards}` | ✅ | ❌ FP |
| GET | `/api/connectors` | `services=a,b` | `{configured, services}` | ✅ | ❌ FP |
| POST | `/api/connectors/:slug/authorize` | — | risposta Composio | ✅ | ❌ FP |
| DELETE | `/api/connectors/:slug` | — | risposta Composio | ✅ | ❌ FP |
| POST/GET | `/api/bots/:id/connector-cards/:mid/{authorize\|status\|resume\|dismiss}` | POST `{threadId}`, GET `?threadId=` | `{connected,pending,status}` / `{resumed:true}` / `{dismissed:true}` | ✅ | ❌ FP |

Anche i campi legati a voce/Composio restano nel wire (`speakReplies`, `voice`, `composio`, `ConfigStatus.tts/composio`,
`Message.kind:"connector"`): il client nativo deve tollerarli/ignorarli, non rifiutarli.

### 2.15 Conteggio

89 handler nel router (method+path pattern) → **104 combinazioni concrete** (espandendo le alternanze
`local-computer/{5}`, `deepseek-harness/{3}`, `PUT|PATCH config`, `connector-cards/{4}`, `computer/{6}`), + fallback
statico + 2 route dell'ingress webhook. Di queste: 8 interne (2 delle quali Composio) e 11 pubbliche fuori perimetro (3 TTS, 4 connectors, 4 connector-cards).
CompanionCore copre **25** route dell'harness (+ `POST /api/pair` del sidecar).

---

## 3. SSE: `GET /api/events`

### 3.1 Query e header

- `screens=off` → il client non riceve i frame `screen` (base64 del desktop ogni pochi secondi). Qualunque altro
  valore/assenza = li riceve. React apre `/api/events` (con screen), CompanionCore usa `screens=on|off` esplicito.
- Resume: `since=<streamId>:<seq>` oppure header `Last-Event-ID` (quello che EventSource manda da solo). `since` vince.
- Risposta: `content-type: text/event-stream`, `cache-control: no-cache`, `connection: keep-alive`.

### 3.2 Framing, cursore, resume

- Ogni frame broadcast: `id: <STREAM_ID>:<seq>\ndata: <JSON {…payload, seq}>\n\n`. Una sola riga `data:`.
- `STREAM_ID` = 8 caratteri random per boot; `seq` riparte da 1 a ogni boot. Un cursore di un altro boot è rifiutato.
- **Primo frame** di ogni connessione, senza riga `id:` e senza `seq`:
  `data: {"kind":"hello","cursor":"<STREAM_ID>:<lastSeq>","resumed":<bool>}`.
  `resumed:true` solo se il cursore è dello stesso stream, `since ≤ lastSeq`, e il replay buffer copre `since+1`
  (o il buffer è vuoto e `since===lastSeq`). Poi il server rimanda i frame bufferizzati con `seq > since`.
  `resumed:false` (anche per cold start senza cursore) = **idratare** da REST.
- Replay buffer: ultimi **500** frame; i `screen` occupano lo slot (gap detection onesta) ma il payload non è
  conservato, quindi non vengono mai rigiocati.
- Keepalive: commento `: keepalive\n\n` ogni **25 s**. (CompanionCore usa idle timeout 90 s.)
- Protocollo di idratazione del client React (da replicare): aprire SSE, attendere `hello`; se `!resumed` lanciare
  `GET /api/bots` + `/api/instances` + `/api/config` + `/api/routines` + `/api/webhooks`, accodare i frame arrivati nel
  frattempo e applicarli dopo; un secondo `hello` non-resumed durante l'idratazione forza un'altra idratazione.
  Fallback: idratare comunque dopo 1 s se `hello` non arriva.

### 3.3 Kind trasmessi

| `kind` | Payload (oltre a `seq`) | Origine | Frames.swift |
|---|---|---|---|
| `hello` | `cursor`, `resumed` | apertura connessione | ✅ |
| `message` | `threadId`, `message: Message` (completo, `png` inline per `screen`) | store `appendMessage` (anche comms mirror, peer approval) | ✅ |
| `message.patch` | `threadId`, `message: Message` (intero, sostituisce) | store `patchMessage` | ✅ |
| `thread` | `threadId`, `activeLeafId` | cambio ramo / edit | ✅ |
| `bot` | `bot`: WireBot (dallo store) **oppure** PublicBot con `messages`/`activeLeafId`/`tasks` (task create/switch/patch/delete, import team, routine createTask). Va fatto **merge** sul bot esistente | store + route | ✅ (decodifica `Bot` parziale) |
| `bot.deleted` | `botId` | store | ✅ |
| `group` | `group`: WireGroup | store + `/read` + import | ✅ (`Room`) |
| `group.deleted` | `groupId` | store | ✅ |
| `notify` | `notification:{kind:"approval"\|"question"\|"done"\|"routine-failed"\|"takeover", botId, botName, threadId, title, body}` | fold runtime, routine, help plea computer | ✅ (commento Swift non elenca `takeover`) |
| `screen` | `botId`, `png` (base64), `mime` (`image/png`\|`image/jpeg`) | screen poller | ✅ |
| `computer` | `botId`, `state:"provisioning"\|"waking"` | dispatch turno Box | ✅ |
| `computer-control` | `botId`, `held`, `helpReason: string\|null` | `ComputerControl` | ❌ (→ `.unknown`) |
| `config` | spread di `ConfigStatus` (`xai, composio, box, vps, opencodeGo, localEndpoint, tts, profile, rooms`) | `PUT/PATCH /api/config` | ◐ (`.config` senza payload; React rilegge anche `/api/instances`) |
| `runtime` | `event: RuntimeEvent` (§3.4) | ogni evento del bus | ◐ (solo `type, threadId, delta, streamKind`) |
| `routine` | `routine: Routine` | RoutineManager | ❌ |
| `routine.deleted` | `routineId` | RoutineManager | ❌ |
| `routine.run` | `run: RoutineRun` | RoutineManager | ❌ |
| `webhook` | `webhook: WebhookTrigger` | WebhookManager | ❌ |
| `webhook.deleted` | `webhookId` | WebhookManager | ❌ |
| `webhook.attempt` | `attempt: WebhookAttempt` | WebhookManager | ❌ |
| `skills` | — | **solo Swift** (2026-10-21): repository delle skill o sua cartella cambiati; il client rilegge `/api/skills` | ✅ |
| `vault` | — | **solo Swift** (2026-10-25): un secret del vault o le concessioni di un bot cambiati; il client rilegge `/api/vault` | ✅ |
| `usage-limit` | `instanceId`, `usageLimit:{window:"five_hour", utilization (0–1, oltre 1 se sopra il tetto), resetsAt? (epoch s)}` | **solo Swift** (2026-10-20): `rate_limit_event` di Claude, solo quando il valore cambia; mai come `runtime` | ✅ |

### 3.4 Eventi runtime rilanciati (`kind:"runtime"`)

Base comune: `eventId, provider, providerInstanceId?, threadId, createdAt (ISO), turnId?, itemId?, requestId?, raw?{source,payload}`.
Il server rimuove solo `resumeCursor` e azzera `sessionId` (→ `null`) su `session.started`; **`raw` passa così com'è**.

| `type` | Campi |
|---|---|
| `session.started` | `sessionId: null`, `model?` |
| `session.exited` | `reason?` |
| `turn.started` | — |
| `turn.completed` | `ok`, `stopReason?`, `cost?`, `denials?: string[]`, `usage?{input,output}` |
| `item.started` | `itemType:"tool"\|"reasoning"`, `title?` |
| `item.updated` | `itemType`, `tokens?` |
| `item.completed` | `itemType:"tool"`, `ok` · oppure `itemType:"assistant_text"`, `text` |
| `content.delta` | `streamKind:"assistant_text"\|"reasoning_text"`, `delta` |
| `request.opened` | `requestType:"permission"\|"question"`, `tool`, `summary`, `choices?`, `multiSelect?`, `approvalScope?:"local-computer"` |
| `request.resolved` | `behavior:"allow"\|"deny"\|"answer"`, `source:"user"\|"auto"\|"timeout"\|"system"\|"unavailable"\|"peer"`, `approvalScope?` |
| `thread.token-usage.updated` | `input`, `output` (indicatore live, non sommare) |
| `runtime.error` | `message`, `setup?` |

Uso lato client: lo stato persistente arriva già foldato come `message`/`message.patch`/`bot`; i runtime servono
per lo streaming. React accumula `content.delta` per `threadId` (testo e reasoning separati, flush a rAF) e su
`turn.completed` pulisce il reasoning; il testo resta finché non arriva il `message` `text` del bot (anche
`interrupted:true` se fermato), che sostituisce la bolla in streaming. Un frame `thread` invalida lo streaming.

---

## 4. Tipi payload chiave

Campi in **grassetto** = presenti sul wire ma **assenti in `Models.swift`**.

### 4.1 Message (`store.ts`)

`id`, `role:"bot"|"user"`, `kind:"text"|"options"|"activity"|"screen"|`**`"connector"`** (Swift → `.unknown`),
`at` (epoch ms), `text?`, `card?`, **`connector?`**, `tool?{name, ok?, spoken?, setup?}`, `png?`, `mime?`, `parentId?`,
`from?{botId,name,color}`, `reactions?[{emoji,by}]`, `comm?{groupId,withBotId,withName,withColor}`, **`queued?`**,
**`interrupted?`**; paginato: `hasImage?` (al posto di `png`/`mime`).

`card` (OptionCardData): `title`, `subtitle`, `options[]`, **`multiSelect?`**, `answered?`, `dismissed?`, `requestId?`,
`tool?`, `held?`, `allowKey?`, **`approvalScope?:"local-computer"`**. Pending = `requestId && answered==null && dismissed!==true`.

`connector` (FP): `slug`, `label`, `description`, `status:"required"|"authorizing"|"connected"|"failed"`, `resumeKey`, `error?`, `dismissed?`, `resumed?`.

### 4.2 Bot (WireBot da `BotRecord`)

Presenti in Swift: `id, threadId, name, title, description, notifications, color, unread, modelSelection{instanceId, model}, createdAt, busy?, pinned?, hidden?, chiefOfStaff?, autoApprove?, codeMode?, alwaysAllow?, computer?, cloudBackend?, speakReplies?, voice?, mascotExpression?, tasks?, messages?, activeLeafId?, hasMore?`.

Mancanti in Swift: **`modelSelection.effort?`** (`none|minimal|low|medium|high|xhigh|max`), **`activity?`**
(`working|waiting-on-you|idle|no-signal|dead`), **`mascotSilhouette?`**, **`mascotAvatarSvg?`**, **`mascotAvatarImage?`**
(filename servito da `/api/attachments/`), **`mascotAvatarSheetRow?`**, **`cwd?`**, **`section?`**, **`pinnedMessageId?`**,
**`approvePeerComms?`**, **`composio?`** (FP), **`rewound?`**. `computer` sul record può essere `cloud|vm|local|off`.

Task (`tasks[]`): `threadId, title, createdAt` in Swift; mancano **`usage?{input, output, costUsd: number|null, turns}`**,
**`pinned?`**, **`cwd?: string|null`**.

Paged/top-level `GET /api/bots`: mancano **`computerControl`** (mappa per bot).

### 4.3 Room (WireGroup da `GroupRecord`)

Swift: `id, threadId, name, memberIds, defaultResponder{kind, botId?}, bulletin, unread, createdAt, dm?, busyBotId?, messages?, hasMore?`.
Mancanti: **`pinnedMessageId?`**. `cwd?` e `pinnedCwd?: string|null` (fissata al primo turno) passano così come sono salvati.

### 4.4 Istanze e catalogo modelli (`registry.describe()` + `pickerVisible`)

`instanceId`, `driverKind`, `displayName`, `snapshot{state:"available"|"unavailable", reason?, authenticated?, version?, `**`billing?:"metered"|"subscription"`**`}`,
`models{default, options[{id, label, `**`custom?, loaded?, contextWindow?, effortLevels?`**`}]}`,
**`capabilities{computerMcp, agentsMcp, composioMcp, phoneMcp, images, effortLevels?, localComputerMcp}`**
(le istanze shadow/non caricate hanno solo `computerMcp, agentsMcp, localComputerMcp:false`),
**`access:"subscription"|"custom"`**, **`install?{command?{darwin,win32,linux}, docsUrl?, signInCommand?, needsNode?}`**,
**`cli?`**, **`cliDefault?`**, **`cliCandidates: string[]`**, **`pickerVisible?`** (solo se c'è un override esplicito).
**Solo Swift:** **`usageLimit?`** = l'ultimo `usage-limit` di quell'istanza (finestra di sessione
dell'abbonamento), assente finché un turno non l'ha riportato; in memoria, si perde al riavvio.

Livelli effort ammessi per un bot = `effortLevelsForModel(models.options, model, capabilities.effortLevels)`
(`src/lib/model-effort.ts`): l'opzione modello vince, altrimenti i livelli del driver; assente = nessun controllo.

### 4.5 ConfigStatus (`configStatus()`)

`xai{configured}`, `composio{configured, mode:"managed"|"self-hosted"|"unavailable"}`, `box{configured}`,
`vps{configured, sshAlias}`, `opencodeGo{configured}`, `localEndpoint{configured, baseUrl}`,
`tts{configured, ready, voice}`, `profile{name, email}`, `rooms{turnTimeoutMinutes}`.
Swift ha solo `composio/box/tts` (come `ConfigFlag{configured, apiKeyConfigured?, ready?, voice?}`, senza `mode`) e `profile`:
mancano **`xai`**, **`vps`**, **`opencodeGo`**, **`localEndpoint`**, **`rooms`**, **`composio.mode`**.

### 4.6 Routine / Webhook (assenti in Swift)

`Routine{id, name, prompt, botId, runOn:"maus"|"cloud", enabled, schedule, durationMinutes, nextRunAt: number|null, createdAt, updatedAt}`.
`RoutineRun{id, routineId, routineName, prompt?, durationMinutes?, botId, runOn, scheduledFor, status:"queued"|"running"|"waiting"|"completed"|"failed"|"cancelled"|"missed", manual, triggerSource?:"schedule"|"manual"|"webhook", webhookId?, deliveryId?, threadId?, startedAt?, finishedAt?, output?, error?, cost?, denials?, createdAt, seenAt?}`.
`WebhookTrigger{id, endpointId, name, prompt, botId, runOn, enabled, createdAt, updatedAt, lastReceivedAt?, lastRunId?, deliveryCount, verificationPending?, verifiedAt?, verificationSample?{receivedAt, eventName?, contentType?, preview}, eventTypes?}`.
`WebhookAttempt{id, webhookId, receivedAt, outcome:"accepted"|"captured"|"duplicate"|"ignored"|"rejected", statusCode, eventName?, preview?, deliveryId?, runId?, reason?}`.

---

## 5. Note e incongruenze rilevate

1. **`computer/join` da CompanionCore senza `Content-Type`**: `cloudDesktop()` fa `POST` senza body, `makeRequest`
   imposta `Content-Type` solo se c'è un body, il sidecar inoltra il content-type solo se presente, e l'harness
   risponde **415** a ogni `computer/*` non-JSON. Da verificare; il client nativo deve mandare
   `Content-Type: application/json` (con `{}`) su tutte le route del §1.3 punto 3.
2. **`PATCH /api/bots/:id` accetta `computer` solo `"vm"|"off"`**, ma il record ammette `cloud|local` e
   `computer/provision` su VPS richiede `bot.computer === "cloud"`: oggi `cloud` non è impostabile via API.
3. Nessuna route per le skill; nessuna route per scrivere `config.instances` (driver/env/displayName di un'istanza):
   oltre a `cli`/`pickerVisible`/DeepSeek, il catalogo istanze è di sola lettura via HTTP.
4. Doppie vie per la stessa cosa: `/read` (usato solo da CC) vs `PATCH {unread:false}` (usato da React);
   `/api/bots/:id/respond` vs `/api/threads/:tid/respond`. Il nativo dovrebbe usare le varianti per thread e `/read`.
5. Route non usate da nessun client: `GET /api/team-library/catalog`, `GET /api/team-library/teams/:slug`,
   `POST /api/webhooks/:id/test`, `GET /api/decisions`.
6. Il frame `bot` ha due shape (slim dallo store, ricco con transcript dalle route task/import): applicare sempre
   merge, e sostituire `messages` solo se presenti.
7. `raw` degli eventi runtime è inoltrato ai client (payload nativo del provider): potenzialmente grande; da non
   persistere né loggare lato client.
8. I proxy figli (agents, phone) sono lanciati con `process.execPath` + `ELECTRON_RUN_AS_NODE=1`: un host Swift che
   lancia l'harness con un `node` standalone eredita il comportamento corretto, ma va verificato.
