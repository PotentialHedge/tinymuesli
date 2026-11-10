import Foundation

/// Which recording a piece of speech came from. The mic is always the user; the system
/// track is everyone else.
public enum Track: String, Codable, Sendable {
    case mic
    case system
}

/// One recognised word (or token) with its position in the track, in seconds.
public struct Word: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// What a `Transcriber` produces: a run of speech from one track, usually a sentence or two.
/// `words` carry the timings; their texts concatenate to `text` (each keeps its leading space).
public struct Phrase: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]

    public init(start: Double, end: Double, text: String, words: [Word]) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// A stretch of time in which one speaker on the system track is talking, from diarization.
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// One speaker-attributed segment of the final transcript. This is the `transcript.json` contract.
public struct Segment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// Display name: "Me", "Speaker 1"..., or "Others" if diarization didn't run.
    public var speaker: String
    public var track: Track
    public var text: String
    /// Mean word confidence, 0...1, when the transcriber reports it.
    public var confidence: Double?

    public init(start: Double, end: Double, speaker: String, track: Track, text: String, confidence: Double? = nil) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.track = track
        self.text = text
        self.confidence = confidence
    }
}

public enum SpeakerLabel {
    public static let me = "Me"
    /// System-track speech when diarization isn't available (yet).
    public static let others = "Others"
}

/// Turns per-track phrases into one speaker-labelled transcript.
public enum TranscriptBuilder {
    /// Mic phrases become "Me" segments. System phrases are split at the word level by
    /// diarization turns, so a phrase that spans a change of speaker is attributed correctly.
    /// `turns == nil` means no diarization: system speech is labelled "Others".
    public static func segments(mic: [Phrase], system: [Phrase], turns: [SpeakerTurn]?) -> [Segment] {
        var result = mic.compactMap { segment(from: $0.words, fallback: $0, speaker: SpeakerLabel.me, track: .mic) }

        let names = turns.map(displayNames(for:)) ?? [:]
        for phrase in system {
            guard let turns, !turns.isEmpty else {
                result += [segment(from: phrase.words, fallback: phrase, speaker: SpeakerLabel.others, track: .system)].compactMap { $0 }
                continue
            }
            let words = phrase.words.isEmpty
                ? [Word(text: phrase.text, start: phrase.start, end: phrase.end)]
                : phrase.words
            for run in speakerRuns(words: words, turns: turns, names: names) {
                result += [segment(from: run.words, fallback: nil, speaker: run.speaker, track: .system)].compactMap { $0 }
            }
        }
        return result.sorted { ($0.start, $0.track == .mic ? 0 : 1) < ($1.start, $1.track == .mic ? 0 : 1) }
    }

    /// Diarizer ids are arbitrary ("S3", "0"...). Number speakers in order of first appearance.
    public static func displayNames(for turns: [SpeakerTurn]) -> [String: String] {
        var names: [String: String] = [:]
        for turn in turns.sorted(by: { $0.start < $1.start }) where names[turn.speaker] == nil {
            names[turn.speaker] = "Speaker \(names.count + 1)"
        }
        return names
    }

