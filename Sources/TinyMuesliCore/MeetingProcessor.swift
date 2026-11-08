import Foundation

/// File names inside a meeting folder. The filesystem is the API; these are the contract.
public enum MeetingFiles {
    public static let transcript = "transcript.md"
    public static let json = "transcript.json"
    /// Voice embeddings per speaker, for recognising recurring speakers later.
    public static let speakers = "speakers.json"
    /// Title, tags and speaker names suggested by Apple's on-device model (see `MeetingSuggester`).
    public static let suggestions = "suggestions.json"
    public static let audio = "audio"
    /// The first file of each track; a continued meeting can add `mic-2.caf` etc. (see `TrackSegments`).
    public static let micAudio = "audio/mic.caf"
    public static let systemAudio = "audio/system.caf"
}

/// The final pass over a recorded meeting: transcribe whatever wasn't transcribed live,
/// diarize the system track, merge both tracks, write `transcript.md` + `transcript.json`,
/// and delete the audio unless it should be kept.
///
/// It only needs the folder, so it doubles as crash recovery and as `tinymuesli transcribe`.
public struct MeetingProcessor: Sendable {
    public var transcriber: Transcriber
    public var diarizer: Diarizer?
    public var keepAudio: Bool

    public init(transcriber: Transcriber, diarizer: Diarizer?, keepAudio: Bool) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.keepAudio = keepAudio
    }

    public struct Result: Sendable {
        public var document: TranscriptDocument
        /// Non-fatal problems, e.g. diarization unavailable so remote speech is labelled "Others".
        public var warnings: [String]
    }

    /// `live` holds phrases already transcribed during recording, per track. Tracks without
    /// them are transcribed from their audio file.
    public func process(folder: URL, live: [Track: [Phrase]] = [:], log: @Sendable (String) -> Void = { _ in }) async throws -> Result {
        let mdURL = folder.appendingPathComponent(MeetingFiles.transcript)
        let existing = (try? String(contentsOf: mdURL, encoding: .utf8)).flatMap(MeetingMetadata.init(parsing:))
        var metadata = existing ?? MeetingMetadata(start: Self.fallbackStart(folder), app: nil, status: .recorded)
        metadata.status = .transcribing
        metadata.error = nil
        metadata.language = transcriber.language
        try write(metadata: metadata, body: Self.body(of: mdURL), to: mdURL)

        do {
            let fm = FileManager.default
            // A track in several files (a continued meeting whose device changed) is joined into one.
            let micTrack = try TrackSegments.single(first: folder.appendingPathComponent(MeetingFiles.micAudio))
            defer { if micTrack.isTemporary { try? fm.removeItem(at: micTrack.url) } }
            let systemTrack = try TrackSegments.single(first: folder.appendingPathComponent(MeetingFiles.systemAudio))
            defer { if systemTrack.isTemporary { try? fm.removeItem(at: systemTrack.url) } }
            let (micURL, systemURL) = (micTrack.url, systemTrack.url)

            let switches = metadata.languageSwitches
            async let micPhrases = phrases(for: .mic, url: micURL, live: live[.mic], switches: switches, log: log)
            async let systemPhrases = phrases(for: .system, url: systemURL, live: live[.system], switches: switches, log: log)
            let mic = try await micPhrases
            let system = try await systemPhrases

            var warnings: [String] = []
            var diarization: Diarization?
            if !system.isEmpty, fm.fileExists(atPath: systemURL.path) {
                if let diarizer {
                    log("Diarizing system audio…")
                    do {
                        diarization = try await diarizer.diarize(file: systemURL)
                    } catch {
                        warnings.append("Speaker identification failed (\(error)); remote speech is labelled \"\(SpeakerLabel.others)\".")
                    }
                } else {
                    warnings.append("No diarizer; remote speech is labelled \"\(SpeakerLabel.others)\".")
                }
            }

            let segments = TranscriptBuilder.segments(mic: mic, system: system, turns: diarization?.turns)
            let document = TranscriptDocument(
                start: metadata.start, end: metadata.end, app: metadata.app,
                language: transcriber.language, segments: segments
            )
            try document.encoded().write(to: folder.appendingPathComponent(MeetingFiles.json), options: .atomic)
            if let diarization, !diarization.embeddings.isEmpty {
                try SpeakerEmbeddings(diarization: diarization).encoded()
                    .write(to: folder.appendingPathComponent(MeetingFiles.speakers), options: .atomic)
            }

            metadata.status = .done
            metadata.speakers = document.speakers
            try write(metadata: metadata, body: TranscriptRenderer.markdown(segments), to: mdURL)

            if !keepAudio {
                try? fm.removeItem(at: folder.appendingPathComponent(MeetingFiles.audio))
            }
            return Result(document: document, warnings: warnings)
        } catch {
            metadata.status = .failed
            metadata.error = "\(error)"
            try? write(metadata: metadata, body: Self.body(of: mdURL), to: mdURL)
            throw error
        }
    }

    private func phrases(for track: Track, url: URL, live: [Phrase]?, switches: [LanguageSwitch],
                         log: @Sendable (String) -> Void) async throws -> [Phrase] {
        if let live { return live }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        log("Transcribing \(track.rawValue) audio…")
        // Each stretch in its own language, as it was switched while recording.
        let legs = Self.legs(of: track, switches: switches)
        var phrases: [Phrase] = []
        for (index, leg) in legs.enumerated() {
            let end = index + 1 < legs.count ? legs[index + 1].start : nil
            let engine = leg.language.map(transcriber.inLanguage) ?? transcriber
            phrases += try await engine.transcribe(file: url, from: leg.start, to: end)
        }
        return phrases
    }

    /// Where each language starts on `track`; nil language = the transcriber's own.
    static func legs(of track: Track, switches: [LanguageSwitch]) -> [(start: Double, language: String?)] {
        var legs: [(start: Double, language: String?)] = [(0, nil)]
        for change in switches.filter({ $0.track == track }).sorted(by: { $0.time < $1.time }) {
            if change.time <= legs[legs.count - 1].start {
                legs[legs.count - 1].language = change.language
            } else {
                legs.append((change.time, change.language))
            }
        }
        return legs
    }

    private func write(metadata: MeetingMetadata, body: String, to url: URL) throws {
        let text = metadata.frontmatter() + (body.isEmpty ? "" : "\n" + body + "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Everything after the frontmatter, so a status change keeps the live transcript.
    public static func body(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Folder names start with "YYYY-MM-DD HHMM".
    static func fallbackStart(_ folder: URL) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.date(from: String(folder.lastPathComponent.prefix(15))) ?? .now
    }
}

/// `speakers.json`: a voice embedding per diarized speaker, keyed by display name.
public struct SpeakerEmbeddings: Codable, Sendable {
    public struct Speaker: Codable, Sendable {
        public var name: String
        public var embedding: [Float]
    }

    public var model = "fluidaudio-offline-wespeaker"
    public var speakers: [Speaker]

    init(diarization: Diarization) {
        let names = TranscriptBuilder.displayNames(for: diarization.turns)
        speakers = diarization.embeddings
            .compactMap { id, embedding in names[id].map { Speaker(name: $0, embedding: embedding) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Keeps `transcript.md` current while recording, so the transcript can be read (by you or an
/// agent) during the meeting, and most of it survives a crash. Remote speech is "Others" until
/// the final pass identifies speakers.
public final class LiveTranscript: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var metadata: MeetingMetadata
    private var phrases: [Track: [Phrase]] = [:]

    public init(url: URL, metadata: MeetingMetadata) {
        self.url = url
        self.metadata = metadata
    }

    public func add(_ phrase: Phrase, track: Track) {
        lock.withLock {
            phrases[track, default: []].append(phrase)
            write()
        }
    }

    /// Drops the words on `track` from `time` on: they're being transcribed again in another language.
    public func cut(_ track: Track, from time: Double) {
        lock.withLock {
            phrases[track] = phrases[track]?.compactMap { $0.clipped(to: -Double.infinity..<time) }
            write()
        }
    }

    public func update(_ change: (inout MeetingMetadata) -> Void) {
        lock.withLock {
            change(&metadata)
            write()
        }
    }

    private func write() {
        let segments = TranscriptBuilder.segments(mic: phrases[.mic] ?? [], system: phrases[.system] ?? [], turns: nil)
        let body = TranscriptRenderer.markdown(segments)
        let text = metadata.frontmatter() + (body.isEmpty ? "" : "\n" + body + "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
