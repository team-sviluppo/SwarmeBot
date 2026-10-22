# Relay delle notifiche push (`swarme-push-relay`)

Il relay è l'unico posto dove sta la chiave REST di OneSignal. Il motore SwarmeBot e il telefono non la vedono
mai. Progetto e motivazioni sono in `docs/plans/2026-10-22-app-ios.md` §6.

```
iPhone ──► relay   POST /v1/register {subscriptionId}           → {pushToken}
iPhone ──► motore  POST /api/push/subscriptions {pushToken, relayUrl}
motore ──► relay   POST /v1/notify {pushToken, title{en,it}, category, data}
relay  ──► OneSignal REST ──► APNs ──► iPhone
```

## Cosa garantisce

- **Nessun database.** Il `pushToken` è l'id della sottoscrizione OneSignal più un HMAC fatto con il segreto del
  relay: chi ha un token può mandare push solo al telefono che l'ha registrato.
- **Nessun testo della chat.** Il motore manda solo il nome del bot e cosa è successo ("Sage ha finito", "Sage
  chiede un'approvazione"), più gli id per aprire la chat. Il relay accetta un titolo di 200 caratteri al massimo
  e `data` fino a 2 KB.
- **Un limite per token:** 120 push all'ora (`RELAY_HOURLY_LIMIT`).
- **Revoca.** Revocare un dispositivo sul motore cancella le sue sottoscrizioni. Per cambiare il segreto del
  relay basta riavviarlo con uno nuovo: tutti i token smettono di valere, e i telefoni si registrano di nuovo
  alla prossima apertura dell'app.

## Installarne uno proprio

Le push di Apple sono legate all'app che le riceve, cioè al bundle ID e alla chiave APNs. Un relay proprio
serve quindi solo con **una build propria dell'app iOS**.

1. **App iOS.** Nell'account Apple Developer, un App ID con Push Notifications e una chiave APNs (.p8).
2. **OneSignal.** Un'app OneSignal configurata con quella chiave APNs. Annota l'App ID e la REST API key.
3. **Relay.** Su un server, dietro un proxy HTTPS (per esempio Caddy, come il motore remoto):
   ```sh
   swift build -c release --product swarme-push-relay
   ONESIGNAL_APP_ID=… ONESIGNAL_API_KEY=… RELAY_SECRET="$(openssl rand -hex 32)" \
     .build/release/swarme-push-relay --port 8920        # oppure --socket /run/swarme-push/relay.sock
   ```
   Il relay ascolta solo su loopback o su un socket unix: l'HTTPS lo fa il proxy. Su Linux compila come il
   motore (`scripts/build-linux-engine.sh` usa la stessa immagine `swift:6.4-noble`).
4. **Build dell'app.** In `iOS/Local.xcconfig`, che git ignora:
   ```
   DEVELOPMENT_TEAM = <team>
   SWARMEBOT_BUNDLE_ID = <il tuo bundle>
   SWARMEBOT_PUSH_APP_ID = <OneSignal App ID>
   SWARMEBOT_PUSH_RELAY = https:/$()/push.example.com
   ```
   Nei file xcconfig `//` apre un commento: `$()` serve a tenere intero l'URL.

Senza `SWARMEBOT_PUSH_APP_ID` e `SWARMEBOT_PUSH_RELAY` l'app non registra niente da nessuna parte, e le push
restano spente.

## API

| Metodo | Percorso | Corpo | Risposta |
|---|---|---|---|
| GET | `/health` | — | `{app, ok}` |
| POST | `/v1/register` | `{subscriptionId}` | 201 `{pushToken}`; 400 se l'id non è valido |
| POST | `/v1/notify` | `{pushToken, title:{en, it?}, category?:"approval"\|"chat", data?}` | `{ok:true}`; 401 token sconosciuto, 429 troppe push, 502 errore di OneSignal |

Variabili d'ambiente:
- obbligatorie: `ONESIGNAL_APP_ID`, `ONESIGNAL_API_KEY`, `RELAY_SECRET` (almeno 32 byte);
- facoltative: `ONESIGNAL_API` (per i test), `RELAY_HOURLY_LIMIT`.
