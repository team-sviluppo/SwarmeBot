// Dictation for the composer: the microphone into Speech's on-device
// DictationTranscriber (SpeechAnalyzer, iOS 26), in the phone's language,
// with punctuation. The text grows while the user speaks; nothing leaves the
// phone.
import AVFoundation
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class Dictation {
    private(set) var running = false
    /// Permission, the language model download, the audio starting.
    private(set) var preparing = false
    var error: String?
    /// The words heard so far: settled, then the guess still changing.
    private(set) var text = ""

    @ObservationIgnored private var settled = ""
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?

    func start() async {
        guard !running, !preparing else { return }
        error = nil
        settled = ""
        text = ""
        preparing = true
        defer { preparing = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = tr("Consenti il microfono a SwarmeBot in Impostazioni.")
            return
        }
        do {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
                error = tr("La dettatura non supporta la lingua del telefono.")
                return
            }
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await download.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                error = tr("La dettatura non è disponibile su questo telefono.")
                return
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            let engine = AVAudioEngine()
            try Self.tap(engine.inputNode, into: continuation, as: format)
            engine.prepare()
            try engine.start()
            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.heard(String(result.text.characters), final: result.isFinal)
                    }
                } catch {
                    self?.error = error.localizedDescription
                }
            }
            try await analyzer.start(inputSequence: stream)
            self.engine = engine
            self.analyzer = analyzer
            input = continuation
            running = true
        } catch {
            self.error = tr("Dettatura non avviata: %@", error.localizedDescription)
            teardown()
        }
    }

    /// Stops listening and waits for the last words.
    func stop() async {
        guard running else { return }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        teardown()
    }

    /// Stops at once, dropping what was not settled (the chat went away).
    func cancel() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        input?.finish()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        results?.cancel()
        teardown()
    }

    private func heard(_ piece: String, final: Bool) {
        if final {
            settled += piece
            text = settled
        } else {
            text = settled + piece
        }
    }

    private func teardown() {
        engine = nil
        analyzer = nil
        input = nil
        results = nil
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The microphone's buffers, converted to what the analyzer takes. The
    /// tap runs on the audio thread: it must not be isolated to the main actor.
    nonisolated private static func tap(_ node: AVAudioInputNode, into input: AsyncStream<AnalyzerInput>.Continuation,
                                        as format: AVAudioFormat) throws {
        let natural = node.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw DictationError.noMicrophone }
        let converter = natural == format ? nil : AVAudioConverter(from: natural, to: format)
        node.installTap(onBus: 0, bufferSize: 4_096, format: natural) { buffer, _ in
            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            if let converted = convert(buffer, with: converter, to: format) { input.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up))
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    private enum DictationError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { tr("Nessun microfono disponibile.") }
    }
}
