# Bot e connettori da cartelle condivise

Stato: implementato sul branch `feat/shared-bots-connectors` (2026-10-28).

## Comportamento

- Impostazioni → Condivisione: due cataloghi, due percorsi indipendenti, scelta cartella nativa,
  importazione multipla selettiva, pubblicazione dal Mac e aggiornamento manuale.
- Scorciatoia nella barra di Impostazioni → Connettori per aprire il catalogo MCP.
- `bots.json`: lista `{id, name, title?, description}`. Nome, ruolo e istruzioni sono centrali;
  ogni copia ha ID e conversazioni locali, modello, cartella di lavoro, avatar e permessi propri.
  Le modifiche del profilo vengono salvate nel catalogo; l'avatar non viene mai scritto lì.
- `mcp-connectors.json`: definizioni MCP portabili; segreti sostituiti da placeholder. Token OAuth,
  client scoperti, ultimo test e stato di attivazione non si condividono. Per pubblicare modifiche
  alla definizione si usa Condividi dal Mac; login e associazioni ai bot si gestiscono in Connettori.
- Aggiornamento prima delle automazioni al boot del motore e al collegamento iniziale dell'app locale,
  anche quando il motore era già avviato. Si aggiornano solo le copie selezionate in passato.
- Identità di provenienza `{folder, id}`: stessa voce senza duplicati, cambio cartella senza collegamenti
  accidentali. Conflitti con ID MCP locali rifiutati prima dell'importazione.
- Cartella non disponibile, catalogo invalido o voce rimossa: ultima copia locale conservata.
  Scollegare una cartella conserva copie e provenienza; per modificare un profilo condiviso occorre
  riselezionare la cartella originale. Nessuna cancellazione propagata.

## API aggiuntive

- `GET /api/shared-repositories/{bots|connectors}` → `{folder, fileName, entries, problem}`.
  Le entry espongono `{id, name, description, imported, conflict}`.
- `PUT /api/shared-repositories/{bots|connectors}` con `{folder: string|null}` imposta il percorso.
- `POST /api/shared-repositories/{bots|connectors}/import` con `{ids: [string]}` importa le selezioni.
- `POST /api/shared-repositories/{bots|connectors}/publish` con `{id: localId}` pubblica un record locale.
- `POST /api/shared-repositories/sync` con `{}` aggiorna le copie → `{problems: [string]}`.
- Mutazioni solo JSON; errori di validazione 400, conflitti 409, record inesistenti 404.
  I contratti precedenti restano invariati; i record importati aggiungono `sharedSource`.

## Verifica

- Test di integrazione in-process delle route: impostazioni, importazione selettiva, riavvio/sync,
  idempotenza, scrittura del profilo, conservazione di avatar/chat/modello, segreti locali,
  collisioni, cataloghi invalidi e cartelle scollegate/non disponibili.
- Suite Swift completa e test delle traduzioni.
- Build Docker aarch64 del motore e bundle Release macOS arm64.
- App avviata con SWARMEBOT_HOME e motore dedicato su 38991: catalogo reale letto via HTTP;
  verifica visiva della schermata Condivisione tramite snapshot.
- Parità Node non eseguita: non c'è un checkout del motore di riferimento; le nuove route
  hanno copertura di integrazione Swift. Login OAuth contro provider reale non eseguito.
- Interazioni con il selettore cartelle non automatizzate: accesso Computer Use all'app non autorizzato.
