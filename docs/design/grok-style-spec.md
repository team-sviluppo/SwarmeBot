# Spec visiva "Grok style": Electron/React → SwiftUI macOS

Fonte di verità: il codice React in `/Users/cristiano/Sviluppo/SwarmeBot` (commit `1cd755d`).
Unità: 1 px CSS = 1 pt macOS. Spaziature Tailwind v4: 1 unità = 4 pt (`px-3.5` = 14 pt).
Raggi Tailwind (skin Midnight): `rounded` 4, `rounded-md` 6, `rounded-lg` 8 (`--radius-lg`), `rounded-xl` 12, `rounded-2xl` 16, `rounded-full` capsula.
Opacità Tailwind `x/NN` = colore x con alpha NN% (es. `bg-raised/70` = `#2F2F2F` al 70%).

> Attenzione agli screenshot in `docs/screenshots/*.png` (2880×1800 @2x = 1440×900 pt): sono **precedenti** all'attuale "compact rail". Mostrano sidebar da ~320 pt, avatar da ~48 pt con silhouette `cursor`, righe da ~77 pt, nome bot ~15 pt, ricerca su una riga separata e footer "Plugins". Il codice attuale usa sidebar 272 pt, avatar 32 pt, silhouette di default `circle`, ricerca + "+" sulla stessa riga, "Connected apps". Questa spec segue il **codice**; dove gli screenshot sono ancora validi (header, bolle, composer, card, menu contestuale, model picker, settings) i valori coincidono.

---

## 1. Tipografia

### 1.1 Famiglia
- Stack (Midnight, Foundry): `"Inter", -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", system-ui, sans-serif` (`src/styles.css:52-53`, ripetuto a `:100`, `:193`). Atelier e Lagoon: `system-ui, -apple-system, …` (`:143`, `:245`).
- **Inter NON è incluso nell'app.** Nessun `@font-face`, nessun `@fontsource/*` in `package.json`, nessun `.woff/.ttf/.otf` nel repo (escluso `node_modules`). L'unica traccia è `third_party/cua-driver/Inter-OFL-1.1.txt` (licenza SIL OFL 1.1 di Inter 4.001 *incorporato nel binario Linux di Cua Driver*, vedi `third_party/cua-driver/README.md:13`), non usabile dalla UI. Quindi l'app renderizza Inter solo se l'utente lo ha installato a sistema; altrimenti **SF Pro** (`-apple-system`). Gli screenshot sono in SF Pro.
- Raccomandazione Swift: `.font(.system(size:weight:))` (SF Pro) = ciò che vede il 99% degli utenti Mac. Se si vuole Inter, va bundlato (Inter 4.x, OFL 1.1 → consentito, includere `OFL.txt` in Resources e registrarlo con `CTFontManagerRegisterFontsForURL`), ma divergerebbe dall'Electron reale.
- Mono: Tailwind `font-mono` / preflight su `code, pre` = `ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas…` → **SF Mono** (`.system(size:, design: .monospaced)`).
- `-webkit-font-smoothing: antialiased` (`styles.css:261`): su macOS equivale al rendering standard SwiftUI.
- Interlinea di default (preflight) = 1.5 per qualunque `text-[Npx]` senza `leading-*`. `leading-relaxed` = 1.625, `leading-tight` = 1.25, `leading-6` = 24 pt. In SwiftUI: `lineSpacing = (size × factor) − altezza naturale SF (≈ 1.19 × size)`. Es. 15 pt × 1.625 = 24.4 → `.lineSpacing(6.5)`; 13 pt × 1.5 = 19.5 → `.lineSpacing(4)`.
- Pesi: `font-medium` 500 → `.medium`; `font-semibold` 600 → `.semibold`; `<strong>`/`**` = `bolder` → 700 `.bold`.
- Letter spacing: nessuno di default. Eccezioni: label uppercase `tracking-[0.08em]` (10 pt → `.tracking(0.8)`; 11 pt → 0.88), "PENDING APPROVAL" `tracking-[0.18em]` (11 pt → 1.98), header code block `tracking-wide` 0.025em (11 pt → 0.28), titolo "Archived bots" −0.01em (22 pt → −0.22).

### 1.2 Tabella dimensioni (pt / peso / interlinea / colore)

