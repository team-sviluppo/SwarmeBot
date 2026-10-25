// English for moving a bot to another engine and copying connectors and
// skills to a server in one go.
extension Translations {
    static let transfer: [String: String] = [
        // Sidebar › Trasferisci su
        "Trasferisci su": "Move to",
        "Spostare %@ su %@?": "Move %@ to %@?",
        "Su %@ nasce un bot con lo stesso nome, titolo, istruzioni, colore e immagine.":
            "A bot with the same name, title, instructions, color and picture is created on %@.",
        "Modello, skill e connettori si configurano a mano su %@: si sceglie tra quelli disponibili lì.":
            "Model, skills and connectors are set up by hand on %@, choosing from the ones available there.",
        "Le chat non vengono spostate.": "Chats are not moved.",
        "Nessuna automazione collegata a questo bot.": "No automations are linked to this bot.",
        "Queste automazioni passano su %@ e vengono eliminate da %@:": "These automations move to %@ and are deleted from %@:",
        "Ogni webhook avrà un nuovo URL e un nuovo segreto, da aggiornare dove lo chiami.":
            "Each webhook gets a new URL and a new secret, to update wherever it is called from.",
        "Elimina il bot da %@, con le sue chat": "Delete the bot from %@, with its chats",
        "Sposta": "Move",
        "%@ è su %@": "%@ is on %@",
        "Scegli modello, skill e connettori nelle impostazioni del bot su %@.": "Choose model, skills and connectors in the bot's settings on %@.",
        "Routine spostate: %@": "Routines moved: %@",
        "Nuovi URL dei webhook: copiali ora, il segreto non verrà mostrato di nuovo.":
            "New webhook URLs: copy them now, the secret won't be shown again.",
        "%@ non ha un indirizzo pubblico per i webhook: configuralo, poi rigenera il segreto dal pannello Automazioni.":
            "%@ has no public address for webhooks: set one up, then regenerate the secret from the Automations panel.",
        "Apri il bot": "Open the bot",
        "Spostamento non riuscito, nulla è cambiato: %@": "The move failed, nothing changed: %@",
        "Routine %@ non eliminata dall'origine: %@": "Routine %@ not deleted from the source: %@",
        "Webhook %@ non eliminato dall'origine: %@": "Webhook %@ not deleted from the source: %@",
        "Il bot originale non è stato eliminato: %@": "The original bot was not deleted: %@",
        "Motore non raggiungibile": "Engine unreachable",
        // Settings › Connettori / Skill › Copia su server…
        "Copia su server…": "Copy to server…",
        "Copia connettori e skill su un server": "Copy connectors and skills to a server",
        "Nessun connettore su questo Mac.": "No connectors on this Mac.",
        "Nessuna skill su questo Mac.": "No skills on this Mac.",
        "stdio: usa un comando di questo Mac, funziona solo se c'è anche sul server":
            "stdio: runs a command of this Mac, works only if the server has it too",
        "HTTP con OAuth: sul server va rifatto il login": "HTTP with OAuth: sign in again on the server",
        "I connettori OAuth si copiano senza il login: dopo la copia va rifatta l'autenticazione sul server.":
            "OAuth connectors are copied without their login: sign in again on the server after the copy.",
        "copiato: rifai il login OAuth sul server": "copied: sign in with OAuth again on the server",
        "Copiato su %@. Il login OAuth non si copia: rifallo sul server, dalle sue impostazioni dei connettori.":
            "Copied to %@. The OAuth login isn't copied: sign in again on the server, from its connector settings.",
        "contiene script": "contains scripts",
        "Copia (%@)": "Copy (%@)",
        "già sul server: verrà sostituito": "already on the server: it will be replaced",
        "Sul server i connettori e le skill copiati vanno poi dati ai bot che devono usarli.":
            "On the server, then give the copied connectors and skills to the bots that should use them.",
        "provato sul server: %@ strumenti": "tried on the server: %@ tools",
        "copiato, ma la prova sul server non è riuscita: %@": "copied, but the try on the server failed: %@",
    ]
}
