// One turn of a phone bot (plan §4.2): the driver streams the reply, calls
// the connectors' tools when the model asks, and says how it ended. The chat
// (LocalChat) turns these callbacks into messages.
import AgentCore
import Foundation

@MainActor
struct TurnSink {
    /// Reply text as it streams.
    var delta: (String) -> Void
    /// A tool call started: its title and arguments; returns an id for `toolDone`.
    var toolStarted: (String, String) -> String
    var toolDone: (String, Bool, String) -> Void
    /// A line for the transcript when something about the tools went wrong.
    var note: (String) -> Void
}

struct TurnOutcome {
    var text: String
    var usage: TokenUsage?
    /// The Hermes session the next turn continues.
    var sessionId: String?
}

struct TurnInput {
    var bot: LocalBot
    /// An endpoint bot's server.
    var server: LocalServer?
    /// The settled chat before this turn, oldest first.
    var history: [LocalMessage]
    var latest: LocalMessage
    /// The latest message's images, as files.
    var images: [(data: Data, mime: String)]
    var tools: ToolBox?
}

@MainActor
protocol LocalDriver: AnyObject {
    func run(_ input: TurnInput, sink: TurnSink) async throws -> TurnOutcome
}

struct DriverError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What the user wrote, after the text of the PDFs they attached.
func promptText(_ message: LocalMessage) -> String {
    ((message.documents ?? []).map(\.promptBlock) + [message.text]).filter { !$0.isEmpty }.joined(separator: "\n\n")
}

/// The text a past message contributes to a model's context.
func transcriptText(_ message: LocalMessage) -> String {
    let text = promptText(message)
    return message.images.isEmpty ? text : text + "\n" + message.images.map { _ in "[immagine allegata]" }.joined(separator: " ")
}

// MARK: - Endpoint

/// An OpenAI-compatible API, with the engine's own rules for Hermes session
/// continuity and the tool loop (AgentCore's `OpenAIChatEndpoint`).
@MainActor
final class EndpointDriver: LocalDriver {
    private var endpoints: [String: OpenAIChatEndpoint] = [:]
    private var probed = Set<String>()

    /// One endpoint object per bot and address: it remembers what the
    /// endpoint proved about sessions and tools while the app runs.
    private func endpoint(for bot: LocalBot, _ server: LocalServer) -> OpenAIChatEndpoint {
        let key = "\(bot.id)|\(server.baseUrl)"
        let apiKey = Keychain.get(server.apiKeyAccount) ?? ""
        if let known = endpoints[key] {
            known.apiKey = apiKey
            known.headers = server.headers
            return known
        }
        let created = OpenAIChatEndpoint(baseUrl: server.baseUrl.trimmingSuffix("/"), apiKey: apiKey, headers: server.headers)
        created.missingURLMessage = tr("L'indirizzo dell'endpoint non è valido.")
        endpoints[key] = created
        return created
    }

    func run(_ input: TurnInput, sink: TurnSink) async throws -> TurnOutcome {
        guard let config = input.bot.endpoint, let server = input.server else {
            throw DriverError(message: tr("Questo bot non ha un server: sceglilo in Modifica il bot."))
        }
        let endpoint = endpoint(for: input.bot, server)
        // `/v1/capabilities` once per endpoint while the app runs, as the engine does on a catalog read
        if probed.insert(ObjectIdentifier(endpoint).debugDescription).inserted { endpoint.applyProbe(await endpoint.probeHermes()) }
        let session = endpoint.session(cursor: input.bot.sessionId)
        // the phone's tools take local times: the model has to know when now is
        let now = input.tools?.phoneTools.isEmpty == false ? PhoneTools.now() : ""
        let prompt = [input.bot.instructions, now].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let system: [JSON] = prompt.isEmpty ? [] : [["role": "system", "content": .string(prompt)]]
        let replay: [JSON] = input.history.compactMap { message in
            switch message.role {
            case .user: return ["role": "user", "content": .string(transcriptText(message))]
            case .bot: return message.text.isEmpty ? nil : ["role": "assistant", "content": .string(message.text)]
            case .tool, .note: return nil
            }
        }
        var content: JSON = .string(promptText(input.latest))
        if config.images, !input.images.isEmpty {
            var parts: [JSON] = [["type": "text", "text": .string(promptText(input.latest))]]
            for image in input.images {
                parts.append(["type": "image_url", "image_url": ["url": .string("data:\(image.mime);base64,\(image.data.base64EncodedString())")]])
            }
            content = .array(parts)
        } else if !input.images.isEmpty {
            content = .string(transcriptText(input.latest))
        }
        let latest: JSON = ["role": "user", "content": content]
        let full = system + replay + [latest]
        let messages = endpoint.isSession ? system + [latest] : full

        var offered: [JSON]?
        var routes: [String: ChatTool] = [:]
        if let tools = input.tools, !endpoint.isSession, !endpoint.toolsUnsupported.contains(config.model) {
            let listed = await tools.tools()
            for failure in listed.failures { sink.note(tr("Connettore non raggiungibile — %@", failure)) }
            let converted = OpenAIChatEndpoint.openAITools(listed.tools)
            if !converted.tools.isEmpty { (offered, routes) = converted }
        }
        let result = try await endpoint.runTurn(
            model: config.model, session: session, messages: messages, full: full, tools: offered,
            onDelta: sink.delta, note: sink.note,
            runTools: { calls in
                var answers: [JSON] = []
                for call in calls {
                    let route = routes[call.name]
                    let id = sink.toolStarted(route.map { "\($0.connectorName) · \($0.name)" } ?? call.name, call.arguments)
                    let answer = await input.tools?.call(route, arguments: call.arguments)
                        ?? ToolBox.Result(text: "Unknown tool \(call.name).", ok: false)
                    sink.toolDone(id, answer.ok, answer.text)
                    answers.append(["role": "tool", "tool_call_id": .string(call.id), "content": .string(answer.text)])
                }
                return answers
            })
        return TurnOutcome(text: result.text, usage: result.usage, sessionId: session)
    }
}
