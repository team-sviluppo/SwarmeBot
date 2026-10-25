# Copia su server e trasferimento dei bot

Data: 2026-10-25 · Branch: `feat/copy-to-remote`

## Obiettivo

1. Non dover ricreare a mano su un server i connettori MCP e le skill già definiti sul Mac.
2. Spostare un bot da questo Mac a un server, e viceversa (o tra due server), ricreandolo con la stessa
   identità; modello, skill e connettori si riconfigurano a mano con quelli disponibili in quell'ambiente.
3. Le automazioni del bot (routine e webhook) **si spostano**: create sulla destinazione ed eliminate
   dall'origine, così nessuna gira due volte.

## Punto di partenza

La copia di un singolo connettore (R14, `SwarmeKit/Remote/ConnectorCopy.swift`, con i segreti letti da
`mcp-connector-secrets.json`) e di una singola skill (`AppModel.copySkill`) su un server esisteva già, dal
dettaglio di ciascuno in Impostazioni. Mancavano la copia di più elementi insieme e lo spostamento dei bot.

## Decisioni

- **Tutto lato app, nessuna route nuova.** L'app parla con entrambi i motori (`client` per quello mostrato,
  `peerClient` per gli altri) con le route che già esistono (`POST /api/bots`, `PATCH`, avatar, routine,
  webhook). Il contratto non cambia, quindi niente scenario di parity nuovo.
- **Cosa passa del bot:** nome, titolo, descrizione (le istruzioni), colore, notifiche, silhouette ed
  espressione della mascotte, immagine (SVG, oppure il raster scaricato dagli allegati dell'origine; per uno
  sprite sheet anche la riga).
- **Cosa resta indietro** (appartiene all'ambiente): modello, skill, connettori, cartella di lavoro, computer,
  auto-approvazione e permessi "consenti sempre", ruolo di Chief of Staff, sezione, grant del vault, documenti
  della libreria, appartenenza ai canali. **Le chat non si spostano.**
- **Ordine sicuro:** prima si crea tutto sulla destinazione (bot, routine, webhook); se un passo fallisce si
  cancella quanto creato lì e l'origine resta com'era. Solo dopo si eliminano routine e webhook dall'origine e,
  se richiesto, il bot. Un errore in questa seconda fase non annulla lo spostamento: diventa un avviso.
- **Webhook:** sulla destinazione nasce con un nuovo URL e un nuovo segreto (appartengono al motore che lo
  riceve); il foglio finale li mostra una volta, da copiare dove il webhook viene chiamato. Se la destinazione
  non ha un indirizzo pubblico per i webhook lo si dice.
- **Routine "una volta" già passata:** arriva spenta, altrimenti la destinazione la eseguirebbe subito.
- **Eliminare il bot originale** è un interruttore del foglio, acceso di default (è uno spostamento); spento,
  il bot resta sull'origine senza automazioni.
- **Copia multipla connettori/skill:** "Copia su server…" in Impostazioni › Connettori e › Skill apre lo stesso
  foglio con entrambe le liste. Spuntati di default i connettori HTTP e tutte le skill; gli stdio si possono
  copiare (il server li prova subito) ma partono non spuntati, perché usano un comando di questo Mac; gli OAuth
  non si copiano (token per motore). Quanto esiste già sul server viene segnalato e sostituito. Ogni elemento va
  per conto suo: uno che fallisce non ferma gli altri.

## Dove

- `SwarmeKit/BotTransfer.swift` — `BotTransfer.move`, `AppModel.move(_:to:deleteOriginal:)`, `transferTargets`.
- `SwarmeKit/Remote/ServerCopy.swift` — `AppModel.copyToServer`, `serverInventory`.
- `SwarmeBot/Views/BotTransferViews.swift` — foglio di conferma/esito, aperto dal menu "Trasferisci su ›" dei
  bot del motore mostrato (`SidebarView`).
- `SwarmeBot/Views/ServerCopyViews.swift` — foglio "Copia su server…".
- `CompanionCore/Automation.swift` — `RoutineInput.runOn`, `WebhookInput.runOn` e `verificationPending`, per non
  perdere questi campi nella copia.

## Progresso

- [x] Spostamento di un bot con routine, webhook e immagine.
- [x] Copia multipla di connettori e skill su un server.
- [x] Traduzioni inglesi (`Translations+Transfer.swift`).

Verificato:
- `BotTransferTests`: due motori `swarme-harness` usa e getta su porte proprie; un bot con SVG, una routine e un
  webhook passa dall'uno all'altro (identità, routine e webhook puntati al nuovo bot, nuovo segreto restituito),
  sull'origine restano solo le automazioni degli altri bot; uno spostamento che fallisce (immagine non
  scaricabile) lascia entrambi i motori com'erano. Più i test unitari su routine passate e campi copiati.
- `swift build` senza warning nuovi, `swift test` verde, `LocalizationTests` verde.

Non verificato:
- I due fogli nell'app avviata: si aprono da menu e pulsanti, e lo snapshot (`SWARMEBOT_SNAPSHOT`) non li
  raggiunge senza interazione.
- Lo spostamento verso un vero server remoto via HTTPS (il codice è lo stesso client, con il token del
  dispositivo); la copia multipla riusa le copie singole già provate su server reale (vedi i piani bot-remoto e
  skill).
