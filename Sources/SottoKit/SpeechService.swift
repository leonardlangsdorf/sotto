import AVFoundation
import Foundation
import Speech
import SottoCore

/// Wraps `SpeechAnalyzer` + `SpeechTranscriber` for one utterance at a time.
///
/// A fresh analyzer is built per dictation because `finalizeAndFinishThroughEndOfInput()`
/// gives a deterministic end-of-results signal, which a long-lived analyzer does not.
/// The expensive part — the model itself — stays resident via
/// `ModelRetention.processLifetime`, so this costs far less than it looks.
@MainActor
final class SpeechService: Transcribing {
    var localeIdentifier: String = "en-US"
    var vocabulary: [String] = []

    var onPartial: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?

    private let audio = AudioCapture()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var fragments: [String] = []

    enum SpeechError: LocalizedError {
        case localeUnsupported(String)
        case noCompatibleAudioFormat
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let id): return "\(id) is not supported for transcription."
            case .noCompatibleAudioFormat: return "No compatible audio format is available."
            case .modelUnavailable: return "The speech model could not be installed."
            }
        }
    }

    // MARK: - Model provisioning

    /// Whether the locale's assets are on disk.
    ///
    /// Deliberately not `AssetInventory.status(forModules:)`: that reports
    /// whether *this process* has reserved the locale, so it answers
    /// `.supported` for an already-downloaded model and sends callers back
    /// through the download path on every launch.
    static func isModelInstalled(locale: Locale) async -> Bool {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return false }
        let target = supported.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales
            .contains { $0.identifier(.bcp47) == target }
    }

    /// Makes the locale usable by this process: downloads the assets if they
    /// are missing, then reserves the locale.
    ///
    /// Reservation is per-process and required before analysis; it is cheap
    /// when the model is already on disk.
    static func prepareModel(
        locale: Locale,
        progress: (@MainActor (Progress) -> Void)? = nil
    ) async throws {
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw SpeechError.localeUnsupported(locale.identifier(.bcp47))
        }

        if await !isModelInstalled(locale: locale) {
            let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [probe]) else {
                throw SpeechError.modelUnavailable
            }
            progress?(request.progress)
            try await request.downloadAndInstall()
        }

        try await AssetInventory.reserve(locale: locale)
    }

    /// Loads the model into memory ahead of the first dictation so the first
    /// hotkey press is as fast as every later one.
    func prewarm() async {
        let locale = Locale(identifier: localeIdentifier)
        guard await Self.isModelInstalled(locale: locale) else { return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let warm = SpeechAnalyzer(modules: [transcriber], options: Self.analyzerOptions)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try? await warm.prepareToAnalyze(in: format)
    }

    private static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    // MARK: - Transcribing

    func startCapture() async throws {
        fragments = []

        let locale = Locale(identifier: localeIdentifier)
        guard await Self.isModelInstalled(locale: locale) else {
            throw SpeechError.modelUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.analyzerOptions)

        // Bias recognition toward the user's own names and jargon.
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            throw SpeechError.noCompatibleAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        self.analyzer = analyzer
        self.continuation = continuation

        // Volatile results drive the HUD; only finalized ones become the transcript.
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.fragments.append(text)
                        self.onPartial?("")
                    } else {
                        self.onPartial?(text)
                    }
                }
            } catch {
                // Surfaced by finishAndTranscribe returning what it has.
            }
        }

        audio.onLevel = { [weak self] level in
            Task { @MainActor in self?.onLevel?(level) }
        }
        audio.onBuffer = { buffer in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        try audio.start(outputFormat: format)
    }

    func finishAndTranscribe() async throws -> String {
        audio.stop()
        continuation?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        reset()
        return Transcript.assemble(fragments)
    }

    /// Transcribes an audio file through the same analyzer configuration used
    /// for live capture. Shared by the tests and the debug bridge so neither
    /// exercises a different code path than the real one.
    func transcribe(fileURL: URL) async throws -> String {
        let locale = Locale(identifier: localeIdentifier)
        guard await Self.isModelInstalled(locale: locale) else {
            throw SpeechError.modelUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.analyzerOptions)

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else {
            throw SpeechError.noCompatibleAudioFormat
        }

        let collector = Task {
            var fragments: [String] = []
            for try await result in transcriber.results where result.isFinal {
                fragments.append(String(result.text.characters))
            }
            return fragments
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        for buffer in try Self.fileBuffers(from: fileURL, converting: format) {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()

        _ = try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return Transcript.assemble(try await collector.value)
    }

    /// Reads a file in chunks and converts each to the analyzer's format — the
    /// same conversion `AudioCapture` performs on live microphone buffers.
    static func fileBuffers(
        from url: URL, converting target: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw SpeechError.noCompatibleAudioFormat
        }
        let chunkSize: AVAudioFrameCount = 4096
        var output: [AVAudioPCMBuffer] = []

        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: chunkSize) else { break }
            try file.read(into: input, frameCount: chunkSize)
            guard input.frameLength > 0 else { break }

            let ratio = target.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: target, frameCapacity: capacity) else { break }

            // The callback is @Sendable but runs synchronously inside convert(),
            // so handing it the buffer is safe.
            nonisolated(unsafe) let source = input
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return source
            }
            if converted.frameLength > 0 { output.append(converted) }
        }
        return output
    }

    func cancel() async {
        audio.stop()
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        reset()
    }

    private func reset() {
        analyzer = nil
        continuation = nil
        resultsTask = nil
        audio.onBuffer = nil
        audio.onLevel = nil
    }
}
