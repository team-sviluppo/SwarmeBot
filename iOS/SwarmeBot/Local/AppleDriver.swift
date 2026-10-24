// Apple's on-device model (Foundation Models, plan §4.5): chat and the
// phone's own tools — no connectors, no images (D2). The context is short
// (about 4,000 tokens), so the chat so far goes in as the tail of the
// instructions, oldest messages first to go, and the model is told when some
// were left out.
import AgentCore
import Foundation
import FoundationModels

@MainActor
final class AppleDriver: LocalDriver {
    /// Characters of past chat handed to the model: well inside its window,
    /// leaving room for the instructions, the prompt and the answer.
    static let historyBudget = 6_000
    /// With tools on, their schemas take part of the window.
    static let historyBudgetWithTools = 3_000

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

    static func instructions(_ bot: LocalBot, history: [LocalMessage], tools: Bool = false) -> String {
        var lines: [String] = []
        var used = 0
        var cut = false
        let budget = tools ? historyBudgetWithTools : historyBudget
        for message in history.reversed() where message.role == .user || message.role == .bot {
            let line = (message.role == .user ? "User: " : "Assistant: ") + transcriptText(message)
            if used + line.count > budget {
                cut = true
                break
            }
            used += line.count
            lines.insert(line, at: 0)
        }
        // model-facing text stays English, like the engine's; the answer follows the user's language
        var out = (bot.instructions.isEmpty ? "You are a helpful assistant." : bot.instructions)
            + "\nAlways answer in the language the user writes in."
        if tools { out += "\n" + PhoneTools.now() + " Use the tools to act on the user's phone; never claim something was done unless a tool said so." }
        if !lines.isEmpty {
            out += "\n\nThe conversation so far" + (cut ? " (older messages left out)" : "") + ":\n" + lines.joined(separator: "\n")
        }
        return out
    }

    func run(_ input: TurnInput, sink: TurnSink) async throws -> TurnOutcome {
        if case let .unavailable(reason) = Self.availability { throw DriverError(message: reason) }
        let tools = input.tools.map { Self.tools($0, sink: sink) } ?? []
        let session = LanguageModelSession(tools: tools, instructions: Self.instructions(input.bot, history: input.history, tools: !tools.isEmpty))
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

    /// The bot's phone tools as Foundation Models tools; a schema the
    /// framework refuses leaves its tool out.
    static func tools(_ box: ToolBox, sink: TurnSink) -> [any Tool] {
        box.phoneTools.compactMap { tool in
            let properties = tool.parameters.map { parameter in
                DynamicGenerationSchema.Property(name: parameter.name, description: parameter.description,
                                                 schema: parameter.integer ? DynamicGenerationSchema(type: Int.self) : DynamicGenerationSchema(type: String.self),
                                                 isOptional: !parameter.required)
            }
            guard let schema = try? GenerationSchema(root: DynamicGenerationSchema(name: tool.name, properties: properties), dependencies: []) else {
                return nil
            }
            return PhoneModelTool(name: tool.name, description: tool.description, parameters: schema) { arguments in
                let id = sink.toolStarted("\(tr("Telefono")) · \(tool.name)", arguments)
                let parsed = (try? JSON.parse(arguments)) ?? .object(JSONObject())
                let answer = await box.callPhone(tool.name, arguments: parsed)
                sink.toolDone(id, answer.ok, answer.text)
                return answer.text
            }
        }
    }
}

/// A phone tool as Foundation Models sees it: a schema built at run time,
/// the arguments handed on as JSON.
struct PhoneModelTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let run: @MainActor @Sendable (String) async -> String

    func call(arguments: GeneratedContent) async throws -> String {
        await run(arguments.jsonString)
    }
}
