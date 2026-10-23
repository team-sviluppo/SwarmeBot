// English for remote servers: Settings › Server remoti, setup, pairing, devices, remote admin.
extension Translations {
    static let remote: [String: String] = [
        "Relay delle notifiche push: %@": "Push notification relay: %@",
        "Ospita il relay delle notifiche push…": "Host the Push Notification Relay…",
        "Relay delle notifiche push su %@": "Push Notification Relay on %@",
        "Il relay manda le push dell'app iOS tramite OneSignal. Gira con lo stesso programma del motore, che lo aggiorna insieme a sé, e risponde in HTTPS su %@/push. Va installato su un solo server: la chiave REST di OneSignal può mandare push a tutti i telefoni con l'app, quindi resta solo lì, in un file leggibile dal suo utente.": "The relay sends the iOS app's pushes through OneSignal. It runs as the same program as the engine, which updates it along with itself, and answers over HTTPS at %@/push. Install it on one server only: the OneSignal REST key can push to every phone with the app, so it stays there alone, in a file only its user can read.",
        "Relay attivo": "Relay Running",
        "Nella build dell'app iOS (iOS/Local.xcconfig o Shared.xcconfig) metti:": "In the iOS app's build (iOS/Local.xcconfig or Shared.xcconfig) set:",
        "OneSignal App ID": "OneSignal App ID",
        "OneSignal REST API key": "OneSignal REST API key",
        "Password di sudo di %@ (se il server la chiede)": "sudo password of %@ (if the server asks for one)",
        "Installo il relay sul server…": "Installing the relay on the server…",
        "Aggiorna le chiavi": "Update Keys",
        "Di %@ non conosco il sito Caddy: rifai la configurazione del server da questo Mac": "I don't know %@'s Caddy site: set the server up again from this Mac",
        "L'URL del relay non è valido": "The relay URL is not valid",
        "Il relay è installato, ma %@ non risponde da qui (%@)": "The relay is installed, but %@ does not answer from here (%@)",
        "nessuna risposta": "no answer",
        // Settings › Server remoti
        "Nessun server. Un bot su un server continua a lavorare anche a Mac spento, e lo ritrovi qui o sul telefono.":
            "No servers. A bot on a server keeps working even with your Mac off, and you'll find it here or on your phone.",
        "Amministrato da questo Mac come %@": "Administered from this Mac as %@",
        "Installo Claude Code e omp sul server…": "Installing Claude Code and omp on the server…",
        "Azioni": "Actions",
        "Mostra i suoi bot": "Show its bots",
        "Abbina un telefono o un altro Mac…": "Pair a phone or another Mac…",
        "Dispositivi abbinati…": "Paired devices…",
        "Configura Claude Code e omp": "Set up Claude Code and omp",
        "Login di Claude sul server…": "Claude login on the server…",
        "Copia la configurazione di pi…": "Copy pi configuration…",
        "Apri un terminale sul server": "Open a terminal on the server",
        "Dimentica su questo Mac…": "Forget on this Mac…",
        "Server remoti": "Remote servers",
        "Il Mac amministra il server via ssh; la chat passa sempre in HTTPS con un token di questo dispositivo.":
            "This Mac administers the server over ssh; chats always go over HTTPS with this device's token.",
        "Aggiungi un server…": "Add a server…",
        "Collega un server con un codice…": "Connect a server with a code…",
        "Copiare la configurazione di pi su %@?": "Copy the pi configuration to %@?",
        "Copia": "Copy",
        "Copiati su %@: %@": "Copied to %@: %@",
        "auth.json, models.json e settings.json di ~/.pi/agent vanno sul server, leggibili solo dal suo utente. Contengono le chiavi API dei tuoi provider. I file già presenti sul server restano come copia di backup.":
            "auth.json, models.json and settings.json from ~/.pi/agent go to the server, readable only by its user. They contain your providers' API keys. Files already on the server are kept as a backup copy.",
        "OK": "OK",
        "Dimenticare %@?": "Forget %@?",
        "Dimentica": "Forget",
        "Il server e i suoi bot continuano a funzionare; questo Mac non lo mostra più. Il dispositivo resta abbinato finché non lo revochi.":
            "The server and its bots keep running; this Mac no longer shows it. The device stays paired until you revoke it.",

        // Setup walk-through
        "Aggiungi un server": "Add a server",
        "Chiudi": "Close",
        "Server (amministrazione via ssh)": "Server (administration over ssh)",
        "Nome da mostrare": "Display name",
        "Server": "Server",
        "10.0.4.12 o vps1.example.it": "10.0.4.12 or vps1.example.it",
        "Porta ssh": "ssh port",
        "Utente": "User",
        "Sito Caddy": "Caddy site",
        "bot.example.it, oppure :8080 dietro un proxy": "bot.example.it, or :8080 behind a proxy",
        "Prefisso": "Prefix",
        "Certificato": "Certificate",
        "Pubblico (Let's Encrypt)": "Public (Let's Encrypt)",
        "Nessuno: dietro un proxy HTTPS": "None: behind an HTTPS proxy",
        "URL di chat (se c'è un proxy davanti)": "Chat URL (if a proxy is in front)",
        "Chat (HTTPS)": "Chat (HTTPS)",
        "I dispositivi usano solo questo URL: %@": "Devices use only this URL: %@",
        "Confronta il fingerprint con quello mostrato dalla console del server:":
            "Compare the fingerprint with the one shown on the server's console:",
        "È quello giusto: approva": "It matches: approve",
        "Password ssh di %@": "ssh password for %@",
        "Serve una volta sola, per installare la chiave dedicata di questo Mac. Non viene salvata.":
            "Needed only once, to install this Mac's dedicated key. It is not saved.",
        "Password di sudo": "sudo password",
        "Per i passi di root qui sotto. Non viene salvata.": "For the root steps below. It is not saved.",
        "Comandi eseguiti come root": "Commands run as root",
        "%@ %@ · %@ · Claude: %@ · pi: %@": "%@ %@ · %@ · Claude: %@ · pi: %@",
        "non installato": "not installed",
        "Avanzamento": "Progress",
        "Mostra i bot del server": "Show the server's bots",
        "Collegati": "Connect",
        "Continua": "Continue",

        // Setup steps and errors (ServerSetupFlow)
        "Fingerprint del server": "Server fingerprint",
        "Chiave dedicata": "Dedicated key",
        "Controllo del server": "Server check",
        "Caddy, cartella dei socket, avvio automatico (root)": "Caddy, socket folder, automatic start (root)",
        "Motore SwarmeBot": "SwarmeBot engine",
        "Servizio e rotte HTTPS": "Service and HTTPS routes",
        "Token di questo Mac": "This Mac's token",
        "Claude Code e omp": "Claude Code and omp",
        "Pronto": "Ready",
        "Indica server e utente": "Enter the server and user",
        "Indica il dominio (o :porta) su cui Caddy risponde": "Enter the domain (or :port) Caddy answers on",
        "L'URL di chat non è valido": "The chat URL is not valid",
        "# poi, per le rotte:": "# then, for the routes:",
        "Password non accettata": "Password not accepted",
        "macOS %@: serve macOS 14 o successivo": "macOS %@: macOS 14 or later is required",
        "Server %@ %@: servono Ubuntu 24.04 o 26.04 (o un Mac)": "Server %@ %@: Ubuntu 24.04 or 26.04 (or a Mac) is required",
        "Architettura %@ non supportata": "Architecture %@ is not supported",
        "L'utente %@ non può usare sudo: serve root una volta sola per Caddy e l'avvio automatico":
            "User %@ can't use sudo: root is needed once for Caddy and the automatic start",
        "Il motore di questa app non è per Mac %@: usa la build dell'app per quell'architettura":
            "This app's engine is not for %@ Macs: use the app build for that architecture",
        "Scarico e verifico il motore Linux %@…": "Downloading and verifying the Linux %@ engine…",
        "all'URL di chat risponde un altro servizio": "another service answers at the chat URL",
        "Server pronto, ma l'URL di chat %@ non risponde da qui: %@. Se c'è un proxy davanti, configuralo e riprova.":
            "The server is ready, but the chat URL %@ does not answer from here: %@. If a proxy is in front, configure it and try again.",
        "Attendo il certificato di Let's Encrypt…": "Waiting for the Let's Encrypt certificate…",

        // Pairing and devices
        "Collega un server con un codice": "Connect a server with a code",
        "Su un dispositivo già abbinato: Server remoti › Abbina un telefono o un altro Mac. Copia qui l'URL e il codice.":
            "On a device that is already paired: Remote servers › Pair a phone or another Mac. Copy the URL and the code here.",
        "URL di chat": "Chat URL",
        "Codice": "Code",
        "Annulla": "Cancel",
        "Collega": "Connect",
        "Abbina un dispositivo a %@": "Pair a device with %@",
        "Codice: %@": "Code: %@",
        "URL: %@": "URL: %@",
        "Vale 10 minuti e una volta sola. Il QR non contiene il token.":
            "Valid for 10 minutes and only once. The QR code does not contain the token.",
        "Dispositivi abbinati a %@": "Devices paired with %@",
        " (questo Mac)": " (this Mac)",
        "Visto %@": "Seen %@",
        "Revoca": "Revoke",

        // Claude login on a server
        "Login di Claude su %@": "Claude login on %@",
        "Nel Terminale di questo Mac esegui il comando qui sotto e accedi con il tuo abbonamento; poi incolla il token che stampa. Il token resta sul server in un file leggibile solo dal suo utente, e nel Portachiavi di questo Mac per i prossimi server che configuri.":
            "In this Mac's Terminal, run the command below and sign in with your subscription; then paste the token it prints. The token stays on the server in a file readable only by its user, and in this Mac's Keychain for the next servers you set up.",
        "sk-ant-…": "sk-ant-…",
        "Salva sul server": "Save on the server",

        // Engine updates
        "Aggiorno il motore…": "Updating the engine…",
        "Motore non installato": "Engine not installed",
        "Aggiornamento del motore disponibile": "Engine update available",
        "Aggiorna motore": "Update engine",
        "Motore aggiornato": "Engine up to date",
        "Controllo il motore…": "Checking the engine…",
        "Aggiornare adesso?": "Update now?",
        "Aggiorna e interrompi": "Update and interrupt",
        "Stanno lavorando: %@. L'aggiornamento riavvia il motore e interrompe i loro turni.":
            "Still working: %@. The update restarts the engine and interrupts their turns.",

        // AppModel+Remote
        "Questo Mac": "This Mac",
        "Motore non raggiungibile: il bot non è stato creato": "Engine not reachable: the bot was not created",
        "Avvio del motore di questo Mac…": "Starting this Mac's engine…",
        "Server remoto non configurato correttamente": "Remote server not configured correctly",
        "Questo Mac non ha un token per %@: abbinalo di nuovo da Impostazioni › Server remoti":
            "This Mac has no token for %@: pair it again from Settings › Remote servers",
        "%@ non riconosce più questo Mac (dispositivo revocato?): abbinalo di nuovo da Impostazioni › Server remoti":
            "%@ no longer recognizes this Mac (device revoked?): pair it again from Settings › Remote servers",
        "%@ non raggiungibile: %@. Il server continua a lavorare; mi ricollego da solo.":
            "%@ not reachable: %@. The server keeps working; I'll reconnect on my own.",
        "L'indirizzo deve essere l'URL https del server, per esempio https://bot.example.it/srv1/deploy":
            "The address must be the server's https URL, for example https://bot.example.it/srv1/deploy",
        "Questo Mac non amministra %@: il token si imposta dal Mac che lo ha configurato":
            "This Mac does not administer %@: set the token from the Mac that set it up",
        "Stanno lavorando: %@. Aggiornare adesso interrompe i loro turni.":
            "Still working: %@. Updating now interrupts their turns.",
        "Questo Mac non amministra %@: l'aggiornamento si fa dal Mac che lo ha configurato":
            "This Mac does not administer %@: update it from the Mac that set it up",
        "Il motore aggiornato non risponde: controlla il server (Apri un terminale sul server)":
            "The updated engine does not answer: check the server (Open a terminal on the server)",
        "Il motore su %@ è di un'altra versione (contratto %@, questa app parla %@): aggiornalo da Impostazioni › Server remoti":
            "The engine on %@ is a different version (contract %@, this app speaks %@): update it from Settings › Remote servers",

        // Agents on a server (ServerAgents)
        "Non riesco a leggere %@": "Can't read %@",
        "Copia di %@ non riuscita (%@)": "Copying %@ failed (%@)",
        "Non sembra un token di claude setup-token (inizia con sk-ant-)":
            "This doesn't look like a claude setup-token token (it starts with sk-ant-)",
        "Claude Code %@: login con il token salvato su questo Mac": "Claude Code %@: logged in with the token saved on this Mac",
        "Claude Code %@: manca il login (menu del server › Login di Claude sul server…)":
            "Claude Code %@: not logged in (server menu › Claude login on the server…)",
        "%@: configurazione di questo Mac copiata (%@), usato dai bot con pi":
            "%@: this Mac's configuration copied (%@), used by bots with pi",
        "omp: c'è la configurazione ma non il programma su questo Mac, quindi non so quale versione installare":
            "omp: the configuration is on this Mac but the program is not, so I don't know which version to install",

        // RemoteAdmin
        "Indirizzo del sito Caddy non valido: un dominio (bot.example.it) o :porta":
            "Invalid Caddy site address: a domain (bot.example.it) or :port",
        "Il prefisso deve essere un percorso come /srv1/deploy": "The prefix must be a path like /srv1/deploy",
        "Un certificato pubblico richiede un dominio, non solo una porta": "A public certificate needs a domain, not just a port",
        "La chiave è stata aggiunta, ma il server non la accetta: controlla PubkeyAuthentication in sshd":
            "The key was added, but the server doesn't accept it: check PubkeyAuthentication in sshd",
        "Risposta inattesa dal server": "Unexpected response from the server",
        "Serve la password di sudo": "The sudo password is required",
        "Password di sudo non accettata: serve la password dell'utente %@ sul server": "sudo password not accepted: it must be the password of the user %@ on the server",
        "L'utente %@ non può usare sudo: serve root una volta per Caddy e il servizio":
            "User %@ can't use sudo: root is needed once for Caddy and the service",
        "Su questo Mac non c'è una configurazione di pi (%@)": "There is no pi configuration on this Mac (%@)",
        "omp non ha una build per %@ %@": "omp has no build for %@ %@",
        "Su questo Mac non c'è una configurazione di omp (%@)": "There is no omp configuration on this Mac (%@)",
        "Il motore di questa app non è per Mac %@": "This app's engine is not for %@ Macs",
        "Il motore non ha restituito un token": "The engine did not return a token",

        // Connectors, host keys, Linux engines, ssh
        "%@ usa OAuth: sui server remoti si configura a parte (i token OAuth non si copiano)":
            "%@ uses OAuth: set it up separately on remote servers (OAuth tokens are not copied)",
        "%@: il segreto %@ non è salvato su questo Mac, quindi non si può copiare":
            "%@: the secret %@ is not saved on this Mac, so it can't be copied",
        "nessuna risposta ssh da %@:%@": "no ssh response from %@:%@",
        "Questa build dell'app non dice dove scaricare il motore Linux (manca linux-engines.json)":
            "This app build doesn't say where to download the Linux engine (linux-engines.json is missing)",
        "Non c'è un motore Linux per l'architettura %@": "There is no Linux engine for the %@ architecture",
        "Il motore Linux scaricato non è quello atteso (SHA-256 %@…, atteso %@…): scartato":
            "The downloaded Linux engine is not the expected one (SHA-256 %@…, expected %@…): discarded",
        "Il motore Linux scaricato è incompleto (%@ byte invece di %@): scartato":
            "The downloaded Linux engine is incomplete (%@ bytes instead of %@): discarded",
        "Download del motore Linux non riuscito: %@": "Linux engine download failed: %@",
        "URL non valido": "Invalid URL",
        "Indirizzo del server non valido": "Invalid server address",
        "La porta ssh deve essere tra 1 e 65535": "The ssh port must be between 1 and 65535",
        "Nome utente non valido": "Invalid user name",
        "La chiave del server è cambiata: va approvata di nuovo prima di continuare":
            "The server's key has changed: approve it again before continuing",
        "Il fingerprint del server non è ancora stato approvato": "The server's fingerprint has not been approved yet",
        "Accesso rifiutato: chiave non installata o password sbagliata": "Access denied: key not installed or wrong password",
        "Server non raggiungibile: %@": "Server not reachable: %@",
        "Comando fallito sul server (codice %@)": "Command failed on the server (code %@)",
    ]
}
