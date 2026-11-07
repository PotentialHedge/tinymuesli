@preconcurrency import AVFAudio
import Foundation
import NaturalLanguage

/// From `time` (seconds into the track) on, `track` is transcribed in `language`.
/// Recorded in the meeting's frontmatter, so transcribing again from the audio gives the same result.
public struct LanguageSwitch: Equatable, Sendable {
    public var track: Track
    public var time: Double
    /// BCP-47 tag, e.g. "de-CH".
    public var language: String

    public init(track: Track, time: Double, language: String) {
        self.track = track
        self.time = time
        self.language = language
    }

    /// Frontmatter form: `mic 312.5 de-CH`.
    var frontmatterItem: String { "\(track.rawValue) \(time.rounded(toPlaces: 2)) \(language)" }

    init?(frontmatterItem: String) {
        let parts = frontmatterItem.split(separator: " ")
        guard parts.count == 3, let track = Track(rawValue: String(parts[0])), let time = Double(parts[1]) else { return nil }
        self.init(track: track, time: time, language: String(parts[2]))
    }
}

/// Spotting that a track isn't in the language it's being transcribed in.
///
/// There are two signs. A model that hears a language it doesn't know is unsure of its words:
/// the English model scores German speech around 0.2–0.4, against 0.75–0.9 for English. But some
/// models write a language they don't know out in that language, so their confidence barely drops
/// (Swiss German scores English speech 0.6–0.8). Then the text itself gives it away. Either sign
/// only prompts a check; the check settles it by transcribing the same audio in each candidate
/// language and comparing.
public struct LanguageMonitor: Sendable {
    /// How much recent speech is judged together, in seconds of track time.
    public var window: Double = 30
    /// Seconds of words needed before judging; short bursts ("Um,", "Yeah.") score low either way.
    public var minimumSpeech: Double = 12
    /// Below this, the model is unsure enough to check.
    public var lowConfidence: Double = 0.6
    /// How sure the text recogniser must be that the words are in another language.
    public var otherLanguageProbability: Double = 0.8
    /// Seconds of track time between checks.
    public var cooldown: Double = 90

    /// Language code (e.g. "en") of the language being transcribed.
    public private(set) var language: String
    private var words: [Word] = []
    private var lastCheck: Double?

    public init(language: String) {
        self.language = Self.code(language)
    }

    public enum Reason: Equatable, Sendable {
        case lowConfidence(Double)
        /// The words read as this language (a code, e.g. "de").
        case textLooksLike(String)
    }

    /// Adds a finished phrase. Returns why it's time to check the language, if it is.
    public mutating func add(_ phrase: Phrase, identify: (String) -> [String: Double] = Self.identify) -> Reason? {
        words += phrase.words
        guard let last = words.last else { return nil }
        words.removeAll { $0.end < last.end - window }
        if let lastCheck, last.end - lastCheck < cooldown { return nil }
        guard speech >= minimumSpeech else { return nil }

        let reason: Reason
        if confidence < lowConfidence {
            reason = .lowConfidence(confidence)
        } else if let other = identify(text).filter({ $0.value >= otherLanguageProbability }).first?.key,
                  Self.code(other) != language {
            reason = .textLooksLike(Self.code(other))
        } else {
            return nil
        }
        lastCheck = last.end
        return reason
    }

    /// The track is now transcribed in `language`: judge only the new language's words. (Those
    /// heard so far are either before the switch or about to be transcribed again.)
    public mutating func switched(to language: String) {
        self.language = Self.code(language)
        words.removeAll()
        lastCheck = nil
    }

    /// Where the speech being judged starts, in track time.
    public var windowStart: Double? { words.first?.start }
    public var text: String { words.map(\.text).joined().trimmingCharacters(in: .whitespaces) }

    /// Words stretch over the pauses before them, so each counts for at most a second.
    private var speech: Double { words.reduce(0) { $0 + Self.weight($1) } }
    private var confidence: Double { Self.confidence(of: words) }

    static func weight(_ word: Word) -> Double { min(max(word.end - word.start, 0), 1) }

    /// Mean word confidence, weighted by how long each word lasts. 0 for no words.
    public static func confidence(of words: [Word]) -> Double {
        let total = words.reduce(0) { $0 + weight($1) }
        guard total > 0 else { return 0 }
        return words.reduce(0) { $0 + weight($1) * ($1.confidence ?? 0) } / total
    }

    /// The text recogniser's guesses: language code → probability.
    public static func identify(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Dictionary(uniqueKeysWithValues: recognizer.languageHypotheses(withMaximum: 3).map { ($0.key.rawValue, $0.value) })
    }

    /// "de-CH" → "de", "zh-Hans" → "zh".
    static func code(_ tag: String) -> String {
        Locale.Language(identifier: tag).languageCode?.identifier ?? tag
    }
}

