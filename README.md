# SwarmeBot per macOS (nativo)

App SwiftUI che sostituisce la shell Electron di SwarmeBot. Implementa la **fase 0 e la base
della fase 1a** del piano `docs/plans/2026-10-13-swift-native-macos-analisi.md`: UI nativa
sopra il harness Node esistente, che resta invariato.

## Avvio in sviluppo

```sh
swift run SwarmeBot          # oppure: swift build && .build/debug/SwarmeBot
swift test                   # 112 test (CompanionCore + SwarmeKit)
```

All'avvio l'app cerca un harness in quest'ordine:

1. `SWARMEBOT_HARNESS_URL=http://127.0.0.1:8799` → si collega, non avvia niente;
2. un harness SwarmeBot già attivo su 8799/18799/28799 (es. l'app Electron) → si collega,
   per non avere due harness che scrivono su `~/.swarmebot`;
3. harness incorporato nel bundle (`Contents/Helpers/node` + `Resources/server`);
4. checkout di sviluppo: `SWARMEBOT_REPO` (default `../SwarmeBot`), avviato con il `node`
   della login shell su `server/index.ts` (`SWARMEBOT_HARNESS_DIST=1` per usare `dist-server`).

Il harness avviato dall'app viene fermato all'uscita (anche su SIGTERM/Ctrl-C) e, se l'app
muore con SIGKILL, si chiude da solo entro ~2 s (watchdog sul processo padre precaricato
con `--import`). Log: `~/Library/Logs/SwarmeBot/server.log`.

`SWARMEBOT_SNAPSHOT=/percorso.png` scrive uno screenshot della finestra dopo 10 s
(`SWARMEBOT_SNAPSHOT_DELAY`): non richiede il permesso di registrazione schermo.

## Pacchetto `.app`

```sh
scripts/bundle-app.sh                                # solo app, harness da SWARMEBOT_REPO
scripts/bundle-app.sh --with-harness --arch arm64 --dmg   # autonoma: 131 MB, DMG 48 MB
scripts/bundle-app.sh --with-harness --arch x86_64 --dmg  # SwarmeBot-intel.dmg
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=… SPARKLE_PUBLIC_KEY=… \
  scripts/bundle-app.sh --with-harness --arch arm64 --dmg --notarize
```

Il `node` di Homebrew non è incorporabile (linka libnode/libuv/abseil da `/opt/homebrew`),
per questo lo script scarica la build ufficiale. 

## Struttura

| Target | Contenuto |
|---|---|
| `CompanionCore` | tipi wire, parser SSE, client HTTP, fold puro dello stato — copiato dall'app iOS, vedi `docs/companion-core-divergence.md` |
| `SwarmeKit` | `HarnessLauncher` (avvio/supervisione/arresto del harness), `AppModel` osservabile (stream, riconnessione, azioni) |
| `SwarmeBot` | app SwiftUI: sidebar a sezioni, transcript, composer, card approvazione/domanda, model picker con effort, inspector, impostazioni |

Contratto HTTP/SSE congelato: `docs/contract/http-sse.md`.

## Stato rispetto al piano

**Fase 0 e fase 1 (app nativa sopra il harness): completate.**

| Area | Cosa c'è |
|---|---|
| Shell | avvio/supervisione harness, chiusura pulita anche su SIGTERM/SIGKILL, notifiche di sistema, badge e menu del Dock, Sparkle 2, bundle firmato, DMG, notarizzazione (`--notarize`) |
| Sidebar | sezioni utente, fissati, non letti, nascosti, menu contestuale, ricerca, nuovo bot/canale |
| Chat | streaming e ragionamento, card permesso/domanda (anche scelta multipla), modifica e reinvio con versioni ‹ 1/3 ›, messaggi in coda/interrotti, reazioni, allegati visualizzati, task (crea, cambia, rinomina, fissa, elimina, costo) |
| Composer | ⏎/⇧⏎, stop, allegati (incolla immagini, trascina file, pulsante +, testo lungo come chip), @menzioni nei canali, scelta modello con effort |
| Canali | creazione, impostazioni (nome, bacheca, membri, chi risponde), eliminazione |
| ⌘K | chat, comandi e ricerca nei messaggi con salto al messaggio |
| Inspector | Dettagli (persona, auto, notifiche, cartella di lavoro), Libreria (PDF e file di testo del bot, attivabili chat per chat), Computer (VM locale, Box cloud con desktop in WKWebView, presa di controllo, anteprima di questo Mac via ScreenCaptureKit) |
| Automazioni (⇧⌘R) | routine con calendario, esecuzioni e annullamento; webhook con URL privato mostrato una volta, rotazione, test, consegne |
| Libreria team | import da GitHub o file, export |
| Impostazioni | profilo, timeout canali, motori (eseguibile, prova, visibilità, installazione e login via Terminale), chiavi nel Portachiavi con import da Electron, Local Endpoint, VPS, DeepSeek Harness, aggiornamenti |

Rischio R1 (transcript lungo) misurato e chiuso: `docs/benchmarks/r1-transcript.md`.

### Test

```sh
swift test                      # unità: CompanionCore + SwarmeKit
scripts/integration-test.sh     # tutte le route desktop contro un harness su data dir temporanea
SWARMEBOT_BENCH=5000 .build/release/SwarmeBot   # benchmark transcript
```

### Non ancora verificato dal vivo

- Invio di messaggi e turni reali (allegati inclusi): le route sono coperte dai test di
  integrazione, ma i test non avviano turni per non usare i modelli.
- Import credenziali da Electron: la decifratura è testata contro un vettore indipendente, non
  sul vero `credentials.bin` (macOS chiederà il permesso al primo uso).
- Notarizzazione e aggiornamento Sparkle end-to-end: servono l'identità Developer ID, un profilo
  `notarytool` e la coppia di chiavi EdDSA (`generate_keys` di Sparkle).

### Fase 2 — motore Swift (anteprima)

`swarme-harness` reimplementa il harness con lo stesso contratto HTTP/SSE. Si sceglie in
Impostazioni › Motore e lavora su una copia dei dati. Oggi: chat 1:1, task, versioni, coda,
approvazioni, libreria, ricerca, export, gestione canali e il motore Local Endpoint; gli altri
motori risultano "non ancora disponibili". Stato e verifiche: `docs/plans/fase-2-architettura.md`.

```sh
OMB_PORT=38899 OMB_DATA_DIR=/tmp/swarme swift run swarme-harness   # a mano
parity/compare.sh                       # parità Node ↔ Swift (anche SCENARIO=advanced)
```
