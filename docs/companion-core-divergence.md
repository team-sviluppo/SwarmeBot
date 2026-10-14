# CompanionCore — divergenze dalla copia iOS

`Sources/CompanionCore` è copiato da `SwarmeBot/ios/Sources/CompanionCore` (commit `1cd755d`),
con i suoi 108 test e le fixture. Le modifiche per il desktop sono tutte **additive** (campi
opzionali, nuovo file), quindi la decodifica resta compatibile con i payload del harness e
il riallineamento con la copia iOS è un diff piccolo.

| File | Modifica |
|---|---|
| `Models.swift` | `ModelSelection.effort` + init pubblico; `Bot.section/activity/pinnedMessageId/cwd`; `ModelOption.effortLevels`; nuovo `InstanceCapabilities`; `Instance.capabilities/pickerVisible/access` + `effortLevels(for:)` |
| `Client.swift` | `makeRequest`, `send`, `perform` da `private` a `internal`, per l'estensione desktop |
| `Client+Desktop.swift` | **nuovo**: `BotPatch`, `health()`, `patchBot`, `deleteBot`, `deleteRoom`, `interrupt(roomId:)` |
| `Models.swift` | `Bot.mascotSilhouette`, `Bot.mascotAvatarSvg`, `Bot.mascotAvatarImage`, `Bot.mascotAvatarSheetRow`: opzionali, aspetto del mascot desktop. `mascotAvatarSheetRow` è `Double?` così un valore non intero non fa fallire la decodifica del bot; l'app accetta solo interi 0…8 |

Quando l'app iOS verrà spostata qui (o il package estratto in un repo comune), queste
modifiche vanno portate anche lì: sono innocue per il telefono.