    /// Assigns each word to the turn it overlaps most (or the nearest), then groups consecutive
    /// words by speaker. Diarization turn edges are a few hundred ms off, so words near a change
    /// of speaker often land on the wrong side. Two corrections:
    /// - each boundary moves (by up to 2 words) to the longest pause near it, since people take
    ///   turns at pauses;
    /// - a lone word between two other runs joins whichever neighbour is closer in time.
    static func speakerRuns(words: [Word], turns: [SpeakerTurn], names: [String: String]) -> [(speaker: String, words: [Word])] {
        guard !words.isEmpty else { return [] }
        var labels = words.map { names[bestTurn(for: $0, in: turns).speaker] ?? SpeakerLabel.others }

        func gap(before k: Int) -> Double { audibleStart(words[k]) - words[k - 1].end }
        var k = 1
        while k < words.count {
            guard labels[k] != labels[k - 1] else { k += 1; continue }
            // Boundary between k-1 and k. Keep at least one word on each side.
            let runStart = (labels[..<k].lastIndex { $0 != labels[k - 1] } ?? -1) + 1
            let runEnd = labels[k...].firstIndex { $0 != labels[k] } ?? words.count
            var best = k
            for candidate in max(runStart + 1, k - 2)...min(runEnd - 1, k + 2) where gap(before: candidate) > gap(before: best) {
                best = candidate
            }
            let (left, right) = (labels[k - 1], labels[k])
            for i in min(best, k)..<max(best, k) { labels[i] = best < k ? right : left }
            k = max(best, k) + 1
        }

        var runs: [(speaker: String, words: [Word])] = []
        for (word, speaker) in zip(words, labels) {
            if runs.last?.speaker == speaker {
                runs[runs.count - 1].words.append(word)
            } else {
                runs.append((speaker, [word]))
            }
        }
        var i = 1
        while i < runs.count - 1 {
            guard runs[i].words.count == 1 else { i += 1; continue }
            let word = runs[i].words[0]
            let gapBefore = word.start - runs[i - 1].words.last!.end
            let gapAfter = runs[i + 1].words.first!.start - word.end
            if gapBefore <= gapAfter {
                runs[i - 1].words.append(word)
            } else {
                runs[i + 1].words.insert(word, at: 0)
            }
            runs.remove(at: i)
            // Neighbours may now have the same speaker: merge them.
            if runs[i - 1].speaker == runs[i].speaker {
                runs[i - 1].words += runs[i].words
                runs.remove(at: i)
            }
            i = max(1, i - 1)
        }
        return runs
    }

    /// The transcriber sometimes stretches a word back over the pause before it ("I" lasting
    /// 1.3 s). The sound is at the end, so a long word only counts from its last 0.35 s.
    static func audibleStart(_ word: Word) -> Double {
        max(word.start, word.end - 0.35)
    }

    static func bestTurn(for word: Word, in turns: [SpeakerTurn]) -> SpeakerTurn {
        var best = turns[0]
        var bestOverlap = -Double.infinity
        let start = audibleStart(word)
        for turn in turns {
            let overlap = min(word.end, turn.end) - max(start, turn.start)
            // Negative overlap is the gap; the closest turn wins when nothing overlaps.
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = turn
            }
        }
        return best
    }

    static func segment(from words: [Word], fallback: Phrase?, speaker: String, track: Track) -> Segment? {
        let text: String
        let start: Double
        let end: Double
        if let first = words.first, let last = words.last {
            text = words.map(\.text).joined()
            start = first.start
            end = last.end
        } else if let fallback {
            text = fallback.text
            start = fallback.start
            end = fallback.end
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let confidences = words.compactMap(\.confidence)
        let confidence = confidences.isEmpty ? nil : (confidences.reduce(0, +) / Double(confidences.count)).rounded(toPlaces: 2)
        return Segment(start: start, end: end, speaker: speaker, track: track, text: trimmed, confidence: confidence)
    }
}

/// The microphone heard as more than one voice: a recording of a room rather than a call, or
/// someone talking next to you. "Me" is the voice that speaks most; the others are "Voice 1"...
/// (by first appearance) until `applied(to:)` gives them speaker names.
///
/// Recordings without a meeting app get this right away. In a call it's only offered (saved as
/// `mic-voices.json`), since there the microphone is almost always just you.
public struct MicVoices: Codable, Sendable, Equatable {
    /// Every mic-track segment, labelled "Me" or "Voice n".
    public var segments: [Segment]
    /// A voice embedding per "Voice n" (not for "Me").
    public var embeddings: [String: [Float]]

    public init(segments: [Segment], embeddings: [String: [Float]]) {
        self.segments = segments
        self.embeddings = embeddings
    }

    public static let placeholderPrefix = "Voice "

