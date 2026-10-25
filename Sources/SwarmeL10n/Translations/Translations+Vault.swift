// English for the secrets vault: Settings › Vault, the bot's card, the errors.
extension Translations {
    static let vault: [String: String] = [
        // Settings › Vault
        "Vault": "Vault",
        "Generico": "Generic",
        "Il comando riceve anche GH_TOKEN e GITHUB_TOKEN, e git è autenticato verso https://github.com senza mettere il token nell'URL.":
            "The command also gets GH_TOKEN and GITHUB_TOKEN, and git is signed in to https://github.com without putting the token in the URL.",
        "Il comando riceve anche HF_TOKEN e HUGGING_FACE_HUB_TOKEN, che hf e huggingface_hub leggono da soli.":
            "The command also gets HF_TOKEN and HUGGING_FACE_HUB_TOKEN, which hf and huggingface_hub read on their own.",
        "Il comando riceve anche NPM_TOKEN e NODE_AUTH_TOKEN: il .npmrc del progetto deve usarli.":
            "The command also gets NPM_TOKEN and NODE_AUTH_TOKEN: the project's .npmrc must use them.",
        "Il comando riceve una variabile con il nome del secret.": "The command gets a variable named after the secret.",
        "Nuovo secret": "New secret",
        "Aggiungi un secret": "Add a secret",
        "Il vault custodisce token e chiavi che i bot usano nei comandi, senza mai vederne il valore.":
            "The vault keeps tokens and keys that bots use in commands without ever seeing their value.",
        "Aggiungi un secret con +, poi scegli nei dettagli di ogni bot quali può usare.":
            "Add a secret with +, then choose in each bot's details which ones it may use.",
        "Il vault è bloccato: manca la sua chiave su questo motore, i secret non si possono usare.":
            "The vault is locked: its key is missing on this engine, so the secrets can't be used.",
        "Sul server, in un file leggibile solo dal suo utente. Le modifiche passano via ssh.":
            "On the server, in a file only its user can read. Changes go through ssh.",
        "Solo lettura: il vault di un server si modifica dal Mac che lo amministra.":
            "Read-only: a server's vault is changed from the Mac that administers it.",
        "Cifrato su questo Mac, con la chiave nel Portachiavi.": "Encrypted on this Mac, with the key in the Keychain.",
        "Su questo Mac, in un file leggibile solo da te.": "On this Mac, in a file only you can read.",
        "Il token o la chiave": "The token or key",
        "Lascia vuoto per non cambiarlo": "Leave empty to keep it",
        "Descrizione": "Description",
        "Cos'è, per il bot: es. token dell'organizzazione acme": "What it is, for the bot: e.g. token of the acme organization",
        "Come usarlo": "How to use it",
        "Istruzioni per il bot: es. usalo solo per push su origin": "Instructions for the bot: e.g. use it only to push to origin",
        "Il bot vede nome, descrizione e istruzioni. Il valore non arriva mai al modello: lo mette il motore nei comandi, e se compare in un output viene mascherato.":
            "The bot sees the name, description and instructions. The value never reaches the model: the engine puts it in the commands, and masks it if it shows up in an output.",
        "Anche i bot che lo usano lo perdono.": "The bots using it lose it too.",
        "Salvato": "Saved",
        "Copiato su %@": "Copied to %@",

        // the bot's card
        "Secret": "Secrets",
        "Istruzioni per i secret": "Instructions for secrets",
        "Es. non fare mai force push; scarica i modelli in ./models": "E.g. never force-push; download models into ./models",
        "Salva istruzioni": "Save instructions",
        "Nessun secret": "No secrets",
        "Aggiungili in Impostazioni › Vault, poi scegli qui quali usa questo bot.":
            "Add them in Settings › Vault, then choose here which ones this bot uses.",
        "Il motore di questo bot non ha una shell: i secret non si possono usare.":
            "This bot's engine has no shell: secrets can't be used.",
        "Il motore di questo bot non ha lo strumento sicuro: usa la modalità variabile d'ambiente, oppure cambia motore.":
            "This bot's engine doesn't have the safe tool: use the environment variable mode, or change engine.",
        "Sicura": "Safe",
        "Variabile d'ambiente": "Environment variable",
        "Il valore è nell'ambiente della CLI del bot per tutto il turno: comodo, ma il modello può leggerlo se lo stampa.":
            "The value is in the environment of the bot's CLI for the whole turn: handy, but the model can read it if it prints it.",
        "Il bot usa il secret solo tramite lo strumento run_with_secrets: il motore esegue il comando e maschera il valore nell'output.":
            "The bot uses the secret only through the run_with_secrets tool: the engine runs the command and masks the value in the output.",

        // errors
        "Il vault di %@ si modifica solo dal Mac che amministra il server": "The vault of %@ can only be changed from the Mac that administers the server",
        "Il valore di %@ non si legge dal vault di questo Mac": "The value of %@ can't be read from this Mac's vault",
    ]
}
