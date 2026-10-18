# Bot remoto (motore SwarmeBot su server) — piano di implementazione

Stato: fasi 0–3 fatte per Linux, fase 4 scritta ma non provata nell'app (branch `feat/remote-engine`); Mac server e fase 5 da fare; vedi §14. Data: 2026-10-16.
Motore: solo Swift (`HarnessCore` / `HarnessDrivers` / `swarme-harness`); il motore Node non riceve la funzione.

## 0. Obiettivo e decisioni prese

Un bot può vivere su un **server remoto** (Ubuntu o Mac). Sul server gira l'intero motore SwarmeBot
(`swarme-harness`), con store delle chat, turni, harness CLI e connettori. L'app Mac e, in futuro, l'app
iOS sono **client** dello stesso motore: si inizia una conversazione dal PC, lo si chiude o spegne, e la si
continua dal telefono. Il turno va avanti sul server e il PC non deve restare acceso.

| # | Decisione | Motivo |
|---|---|---|
| R1 | Sul server gira **l'intero motore**, non solo la CLI | la fonte di verità delle chat deve stare dove tutti i client arrivano e che è sempre acceso |
| R2 | Server: **Ubuntu 24.04 / 26.04** (x86_64, aarch64) **e macOS** | scelta dell'utente |
| R3 | Harness sul server: **Claude Code e pi** | scelta dell'utente; i driver ci sono già (`Claude.swift`, `Pi.swift`) |
| R4 | **Un motore per utente unix**; più utenti, quindi più motori, sullo stesso server, con installazioni e login delle CLI separati | scelta dell'utente |
| R5 | v1 solo **`bypassPermissions`** per i bot remoti | scelta dell'utente. Tecnicamente il broker ora vive sul server e potrebbe aspettare un client: si toglie in una fase successiva (§11) |
| R6 | **Chat e uso quotidiano in HTTPS** (443) con **token di dispositivo**, per Mac e iPhone | passa da qualunque firewall; un solo protocollo e un solo client per tutte le app |
| R7 | **ssh solo per l'amministrazione, solo dal Mac**: installazione, aggiornamenti, login delle CLI, primo token | in mobilità basta la 443; sshd si può limitare alla rete aziendale |
| R8 | Login ssh con **user e password solo per installare una chiave dedicata**, mai salvata | scelta dell'utente |
| R9 | **Una chiave per (host, porta, utente)**: due motori o configurazioni con lo stesso login non generano due chiavi | scelta dell'utente |
| R10 | Fingerprint ssh **approvato in SwarmeBot**, `known_hosts` dedicato, mai `StrictHostKeyChecking=no` | scelta dell'utente |
| R11 | Il motore remoto ascolta **solo su un socket unix** e chiede **sempre** un token, anche al Mac | niente "fidato perché locale"; isola gli utenti dello stesso server |
| R12 | Per ogni server **due indirizzi distinti**: amministrazione (ssh, anche IP privato) e chat (URL HTTPS pubblico, anche dietro proxy in DMZ) | i server possono avere IP privato (§6) |
| R13 | Abbinamento del telefono con **QR mostrato dal Mac** (codice monouso, non il token) | il telefono non vede mai password né chiavi ssh |
| R14 | **Connettori configurati sul motore remoto** via API; dal Mac "copia su server" per quelli con API key | sono già API del motore; a PC spento funzionano |
| R15 | Futura **app iOS**: client del motore remoto, nessun motore sul telefono, nessun sidecar Mac→iPhone | il vecchio companion resta abbandonato |
| R16 | **Automazioni (routine e webhook) di un bot remoto eseguite dal suo motore sul server**, anche con tutti i client scollegati; i risultati si vedono alla riconnessione da qualsiasi client | scelta dell'utente; `RoutineManager` e `WebhookManager` vivono già nel motore |

## 1. Architettura

```
                       chat (HTTPS 443, bearer di dispositivo)
 Mac (app) ───────┐
                  ├──► [proxy DMZ, facoltativo] ──► Caddy sul server ──► socket unix ──► swarme-harness (utente "deploy")
 iPhone (futuro) ─┘                                                                       store · SSE · turni · broker · connettori
                                                                                          └─ claude / pi come figli locali
 Mac ──ssh (indirizzo admin, anche privato)──► server   (solo amministrazione, R7)
```

- Il motore remoto è lo stesso binario e lo stesso codice del motore locale, avviato in **modalità remota** (§3).
- Il contratto HTTP+SSE è quello di `docs/contract/http-sse.md`. Cambiano solo trasporto e autenticazione.
- Le CLI girano come figli del motore, come oggi in locale. La persistenza viene dal fatto che il motore è
  un servizio sempre acceso (§3.5): non servono runner staccati né riagganci per offset.
- Il resume dell'SSE c'è già (`since` / `Last-Event-ID`, replay buffer di 500 frame, `hello.resumed`). Un
  client che si ricollega, anche da un altro dispositivo, si riallinea senza logica nuova; dopo un riavvio
  del motore idrata da REST come oggi.

## 2. Come si aggancia al codice esistente

