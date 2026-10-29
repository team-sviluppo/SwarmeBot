# Gestione dei sottagenti nativi

## Problema e decisioni

Il risultato del padre può chiudere un turno del provider mentre i figli sono ancora attivi.
Terminare il processo in quel momento perde la continuazione e i risultati dei sottotask.

- Un registro per esecuzione conserva identificativo, padre, descrizione, stato e risultato dei
  sottotask. Gli aggiornamenti modificano una sola attività nella trascrizione, senza mischiare
  testo e strumenti dei figli con quelli del padre.
- Si riutilizzano i frame e le attività esistenti: i dettagli dello strumento mostrano stato,
  relazione col padre e risultato. Il campo aggiuntivo `tool.subagent` resta opzionale per i client
  precedenti. Nessuna nuova route e nessun cambiamento del contratto runtime congelato.
- Claude: stdin rimane aperto. Si osservano `task_started`, `task_progress`, `task_updated`,
  `task_notification` e `session_state_changed`. Solo `local_agent` e `local_workflow` tengono
  aperta l'esecuzione: shell, monitor e compagni permanenti possono non terminare mai. La fine
  può arrivare solo in `task_updated.patch.status`; una notifica successiva arricchisce la stessa
  attività. Lo stato di sessione evita di chiudere se un figlio termina subito prima del risultato
  del padre ma deve ancora risvegliarlo. La continuazione del padre è gestita dal CLI.
- Codex: si osservano `collabAgentToolCall`, `subAgentActivity`, thread figli e loro risultati.
  Gli eventi dei figli non chiudono il padre. Se rimangono figli attivi dopo `turn/completed`,
  si recupera il risultato con `thread/read`, mantenendo vivo app-server; a figli terminati si
  riprende il thread padre con i risultati. Una continuazione già avviata dal provider ha precedenza.
- Stop e errori chiudono l'intero processo e marcano i figli ancora attivi come interrotti.
  Dopo un riavvio, il caricamento della chat corregge gli stati rimasti attivi su disco. I risultati
  completati rimangono consultabili. Non si riprendono automaticamente processi morti al riavvio.
- Risultati limitati a 16.000 caratteri per attività e redatti come gli altri dettagli degli
  strumenti; per Claude si conserva anche il riferimento `output_file`, senza leggerlo arbitrariamente.
  Restano in vigore il watchdog di stallo e le normali approvazioni del provider.

## Verifica e avanzamento

- Implementati registro, adattatori Claude/Codex, persistenza e recupero degli stati interrotti.
- Test con CLI finti: completamento prima/dopo il padre, completamento tramite patch, notifiche
  duplicate, separazione dei risultati, recupero e continuazione Codex, stop, persistenza e redazione.
- Scenario HTTP/SSE: `DRIVER=claude|codex SCENARIO=subagents python3 -I parity/run_scenario.py swift . .build/debug/swarme-harness`.
  È una divergenza voluta dal vecchio motore: interrompere i sottagenti al risultato intermedio
  riprodurrebbe il difetto.
- Prova opzionale su sottoscrizione reale e cartella vuota:
  `SWARMEBOT_SUBAGENT_LIVE=claude|codex swift test --filter SubagentTests/testLiveSubagentLifecycle`.

Verifiche completate:

- `swift build`: riuscito, solo warning preesistenti negli adattatori ACP.
- `swift test`: 402 test, 13 saltati perché richiedono servizi esterni o la prova live opzionale,
  zero errori. Sette test automatici specifici per i sottagenti.
- Scenari HTTP/SSE `subagents` riusciti per Claude e Codex, compresi risultati persistenti,
  continuazione, stato busy fino alla conclusione e interruzione.
- Prove reali su sottoscrizione: Claude Haiku e Codex Luna hanno entrambi creato un sottagente,
  ricevuto `CHILD_OK` e risposto `PARENT_OK`. Valori riportati dal motore: Claude 29.015 token
  input / 56 output, costo stimato 0,05745195 USD; Codex 15.346 input / 7 output, costo non esposto.
  Il primo tentativo Codex con `gpt-5.4-mini` è stato rifiutato dalla sottoscrizione; il test ora
  sceglie un Luna effettivamente presente nel catalogo del CLI.

Limiti della verifica: nessun confronto con Node (checkout di riferimento assente), nessuna
compilazione Linux, nessuna nuova vista UI da verificare. I client utilizzano i dettagli degli
strumenti esistenti. Per CLI Claude vecchi senza stato di sessione resta il limite del protocollo:
un figlio già terminato al primo risultato può avere una continuazione ancora non segnalata.

## Riferimenti

- [Codex app-server](https://learn.chatgpt.com/docs/app-server), più schema TypeScript generato
  dalla CLI installata (`codex app-server generate-ts --experimental`).
- [Ciclo di vita nel Claude Agent SDK](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py).
