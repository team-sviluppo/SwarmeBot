# Costo stimato e utilizzo Codex nell'intestazione

## Comportamento

Codex riutilizza gli indicatori già presenti per Claude: costo della chat e percentuale della quota
dell'abbonamento. La percentuale proviene da `account/rateLimits/read` e dagli eventi
`account/rateLimits/updated`. Si legge anche quando viene caricato il catalogo modelli, senza
richiedere un nuovo turno. Si usa il bucket `codex`, evitando che un aggiornamento di un altro
bucket sostituisca la quota visualizzata.

La finestra primaria può non durare cinque ore: la lettura sulla CLI reale ha restituito una
finestra settimanale. L'etichetta delle cinque ore resta specifica per `five_hour`; per le altre
finestre il tooltip indica l'utilizzo corrente e l'ora di azzeramento disponibile. La percentuale
scaduta non viene mostrata, come per Claude.

Il costo è un equivalente in USD alle tariffe API Standard, non una fattura dell'abbonamento:
compare con `≈` e una spiegazione nel tooltip. Viene calcolato per il modello effettivo restituito
da `thread/start` o `thread/resume`, solo quando il provider è identificato come OpenAI e il
listino è noto. Modelli locali o sconosciuti non ricevono prezzi arbitrari.

Il calcolo distingue input, letture cache, scritture cache a tariffa standard di 30 minuti e
output; i token di ragionamento sono già inclusi nell'output. Per i modelli interessati considera
la maggiorazione API oltre 272.000 token. È un equivalente Standard: non applica sovrapprezzi
Fast/Ultrafast, residenza regionale, tool o eventuali condizioni specifiche dell'account.
Il listino verificato il 29 ottobre 2026 copre i modelli GPT-6 e GPT-5.6 del catalogo attuale,
oltre a GPT-5.5, GPT-5.4, GPT-5.4 Mini e GPT-5.3 Codex; supporta anche gli identificativi con data.

Il primo report utilizza `last`, evitando di riaddebitare lo storico di una chat ripresa.
I successivi utilizzano le differenze dei totali e ignorano i duplicati. I totali storici senza
`last` non producono una stima. Il flag opzionale `usage.costEstimated` conserva la provenienza
anche dopo cambi di modello e riavvio; nessun cambiamento ai frame runtime esistenti.
La stima si accumula sui nuovi turni: lo storico privo dei dettagli di modello e cache non viene
ricostruito con prezzi arbitrari.

## Verifica

- `swift build` riuscito, solo warning preesistenti.
- Suite completa: 399 test, 12 integrazioni opzionali saltate, zero errori.
- Cinque test specifici: bucket e finestre, cache, ripresa, duplicati, contesto lungo,
  provider sconosciuti/locali, eventi del driver e persistenza della provenienza del costo.
- Scenario HTTP/SSE `DRIVER=codex SCENARIO=usage` riuscito, con CLI finto e dati isolati.
- App aperta su motore e dati di prova: intestazione verificata visivamente con `≈$0.0001`
  e indicatore verde `42%`. Nessuna modifica ai dati dell'app in uso.
- CLI Codex reale: lettura quota riuscita, senza inferenze né consumo di token del modello.
- Non eseguiti confronto Node (checkout assente), compilazione Linux e inferenze reali per
  confrontare la stima con una fattura: l'abbonamento non fornisce un costo per turno.

## Fonti del protocollo e del listino

- [Codex app-server: quote account](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).
- [Tariffe API Standard](https://developers.openai.com/api/docs/pricing).
- Schede modello per cache e contesto lungo, ad esempio
  [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
  [GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol),
  [GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol).
