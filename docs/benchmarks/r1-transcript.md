# R1 — transcript SwiftUI su thread lunghi

Rischio R1 del piano: "transcript lento su thread lunghi in SwiftUI". Misurato il 2026-10-13 su
Apple silicon, build release, con `SWARMEBOT_BENCH=<n> .build/release/SwarmeBot`
(`Sources/SwarmeBot/BenchRunner.swift`). Thread sintetico: 50% risposte markdown con titolo,
lista, blocco di codice e citazione; 30% chip strumento; 10% card approvazione; 10% messaggi utente.

"Hitch" = intervallo massimo tra due tick di un timer a 120 Hz sul main thread durante la fase.

| Fase | 2.000 msg — prima | 2.000 — dopo | 5.000 — prima | 5.000 — dopo |
|---|---|---|---|---|
| Primo layout | 264 ms | **147 ms** | 413 ms | **161 ms** |
| Streaming 300 delta a 60 Hz (ideale 5,0 s) | 9,2 s, p95 111 ms | **5,3 s, p95 14 ms** | 23,4 s, p95 253 ms | **5,3 s, p95 12 ms** |
| 50 risposte nuove, ogni 120 ms | p95 39 ms | **p95 33 ms** | p95 314 ms | **p95 28 ms** |
| Salto in cima (ricerca) | hitch 42 ms | hitch 147 ms | hitch 60 ms | hitch 187 ms |
| Ritorno in fondo | hitch 78 ms | hitch 201 ms | hitch 48 ms | hitch 222 ms |
| Memoria residente | 204 MB | 255 MB | 297 MB | 299 MB |

## Cosa è cambiato

1. **Testo in streaming fuori da `state`** (`SwarmeKit/LiveText.swift`). `@Observable` traccia
   `state` come un'unica proprietà: ogni delta invalidava transcript, sidebar e inspector. Ora un
   delta ridisegna solo la bolla live (`LiveTail`). Anche il cursore dello stream è uscito da `state`.
2. **Transcript visibile in cache** per versione dello stato (`AppModel.visibleTranscript`): la
   catena del ramo attivo si ricalcola una volta per cambiamento, non per vista per render.
3. **Finestra di 300 messaggi** renderizzati (come `transcript-window.ts` nel client web), che si
   allarga con "Carica messaggi precedenti" o per includere un risultato di ricerca e torna a 300
   quando si salta di nuovo tra i più recenti. Rende il costo di un messaggio nuovo indipendente da N.

## Lettura

R1 è **chiuso per l'uso normale**: apertura, streaming e nuovi messaggi restano fluidi a 5.000
messaggi. Il costo residuo è un singolo scatto di ~150–220 ms quando un salto di ricerca allarga la
finestra a tutta la storia (o la riduce): accettabile per un'azione esplicita e rara. Se serve
ridurlo, il passo successivo è il fallback `NSTableView` previsto dal piano, solo per quel caso.
