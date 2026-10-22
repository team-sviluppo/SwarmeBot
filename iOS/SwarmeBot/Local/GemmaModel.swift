// Gemma on the phone (plan §4.4, phase 0 in §13): Gemma 4 E4B, 4-bit, run
// with MLX. The weights are downloaded on request at a pinned revision into
// Application Support (out of the backup), checked against their LFS SHA-256,
// and loaded only while a chat needs them. One VLM container answers text,
// tool calls (the model's own `.gemma4` format, parsed by mlx-swift-lm) and
// images.
//
// Phase 0 measured a peak of about 5 GiB: the model is offered only on
// phones with 8 GB or more, with the increased-memory-limit entitlement and
// a small MLX cache. MLX does not run on the simulator.
import AgentCore
import CoreImage
import CryptoKit
import Foundation
import Observation
import UIKit
#if !targetEnvironment(simulator)
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers
#endif

@MainActor
@Observable
final class GemmaModel: LocalDriver {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case verifying
        case downloaded
        case loading
        case ready
        case failed(String)
    }

    struct File {
        var name: String
        var bytes: Int64
        /// The LFS SHA-256, for the files stored in LFS.
        var sha256: String?
    }

    static let repo = "mlx-community/gemma-4-e4b-it-4bit"
    static let revision = "475b9088d29754a3379866cf5aeb6b41acd313c2"
    static let files: [File] = [
        File(name: "config.json", bytes: 6_628),
        File(name: "generation_config.json", bytes: 208),
        File(name: "chat_template.jinja", bytes: 17_336),
        File(name: "processor_config.json", bytes: 1_316),
        File(name: "tokenizer_config.json", bytes: 2_740),
        File(name: "model.safetensors.index.json", bytes: 240_961),
        File(name: "tokenizer.json", bytes: 32_169_626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
        File(name: "model.safetensors", bytes: 5_146_800_534, sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    /// What MLX may keep cached between evaluations (phase 0: −0.25 GB of peak).
    static let cacheLimit = 20 * 1024 * 1024
    /// How many times one turn may go back to the model with tool results.
    static let maxToolRounds = 20

    private(set) var state: State = .notDownloaded

    @ObservationIgnored private var download: Task<Void, Never>?
    @ObservationIgnored private var idle: Task<Void, Never>?
    #if !targetEnvironment(simulator)
    @ObservationIgnored private var container: ModelContainer?
    #endif

    init() {
        state = Self.isComplete ? .downloaded : .notDownloaded
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unload() }
        }
    }

    // MARK: Availability

    /// Nil when this phone can run it; otherwise why not.
    static var unavailableReason: String? {
        #if targetEnvironment(simulator)
        return tr("Gemma non gira nel simulatore: provalo su un iPhone.")
        #else
        // 8 GB phones report a little less than 8 GiB
        return ProcessInfo.processInfo.physicalMemory >= 7_500_000_000 ? nil : tr("Gemma richiede un iPhone con almeno 8 GB di memoria.")
        #endif
    }

    static var folder: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Models/gemma-4-e4b-it-4bit", isDirectory: true)
    }

    private static var marker: URL { folder.appendingPathComponent(".complete-\(revision)") }
    static var isComplete: Bool { FileManager.default.fileExists(atPath: marker.path) }

    // MARK: Download

    func startDownload() {
        guard download == nil else { return }
        download = Task { [weak self] in
            await self?.runDownload()
            self?.download = nil
        }
    }

    func cancelDownload() {
        download?.cancel()
    }

    func deleteWeights() {
        cancelDownload()
        unload()
        try? FileManager.default.removeItem(at: Self.folder)
        state = .notDownloaded
    }

    private func runDownload() async {
        do {
            var folder = Self.folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let missing = Self.files.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
            let needed = missing.reduce(Int64(0)) { $0 + $1.bytes }
            if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < needed + 500_000_000 {
                throw DriverError(message: tr("Spazio insufficiente: servono %@ liberi.", ByteCountFormatter.string(fromByteCount: needed + 500_000_000, countStyle: .file)))
            }
            var done = Self.files.filter { !missing.map(\.name).contains($0.name) }.reduce(Int64(0)) { $0 + $1.bytes }
            state = .downloading(Double(done) / Double(Self.totalBytes))
            for file in missing {
                let target = folder.appendingPathComponent(file.name)
                let base = done
                try await FileDownload.fetch(Self.url(file.name), to: target) { [weak self] written in
                    Task { @MainActor in self?.state = .downloading(min(1, Double(base + written) / Double(Self.totalBytes))) }
                }
                if let expected = file.sha256 {
                    state = .verifying
                    let actual = try await Task.detached { try Self.sha256(of: target) }.value
                    guard actual == expected else {
                        try? FileManager.default.removeItem(at: target)
                        throw DriverError(message: tr("Il file %@ scaricato non corrisponde: riprova.", file.name))
                    }
                }
                done += file.bytes
            }
            FileManager.default.createFile(atPath: Self.marker.path, contents: nil)
            state = .downloaded
        } catch is CancellationError {
            state = Self.isComplete ? .downloaded : .notDownloaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func url(_ name: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(name)")!
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Memory

    func unload() {
        #if !targetEnvironment(simulator)
        container = nil
        MLX.Memory.clearCache()
        #endif
        if state == .ready || state == .loading { state = Self.isComplete ? .downloaded : .notDownloaded }
    }

    /// Five idle minutes after a turn, the weights leave memory.
    private func scheduleUnload() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    // MARK: Turns

    func run(_ input: TurnInput, sink: TurnSink) async throws -> TurnOutcome {
        if let reason = Self.unavailableReason { throw DriverError(message: reason) }
        guard Self.isComplete else { throw DriverError(message: tr("Scarica prima Gemma in Impostazioni › Modelli sul telefono.")) }
        #if targetEnvironment(simulator)
        throw DriverError(message: tr("Gemma non gira nel simulatore: provalo su un iPhone."))
        #else
        idle?.cancel()
        defer { scheduleUnload() }
        let container = try await loaded()

        // model-facing text stays English, like the engine's; the answer follows the user's language
        var chat: [Chat.Message] = [.system((input.bot.instructions.isEmpty ? "You are a helpful assistant on the user's phone." : input.bot.instructions)
            + "\nToday is \(Date().formatted(.iso8601.year().month().day())). Always answer in the language the user writes in.")]
        for message in input.history {
            switch message.role {
            case .user: chat.append(.user(transcriptText(message)))
            case .bot where !message.text.isEmpty: chat.append(.assistant(message.text))
            default: break
            }
        }
        let images: [UserInput.Image] = input.images.compactMap { CIImage(data: $0.data).map { .ciImage($0) } }
        chat.append(.user(promptText(input.latest), images: images))

        var specs: [ToolSpec]?
        var routes: [String: ChatTool] = [:]
        if let tools = input.tools {
            let listed = await tools.tools()
            for failure in listed.failures { sink.note(tr("Connettore non raggiungibile — %@", failure)) }
            let converted = OpenAIChatEndpoint.openAITools(listed.tools)
            if !converted.tools.isEmpty {
                specs = converted.tools.compactMap { Self.sendable($0) as? ToolSpec }
                routes = converted.routes
            }
        }

        var texts: [String] = []
        var round = 0
        while true {
            let offered = round < Self.maxToolRounds ? specs : nil
            let prepared = try await container.prepare(input: UserInput(chat: chat, tools: offered))
            let stream = try await container.generate(input: prepared, parameters: GenerateParameters(maxTokens: 2048, temperature: 0.6),
                                                      tools: offered)
            var text = ""
            var calls: [MLXLMCommon.ToolCall] = []
            for await generation in stream {
                try Task.checkCancellation()
                switch generation {
                case let .chunk(piece):
                    if text.isEmpty, !texts.isEmpty { sink.delta("\n\n") }
                    text += piece
                    sink.delta(piece)
                case let .toolCall(call):
                    calls.append(call)
                default:
                    break
                }
            }
            if !text.isEmpty { texts.append(text) }
            guard offered != nil, !calls.isEmpty, let tools = input.tools else { break }
            let identified = calls.enumerated().map { index, call in
                MLXLMCommon.ToolCall(function: call.function, id: call.id ?? "call_\(round)_\(index)")
            }
            chat.append(.assistant(text, toolCalls: identified))
            for call in identified {
                let arguments = (try? JSONEncoder().encode(call.function.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                let route = routes[call.function.name]
                let id = sink.toolStarted(route.map { "\($0.connectorName) · \($0.name)" } ?? call.function.name, arguments)
                let answer = await tools.call(route, arguments: arguments)
                sink.toolDone(id, answer.ok, answer.text)
                chat.append(.tool(answer.text, id: call.id, name: call.function.name))
            }
            try Task.checkCancellation()
            round += 1
            if round == Self.maxToolRounds {
                sink.note(tr("Limite di %@ giri di strumenti raggiunto: il modello conclude senza", String(Self.maxToolRounds)))
            }
        }
        return TurnOutcome(text: texts.joined(separator: "\n\n"), usage: nil, sessionId: nil)
        #endif
    }

    #if !targetEnvironment(simulator)
    private func loaded() async throws -> ModelContainer {
        if let container { return container }
        state = .loading
        MLX.Memory.cacheLimit = Self.cacheLimit
        do {
            let loaded = try await VLMModelFactory.shared.loadContainer(from: Self.folder, using: #huggingFaceTokenizerLoader())
            container = loaded
            state = .ready
            return loaded
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }
    #endif

    /// AgentCore JSON as the `[String: any Sendable]` tree mlx-swift-lm takes.
    nonisolated static func sendable(_ json: JSON) -> any Sendable {
        switch json {
        case .null: return Optional<String>.none as any Sendable
        case let .bool(value): return value
        case let .number(value): return value.rounded() == value && abs(value) < 1e15 ? Int(value) as any Sendable : value
        case let .string(value): return value
        case let .array(items): return items.map { sendable($0) }
        case let .object(object):
            var out: [String: any Sendable] = [:]
            for key in object.keys { if let value = object[key] { out[key] = sendable(value) } }
            return out
        }
    }
}

/// One file over HTTPS into place, resuming from where a failed attempt
/// stopped (the 5 GB weights file makes that indispensable).
enum FileDownload {
    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64) -> Void
        let target: URL
        var continuation: CheckedContinuation<Void, Error>?

        init(target: URL, progress: @escaping @Sendable (Int64) -> Void) {
            self.target = target
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                continuation?.resume(throwing: DriverError(message: "HTTP \(status)"))
                continuation = nil
                return
            }
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: location, to: target)
                continuation?.resume()
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: FileDownload.resumeFile(target))
            }
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
            continuation = nil
        }
    }

    static func resumeFile(_ target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).resume")
    }

    static func fetch(_ url: URL, to target: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = Delegate(target: target, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let resume = resumeFile(target)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resume) {
            try? FileManager.default.removeItem(at: resume)
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: url)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel { data in
                if let data { try? data.write(to: resumeFile(target)) }
            }
        }
    }
}
