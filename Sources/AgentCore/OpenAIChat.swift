// OpenAI-compatible chat completions with Hermes Agent's session continuity
// and a client-side tool loop: what the engine's Local Endpoint driver and the
// iOS app's endpoint bots share (docs/plans/2026-10-22-app-ios.md §3).
//
// The Hermes rules are kept rule for rule because every rule cost a bug to learn:
//
// - we always name the session ourselves (`swarme-<uuid>`), never let Hermes
//   derive one from the first message;
// - while the endpoint is unproven ("unknown") the header goes out AND the
//   body carries the whole branch — right against Hermes and against a plain
//   endpoint alike;
// - only OUR id echoed back proves continuity; LiteLLM echoes upstream
//   headers as `llm_provider-<name>` and only on non-streamed answers, so a
//   silent stream proves nothing either way;
// - only an explicit 403 refusal or a capabilities verdict turns it off, and
//   a 403 mid-turn is recovered by replaying the full branch without header.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public func newId() -> String { UUID().uuidString.lowercased() }

/// What we know about the endpoint's ability to hold the conversation.
public enum Continuity: Equatable, Sendable {
    case unknown
    case session(header: String)
    case none
}

public struct EndpointError: LocalizedError {
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public init(input: Double, output: Double) {
        self.input = input
        self.output = output
    }
}

/// A tool offered to the model, from one connector.
public struct ChatTool: Sendable {
    public var connectorId: String
    public var connectorName: String
    public var name: String
    public var description: String
    public var inputSchema: JSON

    public init(connectorId: String, connectorName: String, name: String, description: String, inputSchema: JSON) {
        self.connectorId = connectorId
        self.connectorName = connectorName
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct ToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

@MainActor
public final class OpenAIChatEndpoint {
    public static let hermesHeader = "X-Hermes-Session-Id"
    public static let proxyPrefix = "llm_provider-"
    /// How many times one turn may go back to the model with tool results.
    public static let maxToolRounds = 20

    public var baseUrl: String
    public var apiKey: String
    /// Extra headers on every request (the iOS app's custom headers).
    public var headers: [String: String]
    public let session: URLSession
    public var hermes: Continuity = .unknown
    /// The error when `baseUrl` is not a URL.
    public var missingURLMessage = "Set the Local Endpoint URL in Settings → Connections"
    /// Models that answered 400 to a request carrying `tools`: no tools for
    /// them until the catalog is read again.
    public var toolsUnsupported = Set<String>()

    public init(baseUrl: String, apiKey: String, headers: [String: String] = [:], session: URLSession = .shared) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.headers = headers
        self.session = session
    }

    public var isSession: Bool { if case .session = hermes { return true } else { return false } }

    /// The session a new turn names: the thread's cursor, or a fresh one;
    /// none once the endpoint said it does not keep sessions.
    public func session(cursor: String?) -> String? {
        hermes == .none ? nil : (cursor ?? "swarme-\(newId())")
    }

    private func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Catalog

    /// `/v1/capabilities`: only a clear "hermes-agent with auth" is a yes; only
    /// an answer naming something else is a no; anything else stays unknown.
    public func probeHermes() async -> Continuity? {
        guard let url = URL(string: baseUrl.trimmingSuffix("/") + "/capabilities") else { return nil }
        let request = request(url, timeout: 5)
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return .unknown }
        guard let json = try? JSON.parse(data) else { return .unknown }
        guard json["platform"]?.string == "hermes-agent" else { return Continuity.none }
        guard json["auth"]?["required"]?.bool == true else { return Continuity.none }
        let header = json["features"]?["session_continuity_header"]?.string
        return .session(header: (header?.isEmpty == false ? header! : Self.hermesHeader))
    }

    /// What `probeHermes` found: an inconclusive probe never undoes what a
    /// real turn established.
    public func applyProbe(_ verdict: Continuity?) {
        if let verdict, verdict != .unknown || hermes == .unknown { hermes = verdict }
    }

    // MARK: Requests

    public struct Completion {
        public var text: String
        public var usage: TokenUsage?
        public var sessionId: String?
        /// What the model asked to run, in the order it listed them.
        public var toolCalls: [ToolCall] = []
    }

    /// The session Hermes says served the turn — directly or renamed by a proxy.
    public static func sessionEcho(_ response: HTTPURLResponse, _ name: String) -> String? {
        let value = response.value(forHTTPHeaderField: name) ?? response.value(forHTTPHeaderField: proxyPrefix + name)
        return value?.isEmpty == false ? value : nil
    }

