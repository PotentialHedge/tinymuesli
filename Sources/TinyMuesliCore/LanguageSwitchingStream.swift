@preconcurrency import AVFAudio
import Foundation

/// Live transcription of one track whose language can change partway through.
///
/// Each language is a leg: its own transcription stream, fed from the leg's start time on. A switch
/// can reach back (to where the new language seems to have started), so the stream keeps the
/// last few minutes of audio, at 16 kHz, to feed the new leg from there. The old leg keeps only
/// the words before the switch.
final class LanguageSwitchingStream: TranscriptionStream, @unchecked Sendable {
    private final class Leg: @unchecked Sendable {
        let language: String
        /// Track time the leg's audio starts at; its phrases are shifted by this.
        let start: Double
        /// Words from here on belong to the next leg. Guarded by the stream's lock.
        var end: Double = .infinity
        var stream: TranscriptionStream!
        var finished: Task<[Phrase], Error>?

        init(language: String, start: Double) {
            self.language = language
            self.start = start
        }
    }

    /// Seconds of audio kept for switches that reach back.
    static let historyLimit: Double = 5 * 60

    private let lock = NSLock()
    private var legs: [Leg] = []
    private var elapsed: Double = 0
    private var history: [(start: Double, buffer: AVAudioPCMBuffer)] = []
    private let downsampler = Converter(to: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
    private let makeTranscriber: @Sendable (String) -> Transcriber
    private let onPhrase: @Sendable (Phrase) -> Void

    init(language: String, makeTranscriber: @escaping @Sendable (String) -> Transcriber,
         onPhrase: @escaping @Sendable (Phrase) -> Void) {
        self.makeTranscriber = makeTranscriber
        self.onPhrase = onPhrase
        legs = [makeLeg(language: language, start: 0)]
    }

    /// The language being transcribed now.
    var language: String { lock.withLock { legs.last!.language } }

    /// Seconds of track audio received so far.
    var duration: Double { lock.withLock { elapsed } }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            legs.last!.stream.append(buffer)
            if let small = try? downsampler.convert(buffer), let copy = small.copy() as? AVAudioPCMBuffer {
                history.append((elapsed, copy))
            }
            elapsed += Double(buffer.frameLength) / buffer.format.sampleRate
            while let first = history.first, first.start < elapsed - Self.historyLimit { history.removeFirst() }
        }
    }

    /// The kept audio from `time` on (from the buffer that contains it).
    func audio(from time: Double) -> AudioSnippet? {
        lock.withLock {
            let tail = history.drop { $0.start + Self.length($0.buffer) <= time }
            guard let first = tail.first else { return nil }
            return AudioSnippet(start: first.start, buffers: tail.map(\.buffer))
        }
    }

    /// Transcribes in `language` from `time` on: from the start of the kept audio, if `time` is
    /// earlier than that, and never before the current leg. Returns where the new leg starts.
    @discardableResult
    func switchLanguage(to language: String, from time: Double) -> Double {
        lock.withLock {
            let current = legs.last!
            let tail = history.drop { $0.start + Self.length($0.buffer) <= max(time, current.start) }
            let start = tail.first?.start ?? elapsed
            let leg = makeLeg(language: language, start: start)
            for item in tail { leg.stream.append(item.buffer) }
            current.end = start
            // The old leg has its audio already: let it catch up and free its model.
            let old = current.stream!
            current.finished = Task { try await old.finish() }
            legs.append(leg)
            return start
        }
    }

    func finish() async throws -> [Phrase] {
        let legs = lock.withLock { self.legs }
        var phrases: [Phrase] = []
        for leg in legs {
            let own: [Phrase]
            if let finished = leg.finished { own = try await finished.value } else { own = try await leg.stream.finish() }
            let range = lock.withLock { leg.start..<leg.end }
            phrases += own.compactMap { $0.shifted(by: leg.start).clipped(to: range) }
        }
        return phrases.sorted { $0.start < $1.start }
    }

    private func makeLeg(language: String, start: Double) -> Leg {
        let leg = Leg(language: language, start: start)
        let onPhrase = onPhrase
        leg.stream = makeTranscriber(language).makeStream { [weak self] phrase in
            guard let self else { return }
            let range = self.lock.withLock { leg.start..<leg.end }
            if let phrase = phrase.shifted(by: leg.start).clipped(to: range) { onPhrase(phrase) }
        }
        return leg
    }

    private static func length(_ buffer: AVAudioPCMBuffer) -> Double {
        Double(buffer.frameLength) / buffer.format.sampleRate
    }
}

/// Recent audio of a track. The buffers aren't written to once kept, so they can be shared.
public struct AudioSnippet: @unchecked Sendable {
    /// Track time of the first buffer.
    public var start: Double
    public var buffers: [AVAudioPCMBuffer]
}
