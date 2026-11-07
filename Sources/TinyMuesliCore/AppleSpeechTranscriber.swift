@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

/// On-device transcription with Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26).
/// The OS manages the models; the first use of a language may download it via `AssetInventory`.
public struct AppleSpeechTranscriber: Transcriber {
    public let locale: Locale
    public var language: String { locale.identifier(.bcp47) }

    /// Use `make(preferred:)`, which resolves to a locale the engine supports.
    init(locale: Locale) {
        self.locale = locale
    }

    /// Picks the supported locale closest to `preferred` (default: the system's), falling back to en-US.
    public static func make(preferred: Locale? = nil) async throws -> AppleSpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        for candidate in [preferred, Locale.current, Locale(identifier: "en-US")].compactMap({ $0 }) {
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                return AppleSpeechTranscriber(locale: locale)
            }
        }
        throw TranscriberError.unsupportedLanguage(preferred?.identifier ?? Locale.current.identifier)
    }

    /// Languages offered in the UI: English, the main European languages and Chinese, as far as
    /// this Mac's `SpeechTranscriber` supports them.
    public static func offeredLocales() async -> [Locale] {
        let wanted: Set<String> = ["en", "de", "fr", "es", "it", "pt", "nl", "sv", "da", "nb", "no", "fi", "pl", "zh"]
        return await SpeechTranscriber.supportedLocales
            .filter { $0.language.languageCode.map { wanted.contains($0.identifier) } ?? false }
            .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
    }

    /// Makes sure the model for `locale` is installed, downloading it if needed.
    public static func ensureInstalled(locale: Locale) async throws {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if await AssetInventory.status(forModules: [module]) == .installed { return }
        // Reserving keeps the OS from evicting the model; harmless if already reserved.
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    public func inLanguage(_ language: String) -> Transcriber {
        AppleSpeechTranscriber(locale: Locale(identifier: language))
    }

    public func makeStream(onPhrase: @escaping @Sendable (Phrase) -> Void) -> TranscriptionStream {
        AppleTranscriptionStream(locale: locale, onPhrase: onPhrase)
    }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case unavailable
    case unsupportedLanguage(String)
    case noCompatibleFormat

    public var description: String {
        switch self {
        case .unavailable: "On-device transcription isn't available on this Mac."
        case .unsupportedLanguage(let id): "Transcription doesn't support \(id)."
        case .noCompatibleFormat: "No audio format compatible with the transcriber."
        }
    }
}

final class AppleTranscriptionStream: TranscriptionStream, Backpressured, @unchecked Sendable {
    private let continuation: AsyncStream<SendableBuffer>.Continuation
    private let task: Task<[Phrase], Error>
    private let pending = Pending()

    init(locale: Locale, onPhrase: @escaping @Sendable (Phrase) -> Void) {
        let (buffers, continuation) = AsyncStream.makeStream(of: SendableBuffer.self)
        self.continuation = continuation
        let pending = pending
        task = Task.detached(priority: .userInitiated) {
            try await Self.run(locale: locale, buffers: buffers, pending: pending, onPhrase: onPhrase)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        pending.add(1)
        continuation.yield(SendableBuffer(buffer: buffer))
    }

    func waitForCapacity() async {
        while pending.count > 8 { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func finish() async throws -> [Phrase] {
        continuation.finish()
        return try await task.value
    }

    private static func run(
        locale: Locale,
        buffers: AsyncStream<SendableBuffer>,
        pending: Pending,
        onPhrase: @escaping @Sendable (Phrase) -> Void
    ) async throws -> [Phrase] {
        try await AppleSpeechTranscriber.ensureInstalled(locale: locale)

        let module = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],  // final results only; no volatile guesses to rewrite later
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.noCompatibleFormat
        }
        try await analyzer.prepareToAnalyze(in: format)

        let collector = Task {
            var phrases: [Phrase] = []
            for try await result in module.results where result.isFinal {
                guard let phrase = Self.phrase(from: result) else { continue }
                phrases.append(phrase)
                onPhrase(phrase)
            }
            return phrases
        }

        // Pull-based: the analyzer asks for the next buffer when it's ready for it.
        let converter = Converter(to: format)
        let inputs = buffers.compactMap { item -> AnalyzerInput? in
            defer { pending.add(-1) }
            return try? converter.convert(item.buffer).map { AnalyzerInput(buffer: $0) }
        }
        do {
            guard let last = try await analyzer.analyzeSequence(inputs) else {
                // No audio at all (e.g. the system track stayed silent): nothing to transcribe.
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                return []
            }
            try await analyzer.finalizeAndFinish(through: last)
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    static func phrase(from result: SpeechTranscriber.Result) -> Phrase? {
        let text = String(result.text.characters)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var words: [Word] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(result.text[run.range].characters)
            words.append(Word(
                text: piece,
                start: range.start.seconds.rounded(toPlaces: 2),
                end: range.end.seconds.rounded(toPlaces: 2),
                confidence: run.transcriptionConfidence.map { Double($0).rounded(toPlaces: 2) }
            ))
        }
        let start = words.first?.start ?? result.range.start.seconds
        let end = words.last?.end ?? result.range.end.seconds
        return Phrase(start: start.rounded(toPlaces: 2), end: end.rounded(toPlaces: 2), text: text, words: words)
    }
}

/// Count of buffers enqueued but not yet handed to the analyzer.
private final class Pending: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add(_ n: Int) { lock.withLock { value += n } }
}

/// Converts mono Float32 track audio to the analyzer's format (typically 16 kHz Int16).
/// Mono → mono, so `AVAudioConverter`'s channel-layout problem doesn't apply here.
final class Converter: @unchecked Sendable {
    private let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to output: AVAudioFormat) {
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if buffer.format == output { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.primeMethod = .none
        }
        guard let converter else { throw TranscriberError.noCompatibleFormat }

        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let error { throw error }
        return out.frameLength > 0 ? out : nil
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