| Elemento | Size | Peso | Line-height | Colore | Fonte |
|---|---|---|---|---|---|
| Sidebar: nome bot | 13 | medium | 19.5 | ink | `Sidebar.tsx:923` |
| Sidebar: preview | 11.5 | regular | 14.4 (`leading-tight`) | ink-secondary | `:940` |
| Sidebar: ora (solo riga selezionata) | 11 | regular | 16.5 | ink-secondary | `:934` |
| Sidebar: "Chief of Staff" in preview | 10.5 | medium | — | accent | `:942` |
| Sidebar: header sezione (uppercase) | 10 | medium, tracking 0.8 | — | ink-secondary | `:475` |
| Sidebar: campo ricerca | 13 | regular | — | ink / placeholder ink-secondary | `:1392` |
| Sidebar footer (Automations, Connected apps, nome profilo) | 13 | regular | — | ink | `:1555,1565,1573` |
| Iniziali profilo | 22 × 0.38 = 8.4 | medium | — | ink-secondary su raised | `Avatar.tsx:333` |
| Header chat: titolo | 14 | semibold | — | ink | `ChatView.tsx:987` |
| Header: badge Chief of Staff | 11 | medium | — | accent su accent/12 | `:991` |
| Header: "+ Task" / pill task | 12.5 | regular | — | ink-secondary | `TaskPicker.tsx:62,89` |
| Header: pill modello | 13 | regular | — | ink | `ModelPicker.tsx:210` |
| Header: pill Stop | 13 | regular | — | ink-secondary | `ChatView.tsx:1001` |
| Usage chip / folder chip | 12 / 12.5 (folder mono) | regular | — | ink-secondary | `:1227,1247` |
| Messaggio bot (corpo) | 15 | regular | 24.4 (`leading-relaxed`) | ink | `ChatView.tsx:373` |
| Messaggio utente | 15 | regular | 24.4 | ink | `:373` |
| Separatore giorno ("Today 3:06 PM") | 13 | regular | 19.5 | ink-secondary | `:85` |
| Ora per-messaggio (hover) | 11 | regular, `tabular-nums` | — | ink-secondary al 70% (≈ #FCFCFC @ 0.42) | `:467` |
| "Interrupted" | 12 | regular | — | ink-secondary | `:442` |
| Codice inline | 13 mono | regular | 21.1 | ink su inset | `ChatMarkdown.tsx:184` |
| Code block corpo | 13 mono | regular | 21.1 (`leading-relaxed`) | tema Shiki `github-dark-default` | `:102,106` + `:50` |
| Code block header (lang) | 11 uppercase, tracking 0.28 | regular | — | ink-secondary | `:91` |
| Markdown h1 | 16 | semibold | — | ink, `mt-2` (8) | `:221` |
| Markdown h2 | 15.5 | semibold | — | `mt-2` | `:224` |
| Markdown h3 / h4 | 15 (eredita) | semibold | — | `mt-1.5` (6) | `:227,230` |
| Markdown h5 | 14 | semibold | — | `mt-1.5` | `:233` |
| Markdown h6 | 13.5 | semibold | — | ink-secondary | `:236` |
| Tabelle | 13.5 | th semibold | — | — | `:202` |
| Link | eredita | regular | — | accent `#1084FE`, underline accent/40 | `:193` |
| Thinking strip label | 12.5 | regular | — | shimmer / ink-secondary | `ChatView.tsx:142` |
| Thinking text espanso | 12.5 | regular | 20.3 | ink-secondary | `:153` |
| Activity chip (tool) | 13, nome tool mono | regular | — | ink-secondary / danger | `:544-556` |
| "Working for 12s" | 12.5 | regular | — | ink-secondary | `:602` |
| Composer testo | 15 | regular | 24 (`leading-6`) | ink | `Composer.tsx:420` |
| Composer placeholder | 15 | regular | 24 | ink-secondary | idem |
| Pulsanti pill generici | 12.5–13.5 | regular / medium (primario) | — | — | vedi §2 |
| Model picker: nome provider | 14 | semibold | — | ink | `ModelPicker.tsx:273` |
| Model picker: sottotitolo | 11.5 | regular | — | ink-secondary | `:283` |
| Model picker: riga modello | 13 | regular | — | ink | `:44` |
| Model picker: badge Default/Loaded | 10 | regular | — | ink-secondary su inset / accent su accent/10 | `:51,54` |
| Model picker: chip stato | 10.5 | medium | — | success su success/10 | `:275-280` |
| Model picker: label rail Cloud/Local | 9 | — | — | — | `:256,260` |
| Approval card: titolo | 15 | semibold | — | ink | `ApprovalCard.tsx:51` |
| Approval card: tool | 11 mono | regular | — | ink-secondary | `:55` |
| Approval card: comando | 12.5 mono | regular | 20.3 | ink su inset | `:59` |
| Approval card: stato | 13 | regular | — | ink-secondary | `:71` |
| Pending approval (composer) etichetta | 11 uppercase, tracking 1.98 | regular | — | ink-secondary | `PendingApproval.tsx:66` |
| Pending approval: label/tool/cmd | 13 / 11 mono / 12 mono | — | 19.5 | — | `:72-76` |
| Pending approval: bottoni | 13.5 | regular (Allow once medium) | — | — | `:107` |
| Option card: titolo / sottotitolo | 16 semibold / 14 | — | — | ink / ink-secondary | `OptionCard.tsx:80-81` |
| Option card: opzione / lettera | 15 / 12 medium | — | — | ink / ink-secondary | `:105,112` |
| Context menu: voce | 14 (bot, room, "+") / 13 (section) | regular | — | ink / danger | `Sidebar.tsx:808,589` |
| Command palette: input / riga / dettaglio / sezione | 14 / 14 / 12.5 / 11 medium uppercase tracking .88 | — | — | — | `CommandPalette.tsx:165,189,191,178` |
| Settings modal: titolo nav / voce / header | 15 semibold / 14 / 15 semibold | — | — | — | `SettingsModal.tsx:202,210,223` |
| Inspector: titolo / righe | 15 semibold / 11.5 mono | — | — | — | `InspectorPanel.tsx:123,159` |
| Empty chat: nome / descr. | 17 semibold / 14 | — | — | ink / ink-secondary | `ChatView.tsx:644,649` |

Liste markdown: `list-disc`/`list-decimal`, `pl-5` (20 pt di rientro), `space-y-1` (4 pt tra item). Tra blocchi markdown: `[&>*+*]:mt-2` = 8 pt (`ChatMarkdown.tsx:156`). Code block `my-2` (8). Blockquote: barra sinistra 2 pt `hairline`, `pl-3` (12), testo ink-secondary. `hr` hairline/40.

---

## 2. Layout e dimensioni

### 2.1 Finestra
- Default 1440×920, min 900×600, `backgroundColor #070707`, macOS `titleBarStyle: hiddenInset`, `trafficLightPosition {x:16, y:16}` (`electron/main.mjs:433-443`).
- Swift: `SwarmeBotApp.swift:14` usa min 900×560 → portare a 600; usare `.windowStyle(.hiddenTitleBar)` + `.windowToolbarStyle(.unifiedCompact)` o nessuna toolbar, sfondo `Theme.app`.
- Colonne: Sidebar 272 | main (flex) | pannello destro opzionale (Settings bot 400, Computer 400, Inspector 460).

### 2.2 Sidebar (`Sidebar.tsx:1351-1590`)
- Larghezza **272 fissa**, `bg-panel #111111`, bordo destro 1 pt `hairline/30`.
- Riga superiore: `px-2.5 pt-2.5 pb-2` (10/10/8), gap 6. Su macOS uno spacer di **56 pt** (`w-14`) a sinistra per i semafori (zona drag). Poi:
  - Campo ricerca flex-1: `rounded-lg` 8, `bg-raised/70`, `px-2 py-1.5` (8/6), icona lente 13 ink-secondary, gap 6, testo 13. Altezza ≈ 31.5 pt.
  - Bottone "+": `p-1` (4) icona 16 stroke 2, `rounded-md` 6, hover `bg-raised`. Menu "+" largo 176 (`w-44`), stile context menu, voci: New Bot, New Room, Export team, Team library, Archived bots (+count 11.5).
- Lista: `px-1.5` (6), gap verticale **1 pt** (`gap-px`); Chief of Staff in testa con `mb-1.5` (6).
- **Riga bot** (`:895-1004`): `flex gap-2` (8), `rounded-lg` 8, bordo 1 pt trasparente, `px-2 py-1.5` (8/6), `pr-8` (32, spazio per il bottone archivia). Avatar **32**. Altezza = 32 + 12 + 2 = **46 pt**.
  - Selezionata: `bg-raised #2F2F2F`. Hover: `bg-raised/50`.
  - Chief of Staff: bordo `accent/25` + `bg-accent/5`, hover `accent/10`; selezionato bordo `accent/40` + `bg-accent/15`.
  - Riga 1: nome (13 medium, troncato) + icona pin 10 se pinned; a destra ora 11 **solo se selezionata**, che va a opacity 0 su hover (cede il posto al bottone archivia).
  - Riga 2: preview 11.5 `leading-tight`; pallino unread 8×8 `accent`.
  - Bottone archivia (hover): assoluto `right-1 top-1.5` (4/6), 24×24, `rounded-md`, `bg-card/90`, `shadow-sm`, icona Archive 12.
  - Niente "title capsule" accanto al nome (lo Swift la mostra: rimuovere).
- **Riga room**: identica, avatar = `StackedMauses`: 1 membro → mascot 32; più membri → fino a 3 mascot da 18 sovrapposti `-space-x-2` (−8 pt) + chip "+N" 16×16 `rounded-full` bordo hairline/40 `bg-raised` testo 8 medium (`:169-193`).
- **Header sezione** (`:446-490`): `px-2 pb-0.5 pt-2` (8/2/8; prima sezione pt 2), gap 6: grip 11 (solo hover, opacity .6), chevron 11 ruotato 90° se espanso (transition-transform 150 ms), nome 10 medium uppercase tracking 0.8, contatore 10 se collassata, poi linea 1 pt `hairline/40` che riempie, poi "…" 13 su hover.
- **Footer** (`:1546-1586`): `px-1.5 pb-2 pt-1` (6/8/4); senza bordo superiore.
  - Automations: riga `rounded-lg px-2 py-1.5` gap 8, icona CalendarDays 15 (ink-secondary; accent se attiva + `bg-raised`), testo 13; pallino 6 `danger` se run fallite non viste.
  - Connected apps: icona Puzzle 15, testo 13.
  - Profilo: InitialsAvatar 22 (cerchio `bg-raised`, iniziali 8.4 medium ink-secondary) + nome 13, flex-1; poi UpdateButton; poi ingranaggio 15 `p-1.5` `rounded-md`.

### 2.3 Header chat (`ChatView.tsx:960-1067`)
- `px-4 py-2` (16/8), `justify-between`, area drag. Altezza ≈ **50 pt** (contenuto 34 + 16).
- Sinistra (`gap-2.5` = 10, wrapper `rounded-lg px-1.5 py-1`): bottone avatar `p-0.5 rounded-lg` hover `raised/50` con **MausAvatar 22** (animato, riceve i motion beat) → titolo 14 semibold (rinominabile) → badge Chief of Staff (capsula `bg-accent/12` `px-2 py-0.5`, crown 11, testo 11 medium accent) → spinner 14 se busy.
- Destra (`gap-2` = 8), in ordine: [Stop pill se busy] · TaskPicker · Pin 16 · Export 16 · UsageChip · WorkingFolderChip · **ModelPicker** · Call · Monitor 18 · Bug(Inspector) 18.
  - Icone: `rounded-md p-1.5` (6) → hit 28/30 pt; colore ink-secondary, hover `bg-raised` + ink; attive `text-accent`.
  - Stop pill: capsula bordo 1 `hairline/40`, `bg-raised/60`, `px-2.5 py-1` (10/4), quadrato pieno 12, testo 13.
  - "+ Task" (nessun task): capsula bordo `hairline/40`, **senza fondo**, `px-2.5 py-1`, icona Plus 12, 12.5, ink-secondary; hover `bg-raised` + ink. Con task: max 220, titolo + count `opacity .6` + pin 11 accent + chevron 12.
  - Model pill: capsula bordo `hairline/40`, `bg-raised/60`, `py-1 pl-2 pr-2.5` (4/8/10), gap 6, ProviderMark 14, label max 160 troncata 13 ink, chevron 14 ink-secondary (ruota 180° quando aperto). Altezza ≈ 28.
  - Usage chip: capsula `hairline/40` `bg-raised/60` `px-2.5 py-1` 12 tabular. Folder chip: idem, max 180, icona Folder 12, testo 12.5 mono.
- Sotto l'header: banner errore (`max-w-[900px] px-5`, `rounded-lg` bordo danger/30, `bg-danger/10`, `px-3 py-2`, 13) e PinnedBanner (`rounded-lg` bordo `accent/25`, `bg-accent/[0.07]`, `px-3 py-1.5`, pin 12, mittente 11.5 medium accent, testo 12.5).

### 2.4 Transcript (`ChatView.tsx:1093-1180`)
- Scroll `px-5` (20). Colonna centrata **max 900**, `flex-col gap-3` (**12 pt tra messaggi**), `pb-4` (16).
- Separatore giorno: `py-3` (12 sopra/sotto), centrato, 13 ink-secondary, testo `"{Today|Yesterday|Wed, Aug 12} {h:mm}"`; compare quando cambia la data di calendario rispetto al messaggio precedente (`:656`). (Lo Swift usa 11 medium tertiary: correggere.)
- Riga messaggio (`:332-475`): `group flex-col`, allineata a destra (user) o sinistra (bot). Dentro, riga orizzontale `gap-1.5` (6):
  - User: [Edit 14][Reactions][Copy 14][Pin 14][**bolla**] + ora a sinistra (`order-first mr-1`).
  - Bot: [Pin 14][**bolla**][colonna Copy/Speak/Regenerate 14, `self-end pb-0.5` gap 2] + ora a destra `ml-1`.
  - Bottoni hover: `rounded-md p-1.5`, ink-secondary, `opacity-0` → 1 su hover del gruppo (transition-opacity 150 ms).
  - Ora: 11 `tabular-nums` ink-secondary/70, `self-end pb-1`, opacity 0 → 1 su hover.
- **Bolla bot**: `bg-card #262626`, `rounded-2xl` **16**, `px-4 py-2.5` (**16/10**), testo 15/24.4, max **88%** della colonna (`lib/bubble-width.ts:21`), bolla in streaming `min-w` nessuno (ThinkingStrip min 200).
- **Bolla user**: `bg-bubble-user #5A5A5A`, `rounded-2xl` 16, `px-4 py-2.5` (16/10), `whitespace-pre-wrap`, max **70%** (`:24`). Collassabile oltre soglia: `max-h-40` (160) + mask gradient nero 60%→trasparente, link "Show full message" 12.5.
- Reaction bar bot: assoluta `bottom-0 right-3` traslata +50% Y, capsula bordo hairline/40 `bg-panel` `px-1 py-0.5`, emoji 13; si vede su hover.
- Activity chip (tool call): capsula bordo `hairline/40`, `bg-panel #111`, `px-3 py-1.5` (12/6), gap 8, icona 13 (spinner / check success / x danger), nome tool mono troncato a 480.
- Bot-to-bot chip: idem con MausAvatar 16 del peer + chevron 13.
- Indicatore "working" (`:1168-1179`): bolla `bg-raised #2F2F2F` (non card!), `rounded-2xl`, `px-4 py-3`, gap 10: 3 pallini 6×6 `bg-ink-secondary` gap 6, `animate-bounce` con delay 0/150/300 ms + "Working for Ns" 12.5.
- Streaming: bolla bot + caret 2×14 `bg-ink` `ml-0.5`, blink step 1 s.
- Errore turno: bolla `rounded-xl` (12) bordo `danger/30` `bg-danger/10` `px-3.5 py-2.5` 13.5 danger, icona 15; Retry pill bordo danger/30 `px-2.5 py-1` 12.5.
- "Jump to latest": capsula flottante `bottom-24` (96) centrata, bordo hairline/40, `bg-raised`, `px-3 py-1.5`, 12.5, `shadow-lg`, `animate-pop-in`.
- Screenshot del bot: `max-w-[70%]` `rounded-2xl` bordo hairline/40.

### 2.5 Composer (`Composer.tsx:245-466`)
- Wrapper `px-8 pb-6 pt-2` (**32 / 24 / 8**), colonna `max-w-[900px]` centrata.
- Pill: `flex items-end gap-2` (8), **`rounded-full`**, bordo 1 pt `hairline/30`, **`bg-raised/70`** (#2F2F2F @ 0.7 su #070707 ≈ #232323), `py-1.5 pl-4 pr-2` (**6 / 16 / 8**).
- Textarea: 15 pt, interlinea 24, `py-1` (4), max altezza 160, nessun bordo. Altezza a riposo = 6 + 4 + 24 + 4 + 6 + 2 bordo = **46 pt** (screenshot: ~49 pt).
- Bottoni a destra (32×32 cerchio): Stop (busy, quadrato pieno 14, ink-secondary hover raised) · Mic 18 (solo vuoto e dettatura disponibile; registrando `bg-danger/20 text-danger animate-pulse`) · **Send** (solo con contenuto): `bg-accent #1084FE`, freccia ArrowUp 17 **bianca**, hover `brightness-110`; busy → `bg-raised` icona Clock 15 ink-secondary.
- **Nessun "+" allegati** visibile nel composer (allegati via paste/drag). Nessun model picker sotto il composer (è nell'header).
- Placeholder: `Message {bot}`; busy `{name} is working — sends when this turn finishes`; approval `Answer the approval above to continue`; dettatura `Listening…`.
- Sopra la pill: banner coda (`rounded-lg` bordo hairline/40 `bg-panel` `px-3 py-2` 12.5 + Clock 13), menu menzioni (`w-72` = 288, `rounded-xl`, bordo hairline/40, `bg-raised`, `shadow-lg`, righe con MausAvatar 24 + nome 14 medium + "Agent/Room" 12), pannello approval (vedi 2.7).

### 2.6 Pannelli destri
- Settings bot (`SettingsPanel.tsx:582`) e Computer (`ComputerPanel.tsx:546`): **400**, Inspector (`InspectorPanel.tsx:121`): **460**. Tutti `bg-panel`, bordo sinistro 1 pt `hairline/40`, `animate-panel-in`.
- Header pannello: `px-4 py-3` (16/12), titolo 15 semibold + icona 16 ink-secondary, close X 18 `p-1 rounded-md`.
- Inspector: tab segmentati `rounded-lg bg-inset p-0.5`; lista mono 11.5; righe `px-3 py-1.5`, ora tabular, payload `bg-app` 11 mono.
- Switch: 44×26 (pannello) / 44×24 (modal), capsula `bg-accent` on / `bg-raised` off, knob bianco 20 (18 nel modal) a `left 3`→`21`, `transition-all` 150 ms.
- Swift (`RootView.swift:30-33`): `.inspector` 260–420 ideal 300 → usare 400 fisso (settings/computer) e 460 (inspector eventi).

### 2.7 Card
**Approval card nel transcript** (`ApprovalCard.tsx:43-91`): larghezza piena fino a **840**, `rounded-2xl` 16, bordo 1 pt `accent/40` (pending) oppure `hairline/30` + opacity .7 (risolta), `bg-card`, `p-4` (16).
1. Riga titolo baseline: "{Bot} wants to {run a command|read a file|write a file|edit a file|fetch a web page|search the web}" 15 semibold; a destra nome tool 11 mono ink-secondary.
2. `pre` `mt-2` (8), `max-h-40` (160) scroll, `rounded-lg` 8, `bg-inset #191919`, `px-3 py-2` (12/8), 12.5 mono `leading-relaxed`, ink.
3. Eventuale `held`: `mt-2 rounded-lg` bordo `warning/30` `bg-warning/10` `px-3 py-2` 12.5 warning.
4. Stato `mt-3` (12), gap 6, 13 ink-secondary: ShieldCheck 14 accent "Waiting for your answer below" / Check 14 success "Allowed" / X 14 "Denied" / TriangleAlert 14 warning "Unavailable · action not run".

**Pannello approval nel composer** (`Composer.tsx:305` + `PendingApproval.tsx`): contenitore `mb-2 rounded-2xl` bordo `accent/40` `bg-card` overflow hidden. Testata `border-b hairline/50`, `bg-raised/40`, `px-4 py-3`: "PENDING APPROVAL" 11 uppercase tracking 1.98 · chip conteggio (`rounded-full bg-raised px-1.5 py-0.5` 11) · label 13 ink · tool 11 mono; `pre` 12 mono `mt-2 max-h-40`. Azioni `flex justify-end gap-2 px-2 py-2`, bottoni capsula `px-3.5 py-1.5` (14/6) 13.5, transition-colors: **Cancel turn** (ink-secondary, hover raised) · **Deny** (bordo `danger/40`, testo danger, hover `danger/10`) · **Always allow** (bordo `hairline/50`, ink, hover raised) · **Allow once** (`bg-accent`, bianco, medium, hover brightness 110%).

**Option card** (`OptionCard.tsx:77-160`, vedi `approval-card.png`): max 840, `rounded-2xl`, bordo `hairline/50`, `bg-card`, `p-4`. Titolo 16 semibold, sottotitolo 14 ink-secondary `mt-0.5`; X 16 `p-1 rounded-md` in alto a destra. Lista `mt-3 rounded-lg` bordo `hairline/40` overflow hidden; righe `px-3 py-3` gap 12, 15 ink, separatori `border-t hairline/40`, selezionata `bg-raised`, hover `raised/60`; badge lettera A/B/C 24×24 `rounded-md` `bg-raised` 12 medium ink-secondary. Campo "Type your own answer": `mt-3 rounded-lg` bordo `hairline/40` `bg-inset` `px-3 py-2.5` 15. Bottone invio `rounded-lg bg-accent px-3 py-2` 14 medium bianco.

**Code block**: `my-2 rounded-lg` bordo `hairline/40` `bg-inset`; header `px-3 py-1` bordo-b `hairline/30`, lang 11 uppercase, copia 13 `p-1`; corpo `p-3` 13 mono, scroll orizzontale.

### 2.8 Menu contestuale (`Sidebar.tsx:795-880`, `context-menu.png`)
- `fixed` al punto del click, **larghezza 228** (menu sezione 236), `rounded-xl` **12**, bordo 1 pt `hairline/50`, `bg-card #262626`, `py-1.5` (6), ombra `shadow-2xl shadow-black/60` = `0 25 50 -12 rgba(0,0,0,.6)`.
- Voce: `px-3.5 py-2` (14/8), gap 12, icona lucide 16 ink-secondary, testo 14 ink; hover `bg-raised/70`; disabilitata opacity .4; Delete in `danger` (icona inclusa). Altezza voce ≈ 37 pt.
- Divisore: `mx-2 my-1` (8/4), 1 pt `hairline/40`.
- Voci bot: Pin/Unpin · Make Chief of Staff (crown, accent se attivo) · Move to section · Mark as Unread · — · Edit Profile · Duplicate · — · Copy conversation ID · — · Archive · Delete.
- Swift: oggi usa `.contextMenu` nativo (NSMenu, stile sistema). Per il look Grok serve un popover custom (vedi gap #9) — oppure accettare il menu nativo, che su macOS dark è visivamente vicino.

### 2.9 Popover vari
- **Model picker** (`ModelPicker.tsx:223-420`, `model-picker.png`): ancorato `right-0 top-full mt-2` (8 sotto la pill), **380 × max 480**, `rounded-2xl`, bordo `hairline/50`, `bg-card`, `shadow-2xl black/50`. Rail sinistro **56** (`w-14`), `bg-panel`, bordo-r `hairline/40`, `p-2` gap 4; item 36×36 `rounded-lg`, selezionato `bg-raised` + ring 1 `hairline/50`, hover `raised/60`, ProviderMark 18, pallino warning 6 con ring 2 panel; label "Cloud"/"Local" 9. Destra: header `px-4 pt-3.5 pb-2` (nome 14 semibold + chip stato capsula `px-2 py-0.5` 10.5 medium `success/10`), sottotitolo 11.5 `mt-0.5`; search `rounded-lg` bordo hairline/40 `bg-inset` `px-2.5 py-1.5` icona 13 testo 12.5, focus bordo `accent/60`; lista `px-2 pb-2`, righe `rounded-lg px-2.5 py-2` 13, corrente `bg-raised` + check 14 accent; footer `border-t px-4 py-3` 12.5 medium + chevron 14.
- **TaskPicker dropdown**: `right-0 mt-1`, **300**, `rounded-xl` bordo hairline/50 `bg-card` `py-1` shadow; righe `px-2.5 py-2` gap 8, check 13, titolo 13, meta 11; "New task" `border-t px-3 py-2` 13.
- **Command palette** (`CommandPalette.tsx:146-243`): overlay `bg-black/50`, top `14vh`, **max 560 × min(480, 70vh)**, `rounded-xl` bordo hairline/50 `bg-card` shadow-2xl black/60; input row `px-4 py-3` gap 12 bordo-b, lente 16, input 14, kbd 11 bordo `rounded-md`; lista `p-2`; righe `rounded-xl px-3 py-2` gap 12, selezionata `bg-raised`, hover `raised/50`; icona 16.
- **Settings modal** (`SettingsModal.tsx:189-296`, `app-settings.png`): overlay `bg-black/50` `p-6`, **860 × 560**, `rounded-2xl` bordo hairline/50 `bg-panel`, shadow-2xl; nav **190** `p-3` bordo-r hairline/40, voci `rounded-lg px-2.5 py-2` gap 10 icona 15 testo 14, attiva `bg-raised` ink, altre ink-secondary; contenuto header `px-5 py-3` 15 semibold; card interne `rounded-xl bg-card`; input `rounded-lg` bordo hairline/40 `bg-inset px-3 py-2` 14.
- Dialog "New Room": 340, `rounded-2xl` bordo hairline/50 `bg-card p-4`, overlay `black/40`.
- Archived bots: max 760, `rounded-[24px]`, `bg-panel`, backdrop blur 2, overlay `black/55`.
- Toast: `fixed bottom-4 left-4` max 300, `rounded-xl` bordo, `px-3.5 py-2.5` 13, `shadow-xl`.

---

## 3. Colori

### 3.1 Midnight (default, "campionata dall'app Grok", `styles.css:24-66, 78-104`)

| Token | Hex | Theme.swift | Uso |
|---|---|---|---|
| `app` | `#070707` | `app` ✓ | sfondo finestra, main, ground |
| `panel` | `#111111` | `panel` ✓ | sidebar, pannelli destri, chip tool, rail picker, settings modal |
| `raised` | `#2F2F2F` | `raised` ✓ | riga selezionata, hover pieno, fondo indicatore working, badge lettera, switch off |
| `raised-hover` | `#3D3D3D` | `hover` ✓ (rinominare `raisedHover`) | hover di superfici già raised, scrollbar hover, bottone disabilitato |
| `card` | `#262626` | `card` ✓ | bolla bot, card, menu, popover, palette |
| `inset` | `#191919` | `inset` ✓ | codice, input, campi di card |
| `hairline` | `#333333` | `hairline` ✓ | bordi (quasi sempre con alpha 30–50%) |
| `ink` | `#FCFCFC` | `ink` ✓ | testo primario, caret |
| `ink-secondary` | `#FCFCFC` @ 0.60 (`#fcfcfc99`) | `secondary` ✓ | testo secondario, icone |
| — | `#FCFCFC` @ 0.42 (secondary/70) | `tertiary` = 0.38 ✗ | ora per-messaggio, "Queued…": usare 0.42 |
| `accent` | `#1084FE` | `accent` ✓ | send, primari, unread, link, check, switch on |
| `accent-border` | `#459FFE` | manca | bordo accent pieno |
| `focus` | `#459FFE` | manca | anello focus 2 pt offset 2 (`styles.css:267-270`) |
| `accent-text` | `#7FC0FF` | manca | testo accent su scuro (alcune label) |
| `accent-ink` | `#FFFFFF` | manca | testo su fondo accent |
| `bubble-user` | `#5A5A5A` | `bubbleUser` ✓ | bolla utente |
| `success` | `#38D591` | ✓ | check, stato connesso |
| `danger` | `#FF5667` | ✓ | delete, errori, pallino automations |
| `danger-ink` | `#FFFFFF` | manca | testo su danger |
| `warning` | `#FF9800` | ✓ | held, coda, provider in avviso |
| `scrollbar` | `#3D3D3D` | manca | thumb 8 pt, raggio 4, track trasparente |
| `maus-line` | `#FCFCFC` | n/a | (legacy) |
| selection | `accent` 45% | manca | `.textSelection` / `NSTextView.selectedTextAttributes` |
| semafori finti (non-mac) | `#FF5F57 #FEBC2E #28C840` | n/a | |

Alpha ricorrenti da definire in Swift (helper `Theme.x.opacity(n)`): `raised` .70 (search, composer), .60 (pill header, hover picker), .50 (hover righe), .40 (testata approval); `hairline` .30 (bordo sidebar, composer, code header), .40 (chip, divisori, liste), .50 (menu, popover, modal); `accent` .40 (approval/option pending), .25/.05/.10/.15 (Chief of Staff), .12 (badge), .07 (pinned banner), .10 (badge Loaded); `danger` .10/.30/.40; `warning` .10/.30; `success` .10; overlay `black` .40/.50/.55; ombre `black` .50/.60.

Swift `HoverHighlight` (`Theme.swift:45`) usa `card.opacity(0.7)` per hover: deve essere `raised.opacity(0.5)`.

### 3.2 Altre skin (`styles.css:115-249`; `lib/skins.ts`)
| Token | Atelier | Foundry | Lagoon |
|---|---|---|---|
| app | #f5f1eb | #100e0b | #dfeceb |
| panel | #fbf8f2 | #171410 | #ecf4f3 |
| raised | #ffffff | #262019 | #ffffff |
| raised-hover | #f2e9dc | #322b21 | #cfe4e1 |
| card | #ffffff | #1e1a14 | #ffffff |
| inset | #f5f1eb | #0b0a08 | #d5e8e5 |
| hairline | #c8bda8 | #3d3529 | #aebfbd |
| ink | #1a1a18 | #f4efe4 | #14201f |
| ink-secondary | #6b6559 | #b0a696 | #4d5c5b |
| accent | #a05f25 | #d99a3e | #11736d |
| accent-border | #b06a2c | #e8b25e | #14807a |
| accent-text / focus | #96551f | #e0a44c | #0d5f5a |
| accent-ink | #ffffff | #1c150c | #ffffff |
| bubble-user | #f2e9dc | #2a2318 | #cfe4e1 |
| success / danger / warning | #3f6b47 / #a33a32 / #7a5f31 | #57b078 / #e0685e / #dfa441 | #2f6b4f / #a8382f / #7a5a2a |
| danger-ink | #ffffff | #1c0d0b | #ffffff |
| scrollbar | #c9c0ae | #3d3529 | #a6b8b6 |
| font | system-ui | Inter→SF | system-ui |
| radius lg / xl | 6 / 10 | 4 / 8 | 8 / 14 |

Midnight: radius lg 8, xl 12. Nota: `rounded-2xl` (16) e `rounded-full` non cambiano con la skin. Disabled su `bg-accent`/`bg-danger`: fondo `raised-hover`, testo `ink-secondary`, opacity 1 (`styles.css:872-877`). Lo Swift oggi ha solo Midnight: se si vogliono le skin, `Theme` diventa una struct iniettata via `@Environment`.

### 3.3 Palette mascot (`src/lib/mascot.ts:53-100`)
`white #F1F1F3`, `green #009957`, `blue #377FE6`, `red #D94B52`, `orange #E78531`, `purple #8057C8`, `cyan #0EA5C6`, `pink #D84F8B`, `yellow #D8A729`, `teal #01A492`, `coral #E5634E`. Fallback per colore sconosciuto: **green**.
- Gradiente corpo (`Avatar.tsx:114-117`): `[mix(fill,#FFF,0.55), fill, mix(fill,#000,0.42)]` (mix canale per canale, arrotondato), su `linearGradient x1=1 y1=0 x2=0 y2=1` (bounding box: alto-destra → basso-sinistra), stop a 0% / **55%** / 100% (`CursorAvatar.tsx:1631-1635`).
- Inchiostro occhi/bocca (`mascot.ts:98-100`): luma Rec.709 > 0.72 → `#2A2A30`, altrimenti `#FFFFFF` (di fatto solo `white` → scuro).
- Swift `MausPalette` (`MausAvatar.swift:22-41`): manca `white`, fallback `#8E8E93` invece di green, occhi sempre bianchi → vedi gap.

---

## 4. Animazioni

Curve Tailwind: transition default `150ms cubic-bezier(0.4,0,0.2,1)` (`transition-colors/-opacity/-transform/-all`). "Ease out expo-like" del progetto: `cubic-bezier(0.22,1,0.36,1)`.

| Nome | Definizione | Trigger | SwiftUI |
|---|---|---|---|
| `msg-in` | 180 ms `cubic-bezier(.22,1,.36,1)`, translateY 4→0, opacity 0→1 (`styles.css:28,320-323`) | ogni riga messaggio al mount (`ChatView.tsx:332`) | `.transition(.opacity.combined(with: .offset(y: 4)))` + `.animation(.timingCurve(0.22,1,0.36,1, duration: 0.18))`. Swift oggi: offset 6 + spring 0.24 → correggere |
| `panel-in` | 240 ms stessa curva, translateX 28→0 + fade (`:25,306-309`) | apertura Settings/Computer/Inspector | `.transition(.offset(x: 28).combined(with: .opacity))`, `.timingCurve(0.22,1,0.36,1, duration: 0.24)` |
| `pop-in` | 200 ms stessa curva, scale .96 + translateY 6 → 1/0, fade (`:26,310-313`) | modal Archived, "Jump to latest" | `.transition(.scale(0.96).combined(with: .offset(y: 6)).combined(with: .opacity))`, durata 0.2 |
| `caret-blink` | 1 s `step-end` infinito, opacity 1/0 a 50% (`:27,315-318`) | caret di streaming 2×14 | `TimelineView(.periodic(from: .now, by: 0.5))` alternando opacity 1/0 (nessun fade) |
| `shimmer` | 2 s linear infinito; testo con gradiente `ink-secondary 40% → ink 50% → ink-secondary 60%`, background-size 200%, position 200%→−200% (`:29,325-339`) | label "Thinking…" mentre ragiona | `Text` con `.foregroundStyle(LinearGradient)` mascherato, offset fase animato `.linear(duration: 2).repeatForever(autoreverses: false)` |
| `animate-bounce` (Tailwind) | 1 s infinito: 0/100% translateY −25% con `cubic-bezier(.8,0,1,1)`, 50% 0 con `cubic-bezier(0,0,.2,1)` | 3 pallini working, delay 0/150/300 ms | per pallino: `y = -1.5pt` (25% di 6) → 0 → −1.5; `TimelineView(.animation)` con fase `(t + delay) mod 1` e easing descritto. Swift oggi pulsa l'opacità: sostituire |
| `animate-spin` | 1 s linear rotate | Loader2 (spinner) | `ProgressView().controlSize(.small)` o rotazione `.linear(duration:1).repeatForever` |
| `animate-pulse` | 2 s `cubic-bezier(.4,0,.6,1)`, opacity 1→.5→1 | mic in registrazione | `.opacity` animata `.timingCurve(0.4,0,0.6,1,duration:1).repeatForever()` |
| hover reveal | `transition-opacity` 150 ms | copy/pin/edit/ora/archivia | `.opacity(hover ? 1 : 0).animation(.timingCurve(0.4,0,0.2,1,duration:0.15), value: hover)` |
| hover fill | `transition-colors` 150 ms | righe, pill | idem su `background` |
| chevron | `transition-transform` 150 ms, rotate 90° (sezione) / 180° (picker, thinking) | | `.rotationEffect` animato 0.15 |
| switch | `transition-all` 150 ms knob left 3↔21 | toggle | `withAnimation(.timingCurve(0.4,0,0.2,1,duration:0.15))` |
| sidebar mobile | `duration-200` translateX | < md | n/a su desktop |
| reduced motion | tutto off; spinner diventa pulse 1.6 s opacity .45↔1 (`:329-332, 816-847`) | `prefers-reduced-motion` | `@Environment(\.accessibilityReduceMotion)` |

**Keyframe `maus-*` in `styles.css:347-799`**: sono codice morto. Le classi `.maus-character/.maus-face/...` non sono più usate da nessun componente (grep in `src/` trova solo `styles.css`); il mascot è ora `CursorAvatar.tsx`, animato via JS. Non portarli. Il movimento reale del mascot è in §5.

---

## 5. Mascot (bot shapes)

### 5.1 Architettura React
`MausAvatar` (`src/components/Avatar.tsx:173-321`) sceglie fra:
1. `mascotAvatarImage` + `mascotAvatarSheetRow` valido → `SpriteSheetAvatar` (sprite animato).
2. `mascotAvatarImage` senza riga → `<img>` circolare `object-cover`, statico.
3. `mascotAvatarSvg` → `SvgAvatar` (markup SVG caricato dall'utente, clip circolare, id rinominati per istanza `namespaceSvgIds`, `SvgAvatar.tsx:14-22`). Statico.
4. Altrimenti `CursorAvatar` (motore vettoriale) con `silhouette = silhouetteFor(look.mascotSilhouette)`.
Con immagine/SVG non girano né stati, né motion, né gaze.

### 5.2 Geometria comune (`CursorAvatar.tsx`)
- Face box **228.541** unità (`:50`); `viewBox = "-15 -15 258.541 258.541"` (`:51`): 15 unità di margine per bob/sway/effetti. L'avatar da `size` pt mappa 258.541 unità → `size`.
- Faccia: clip alla silhouette (con il suo `fit`), poi `translate(anchor.x anchor.y) scale(anchor.scale) translate(-120 -122.5)` (`anchorTransform`, `:1149-1150`; `FACE_CENTRE` `:58`).
- Occhi: 2 anelli × 48 punti per ciascuna delle **25 espressioni** (`ENCODED`, `:65-92`; parsing `:93-101`). La direzione di sguardo propria di ogni espressione (`GAZE`, `:117-121`) viene sottratta (`EXPRESSIONS`, `:124-126`) e riapplicata × `lookAround`.
- Bocca: `MOUTHS[25] = [halfWidth, curve, gap, skew]` (`:136-162`), tratto **7.5** (`:165`), round cap; geometria in `mouthFrame`/`mouthPath` (`:1109-1147`).
- Proiezione sferica degli occhi: `SPHERE_C 114.2705`, `SPHERE_R 105` (`:52-53`), scala orizzontale per prospettiva con `turn`/`spin` (`:1484-1528`).
- Gaze puntatore: ±**13.2** x, ±**8.4** y unità (`GAZE_X/Y`, `:54-55`); range 1 se `forward`, 0.25 altrimenti (`Avatar.tsx:66`).
- **`lookAround`**: in app `MausAvatar` passa `forward ? 0 : 1` con `forward = true` di default (`Avatar.tsx:190,308`) → **0: occhi sempre centrati**. (Default del componente nudo 0.5; nel draw il fallback è 0.35.)
- Morph fra espressioni: molla critica `f = 7`: `v += (-2·f·v − f²·(m−1))·dt; m += v·dt`, `dt ≤ 0.1 s` (`:1550-1560`). Interpolazione lineare punto per punto, bocca e gaze (`:1725-1743`).
- Blink: 320 ms; scala Y = `1 − t/0.42` per t<0.42, poi `(t−0.42)/0.58`; minimo 0.04 (`:1745-1754`). Cadenza per stato `BLINK` (`:928-1038`, `null` = mai).
- Cambio espressione: dopo `EXPR_CADENCE[state]` ms (`:768-927`) sceglie a caso dal `POOLS[state]` (`:568-767`) escludendo la corrente. All'ingresso nello stato usa `POOLS[state][0]` (faccia a riposo).
- Movimento corpo `MOTION` (`:198-246`) + `bodyTransform` (`:1167-1233`): bob `[amp, period]`, sway `[deg, period]`, pulse `[fraz, period]`, circle, jitter (due onde, la seconda a 0.63 periodo, fase 1.1), tilt fisso, squash (pivot sul "terreno" y = 228.541, `sy = 1−a/2, sx = 1+a/2`), enter `[scala iniziale, ms]` con easeOutBack c=1.7, settle con easeInOut su 1400 ms. Fase = tempo dall'ingresso nello stato.
- Effetti (`:263-521`): **trails** (nastri dietro il corpo: `count` archi, 12 campioni, raggio × (0.78+0.4·seed) × (1 + 0.14·sin(kπ)), y × 0.78, span 0.85–1.55 rad, stroke 5–8, opacity .85, colori `#4ADE80 #34D399 #22D3EE #60A5FA`) per orbit/radar/progress/loading/uploading/sending/receiving (`:336-342`); **confetti** (davanti, stroke 4–6.4 quadratiche lunghe 11–23, gravità 34·t², colori `#F472B6 #C084FC #818CF8 #38BDF8 #34D399 #FACC15 #FB7185`) per celebrate/excited/laughing (`:331-333`); **glyph** "!" / "?" che sostituisce il corpo (fade 200 ms, scala .72→1) per alerting/notifying/confused (`:317-325, 345-347`).
- Frame rate: 30 fps con un unico pump (`:1689-1723`). Al massimo **12** mascot animati insieme (`lib/avatar-frames.ts:35`), priorità a riga selezionata / bot busy / motion in corso; fuori viewport fermi. Mascot in pausa: un solo frame con morph=1.
- Stati: 39 (`CursorState`, `:523`); gruppi in `mascot.ts:15-51`.
- Scelta stato (`mascot.ts:539-582`): pin `mascotExpression` → ultimo tool fallito `alerting` → busy `working` → unread `notifying` → ultimo msg `options` `curious` → keyword del profilo → **`restingFaceFor(id ?? name)`**: FNV-1a 32 bit su id, modulo 7 su `RESTING_FACES = [idle, happy, curious, working, thinking, listening, proud]` (`:192-221`).
- Motion beat one-shot (`Avatar.tsx:77-93`): sovrascrive lo stato per **1400 ms** e/o blink/spin: arrive→spawning+spin 900; switch→waking+spin 620; customize→proud+blink; alert→alerting; thinking; working; launch→loading; success→happy+blink; celebrate→celebrate+spin 700; blink; surprise→surprised+blink; failure→sad. Trigger (`store.tsx:586-1049`): selezione bot→switch; bot nuovo→arrive; mark unread→surprise; frame schermo→success; provisioning→launch; errore→alert; modifica aspetto→customize; invio/edit→working; tool ok/ko→success/failure; inizio/fine busy→working/celebrate; reasoning→thinking; risposta testo→blink. Spin = rotazione `turn` 0→360° in `durationMs` (occhi girano sulla sfera).

### 5.3 Silhouette (`src/lib/mascot.ts`)
Ogni silhouette = `{ name, fit, body, clip, anchor:{x,y,scale} }`. Tutte, tranne `cursor`, sono un solo `<path d>` già nel face box (fit vuoto), body = clip = stesso path (`fromPath`, `:239-249`). **Default `circle`** (`DEFAULT_SILHOUETTE_ID`, `:499`); valori sconosciuti → circle (`:507-514`). Ordine nel picker `MAUS_SILHOUETTE_IDS` (`:472-497`).

| id | Riga | Definizione | anchor x / y / scale |
|---|---|---|---|
| cursor | `CursorAvatar.tsx:39-45` (+ `mascot.ts:331-334`) | path 4 KB in `body`/`clip` (riga 42/43) dentro `<g transform="translate(210,80)">`; fit `translate(-56.5564 -37.6751) scale(0.593899)`; il fill `#000000` è sostituito con il gradiente | 93 / 101 / 0.74 |
| circle | `mascot.ts:338-342` | `M 114.27 9.27 A 105 105 0 1 1 114.27 219.27 A 105 105 0 1 1 114.27 9.27 Z` | 114.27 / 116 / 0.86 |
| squircle | `:343-347` | path letterale | 114.27 / 116 / 0.88 |
| hexagon | `:348-352` | letterale | 114.27 / 118 / 0.80 |
| octagon | `:353-357` | letterale | 114.27 / 116 / 0.86 |
| shield | `:358-362` | letterale | 114.27 / 106 / 0.76 |
| droplet | `:363-367` | letterale | 114.27 / 141 / 0.72 |
| egg | `:368-372` | letterale | 114.27 / 124 / 0.78 |
| capsule | `:373-377` | letterale | 114.27 / 114 / 0.64 |
| star | `:378-382` | letterale | 114.27 / 110 / 0.62 |
| tile | `:386-390` | letterale | 114.27 / 114 / 0.70 |
| oval | `:391-395` | letterale | 114.27 / 115 / 0.74 |
| triangle | `:399-403` | letterale (3 quadratiche) | 114.27 / 143 / 0.56 |
| blob | `:404-408` | letterale | 112 / 116 / 0.78 |
| pill | `:445-449` | letterale | 114.27 / 114 / 0.66 |
| cloud | `:411-415` | `polarPath(a => 92·(0.9+0.1·lobes(6,1)(a)), {sx:1.12, sy:0.96, rotate:8})` | 114.27 / 116 / 0.80 |
| slanted | `:417-423` | `polarPath(a => 86 / (|cos a|⁴+|sin a|⁴)^0.25, {rotate:-16})` | 114.27 / 116 / 0.78 |
| sparkle | `:424-428` | `polarPath(a => 110·(0.6+0.4·spikes(4,1.6)(a)), {rotate:-8, samples:128})` | 114.27 / 116 / 0.58 |
| clover | `:429-433` | `polarPath(a => 106·(0.78+0.22·lobes(4,0.8)(a−π/4)), {rotate:8, samples:128})` | 114.27 / 116 / 0.78 |
| pebble | `:435-439` | `polarPath(a => 88·(1+0.24·spikes(1,5)(a−π)), {sy:0.9, rotate:-20})` | 124 / 118 / 0.72 |
| flower | `:440-444` | `polarPath(a => 104·(0.8+0.2·lobes(7,0.8)(a)), {samples:140})` | 114.27 / 116 / 0.72 |
| pentagon | `:450-454` | `roundedPolygon(5, 108, 0.2, -12)` | 114.27 / 120 / 0.76 |
| burst | `:455-459` | `polarPath(a => 108·(0.72+0.28·spikes(7,1)(a)), {rotate:-90, samples:168})` | 114.27 / 116 / 0.62 |
| gem | `:460` | `roundedPolygon(6, 106, 0.2, 18)` | 114.27 / 116 / 0.80 |

Generatori (da portare 1:1 o, meglio, da pre-calcolare): `BOX_CENTRE = 114.27` (`:252`), `round2` (`:256`), `smoothClosedPath` Catmull-Rom → cubiche (`:262-272`), `polarPath` (samples default 96, sx/sy prima della rotazione, `:279-295`), `lobes(count, fullness) = |cos(count/2·a)|^fullness` (`:298-299`), `spikes(count, sharpness) = ((1+cos(count·a))/2)^sharpness` (`:302-303`), `roundedPolygon` (vertici da −90°+rotate, quadratica per vertice, `:310-323`).
Consiglio: uno script Node (`node --experimental-strip-types` o `tsx`) che importa `MAUS_SILHOUETTES` e stampa `{id, d, anchor}` in `MausSilhouettes.swift` generato → path data verbatim, nessun drift numerico. Il parser Swift attuale (`MausAvatar.swift:146-200`) conosce solo `M C Z`: va esteso ad `A` (archi: circle, squircle, droplet, egg, capsule, tile, oval, pill), `L H V` e `Q` (triangle, pentagon, gem), oppure lo script deve convertire tutto in cubiche assolute.

### 5.4 Sprite sheet e immagini (`src/lib/sprite-sheet.ts`, `SpriteSheetAvatar.tsx`)
- Griglia **9 righe × 8 colonne** (`SHEET_ROWS 9`, `SHEET_COLS 8`), **250 ms/frame** (`:2-4`). Riga = `mascotAvatarSheetRow` intero 0…8 (`clampSheetRow`, `:6-10`), altrimenti immagine statica.
- Frame effettivi per riga misurati sui pixel: un frame conta se ha pixel con alpha > 8 e luminosità > 12 (`:13-27, 28-72`); riga vuota = 1 frame (statica).
- Render: cerchio `size×size`, `bg-black`, `background-size: 8·size × 9·size`, `background-position-y: −size·row`, animazione `steps(frames)` su `frames × 250 ms` fino a `x = −frames·size` (`SpriteSheetAvatar.tsx:47-69`, `styles.css:808-814`). Non si ferma con `animated=false`, solo con reduce-motion.
- Immagine statica/SVG: cerchio, `object-cover`.
- Swift: `TimelineView(.periodic(by: 0.25))` + `Image(nsImage:)` ritagliata con `CGImage.cropping(to:)` sulla cella `(frame·w/8, row·h/9)` e `.clipShape(Circle())` su fondo nero.

### 5.5 Dimensioni avatar per contesto
Sidebar riga bot **32** · room stack 18 (×3) o 32 · header chat **22** · empty state chat **88** · messaggi in room (GroupView) **24** · chip bot↔bot 16 · menu menzioni 24 · dialog New Room 28 · Archived bots 42 · header Settings bot 38 · profilo utente (iniziali) 22. **Nessun avatar accanto alle bolle nelle chat 1:1.**

### 5.6 Stato del port Swift (`Mascot/MausAvatar.swift`, `MausFaceData.swift`)
Supportato: silhouette `cursor` (path verbatim, `:45-138`); 25 espressioni, bocche, pool, cadenze, blink, motion del corpo (`MausFaceData.swift:62-550`); molla f=7; blink 320 ms; 30 fps; gradiente a 3 stop 0/0.55/1 con stessa direzione; comete stile Dynamic Island iOS.
Mancante / divergente:
1. Solo `cursor`; default React è `circle`; mancano le altre 23 silhouette e il campo `mascotSilhouette` nel modello `Bot` (`CompanionCore/Models.swift:172-190`).
2. Anchor `cursor`: Swift `87.04 / 98.65 / 0.84` (`MausFaceData.swift:66`) vs desktop `93 / 101 / 0.74` → occhi più grandi e spostati a sinistra.
3. `lookAround` 0.35 (`MausAvatar.swift:280`) vs 0 in app.
4. Gaze del puntatore assente (`gazeTravel` definito ma inutilizzato); turn/spin sferico assente.
5. Effetti: le "comete" iOS (con `bodyScale` .72–.74 che rimpicciolisce il corpo) ≠ trails desktop (corpo non scalato, archi verdi/ciano/blu); confetti e glyph `!`/`?` assenti.
6. Motion beat one-shot (switch/arrive/success/…) assenti.
7. Colore `white` assente, fallback grigio invece di green, inchiostro occhi sempre bianco (manca `eyeInkFor`).
8. Fallback stato `.idle` (`MascotState.swift:47`) invece di `restingFaceFor` hash FNV-1a.
9. Avatar SVG custom, immagine, sprite sheet assenti (campi `mascotAvatarSvg`, `mascotAvatarImage`, `mascotAvatarSheetRow` mancanti nel modello).
10. Budget animazione: Swift anima in sidebar solo i bot busy; React anima fino a 12 visibili (priorità selezionato/busy/motion).

---

## 6. Gap list prioritizzata (SwiftUI → look Electron)

**P0 — impatto visivo immediato**

1. **Composer** — `Views/ComposerView.swift:38-97, 275-285`. Pill `RoundedRectangle(cornerRadius: 22)` + `Theme.card` + stroke `hairline` → `Capsule()` con fill `Theme.raised.opacity(0.7)` e stroke 1 pt `Theme.hairline.opacity(0.3)`; padding `.leading 16, .trailing 8, .vertical 6`. Testo 15 pt, interlinea 24 (`ComposerTextView` `field.font = .systemFont(ofSize: 15)`, paragraph style `minimumLineHeight/maximumLineHeight 24`), cap 160. Rimuovere il "+" (allegati restano via drop/paste) o renderlo invisibile finché vuoto. Send: cerchio **32**, `Theme.accent`, `arrow.up` 15 semibold **bianco**; visibile solo con contenuto; busy → `Theme.raised` + `clock` ink-secondary. Stop: cerchio 32 trasparente, `stop.fill` 12, hover raised. Wrapper esterno: `.padding(.horizontal, 32).padding(.bottom, 24).padding(.top, 8)`, `maxWidth: 900`. Spostare `ModelPickerButton` nell'header.
2. **Bolle** — `Views/ChatView.swift:353-398`. Font 15 (`Theme.bodySize = 15`) + `.lineSpacing(6.5)`; padding `.horizontal 16, .vertical 10`; raggio **16** `.continuous`; max width relativa: bot 88%, user 70% della colonna (usare `GeometryReader`/`containerRelativeFrame` invece di `bubbleMaxWidth 560`).
3. **Colonna transcript** — `Theme.swift:30` `transcriptMaxWidth 760 → 900`; `ChatView.swift:44,83-84` spacing 6 → **12**, padding orizzontale 24 → **20**, `vertical 16` → top 0 / bottom 16. `ChatView.swift:17-19` composer: vedi #1.
4. **Header chat** — `Views/ChatHeader.swift:14-30`. Altezza 36 → **50** (`.padding(.horizontal, 16).padding(.vertical, 8)`), aggiungere `MausAvatar(size: 22)` prima del titolo (gap 10); a destra (gap 8): pill Task (capsula stroke `hairline.opacity(0.4)`, nessun fill, `plus` 12 + "Task" 12.5 ink-secondary, padding 10/4), pin 16, export 16, model pill (capsula stroke hairline/40 + fill `raised.opacity(0.6)`, padding 8/4/10, logo provider 14, testo 13 ink, chevron 12), icone 18 per computer/inspector con `IconButtonStyle(size: 30)` `RoundedRectangle(6)` invece di `Circle`. Togliere la toolbar di sistema `sidebar.right` (`RootView.swift:34-44`) o fonderla in questa riga.
5. **Sidebar riga bot** — `Views/SidebarView.swift:221-260`. HStack spacing 10 → **8**; padding `.horizontal 8, .vertical 6`, `.trailing 32`; togliere la capsula titolo; preview 12 → **11.5** con `lineSpacing(0)`; ora 11 a destra del nome solo se selezionata; unread dot 7 → **8**; selezione `Theme.raised` raggio 8; hover `Theme.raised.opacity(0.5)` (fix `Theme.swift:45`); LazyVStack spacing 2 → **1**, padding orizzontale 10 → **6**. Chief of Staff: bordo `accent.opacity(0.25/0.4)` + fill `accent.opacity(0.05/0.15)`.
6. **Sidebar header e footer** — `SidebarView.swift:78-139`. Campo ricerca sempre visibile: `RoundedRectangle(8)` fill `raised.opacity(0.7)`, padding 8/6, `magnifyingglass` 12 ink-secondary, testo 13, preceduto da spacer **56** per i semafori; poi "+" 16. Padding riga `10/10/8`. Rimuovere `FeaturedBotCard` (`:195-218`, non esiste in React). Footer: righe "Automations" (`calendar` 15) e "Connected apps" (`puzzlepiece.extension` 15), testo 13, padding 8/6 raggio 8; riga profilo con cerchio iniziali 22 `raised` + nome 13 + `gearshape` 15; nessun bordo superiore; container padding `6/8/4`.
7. **Header sezione** — `SidebarView.swift:180-191`: 10.5 semibold tracking 0.6 tertiary → **10 medium, tracking 0.8, `Theme.secondary`**, + chevron 11 (ruota 90°) + linea 1 pt `hairline.opacity(0.4)` che riempie; padding `.horizontal 8, .top 8, .bottom 2`.
8. **Mascot di default e anchor** — `Mascot/MausFaceData.swift:66` anchor → `(93, 101, 0.74)` per `cursor`; `MausAvatar.swift:280` `lookAround` → **0**; aggiungere `circle` come default (path `mascot.ts:340`, anchor 114.27/116/0.86) con il parser esteso ad `A`; `MausPalette` + `white #F1F1F3`, fallback green, `eyeInk(for:)` (luma > 0.72 → `#2A2A30`) usato in `drawBody` (`:545,552`).

**P1 — fedeltà**

9. **Menu contestuale bot** — `SidebarView.swift` (contextMenu): popover custom 228 pt, `RoundedRectangle(12)` fill `Theme.card`, stroke `hairline.opacity(0.5)`, `.shadow(color: .black.opacity(0.6), radius: 25, y: 25)`, voci 14 pt padding 14/8, icone SF 15 ink-secondary, hover `raised.opacity(0.7)`, divisori `hairline.opacity(0.4)` con inset 8/4; voci e ordine §2.8. (Alternativa a costo zero: tenere NSMenu nativo.)
10. **Approval / Option card** — `Views/OptionCardView.swift:20-60`: raggio 12 → **16**, padding 14 → **16**, maxWidth 560 → **840**; titolo 13.5 → **15 semibold** (approval) / **16** (option) + sottotitolo 14; comando 12.5 mono in `inset` raggio 8 padding 12/8; opzioni come lista bordata con badge lettera 24×24 (§2.7); stato finale 13 con icona 14. Pannello "Pending approval" nel composer con i 4 bottoni capsula 13.5 (Cancel turn / Deny / Always allow / Allow once).
11. **Separatori giorno e ore** — `ChatView.swift:64-70`: 11 medium tertiary → **13 regular `Theme.secondary`**, padding vertical 12, formato `"Today h:mm"`/`"Yesterday h:mm"`/`"EEE, MMM d h:mm"`, solo al cambio di giorno. Ora per-messaggio 11 `monospacedDigit()` `ink.opacity(0.42)` che appare su hover.
12. **Indicatore di lavoro** — `ChatView.swift:469-488`: fondo `Theme.raised` (non card), raggio 16, padding 16/12; pallini 6 con bounce (§4) delay 0/0.15/0.3 s, gap 6; + `Text("Working for \(s)s")` 12.5 secondary, gap 10.
13. **Animazione messaggi** — `ChatView.swift:79,90` e `Theme.swift:32`: offset 4, `.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)`. Pannelli destri: `.transition(.offset(x: 28).combined(with: .opacity))` 0.24 s stessa curva.
14. **Markdown** — `Views/MarkdownText.swift:26-102`: corpo 15 + lineSpacing 6.5; spacing blocchi 8; h1 16 / h2 15.5 / h3-h4 15 / h5 14 / h6 13.5 secondary (oggi 18/16/14); code block: bordo `hairline.opacity(0.4)` raggio 8 fill `inset`, header con label lingua 11 uppercase + copia, corpo 13 mono padding 12 (oggi 12.5, padding 10); inline code 13 mono fill `inset` raggio 4 padding 4/1; link `Theme.accent` sottolineato; liste rientro 20 spacing 4; blockquote barra 2 pt `hairline` (oggi 3 pt `Color.secondary.opacity(0.4)`).
15. **Model picker** — `Views/ModelPicker.swift:14-140`: popover 380 × ≤480, raggio 16, rail 56 con icone provider 36×36 raggio 8, lista righe 13 pt padding 10/8 raggio 8, corrente `raised` + check accent 14, badge "Default" 10 pt su `inset` (oggi colonna 190 + 280 con testo 12.5).
16. **Pannelli destri** — `RootView.swift:30-33`: larghezze 400 (bot settings/computer) e 460 (inspector eventi), sfondo `panel`, bordo sinistro `hairline.opacity(0.4)`, header 16/12 titolo 15 semibold.
17. **Command palette** — `Views/CommandPalette.swift:32-72`: input 16 → **14**, righe raggio 8 → **12**, testo 13 → **14**, sezioni con header 11 medium uppercase tracking 0.88; sfondo `card`, bordo hairline/50, overlay nero 50%, posizionata a 14% dall'alto (non sheet centrato).
18. **Token mancanti in `Theme.swift`** — aggiungere `accentBorder #459FFE`, `focus #459FFE`, `accentText #7FC0FF`, `accentInk #FFF`, `dangerInk #FFF`, `scrollbar #3D3D3D`; `tertiary` 0.38 → 0.42; rinominare `hover` → `raisedHover`; `radius` 12 resta per `rounded-xl`, aggiungere `radiusCard = 16`, `radiusRow = 8`, `radiusIcon = 6`. `PillButtonStyle` (`:58-72`): prominent = `accent` + bianco (oggi ink + nero).

**P2 — mascot completo**

19. Modello `Bot` (`CompanionCore/Models.swift`) + `mascotSilhouette`, `mascotAvatarSvg`, `mascotAvatarImage`, `mascotAvatarSheetRow`.
20. Le 23 silhouette mancanti via script generatore (§5.3) + anchor per silhouette (`MausFaceData.anchor` diventa per-silhouette).
21. `restingFaceFor` FNV-1a in `MascotState.swift:47`.
22. Motion beat one-shot (stato temporaneo 1.4 s + blink/spin) pilotati dagli stessi eventi dello store React.
23. Gaze puntatore (`.onContinuousHover`, ±13.2/±8.4 unità) e proiezione sferica per lo spin.
24. Effetti desktop: trails (sostituire o affiancare le comete; nessun `bodyScale`), confetti, glyph `!`/`?`.
25. Sprite sheet 9×8 / 250 ms, SVG custom (WKWebView offscreen → NSImage, o parser SVG minimale), immagine circolare.
26. Budget animazione: fino a 12 mascot animati visibili in sidebar, priorità selezionato/busy/motion.
27. Skin Atelier/Foundry/Lagoon (`Theme` iniettabile), solo se richiesto.

---

## Sintesi: top 10 gap
1. Composer: capsula `raised/70` bordo `hairline/30`, testo 15/24, send blu accent 32 pt, niente "+", model picker spostato nell'header.
2. Bolle: 15 pt `leading-relaxed`, raggio 16, padding 16/10, larghezze 88% bot / 70% user.
3. Colonna transcript 900 pt, gap 12 tra messaggi, padding 20; separatori giorno 13 pt secondary.
4. Header chat alto 50 pt con avatar 22, pill "+ Task", pill modello, icone 16–18.
5. Sidebar: ricerca sempre visibile + spacer semafori, righe 46 pt (gap 8, padding 8/6, preview 11.5), niente card "featured" né capsula titolo, footer Automations / Connected apps / profilo.
6. Mascot: default `circle` invece di `cursor`, anchor `cursor` 93/101/0.74, `lookAround` 0, colore `white` e inchiostro occhi scuro.
7. Card approval/option: raggio 16, padding 16, larghezza 840, titoli 15–16, lista opzioni con badge lettera, pannello approval nel composer con 4 bottoni.
8. Animazioni: `msg-in` 180 ms `(0.22,1,0.36,1)` offset 4, `panel-in` 240 ms offset 28, pallini bounce su fondo `raised`, caret a scatti, shimmer "Thinking".
9. Markdown: titoli 16/15.5/15, code block con header e bordo, codice 13 mono, link accent.
10. Mascot completo: 23 silhouette mancanti + campi del modello, motion beat, gaze puntatore, effetti trails/confetti/glyph, sprite sheet/SVG.
