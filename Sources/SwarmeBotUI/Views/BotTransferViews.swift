import CompanionCore
import SwarmeKit
import SwiftUI

/// A bot of the shown engine and where it is going.
struct BotTransferRequest: Identifiable {
    let bot: Bot
    let target: EngineChoice
    var id: String { "\(bot.id)>\(target)" }
}

/// "Sposta su…": what goes over and what does not, then the move; at the end
/// the new webhook addresses, which are shown once.
struct BotTransferSheet: View {
    let request: BotTransferRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var routines: [Routine]?
    @State private var webhooks: [WebhookTrigger] = []
    @State private var deleteOriginal = true
    @State private var busy = false
    @State private var error: String?
    @State private var result: BotTransferResult?

    private var source: String { model.engineName }
    private var target: String { model.engineName(request.target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result { done(result) } else { confirm }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            do {
                (routines, webhooks) = try await model.automationsToMove(request.bot)
            } catch {
                self.error = error.localizedDescription
                routines = []
            }
        }
    }

    @ViewBuilder
    private var confirm: some View {
        Text(tr("Spostare %@ su %@?", request.bot.name, target)).font(.headline)
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("Su %@ nasce un bot con lo stesso nome, titolo, istruzioni, colore e immagine.", target), systemImage: "person.crop.circle.badge.plus")
            Label(tr("Modello, skill e connettori si configurano a mano su %@: si sceglie tra quelli disponibili lì.", target), systemImage: "slider.horizontal.3")
            Label(tr("Le chat non vengono spostate."), systemImage: "bubble.left.and.bubble.right")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)

        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if let routines {
                    if routines.isEmpty, webhooks.isEmpty {
                        Text(tr("Nessuna automazione collegata a questo bot.")).foregroundStyle(.secondary)
                    } else {
                        Text(tr("Queste automazioni passano su %@ e vengono eliminate da %@:", target, source))
                        ForEach(routines) { Label($0.name, systemImage: "clock") }
                        ForEach(webhooks) { Label($0.name, systemImage: "bolt.horizontal") }
                        if !webhooks.isEmpty {
                            Text(tr("Ogni webhook avrà un nuovo URL e un nuovo segreto, da aggiornare dove lo chiami."))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 12.5))
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Toggle(tr("Elimina il bot da %@, con le sue chat", source), isOn: $deleteOriginal)
        if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
        HStack {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(tr("Annulla")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            Button(tr("Sposta")) { Task { await move() } }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || routines == nil)
        }
    }

    @ViewBuilder
    private func done(_ result: BotTransferResult) -> some View {
        Text(tr("%@ è su %@", result.bot.name, target)).font(.headline)
        Text(tr("Scegli modello, skill e connettori nelle impostazioni del bot su %@.", target))
            .font(.system(size: 12.5)).foregroundStyle(.secondary)
        if !result.routines.isEmpty {
            Text(tr("Routine spostate: %@", result.routines.joined(separator: ", "))).font(.system(size: 12.5))
        }
        if !result.webhooks.isEmpty {
            Text(tr("Nuovi URL dei webhook: copiali ora, il segreto non verrà mostrato di nuovo.")).foregroundStyle(Theme.warning)
            ForEach(result.webhooks) { webhook in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: webhook.name).font(.system(size: 12.5, weight: .medium))
                    if let url = webhook.credential?.url {
                        HStack {
                            Text(verbatim: url).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                            Button(tr("Copia")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                        }
                    } else {
                        Text(tr("%@ non ha un indirizzo pubblico per i webhook: configuralo, poi rigenera il segreto dal pannello Automazioni.", target))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        ForEach(result.warnings, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(Theme.danger).textSelection(.enabled) }
        HStack {
            Spacer()
            Button(tr("Chiudi")) { dismiss() }
            Button(tr("Apri il bot")) {
                model.open(bot: result.bot.id, on: request.target)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func move() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            result = try await model.move(request.bot, to: request.target, deleteOriginal: deleteOriginal)
        } catch {
            self.error = tr("Spostamento non riuscito, nulla è cambiato: %@", error.localizedDescription)
        }
    }
}
