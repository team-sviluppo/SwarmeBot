// English for the engine launcher, credentials, the app model's statuses and errors.
extension Translations {
    static let engine: [String: String] = [
        // AppModel
        "Avvio…": "Starting…",
        "Connessione al motore persa.": "Lost connection to the engine.",
        "Nessun modello": "No model",
        // AppModel+Desktop
        "Non è un JSON valido: incolla un oggetto come {\"mcpServers\": {…}}": "Not valid JSON: paste an object like {\"mcpServers\": {…}}",
        "Il motore scelto per questo bot non usa i connettori: valgono con Claude, Codex, gli agenti ACP e il server compatibile OpenAI.": "This bot's engine doesn't use connectors: they work with Claude, Codex, ACP agents and the OpenAI-compatible server.",
        "Questo modello è un profilo Hermes: usa i suoi strumenti e ignora i connettori di SwarmeBot.": "This model is a Hermes profile: it uses its own tools and ignores SwarmeBot's connectors.",
        // HarnessLauncher
        "VACUUM INTO di messages.db è uscito con codice %@": "VACUUM INTO of messages.db exited with code %@",
        "Avvio del motore…": "Starting the engine…",
        "Nessun harness risponde su %@.": "No engine is answering at %@.",
        "Backup di ~/.swarmebot non riuscito, il motore non parte: %@": "Couldn't back up ~/.swarmebot, so the engine won't start: %@",
        "Impossibile preparare ~/.swarmebot: %@": "Couldn't prepare ~/.swarmebot: %@",
        "Motore non trovato: swarme-harness non è accanto all'app. Reinstalla SwarmeBot, oppure usa SWARMEBOT_HARNESS_URL per collegarti a un motore già avviato.": "Engine not found: swarme-harness is not next to the app. Reinstall SwarmeBot, or use SWARMEBOT_HARNESS_URL to attach to an engine already running.",
        "Avvio del motore sulla porta %@…": "Starting the engine on port %@…",
        "Impossibile avviare il motore: le porte 8799/18799/28799 sono occupate o il processo esce subito.": "Couldn't start the engine: ports 8799/18799/28799 are in use or the process exits right away.",
        "Vedi ~/Library/Logs/SwarmeBot/server.log.": "See ~/Library/Logs/SwarmeBot/server.log.",
        "segnale %@": "signal %@",
        "codice %@": "code %@",
        "Il processo è uscito subito (%@).": "The process exited right away (%@).",
        "Il motore si è chiuso %@ volte di seguito. Vedi ~/Library/Logs/SwarmeBot/server.log.": "The engine quit %@ times in a row. See ~/Library/Logs/SwarmeBot/server.log.",
        "Il motore si è chiuso (codice %@); riavvio tra %@s…": "The engine quit (code %@); restarting in %@s…",
        // Credentials
        "Chiave API xAI": "xAI API key",
        "Token Box (computer cloud)": "Box token (cloud computer)",
        "Chiave OpenCode Go": "OpenCode Go key",
        "Chiave del server compatibile OpenAI": "OpenAI-compatible server key",
        "Portachiavi: %@": "Keychain: %@",
        "errore %@": "error %@",
    ]
}
