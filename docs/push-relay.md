# Relay delle notifiche push (`swarme-push-relay`)

Il relay è l'unico posto dove stanno le credenziali AWS. Il motore SwarmeBot e il telefono non le vedono
mai, e la chiave APNs di Apple non è nemmeno sul relay: sta su AWS, nelle applicazioni SNS. Progetto e
motivazioni sono in `docs/plans/2026-10-22-app-ios.md` §6.

```
iPhone ──► relay   POST /v1/register {deviceToken, environment, language}   → {pushToken}
iPhone ──► motore  POST /api/push/subscriptions {pushToken, relayUrl}
motore ──► relay   POST /v1/notify {pushToken, title{en,it}, category, data}
relay  ──► Amazon SNS (Publish) ──► APNs ──► iPhone
```

Il provider era OneSignal; è stato sostituito da Amazon SNS per il free tier (1 milione di push mobili al
mese). Il contratto tra motore e relay (`/v1/notify`) e le rotte `/api/push/subscriptions` non sono cambiati.

## Cosa garantisce

- **Nessun database.** Il `pushToken` è `v2.<ambiente>.<lingua>.<id endpoint SNS>.<HMAC>`: l'HMAC è fatto con
  il segreto del relay, quindi chi ha un token può mandare push solo al telefono che l'ha registrato.
- **Nessun testo della chat.** Il motore manda solo il nome del bot e cosa è successo ("Sage ha finito", "Sage
  chiede un'approvazione"), più gli id per aprire la chat. Il relay accetta un titolo di 200 caratteri al massimo
  e `data` fino a 2 KB.
- **Limiti:** 120 push all'ora per token (`RELAY_HOURLY_LIMIT`) e 300 registrazioni all'ora per tutto il
  relay (`RELAY_REGISTER_LIMIT`: ogni registrazione può creare un endpoint SNS).
- **Lingua.** Il telefono dice al relay la lingua scelta nell'app (Impostazioni › Generale), e il relay manda
  il titolo in quella lingua. Se la cambi, l'app si registra di nuovo.
- **Revoca.** Revocare un dispositivo sul motore cancella le sue sottoscrizioni. Il motore cancella da solo
  una sottoscrizione quando il relay risponde 401 (token che non è suo) o 410 (endpoint SNS disabilitato da
  APNs): il telefono si registra di nuovo all'apertura dell'app. Per cambiare il segreto del relay basta
  riavviarlo con uno nuovo: tutti i token smettono di valere.

## Installarne uno proprio

Le push di Apple sono legate all'app che le riceve, cioè al bundle ID e alla chiave APNs. Un relay proprio
serve quindi solo con **una build propria dell'app iOS**.

### 1. Apple Developer

Un App ID con Push Notifications e una chiave APNs (.p8). Annota **Key ID**, **Team ID** e il **Bundle ID**.

### 2. AWS (console)

Tutto nella stessa region (la region sta nell'ARN, il relay la ricava da lì).

1. **SNS › Mobile › Push notifications › Create platform application**, due volte, con autenticazione
   **Token**, la `.p8`, Key ID, Team ID e Bundle ID:
   - `swarmebot-ios`, piattaforma *Apple iOS* (produzione: TestFlight e App Store);
   - `swarmebot-ios-sandbox`, piattaforma *Apple iOS Sandbox* (build lanciate da Xcode su un telefono).

   Annota i due ARN. Ne basta uno solo se ti serve un solo ambiente.
2. **IAM › Policies**: una policy per il relay, con solo questo (sostituisci `REGION` e `ACCOUNT`):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Effect": "Allow", "Action": "sns:CreatePlatformEndpoint",
         "Resource": ["arn:aws:sns:REGION:ACCOUNT:app/APNS/swarmebot-ios",
                      "arn:aws:sns:REGION:ACCOUNT:app/APNS_SANDBOX/swarmebot-ios-sandbox"] },
       { "Effect": "Allow",
         "Action": ["sns:Publish", "sns:GetEndpointAttributes", "sns:SetEndpointAttributes", "sns:DeleteEndpoint"],
         "Resource": ["arn:aws:sns:REGION:ACCOUNT:endpoint/APNS/swarmebot-ios/*",
                      "arn:aws:sns:REGION:ACCOUNT:endpoint/APNS_SANDBOX/swarmebot-ios-sandbox/*"] }
     ]
   }
   ```
3. **IAM › Users**: un utente solo per il relay, senza accesso alla console, con quella policy, e una
   **access key** (use case: *Application running outside AWS*). La secret key si vede una volta sola.
4. Facoltativo: un budget in Billing, e il delivery status logging dei soli fallimenti sulle platform
   application (CloudWatch), per capire perché una push non parte.

### 3. Relay

Il modo più semplice è ospitarlo accanto a un motore remoto, dallo stesso Mac che lo amministra:
Impostazioni › Server remoti › Azioni › **Ospita il relay delle notifiche push…**, con gli ARN delle
applicazioni SNS, l'access key ID e la secret access key.
- Il relay è lo stesso programma del motore (`swarme-harness push-relay serve`): non c'è un binario in più e
  si aggiorna con il motore.
- Gira come servizio suo: `swarmebot-push.service` utente su Linux, LaunchDaemon `it.swarmebot.push.<utente>`
  su Mac.
- Risponde su `<URL di chat>/push`, nello stesso Caddy.
- Le chiavi vanno in `~/.swarmebot/push-relay.json` (0600), mai nei segreti del motore, che arrivano agli
  agenti. Il segreto del relay nasce sul server e resta lì; reinstallare con chiavi nuove lo conserva.
- Va su **un solo** server: la chiave AWS manda push a tutti i telefoni con l'app.

Oppure, a mano, su un server qualsiasi dietro un proxy HTTPS (per esempio Caddy, come il motore remoto):
```sh
swift build -c release --product swarme-push-relay
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… \
SNS_APNS_APP_ARN=arn:aws:sns:…:app/APNS/swarmebot-ios \
SNS_APNS_SANDBOX_APP_ARN=arn:aws:sns:…:app/APNS_SANDBOX/swarmebot-ios-sandbox \
RELAY_SECRET="$(openssl rand -hex 32)" \
  .build/release/swarme-push-relay --port 8920        # oppure --socket /run/swarme-push/relay.sock