| Punto | Oggi | Con il bot remoto |
|---|---|---|
| `HTTPServer.swift` | `NWListener` TCP su `127.0.0.1:8799` | + listener su **socket unix** in modalità remota; su Linux senza `Network` (§3.6) |
| Gate di sicurezza (`http-sse.md` §1.3) | `Host` loopback obbligatorio, `Origin` loopback | in modalità remota: niente controllo `Host`, `Origin` rifiutato se presente, **bearer di dispositivo obbligatorio** su ogni rotta pubblica |
| Rotte interne `/api/internal/*` | bearer `COMMS_TOKEN`, loopback | solo su un listener interno separato (§3.3), mai sul socket che Caddy inoltra |
| `ConnectorProxy` / `AgentsProxy` | `OMB_HARNESS_URL=http://127.0.0.1:8799` | URL del listener interno |
| `SSEHub.swift` | keepalive ogni 25 s | + header `X-Accel-Buffering: no`; keepalive configurabile (default 15 s in modalità remota) |
| `AppConfig` / data dir | `~/.swarmebot` | uguale, per utente unix |
| Nuovo: dispositivi | — | `devices.json` + rotte `/api/devices*` (§4) |
| Routine (`Routines.swift`, `nextOccurrence`) | orari calcolati con `Calendar.current` (fuso del Mac) | + fuso orario esplicito per routine (§8.1) |
| Webhook in ingresso (`Webhooks.swift`, `main.swift:47`) | secondo listener `127.0.0.1:8800`, `webhookIngressBaseUrl` loopback | socket unix dedicato, URL pubblico via Caddy (§8.1) |
| App: `AutomationsView` | automazioni di un solo motore | automazioni per motore (§7) |
| App: `CompanionCore.Client` | un solo motore, loopback, senza bearer | **un client per motore**, base URL con prefisso di percorso, bearer |
| App: modello (`AppModel`, barra laterale) | un motore | **multi-motore**: locale + N remoti (§7) |
| Nuovo: amministrazione ssh | — | `SSHCommand`, identità, provisioning (§5) |
| Rilascio | app macOS | + `swarme-harness` Linux statico x86_64/aarch64 nel bundle |

**Regola anti-regressione**: il motore locale avviato dall'app resta identico (TCP loopback, gate attuali,
nessun bearer). `parity/all.sh` e `swift test` invariati.

## 3. Motore in modalità remota

### 3.1 Avvio

`swarme-harness serve --remote --socket ~/.swarmebot/run/engine.sock --webhook-socket ~/.swarmebot/run/hooks.sock --public-url https://…/<prefisso>/ [--keepalive 15]`

- Niente porta TCP: più utenti sullo stesso server non vanno in conflitto (R4, R11).
- I socket stanno in `/run/swarmebot/<utente>/`, creata da root (tmpfiles.d) come `2750 <utente>:caddy`:
  il bit setgid dà ai socket (0660) il gruppo `caddy`. **Deviazione dal piano iniziale:** non in
  `~/.swarmebot/run`, perché Caddy avrebbe dovuto entrare nel gruppo dell'utente e quindi poter leggere i
  suoi file nella home (su Ubuntu le home sono 0750).
- Il listener interno (§3.3) è TCP su `127.0.0.1` con una porta libera scelta all'avvio.
- `--public-url` è l'URL di chat (§6.1): serve al motore solo per mostrare gli URL dei webhook (§8.1).

### 3.2 Autenticazione

- Ogni richiesta sul socket pubblico deve avere `Authorization: Bearer <token di dispositivo>`, verificato
  sull'hash in `devices.json` con confronto a tempo costante. Altrimenti 401.
- Fanno eccezione solo `GET /api/health` (senza dati) e `POST /api/devices/claim` (§4.3).
- Dopo 10 tentativi falliti in 1 minuto dallo stesso IP: 429 per 5 minuti. L'IP viene da `X-Forwarded-For`
  solo se la richiesta arriva da un proxy dichiarato attendibile (§6.4).
- Il token identifica il dispositivo: `lastSeenAt` si aggiorna, e nei log compare il nome del dispositivo.

### 3.3 Rotte interne

`/api/internal/*` (proxy MCP di connettori, agenti, permessi) risponde **solo** su un listener interno,
con il `COMMS_TOKEN` di oggi; quel listener non serve nient'altro (404). Sul socket pubblico
`/api/internal/*` risponde 404 a prescindere dal token: un proxy configurato male non le espone.

**Deviazione dal piano iniziale (fase 1):** il listener interno è TCP su `127.0.0.1` con porta libera
(porta 0), non un socket unix. I proxy (`ConnectorProxy`, `AgentsProxy`) parlano HTTP con `URLSession`,
che non sa collegarsi a un socket unix; riscriverli non vale il guadagno. La porta libera evita i
conflitti tra utenti dello stesso server. Un altro utente locale può raggiungere la porta, ma senza il
`COMMS_TOKEN` (24 byte casuali per avvio, passato solo ai figli) riceve 401: la stessa protezione del
motore locale di oggi. `harnessURL` punta a questo listener.

### 3.4 Prefisso di percorso

Il motore non genera URL assoluti e non presume di stare alla radice: le risposte contengono percorsi
relativi all'API (per esempio `attachments/<name>`). Il prefisso (`/srv1/deploy/`) lo toglie Caddy o il
proxy, e lo aggiunge il client alla base URL. Da verificare rotta per rotta nel contratto (§12).