/// The result of a check: the track sounds like it's in another language.
public struct LanguageSuggestion: Equatable, Sendable {
    public var track: Track
    /// BCP-47 tag to switch to.
    public var language: String
    /// Where the speech in that language seems to start, in track time.
    public var from: Double
    /// Mean word confidence on the checked audio, in the current language and in `language`.
    public var currentScore: Double
    public var score: Double
}

/// Compares transcription languages on a stretch of audio.
public enum LanguageDetector {
    /// How much better another language must score to be suggested…
    static let clearMargin = 0.15
    /// …or, when the text recogniser also reads the words as that language.
    static let agreeingMargin = 0.04
    static let minimumScore = 0.6

    /// Languages worth trying, most likely first: what the recogniser reads in `text`, then your
    /// macOS languages (Language & Region). Not `current`'s language, and only ones on `offered`.
    public static func candidates(
        text: String,
        current: String,
        offered: [Locale],
        preferred: [String] = Locale.preferredLanguages,
        identify: (String) -> [String: Double] = LanguageMonitor.identify,
        limit: Int = 3
    ) -> [String] {
        let currentCode = LanguageMonitor.code(current)
        let guessed = identify(text).filter { $0.value >= 0.2 }.sorted { $0.value > $1.value }.map(\.key)
        var codes: [String] = []
        for code in (guessed + preferred).map(LanguageMonitor.code) where code != currentCode && !codes.contains(code) {
            codes.append(code)
        }

        let choices = LanguageChoice.choices(from: offered)
        let offeredTags = Set(offered.map { $0.identifier(.bcp47) })
        return codes.compactMap { code -> String? in
            // Your own variant (de-CH in your macOS languages) beats the language's default one.
            if let exact = preferred.first(where: { LanguageMonitor.code($0) == code && offeredTags.contains($0) }) {
                return exact
            }
            return choices.first { LanguageMonitor.code($0.tag) == code }?.tag
        }
        .prefix(limit)
        .map { $0 }
    }

    /// Picks the language to suggest from each language's score on the same audio, or nil to stay.
    static func best(current: Double, scores: [(language: String, score: Double)], textLanguage: String?) -> (language: String, score: Double)? {
        scores
            .filter { candidate in
                guard candidate.score >= minimumScore else { return false }
                let margin = LanguageMonitor.code(candidate.language) == textLanguage ? agreeingMargin : clearMargin
                return candidate.score >= current + margin
            }
            .max { $0.score < $1.score }
    }

    /// Transcribes `audio` in the current language and the candidates, and suggests the one that
    /// fits clearly better, if any.
    public static func check(
        track: Track,
        audio snippet: AudioSnippet,
        current: String,
        text: String,
        offered: [Locale]
    ) async -> LanguageSuggestion? {
        let candidates = candidates(text: text, current: current, offered: offered)
        guard !candidates.isEmpty, !snippet.buffers.isEmpty,
              let currentScore = await score(snippet, language: current) else { return nil }
        var scores: [(language: String, score: Double)] = []
        for candidate in candidates {
            if let score = await score(snippet, language: candidate) { scores.append((candidate, score)) }
        }
        let textLanguage = LanguageMonitor.identify(text).filter { $0.value >= 0.5 }.first.map { LanguageMonitor.code($0.key) }
        guard let best = best(current: currentScore, scores: scores, textLanguage: textLanguage) else { return nil }
        return LanguageSuggestion(track: track, language: best.language, from: snippet.start, currentScore: currentScore, score: best.score)
    }

    /// Mean word confidence of `audio` transcribed in `language`; nil if it couldn't be transcribed
    /// (e.g. the model failed to download).
    static func score(_ audio: AudioSnippet, language: String) async -> Double? {
        let stream = AppleSpeechTranscriber(locale: Locale(identifier: language)).makeStream { _ in }
        for buffer in audio.buffers {
            stream.append(buffer)
            await (stream as? Backpressured)?.waitForCapacity()
        }
        guard let phrases = try? await stream.finish() else { return nil }
        return LanguageMonitor.confidence(of: phrases.flatMap(\.words))
    }
}

extension Phrase {
    func shifted(by offset: Double) -> Phrase {
        guard offset != 0 else { return self }
        return Phrase(
            start: (start + offset).rounded(toPlaces: 2), end: (end + offset).rounded(toPlaces: 2), text: text,
            words: words.map { Word(text: $0.text, start: ($0.start + offset).rounded(toPlaces: 2),
                                    end: ($0.end + offset).rounded(toPlaces: 2), confidence: $0.confidence) }
        )
    }

    /// Only the words whose middle lies in `range`; nil if none do.
    func clipped(to range: Range<Double>) -> Phrase? {
        guard !words.isEmpty else { return range.contains((start + end) / 2) ? self : nil }
        let kept = words.filter { range.contains(($0.start + $0.end) / 2) }
        if kept.count == words.count { return self }
        guard let first = kept.first, let last = kept.last else { return nil }
        let text = kept.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return Phrase(start: first.start, end: last.end, text: text, words: kept)
    }
}