```
Il relay ascolta solo su loopback o su un socket unix: l'HTTPS lo fa il proxy. Lo stesso relay gira anche come
`swarme-harness push-relay serve`; `swarme-harness push-relay configure` legge
`{accessKeyId, secretAccessKey, appArn, sandboxAppArn}` da stdin. Su Linux compila come il motore
(`scripts/build-linux-engine.sh` usa la stessa immagine `swift:6.4-noble`).

### 4. Build dell'app

In `iOS/Local.xcconfig`, che git ignora:
```
DEVELOPMENT_TEAM = <team>
SWARMEBOT_BUNDLE_ID = <il tuo bundle>
SWARMEBOT_PUSH_RELAY = https:/$()/push.example.com
```
Nei file xcconfig `//` apre un commento: `$()` serve a tenere intero l'URL.

Senza `SWARMEBOT_PUSH_RELAY` l'app non registra niente da nessuna parte, e le push restano spente.

L'app dice al relay se la build usa il APNs sandbox o quello di produzione leggendo il profilo di firma
(`embedded.mobileprovision`): una build firmata per lo sviluppo usa l'applicazione sandbox, TestFlight e App
Store quella di produzione.

## API

| Metodo | Percorso | Corpo | Risposta |
|---|---|---|---|
| GET | `/health` | — | `{app, ok}` |
| POST | `/v1/register` | `{deviceToken, environment?:"production"\|"sandbox", language?:"en"\|"it"}` | 201 `{pushToken}`; 400 token o ambiente non validi, o ambiente non configurato; 429 troppe registrazioni; 502 errore di AWS |
| POST | `/v1/notify` | `{pushToken, title:{en, it?}, category?:"approval"\|"chat", data?}` | `{ok:true}`; 401 token sconosciuto, 410 endpoint SNS disabilitato o cancellato, 429 troppe push, 502 errore di AWS |

`/v1/register` è idempotente: lo stesso device token dà lo stesso `pushToken`, e se APNs aveva disabilitato
l'endpoint SNS lo riattiva.

Variabili d'ambiente:
- obbligatorie: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `RELAY_SECRET` (almeno 32 byte) e almeno una
  tra `SNS_APNS_APP_ARN` e `SNS_APNS_SANDBOX_APP_ARN`;
- facoltative: `SNS_ENDPOINT` (per i test), `RELAY_HOURLY_LIMIT`, `RELAY_REGISTER_LIMIT`.

Le stesse chiavi stanno in `push-relay.json` con i nomi `accessKeyId`, `secretAccessKey`, `appArn`,
`sandboxAppArn`, `secret`; l'ambiente prevale sul file.

## Passare da OneSignal

Un `push-relay.json` con `appId` e `apiKey` (quello di OneSignal) non è più una configurazione valida e il
relay non parte finché non si rifanno le chiavi dal Mac (**Aggiorna le chiavi**): il segreto del relay si
conserva. I vecchi token `v1` rispondono 401, il motore cancella quelle sottoscrizioni alla prima push, e i
telefoni con la build nuova si registrano da soli all'apertura dell'app. Le build con OneSignal non ricevono
più push.