### 3.5 Servizio sempre acceso

- **Ubuntu**: unità `systemd --user` (`swarmebot.service`, `Restart=on-failure`) +
  `loginctl enable-linger <utente>` (root, una volta sola). Il servizio parte al boot senza login.
- **macOS**: `LaunchDaemon` in `/Library/LaunchDaemons` con `UserName=<utente>` (root, una volta sola), che
  parte senza login grafico. **Da verificare (fase 0)**: Claude salva il login nel Portachiavi, che in un
  demone senza sessione può essere bloccato. Ripiego: token OAuth della CLI (`CLAUDE_CODE_OAUTH_TOKEN`)
  nei segreti del motore. Lo stesso controllo vale per le credenziali di pi (`~/.pi/agent/auth.json`).
- Un riavvio del motore (crash, aggiornamento) interrompe i turni in corso, come oggi in locale. Gli
  aggiornamenti dall'app aspettano che non ci siano turni attivi o chiedono conferma (§5.5).

### 3.6 Port Linux

**Fatto (fase 0/2):** build in Docker sull'immagine `swift:6.4-noble` con `--static-swift-stdlib`
(`scripts/build-linux-engine.sh`), non con lo Static Linux SDK: glibc 2.39, quindi gira su 24.04 e 26.04, e
SQLite resta quello di sistema. Sul server servono solo `libsqlite3-0` e `libcurl4t64`, installati dalla
preparazione. Binario aarch64 strippato: 60 MB.

Moduli che oggi non compilano su Linux: `HTTPServer.swift` (Network), `PermissionBroker.swift`,
`MessageDB.swift` (SQLite), `MCPOAuth.swift`, `Library.swift`, `Box.swift`, `Webhooks.swift`,
`AttachmentInliner.swift` (CoreGraphics, PDFKit, Vision, NaturalLanguage, UniformTypeIdentifiers, CryptoKit).

- `HTTPServer`: listener POSIX (o SwiftNIO) dietro la stessa interfaccia, sia per TCP sia per socket unix.
- CryptoKit → `swift-crypto` (stessa API).
- SQLite: verificare la libreria con lo Static Linux SDK (musl).
- Allegati, PDF, OCR, computer use: dietro `#if canImport(...)`. Su Linux le capability corrispondenti
  sono spente, così l'interfaccia non le offre.
- `MCPClient` HTTP: lo streaming SSE con `FoundationNetworking` è il punto debole; se non regge,
  AsyncHTTPClient solo per Linux.

## 4. Dispositivi e token

### 4.1 Modello — `~/.swarmebot/devices.json` (motore remoto)

```json
{ "id": "dev_…", "name": "Mac di Cristiano", "kind": "mac", "tokenHash": "sha256:…",
  "createdAt": "…", "lastSeenAt": "…", "revokedAt": null }
```

Il token (32 byte casuali, base64url) si mostra una volta sola e non viene mai salvato in chiaro sul server.
Sul client sta nel Portachiavi.

### 4.2 Primo dispositivo (il Mac), via ssh

Durante la configurazione (§5.4) il Mac esegue sul server `swarme-harness device add --name … --kind mac`,
che scrive il record e stampa il token una volta. Da lì in poi il Mac usa solo HTTPS (R7).

### 4.3 Abbinamento del telefono (QR)

1. Dal Mac: `POST /api/devices/pairing` → codice monouso valido 10 minuti.
2. Il Mac mostra un QR con `{chatURL, code, serverName}`. Niente token nel QR: una foto dello schermo
   dopo 10 minuti non serve a niente.
3. Il telefono: `POST /api/devices/claim {code, name, kind:"ios"}` → token, salvato nel Portachiavi.

### 4.4 Gestione

`GET /api/devices` e `DELETE /api/devices/:id` (revoca immediata, anche delle connessioni SSE aperte con
quel token). In v1 tutti i dispositivi di un motore sono equivalenti: un motore ha un solo proprietario.
Senza dispositivi validi si recupera via ssh (`device add`).

## 5. Amministrazione via ssh (solo Mac)

### 5.1 Identità — `~/.swarmebot/ssh/identities.json` (Mac)

```json
{ "id": "srv1_deploy", "host": "10.0.4.12", "port": 22, "user": "deploy",
  "hostKey": { "type": "ssh-ed25519", "fingerprint": "SHA256:…", "approvedAt": "…" },
  "key": { "path": "~/.swarmebot/ssh/srv1_deploy/id_ed25519", "installedAt": "…" } }
```

Chiave logica `(host minuscolo, port, user)` (R9): prima di crearne una si cerca quella esistente.

### 5.2 Comando ssh

`/usr/bin/ssh` di sistema, opzioni costruite in un solo punto (`SSHCommand`, testabile):
`-i <key> -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=~/.swarmebot/ssh/known_hosts
-o StrictHostKeyChecking=yes -o ControlMaster=auto -o ControlPath=~/.swarmebot/ssh/cm/%C -o ControlPersist=10m`.
Nessun segreto in argv: i dati passano su stdin.