    /// "Voice 1", "Voice 2"... in order of first appearance.
    public var voices: [String] {
        var seen: [String] = []
        for s in segments where s.speaker != SpeakerLabel.me && !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    /// `segments` with the mic track replaced by these voices, each voice named "Speaker n" after
    /// the highest number in use. Returns the names given, keyed by voice.
    public func applied(to segments: [Segment]) -> (segments: [Segment], names: [String: String]) {
        var next = segments.compactMap { s in
            s.speaker.wholeMatch(of: /Speaker (\d+)/).flatMap { Int($0.1) }
        }.max() ?? 0
        var names: [String: String] = [:]
        for voice in voices {
            next += 1
            names[voice] = "Speaker \(next)"
        }
        let mic = self.segments.map { s in
            var s = s
            s.speaker = names[s.speaker] ?? SpeakerLabel.me
            return s
        }
        let result = segments.filter { $0.track != .mic } + mic
        return (result.sorted { ($0.start, $0.track == .mic ? 0 : 1) < ($1.start, $1.track == .mic ? 0 : 1) }, names)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension TranscriptBuilder {
    /// Splits the mic track by voice. Voices with less than `minimumSpeech` seconds of words are
    /// counted as "Me": diarizers often hear one person's odd moments as someone else. Nil when
    /// only one voice is left.
    public static func micVoices(mic: [Phrase], diarization: Diarization, minimumSpeech: Double = 5) -> MicVoices? {
        let turns = diarization.turns
        guard Set(turns.map(\.speaker)).count > 1 else { return nil }
        let identity = Dictionary(turns.map { ($0.speaker, $0.speaker) }, uniquingKeysWith: { a, _ in a })
        let runs = mic.flatMap { phrase in
            speakerRuns(words: phrase.words.isEmpty ? [Word(text: phrase.text, start: phrase.start, end: phrase.end)] : phrase.words,
                        turns: turns, names: identity)
        }
        var speech: [String: Double] = [:]
        for run in runs {
            speech[run.speaker, default: 0] += run.words.reduce(0) { $0 + max(0, $1.end - audibleStart($1)) }
        }
        guard let main = speech.max(by: { $0.value < $1.value })?.key else { return nil }
        let others = speech.filter { $0.key != main && $0.value >= minimumSpeech }.keys
        guard !others.isEmpty else { return nil }

        var names: [String: String] = [:]
        for turn in turns.sorted(by: { $0.start < $1.start }) where names[turn.speaker] == nil {
            names[turn.speaker] = others.contains(turn.speaker)
                ? MicVoices.placeholderPrefix + "\(names.values.filter { $0 != SpeakerLabel.me }.count + 1)"
                : SpeakerLabel.me
        }
        var segments: [Segment] = []
        for phrase in mic {
            let words = phrase.words.isEmpty ? [Word(text: phrase.text, start: phrase.start, end: phrase.end)] : phrase.words
            for run in speakerRuns(words: words, turns: turns, names: names) {
                segments += [segment(from: run.words, fallback: nil, speaker: run.speaker, track: .mic)].compactMap { $0 }
            }
        }
        var embeddings: [String: [Float]] = [:]
        for (id, embedding) in diarization.embeddings {
            if let name = names[id], name != SpeakerLabel.me { embeddings[name] = embedding }
        }
        return MicVoices(segments: segments, embeddings: embeddings)
    }
}

/// Renders the transcript body of `transcript.md`.
///
///     **Me** [00:00:03] Thanks for joining. Shall we start with the roadmap?
///
///     **Speaker 1** [00:00:07] Sure. We shipped the importer last week.
///
/// One paragraph per turn: consecutive segments from the same speaker are joined, unless
/// there's a long pause, so the file stays easy to read and to grep.
public enum TranscriptRenderer {
    public static func markdown(_ segments: [Segment], joinPausesUnder maxPause: Double = 30) -> String {
        var paragraphs: [(speaker: String, start: Double, end: Double, text: String)] = []
        for segment in segments {
            if var last = paragraphs.last, last.speaker == segment.speaker, segment.start - last.end < maxPause {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                paragraphs[paragraphs.count - 1] = last
            } else {
                paragraphs.append((segment.speaker, segment.start, segment.end, segment.text))
            }
        }
        return paragraphs
            .map { "**\($0.speaker)** [\(timestamp($0.start))] \($0.text)" }
            .joined(separator: "\n\n")
    }

    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// `transcript.json`: everything in `transcript.md`, in a form that's easy to process.
public struct TranscriptDocument: Codable, Sendable, Equatable {
    public var version = 1
    public var start: Date
    public var end: Date?
    public var app: String?
    public var language: String?
    public var speakers: [String]
    public var segments: [Segment]

    public init(start: Date, end: Date?, app: String?, language: String?, segments: [Segment]) {
        self.start = start
        self.end = end
        self.app = app
        self.language = language
        self.segments = segments
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        speakers = seen
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