    /// `tool_calls` of a whole (non-streamed) message.
    public static func toolCalls(_ value: JSON?) -> [ToolCall] {
        (value?.array ?? []).enumerated().map { index, call in
            ToolCall(id: call["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)_\(newId().prefix(6))",
                     name: call["function"]?["name"]?.string ?? "",
                     arguments: call["function"]?["arguments"]?.string ?? "")
        }
    }

    public func complete(_ messages: [JSON], model: String, stream: Bool, sessionId: String?, tools: [JSON]? = nil,
                         onDelta: ((String) -> Void)? = nil) async throws -> Completion {
        guard let url = URL(string: baseUrl + "/chat/completions") else { throw EndpointError(status: 0, message: missingURLMessage) }
        let headerName: String
        if case let .session(header) = hermes { headerName = header } else { headerName = Self.hermesHeader }
        var request = request(url, timeout: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: headerName) }
        var body: JSONObject = ["model": .string(model), "messages": .array(messages), "stream": .bool(stream)]
        if let tools { body["tools"] = .array(tools) }
        request.httpBody = JSON.object(body).data

        if !stream {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let echo = http.flatMap { Self.sessionEcho($0, headerName) }
            guard let http, (200...299).contains(http.statusCode) else {
                let body = String(decoding: data.prefix(200), as: UTF8.self)
                throw EndpointError(status: http?.statusCode ?? 0, message: "Local Endpoint HTTP \(http?.statusCode ?? 0)\(body.isEmpty ? "" : ": \(body)")")
            }
            let json = try? JSON.parse(data)
            let usage = json?["usage"].map { TokenUsage(input: $0["prompt_tokens"]?.double ?? 0, output: $0["completion_tokens"]?.double ?? 0) }
            let message = json?["choices"]?.array?.first?["message"]
            return Completion(text: message?["content"]?.string ?? "", usage: usage, sessionId: echo, toolCalls: Self.toolCalls(message?["tool_calls"]))
        }

        let (bytes, response) = try await session.streamingBytes(for: request)
        let http = response as? HTTPURLResponse
        let echo = http.flatMap { Self.sessionEcho($0, headerName) }
        guard let http, (200...299).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 200 { break }
            }
            let text = String(decoding: body, as: UTF8.self)
            throw EndpointError(status: http?.statusCode ?? 0, message: "Local Endpoint HTTP \(http?.statusCode ?? 0)\(text.isEmpty ? "" : ": \(text)")")
        }
        var text = ""
        var usage: TokenUsage?
        // tool calls arrive in pieces, keyed by index: id and name first, the arguments in fragments
        var calls: [Int: ToolCall] = [:]
        for try await raw in bytes.lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { continue }
            guard let chunk = try? JSON.parse(data) else { continue }
            let delta = chunk["choices"]?.array?.first?["delta"]
            if let piece = delta?["content"]?.string, !piece.isEmpty {
                text += piece
                onDelta?(piece)
            }
            for (position, call) in (delta?["tool_calls"]?.array ?? []).enumerated() {
                let index = call["index"]?.int ?? position
                var entry = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                if let id = call["id"]?.string, !id.isEmpty { entry.id = id }
                // some servers repeat the whole name on every fragment
                if let name = call["function"]?["name"]?.string, !name.isEmpty, name != entry.name { entry.name += name }
                if let arguments = call["function"]?["arguments"]?.string { entry.arguments += arguments }
                calls[index] = entry
            }
            if let reported = chunk["usage"], !reported.isNull {
                usage = .init(input: reported["prompt_tokens"]?.double ?? 0, output: reported["completion_tokens"]?.double ?? 0)
            }
        }
        let toolCalls = calls.sorted { $0.key < $1.key }.map { index, call in
            var call = call
            if call.id.isEmpty { call.id = "call_\(index)_\(newId().prefix(6))" }
            return call
        }
        return Completion(text: text, usage: usage, sessionId: echo, toolCalls: toolCalls)
    }

    // MARK: Tools

    /// Connector tools as OpenAI `tools`, and the way back from the name the
    /// model calls to the connector and tool. Names become `<id>__<tool>`,
    /// within `^[a-zA-Z0-9_-]{1,64}$`; a long or clashing one gets a hash.
    public static func openAITools(_ tools: [ChatTool]) -> (tools: [JSON], routes: [String: ChatTool]) {
        var out: [JSON] = []
        var routes: [String: ChatTool] = [:]
        for tool in tools {
            let raw = "\(tool.connectorId)__\(tool.name)"
            var name = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" ? Character($0) : "_" })
            if name.count > 64 || routes[name] != nil {
                let hash = String(format: "%06x", raw.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 } & 0xFFFFFF)
                name = String(name.prefix(57)) + "_" + hash
            }
            routes[name] = tool
            out.append(["type": "function", "function": [
                "name": .string(name),
                "description": .string(String("[\(tool.connectorName)] \(tool.description)".prefix(1024))),
                "parameters": tool.inputSchema.object != nil ? tool.inputSchema : ["type": "object", "properties": .object(JSONObject())],
            ]])
        }
        return (out, routes)
    }

    // MARK: Turns

    public struct TurnResult {
        /// The text of every round, a paragraph apart.
        public var text: String
        public var usage: TokenUsage?
    }

    /// One turn: the model, the tools it asks for, the model again, until it
    /// answers without tools or runs out of rounds.
    ///
    /// - `messages` is what goes out first (with a proven session: system and
    ///   the latest message only); `full` is the whole branch, replayed when
    ///   Hermes refuses the session.
    /// - `onDelta` gets the text as it streams; a later round's text starts on
    ///   a new paragraph.
    /// - `note` gets a line for the transcript when something about the tools
    ///   went wrong; `runTools` answers the calls of one round with `tool`
    ///   messages, in the model's order.
    public func runTurn(model: String, session: String?, messages: [JSON], full: [JSON], tools offered: [JSON]?,
                        onDelta: @escaping (String) -> Void, note: (String) -> Void,
                        runTools: ([ToolCall]) async -> [JSON]) async throws -> TurnResult {
        var offered = offered
        var replied = false
        var roundStarted = false
        let delta: (String) -> Void = { piece in
            if replied, !roundStarted { onDelta("\n\n") }
            roundStarted = true
            onDelta(piece)
        }
        var conversation = messages
        var requestSession = session
        var texts: [String] = []
        var usage: TokenUsage?
        var firstEcho: String?
        var round = 0
        while true {
            let tools = round < Self.maxToolRounds ? offered : nil
            roundStarted = false
            var result: Completion
            do {
                result = try await complete(conversation, model: model, stream: true, sessionId: requestSession, tools: tools, onDelta: delta)
            } catch let error as EndpointError where requestSession != nil && error.status == 403 && round == 0 {
                // Hermes refused continuation: replay the whole branch, no header
                hermes = .none
                requestSession = nil
                conversation = full
                result = try await complete(conversation, model: model, stream: true, sessionId: nil, tools: tools, onDelta: delta)
            } catch let error as EndpointError where tools != nil && error.status == 400 && round == 0 {
                // a model without function calling: the turn goes on without tools
                toolsUnsupported.insert(model)
                offered = nil
                note("Questo modello non accetta strumenti: connettori non usati")
                result = try await complete(conversation, model: model, stream: true, sessionId: requestSession, onDelta: delta)
            }
            try Task.checkCancellation()
            if round == 0 { firstEcho = result.sessionId }
            if !result.text.isEmpty {
                texts.append(result.text)
                replied = true
            }
            if let reported = result.usage {
                usage = .init(input: (usage?.input ?? 0) + reported.input, output: (usage?.output ?? 0) + reported.output)
            }
            guard tools != nil, !result.toolCalls.isEmpty else { break }
            var assistant: JSONObject = ["role": "assistant", "content": result.text.isEmpty ? .null : .string(result.text)]
            assistant["tool_calls"] = .array(result.toolCalls.map {
                ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments)]]
            })
            conversation.append(.object(assistant))
            conversation += await runTools(result.toolCalls)
            try Task.checkCancellation()
            round += 1
            if round == Self.maxToolRounds {
                note("Limite di \(Self.maxToolRounds) giri di strumenti raggiunto: il modello conclude senza")
            }
        }
        // only OUR id coming back is proof; a silent stream proves nothing
        let honoured = firstEcho != nil && firstEcho == session
        if honoured {
            if case .session = hermes {} else { hermes = .session(header: Self.hermesHeader) }
        } else if case .session = hermes {
            hermes = .unknown
        }
        return TurnResult(text: texts.joined(separator: "\n\n"), usage: usage)
    }
}

extension String {
    public func trimmingSuffix(_ suffix: String) -> String {
        var out = self
        while out.hasSuffix(suffix) { out.removeLast(suffix.count) }
        return out
    }
}