### 5.3 Fingerprint e chiave (R8–R10)

- **Fingerprint**: `ssh-keyscan` → SHA256 (`ssh-keygen -lf -`), mostrato per il confronto con la console del
  server, salvato in `known_hosts` se approvato. Se la chiave host cambia: blocco con vecchio e nuovo
  fingerprint e nuova approvazione esplicita.
- **Chiave**: se l'identità esiste si prova la sua chiave; se entra, niente password. Altrimenti password
  (via `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force`; l'helper `swarme-harness askpass` la chiede all'app con
  un token monouso; resta solo in memoria). Si genera la chiave ed25519 se l'identità non ne ha una, si
  aggiunge a `authorized_keys` in modo idempotente (commento `swarmebot:<id>`) e si verifica in BatchMode.

### 5.4 Configurazione di un server (procedura guidata)

| Passo | Utente | Cosa |
|---|---|---|
| 1 | — | fingerprint, password, chiave |
| 2 | root (sudo) | Caddy installato e attivo; gruppo condiviso per il socket; linger (Ubuntu) o LaunchDaemon (Mac) |
| 3 | utente | `swarme-harness` della versione dell'app in `~/.swarmebot/bin` (scp + `mv` atomico, controllo hash) |
| 4 | utente | Claude e pi installati per l'utente (installer nativo / npm), su conferma con comando mostrato |
| 5 | utente | login di Claude e pi guidato su `ssh -tt`: l'app mostra l'URL e un campo per il codice. Comando esatto da verificare in fase 0 |
| 6 | utente | servizio avviato, `device add` per il Mac, token nel Portachiavi |
| 7 | — | URL di chat (§6.1) e prova: `GET /api/health` e `GET /api/bots` col token, via HTTPS |

Il sudo usa la password dell'utente se serve (stesso `askpass`, mai salvata). Ogni comando root viene
mostrato prima di eseguirlo.

### 5.5 Aggiornamenti

Quando la versione dell'app cambia, la scheda del server propone "Aggiorna motore": controlla via HTTPS che
non ci siano turni attivi (altrimenti chiede conferma), sostituisce il binario via ssh e riavvia il
servizio. Fuori sede (ssh non raggiungibile) l'aggiornamento resta in sospeso e la chat continua a
funzionare con la versione precedente, se il contratto è compatibile. Il motore espone la versione del
contratto in `/api/health`; l'app rifiuta un motore incompatibile con un messaggio chiaro.

## 6. Rete

### 6.1 Due indirizzi (R12)

Ogni server nell'app ha:
- **indirizzo di amministrazione**: host e porta ssh, anche privati, usati solo dal Mac;
- **URL di chat**: `https://…/<prefisso>/`, quello che finisce nel QR e che usano tutti i client.

I due non si ricavano l'uno dall'altro.

### 6.2 Caddy sul server

Un solo Caddy per server. Ogni utente ha un percorso (`/srv1/deploy/`) o un sottodominio, inoltrato a
`unix//home/deploy/.swarmebot/run/engine.sock` (su Mac `/Users/…`). Caddy toglie il prefisso.
`<prefisso>/hooks/*` va invece a `hooks.sock`, il listener dei soli webhook (§8.1). Su un server
pubblico Caddy ottiene il certificato Let's Encrypt; su un server privato dietro DMZ usa un certificato
interno o la rete ristretta (§6.3).

### 6.3 Server con IP privato

```
client ──https──► proxy pubblico in DMZ ──https──► Caddy sul server privato ──► socket del motore
```

- Il proxy in DMZ fa solo inoltro HTTP. Non conosce i token e non autentica: lo fa il motore (§3.2).
- Il tratto DMZ → server privato va in TLS, o almeno su una rete interna ristretta.
- Se il server privato non è raggiungibile dalla DMZ: connessione rovesciata dal server (Cloudflare
  Tunnel, frp, `ssh -R` verso la DMZ). Lo schema per i client non cambia.
- Mac server a casa dietro NAT: stesso schema, oppure Tailscale.
- La configurazione del proxy in DMZ non è parte di questo lavoro: il piano garantisce solo che funzioni
  (requisiti in §6.4); si documenta un esempio per Caddy e uno per nginx.

### 6.4 Requisiti per qualsiasi proxy davanti al motore

- **SSE senza buffer**: il motore manda `X-Accel-Buffering: no`; sul proxy buffering spento e
  `read timeout` ≥ 5 minuti. Il keepalive ogni 15 s in modalità remota tiene viva la connessione.
