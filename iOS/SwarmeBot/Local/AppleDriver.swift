// Apple's on-device model (Foundation Models, plan §4.5): chat only — no
// tools and no images (D2). The context is short (about 4,000 tokens), so the
// chat so far goes in as the tail of the instructions, oldest messages first
// to go, and the model is told when some were left out.
import Foundation
import FoundationModels

@MainActor
final class AppleDriver: LocalDriver {
    /// Characters of past chat handed to the model: well inside its window,
    /// leaving room for the instructions, the prompt and the answer.
    static let historyBudget = 6_000

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(tr("Questo dispositivo non supporta Apple Intelligence."))
            case .appleIntelligenceNotEnabled: return .unavailable(tr("Attiva Apple Intelligence in Impostazioni per usare questo modello."))
            case .modelNotReady: return .unavailable(tr("Il modello di Apple si sta ancora scaricando: riprova più tardi."))
            @unknown default: return .unavailable(tr("Il modello di Apple non è disponibile."))
            }
        }
    }

    static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize: return tr("La chat è troppo lunga per il modello di Apple: inizia una nuova chat.")
        case .guardrailViolation, .refusal: return tr("Il modello di Apple ha rifiutato di rispondere.")
        case .unsupportedLanguageOrLocale: return tr("Il modello di Apple non supporta questa lingua.")
        case .assetsUnavailable: return tr("Il modello di Apple non è disponibile in questo momento.")
        default: return tr("Il modello di Apple non ha risposto (%@).", String(describing: error))
        }
    }

    static func instructions(_ bot: LocalBot, history: [LocalMessage]) -> String {
        var lines: [String] = []
        var used = 0
        var cut = false
        for message in history.reversed() where message.role == .user || message.role == .bot {
            let line = (message.role == .user ? "User: " : "Assistant: ") + transcriptText(message)
            if used + line.count > historyBudget {
                cut = true
                break
            }
            used += line.count
            lines.insert(line, at: 0)
        }
        // model-facing text stays English, like the engine's; the answer follows the user's language
        var out = (bot.instructions.isEmpty ? "You are a helpful assistant." : bot.instructions)
            + "\nAlways answer in the language the user writes in."
        if !lines.isEmpty {
            out += "\n\nThe conversation so far" + (cut ? " (older messages left out)" : "") + ":\n" + lines.joined(separator: "\n")
        }
        return out
    }

    func run(_ input: TurnInput, sink: TurnSink) async throws -> TurnOutcome {
        if case let .unavailable(reason) = Self.availability { throw DriverError(message: reason) }
        let session = LanguageModelSession(instructions: Self.instructions(input.bot, history: input.history))
        var text = ""
        do {
            for try await snapshot in session.streamResponse(to: transcriptText(input.latest)) {
                let content = snapshot.content
                // each snapshot is the answer so far
                if content.hasPrefix(text) {
                    let piece = String(content.dropFirst(text.count))
                    if !piece.isEmpty { sink.delta(piece) }
                }
                text = content
            }
        } catch let error as LanguageModelSession.GenerationError {
            throw DriverError(message: Self.describe(error))
        }
        return TurnOutcome(text: text, usage: nil, sessionId: nil)
    }
}
