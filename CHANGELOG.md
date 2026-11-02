# Changelog

Le note descrivono le differenze visibili agli utenti rispetto alla versione precedente.
Prima di pubblicare una release, aggiungere una sezione con il numero esatto della versione.

## [Unreleased]

### Correzioni

- Ripristinato l’ID della lista ClickUp nella scheda progetto, sia in creazione sia in modifica, visibile solo quando Cylon è attivo. Il pulsante Salva del progetto salva anche questo valore, mantenendo gli ID già configurati.

## [0.6.0]

### Progetti

- Ogni progetto può contenere quanti repository servono, ciascuno con un'etichetta personalizzata.
- Un nuovo progetto parte dalla cartella della chat corrente, con etichetta Default.
- Rinominare o riordinare i repository mantiene le assegnazioni di bot e canali e gli script del progetto.
- La lista ClickUp si configura nelle impostazioni del plugin Cylon e compare solo quando il plugin è attivo. Le configurazioni precedenti vengono mantenute.

### Plugin

- Cylon viene distribuito come plugin privato, incluso automaticamente nelle build quando la raccolta privata è disponibile.
- Le build dell'app e dei motori possono escludere i plugin privati con l'opzione `--no-private-plugins`.

### Aggiornamenti

- Gli aggiornamenti si scaricano dalla repository pubblica, senza token GitHub nell'app.
- La finestra di aggiornamento e la release GitHub mostrano le stesse note, con il confronto rispetto alla versione precedente.

## [0.5.3]

### Progetti

- Ogni progetto può contenere quanti repository servono, ciascuno con un'etichetta personalizzata.
- Un nuovo progetto parte dalla cartella della chat corrente, con etichetta Default.
- Bot e canali continuano a scegliere il repository su cui lavorare. Rinominare un'etichetta mantiene assegnazioni e script.
- La lista ClickUp si configura nelle impostazioni del plugin Cylon e compare solo quando il plugin è attivo. Le configurazioni precedenti vengono mantenute.

### Aggiornamenti

- Gli aggiornamenti si scaricano dalla repository pubblica, senza token GitHub nell'app.
- La finestra di aggiornamento e la release GitHub mostrano lo stesso changelog, con le differenze dalla versione precedente.