- **Resume lato client**: riconnessione automatica con `Last-Event-ID` (c'è già in `CompanionCore.SSE`).
- **Prefisso**: rimosso dal proxy, mai interpretato dal motore (§3.4).
- **`X-Forwarded-For`**: il motore lo usa solo se la richiesta viene da un proxy nell'elenco
  `trustedProxies` della sua configurazione (per Caddy sullo stesso server: il socket stesso).
- **Allegati**: limite del corpo sul proxy ≥ `IMAGE_MAX_BYTES` del motore.
- `/api/internal/*` non esiste sul socket pubblico (§3.3), quindi non serve escluderlo nei proxy.

## 7. App Mac multi-motore

- `~/.swarmebot/remote-engines.json`: `{id, name, chatURL, identity?, deviceId}`; il token nel Portachiavi.
  `identity` è facoltativo: un motore si può usare anche senza averlo amministrato da questo Mac (per esempio
  abbinato con un QR da un altro Mac).
- Un `CompanionCore.Client` per motore (locale + remoti), ognuno con il proprio SSE e il proprio stato.
- Barra laterale: i bot raggruppati per motore ("Questo Mac", "srv1 · deploy", …), con lo stato della
  connessione (connesso, riconnessione, non raggiungibile, token revocato).
- Creazione bot: si sceglie il motore; su un motore remoto si vedono solo le istanze di quel motore
  (Claude e pi del server). La cartella di lavoro è un percorso sul server.
- Automazioni: `AutomationsView` raggruppa routine, webhook ed esecuzioni per motore. Una routine si crea
  sempre sul motore del bot a cui è destinata: non esistono routine del Mac che pilotano un bot remoto.
- Scheda server: stato, versione, dispositivi abbinati (con revoca), "Abbina telefono" (QR), "Aggiorna
  motore", connettori, istanze, "Rimuovi chiave dal server".
- **Fuori dalla v1**: gruppi con bot di motori diversi, `ask_bot`/`delegate_bot` tra motori diversi,
  spostamento di un bot da un motore all'altro. Tra bot dello **stesso** motore remoto, gruppi e `ask_bot`
  funzionano come in locale.

## 8. Harness e MCP sul server

- **Claude e pi**: driver attuali, invariati, configurati come istanze del motore remoto. Login per utente (R4).
- **MCP configurati sul server** (`~/.claude.json`, `.mcp.json`, configurazione di pi): li caricano le CLI.
- **Connettori SwarmeBot** (R14): vivono nel motore remoto, con pool, segreti e proxy di oggi. Si gestiscono
  dall'app con le stesse viste, puntate al motore scelto. "Copia su server" prende un connettore locale con
  `auth: none`/`headers` e lo crea sul motore remoto con i suoi segreti, in HTTPS (`POST /api/mcp-connectors`).
  I connettori stdio richiedono il comando sul server: il "Prova connessione" gira lì e lo segnala.
- **Connettori OAuth sul motore remoto**: il redirect va al motore e non al loopback del Mac. Fase successiva (§11).
- **Allegati e immagini**: vanno al motore remoto con `POST /api/attachments` e il percorso nel prompt è un
  percorso del server, quindi funzionano senza lavoro extra (dove il port Linux lo permette, §3.6).
- **Computer use**: escluso per i motori remoti in v1.

### 8.1 Automazioni (R16)

Routine e webhook appartengono al motore che ospita il bot: su un motore remoto lo scheduler, la coda delle
esecuzioni e i turni non automatici girano sul server, come le chat. Alla riconnessione un client vede i task
creati dalle esecuzioni e lo storico (`routine.run`) via REST o col resume dell'SSE. Se è stato
scollegato più a lungo di quanto copre il replay buffer, idrata da REST (`hello.resumed:false`), come oggi.

Cosa cambia:
- **Fuso orario.** `RoutineManager.nextOccurrence` usa `Calendar.current`, cioè il fuso della macchina; molte
  VPS sono in UTC, quindi "ogni giorno alle 9" scatterebbe alle 9 UTC. Ogni routine salva il fuso IANA del
  client che la crea o modifica (`timeZone: "Europe/Rome"`) e il motore calcola gli orari con quello, ora
  legale compresa. Le routine senza `timeZone` (già esistenti, motore locale) continuano a usare
  `Calendar.current`.
- **Webhook in ingresso.** Oggi c'è un secondo listener su `127.0.0.1:8800`. In modalità remota diventa
  `hooks.sock` (niente conflitti di porta tra utenti), esposto da Caddy su `<prefisso>/hooks/*`.
  `webhookIngressBaseUrl` diventa `--public-url` + `hooks`, così l'app mostra l'URL pubblico vero. Con un
  server pubblico i webhook funzionano senza tunnel né relay. L'autenticazione resta quella di oggi: segreto
  nel percorso o come bearer, solo l'hash salvato. Il listener dei webhook non accetta i token di dispositivo
  e non serve altre rotte.
- **`runOn`.** Su un motore remoto vale solo `maus`, cioè il motore stesso; `cloud` (boxAgent) non è
  offerto.
- **Recupero delle esecuzioni perse.** La regola delle 12 ore (`catchUpMillis`) resta; il testo "This computer
  was offline…" diventa neutro ("il motore era spento…"), perché sul server significa un fermo del servizio.
- I turni non automatici girano in `bypassPermissions` (R5), quindi nessuna esecuzione resta bloccata ad
  aspettare un client.
- Notifiche di fine esecuzione sul telefono con l'app chiusa: APNs, insieme all'app iOS (§9).

## 9. App iOS (futura)

Non è parte di questo lavoro, ma il piano la rende possibile senza modifiche al motore:
- client `CompanionCore` su HTTPS con bearer, lo stesso dell'app Mac;
- abbinamento con QR (§4.3);
- nessuna funzione di amministrazione e nessun ssh;
- **notifiche** ("il bot ha finito", "il bot ti chiede qualcosa") con l'app chiusa: richiedono APNs, cioè
  una chiave Apple sul motore o un piccolo relay. Si progettano con l'app iOS.

## 10. Sicurezza

- Il motore è esposto su internet: bearer su ogni rotta pubblica, rotte interne su un socket separato,
  limite sui tentativi, limiti sul corpo, nessun header CORS, `Origin` rifiutato.
- I token si salvano solo come hash sul server e solo nel Portachiavi sui client; si revocano uno per uno.
- Password ssh e sudo mai salvate; chiave dedicata; `known_hosts` dedicato; comandi root mostrati prima.
- `bypassPermissions` (R5): il bot può fare tutto quello che può fare il suo utente unix. Si consiglia un
  utente dedicato senza sudo; la procedura guidata lo dice.
- Più utenti sullo stesso server sono isolati dai permessi unix: socket del motore 0660 con gruppo condiviso
  solo con Caddy, socket interno 0600, data dir 0700.
- I segreti dei connettori sul server stanno in un file 0600 dell'utente: root sul server li può leggere.
  Avviso esplicito alla prima copia.
- sshd si può limitare alla rete aziendale: la chat non ne ha bisogno (R7).

## 11. Fasi

### Fase 0 — Prove tecniche
- Build Linux statica del motore: elenco reale degli errori, stima del lavoro per §3.6.
- Listener su socket unix su macOS e Linux.
- Mac come server: LaunchDaemon con `UserName`, login di Claude e pi senza sessione grafica.
- Comandi di login non interattivi di Claude e pi su un server senza browser.
- SSE attraverso Caddy e nginx con prefisso: nessun buffer, nessun taglio su turni > 10 minuti.

### Fase 1 — Modalità remota del motore (su macOS)
Socket pubblico, interno e dei webhook, bearer, `devices.json` e rotte `/api/devices*`, nuovi gate,
prefisso, SSE per proxy, fuso orario delle routine, `--public-url`. Si prova tutto in locale con Caddy
davanti, senza ssh.

### Fase 2 — Port Linux e pacchetto
`#if canImport`, listener POSIX/NIO, `swift-crypto`, SQLite, capability spente; binari x86_64/aarch64 nel bundle.

### Fase 3 — Amministrazione ssh dal Mac
Identità, fingerprint, chiave, procedura guidata §5.4 (Caddy, servizio, CLI, login, primo token),
aggiornamenti §5.5.

### Fase 4 — App Mac multi-motore
`remote-engines.json`, un client per motore, barra laterale per motore, creazione bot su motore remoto,
automazioni per motore, scheda server, QR di abbinamento.

### Fase 5 — Connettori sul motore remoto
Viste dei connettori puntate al motore scelto, "Copia su server", prova connessione remota.

### Fase 6 — Facoltativa
Approvazioni sui bot remoti (broker con timeout lungo, risposta da qualsiasi client: fine di R5); OAuth sul
motore remoto; funzioni tra motori diversi; esempi di proxy DMZ e tunnel rovesciato documentati.

### Fase 7 — App iOS (progetto a parte)
§9.

## 12. Verifica

- **Unit**: gate della modalità remota (senza token 401, token revocato 401, `/api/internal` 404 sul socket
  pubblico), hash e confronto dei token, codice di abbinamento monouso e scaduto, `X-Forwarded-For` solo da
  proxy attendibili, `SSHCommand`, parsing dei fingerprint, ricerca dell'identità esistente (R9).
- **Contratto**: ogni rotta di `http-sse.md` chiamata con un prefisso di percorso tramite Caddy; nessun URL
  assoluto nelle risposte.
- **Integrazione** (container Ubuntu 24.04 con sshd e password, finto `claude` stream-json):
  1. configurazione completa da zero dal Mac;
  2. turno lungo avviato dal Mac, app chiusa, riaperta: avanzamento visibile e turno chiuso correttamente;
  3. secondo client (secondo `CompanionCore.Client` con un altro token) che segue lo stesso turno in diretta;
  4. due utenti sullo stesso server: due motori, due socket, nessun accesso incrociato;
  5. due configurazioni con lo stesso login: una sola chiave, una sola riga in `authorized_keys`;
  6. chiave host cambiata → blocco;
  7. revoca di un dispositivo con SSE aperto → connessione chiusa;
  8. ssh irraggiungibile, HTTPS sì: chat funzionante, aggiornamento in sospeso;
  9. dietro un secondo proxy (DMZ simulata) con prefisso: SSE e resume funzionanti;
  10. routine programmata con tutti i client scollegati: eseguita sul server; alla riconnessione task ed
      esecuzione visibili, anche da un secondo client;
  11. routine "ogni giorno alle 9" creata con fuso `Europe/Rome` su un server in UTC: scatta alle 9 di Roma,
      anche attraverso il cambio dell'ora legale;
  12. webhook inviato all'URL pubblico via Caddy con il Mac spento: consegna accettata ed eseguita; lo stesso
      URL senza segreto, o con un token di dispositivo, rifiutato.
- **Reale**: una VPS Ubuntu 24.04, una 26.04 e un Mac server; Claude e pi veri; Mac spento a metà turno.
- `parity/all.sh` e `swift test` invariati per il motore locale.

## 13. Punti aperti (non bloccanti)

- Percorso (`/srv1/deploy/`) o sottodominio per utente come default di Caddy.
- Keepalive SSE: 15 s fisso in modalità remota o configurabile per server.
- Durata del codice di abbinamento e numero massimo di dispositivi per motore.
- Compatibilità del contratto tra versioni di app e motore remoto diverse (quanto a lungo si accetta un motore vecchio).
- Dove conservare il token OAuth delle CLI sul Mac server se il Portachiavi non è utilizzabile dal demone.

## 14. Avanzamento

### Fase 1 — fatta (2026-10-18)

- `HTTPTransport.swift` (nuovo): `HTTPConnection` con due implementazioni, Network.framework (motore locale,
  invariato) e socket POSIX (socket unix; TCP su loopback; su Linux tutto). Un socket esistente al percorso
  viene sostituito, un file normale no.
- `HTTPServer`: gate configurabile (`init(gate:handler:)`); il costruttore di prima tiene i gate di loopback.
  `start(unixSocket:mode:)`, `startLoopback(port:)` (porta 0 → libera), `HTTPRequest.deviceId`, stato 429.
- `RemoteAccess.swift` (nuovo): `DeviceRegistry` (`devices.json` 0600, solo hash SHA-256, riletto quando il
  file cambia, così `device add` via ssh vale subito), `PairingCodes` (10 caratteri, 10 minuti, monouso, al
  massimo 5 aperti), `FailureLimiter` (10 errori in un minuto → 429 per 5 minuti, per `X-Forwarded-For`),
  gate remoto (§3.2–3.3; rotte computer → 501) e rotte `/api/health`, `/api/devices*`.
- `SSEHub`: `keepaliveSeconds`, `proxyFriendly` (`X-Accel-Buffering: no`), `close(deviceId:)` alla revoca.
- `Routines`: `schedule.timeZone` facoltativo e validato, usato da `nextOccurrence`; `missedReason`.
- `swarme-harness serve --remote …` e `swarme-harness device add|list|revoke` (`Sources/swarme-harness/Remote.swift`).
- Test: `RemoteAccessTests.swift`, 19 test (registro, abbinamento, limiti, gate, socket unix reali, porta
  libera, fuso orario con il cambio dell'ora legale). Suite completa verde.
- Prova manuale con Caddy davanti (`handle_path /srv1/me/*`, `flush_interval -1`, `/srv1/me/hooks/*` →
  `hooks.sock`): salute, 401 senza token, 404 su `/api/internal`, 403 con `Origin`, abbinamento e revoca
  (lo stream SSE del dispositivo revocato si chiude subito), keepalive SSE ogni 15 s senza buffer, webhook
  consegnato all'URL pubblico con il prefisso, segreto sbagliato rifiutato.
- **Non verificato:** `parity/all.sh` richiede il repo Node di riferimento in `../SwarmeBot`, che su questa
  macchina non c'è. Il motore locale non cambia percorso (stesso listener Network, stessi gate), ma la
  parity va rilanciata dove c'è il repo Node.

### Fase 0 — fatta per Linux (2026-10-18)

- Build Linux riuscita dopo questi cambi (macOS invariato, suite verde):
  - `POSIXCompat.swift` (nuovo): `Sys.write/close/listen/connect`, `streamSocket`, `noSigPipe` (su Linux
    nessun flag per descrittore: `signal(SIGPIPE, SIG_IGN)` all'avvio di ogni sottocomando, `main.swift`);
  - `CLIProcess`: `posix_spawn` con i tipi Glibc, `addclosefrom_np(3)` al posto di
    `POSIX_SPAWN_CLOEXEC_DEFAULT`, un thread in `waitpid` al posto di `DispatchSourceProcess`;
  - `StreamingBytes.swift` (nuovo): `URLSession.streamingBytes(for:)`, cioè `bytes(for:)` su Apple e una
    sessione con delegate su Linux; usato da `MCPClient`, Grok e Local Endpoint;
  - `#if canImport` per CryptoKit (→ `swift-crypto`, solo Linux), SQLite3 (→ modulo di sistema `CSQLite3`),
    FoundationNetworking, PDFKit/Vision/NaturalLanguage in `Library` (su Linux niente PDF, OCR ed
    embedding: ricerca per parole chiave) e in `AttachmentInliner` (tipi per estensione);
  - `JSON(any:)`: booleani riconosciuti da `objCType` su Linux; `SecRandomCopyBytes` →
    `SystemRandomNumberGenerator` nei webhook.
- Su Ubuntu 24.04 pulito: motore remoto avviato, token, SSE, e **un turno Claude vero** con il finto CLI
  della parity (spawn, stream-json, messaggi), **compresa una card di permesso** (broker su socket unix e
  proxy `mcp-permission`).
- **Da fare:** Mac come server (LaunchDaemon, Portachiavi della CLI), login non interattivo di Claude e pi,
  build x86_64 verificata su una macchina x86_64.

### Fase 2 — fatta per Linux (2026-10-18)

`scripts/build-linux-engine.sh [aarch64|x86_64]` → `build/linux/swarme-harness-<arch>` + `.sha256`.
Manca l'inclusione nel bundle dell'app (`bundle-app.sh`).

### Fase 3 — fatta per Linux (2026-10-18)

In `Sources/SwarmeKit/Remote/`:
- `SSHIdentity.swift`: `SSHIdentityStore` (`~/.swarmebot/ssh/`: `identities.json`, `known_hosts` con le sole
  chiavi approvate, una cartella 0700 per chiave, `cm/` per i master). `findOrCreate` trova l'identità per
  (host minuscolo, porta, utente): **una chiave per login** (R9). `ensureKey` genera la chiave solo se manca.
- `SSHCommand.swift`: opzioni ssh in un solo punto; `ProcessRunner`; `SSHFailure` (chiave host cambiata o
  sconosciuta, accesso negato, irraggiungibile); password tramite `SSH_ASKPASS` + script 0700 che stampa una
  variabile d'ambiente del solo processo ssh. **Deviazione:** non un token monouso verso il motore. Basta la
  variabile d'ambiente: niente disco, niente argv, e un altro utente non legge l'ambiente dei processi
  altrui. `closeMaster()` chiude il master dopo la rimozione della chiave o una nuova approvazione: il
  master riusato altrimenti risponderebbe ancora per lo stato vecchio, fino a `ControlPersist`.
- `HostKeys.swift`: `ssh-keyscan`, fingerprint SHA256 come `ssh-keygen -l`, preferenza ed25519, approvazione.
- `RemoteScripts.swift`: gli script, sempre come `sh -c '<script>' sh 'arg'…` con lo stdin solo per i dati.
  **Correzione in corso d'opera:** script e dati sullo stesso stdin di `sh -s` non vanno bene, perché dash
  legge a blocchi ed eseguirebbe i dati.
- `RemoteAdmin.swift`: chiave con password, probe, `runAsRoot` (root diretto, `sudo -n`, oppure
  `sudo -k -S` con la password verificata prima con `-v`, così una password sbagliata non consuma mai lo
  script), upload del motore con controllo hash, servizio utente systemd + linger + tmpfiles, rotte Caddy
  con `caddy validate` e ripristino se non valide, primo token di dispositivo.
- `RemoteEngines.swift`: `remote-engines.json` + token nel Portachiavi.
- Test: `RemoteAdminIntegrationTests` contro un container Ubuntu 24.04 con systemd, sshd e sudo con password.
  Sono verificati:
  - password sbagliata rifiutata;
  - chiave installata una sola volta e riusata;
  - probe e sudo (con una password sbagliata lo script non parte);
  - upload, servizio, Caddy, primo token;
  - chat via HTTP con prefisso, 401 senza token;
  - preparazione ripetibile;
  - secondo utente con chiave propria, che non entra nel socket del primo;
  - rimozione della chiave;
  - chiave host cambiata → blocco.
- Verificato a mano:
  - riavvio del server: motore e Caddy ripartono da soli;
  - **turno di 20 s avviato via HTTP con il client subito scollegato**: completato sul server e visibile al
    ritorno del client.
- **Da fare:** aggiornamento del motore con controllo dei turni attivi (§5.5), Mac come server, login delle CLI.

### Fase 4 — scritta, non provata nell'app (2026-10-18)

- **Deviazione:** un motore alla volta. In cima alla barra laterale c'è un selettore (`EngineSwitcher`):
  "Questo Mac" o un server remoto. Cambiare motore ripunta il client (URL di chat, token) e ricarica lo
  stato; chat, bot, automazioni e connettori del server usano le viste di sempre, perché sono le stesse API.
  La barra laterale con i bot di più motori insieme e le notifiche dei motori non mostrati restano per dopo.
- `CompanionCore`: `Connection.scheme`/`basePath` (compatibili con le connessioni salvate),
  `Connection.remote(chatURL:)`, prefisso su ogni richiesta; `Client+Remote.swift` (dispositivi, codice di
  abbinamento, `claim`, `RemotePairingLink` = `swarmebot://pair?url=…&code=…&name=…`, senza token).
- `SwarmeKit`: `AppModel+Remote.swift` (scelta del motore ricordata, motivi leggibili quando lo stream cade,
  per esempio dispositivo revocato), `ServerSetupFlow` (la procedura come macchina a stati), `ServerTerminal`
  (Terminale già collegato con la chiave, per i login di `claude` e `pi`).
- App: `RemoteViews.swift` con selettore, Impostazioni › Server remoti, procedura guidata, "Collega con un
  codice", QR di abbinamento e dispositivi con revoca.
- Verificato: `ServerSetupFlowIntegrationTests` percorre la procedura su un server nuovo, dal modulo alla
  chat (fingerprint, password chiesta e poi dimenticata, sudo, servizio, token nel Portachiavi, salute e
  flotta via HTTP). `RemoteConnectionTests` e `RemotePairingLinkTests` verdi.
- **Non verificato:** l'app vera non è stata avviata. L'app di sviluppo usa sempre `~/.swarmebot` (su macOS
  `HOME` non lo sposta) e il Portachiavi dell'utente: va provata con il suo consenso.

