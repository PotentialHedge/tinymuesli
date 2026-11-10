import Foundation

/// Changes you make to a finished meeting: tags, and names for its speakers. Names are written
/// into the files themselves (`transcript.md`, `transcript.json`, `speakers.json`), so the CLI,
/// MCP server and anything reading the folder see them.
public struct MeetingEditor: Sendable {
    public enum EditError: LocalizedError, Equatable {
        case notFinished
        case invalidName
        case reservedName(String)
        case unknownSpeaker(String)

        public var errorDescription: String? {
            switch self {
            case .notFinished: "This meeting can be edited once it has been transcribed."
            case .invalidName: "Enter a name."
            case .reservedName(let name): "“\(name)” is reserved."
            case .unknownSpeaker(let name): "No one in this meeting is called “\(name)”."
            }
        }
    }

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    private var markdownURL: URL { folder.appendingPathComponent(MeetingFiles.transcript) }
    private var jsonURL: URL { folder.appendingPathComponent(MeetingFiles.json) }
    private var speakersURL: URL { folder.appendingPathComponent(MeetingFiles.speakers) }

    /// An empty title removes it, so the meeting is called by its app again.
    public func setTitle(_ title: String?) throws {
        var metadata = try readMetadata()
        guard metadata.status == .done || metadata.status == .failed else { throw EditError.notFinished }
        metadata.title = title.map { Self.clean($0) }.flatMap { $0.isEmpty ? nil : $0 }
        try write(metadata: metadata, body: MeetingProcessor.body(of: markdownURL))
    }

    /// Tags are trimmed, deduplicated (ignoring case) and kept in the order given.
    public func setTags(_ tags: [String]) throws {
        var metadata = try readMetadata()
        guard metadata.status == .done || metadata.status == .failed else { throw EditError.notFinished }
        metadata.tags = Self.cleanTags(tags)
        try write(metadata: metadata, body: MeetingProcessor.body(of: markdownURL))
    }

    public static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { clean($0) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Renames a speaker everywhere in the meeting. Naming two speakers the same merges them, which
    /// is what you want when diarization split one person in two.
    public func rename(speaker old: String, to new: String) throws {
        let new = Self.clean(new)
        guard !new.isEmpty else { throw EditError.invalidName }
        guard old != new else { return }
        guard new != SpeakerLabel.me, old != SpeakerLabel.me else { throw EditError.reservedName(SpeakerLabel.me) }
        var metadata = try readMetadata()
        // The final pass rewrites these files; a meeting still being recorded has no speakers yet.
        guard metadata.status == .done else { throw EditError.notFinished }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var document = try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: jsonURL))
        for i in document.segments.indices where document.segments[i].speaker == old {
            document.segments[i].speaker = new
        }
        document = TranscriptDocument(start: document.start, end: document.end, app: document.app,
                                      language: document.language, segments: document.segments)

        if var voices = try? decoder.decode(SpeakerEmbeddings.self, from: Data(contentsOf: speakersURL)) {
            for i in voices.speakers.indices where voices.speakers[i].name == old {
                voices.speakers[i].name = new
            }
            try voices.encoded().write(to: speakersURL, options: .atomic)
        }
        try document.encoded().write(to: jsonURL, options: .atomic)
        metadata.speakers = document.speakers
        try write(metadata: metadata, body: TranscriptRenderer.markdown(document.segments))
    }

    /// Gives `speaker`'s lines to `target`, another speaker in this meeting, for when diarization
    /// heard one person as two. Unlike `rename`, the target has to exist already.
    public func merge(speaker: String, into target: String) throws {
        let speakers = try readMetadata().speakers
        for name in [speaker, target] where !speakers.contains(name) { throw EditError.unknownSpeaker(name) }
        try rename(speaker: speaker, to: target)
    }

    private func readMetadata() throws -> MeetingMetadata {
        let text = try String(contentsOf: markdownURL, encoding: .utf8)
        guard let metadata = MeetingMetadata(parsing: text) else { throw CocoaError(.fileReadCorruptFile) }
        return metadata
    }

    private func write(metadata: MeetingMetadata, body: String) throws {
        let text = metadata.frontmatter() + (body.isEmpty ? "" : "\n" + body + "\n")
        try text.write(to: markdownURL, atomically: true, encoding: .utf8)
    }

    /// One line, without the characters that mark speakers in `transcript.md` (`**Name** [time]`).
    public static func clean(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .filter { !"*[]".contains($0) }
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Recognises voices from earlier meetings: a speaker you named in one meeting is a known voice,
/// and an unnamed speaker in another meeting whose embedding is close enough is suggested as them.
/// Everything comes from the meetings' `speakers.json`, so there's nothing separate to keep in sync.
public struct VoiceMatcher: Sendable {
    public struct KnownVoice: Sendable {
        public var name: String
        public var meeting: URL
        /// Unit length.
        public var embedding: [Float]
    }

    public struct Suggestion: Sendable, Equatable {
        /// The name the speaker has now, e.g. "Speaker 2".
        public var speaker: String
        public var name: String
        /// Cosine similarity, 0...1.
        public var similarity: Double
        /// How many earlier meetings that voice was named in.
        public var meetings: Int
    }

    /// From the meetings here, different people scored at most 0.49 and the same person 0.65 and up.
    public static let threshold = 0.6

    public var known: [KnownVoice]

    public init(known: [KnownVoice]) {
        self.known = known
    }

    /// Reads the named voices of every meeting in the store.
    public init(store: MeetingStore) {
        var known: [KnownVoice] = []
        for folder in store.recentMeetings(limit: .max) {
            for speaker in Self.voices(in: folder) where !Self.isPlaceholder(speaker.name) {
                known.append(KnownVoice(name: speaker.name, meeting: folder, embedding: Self.normalized(speaker.embedding)))
            }
        }
        self.known = known
    }

    public static func voices(in folder: URL) -> [SpeakerEmbeddings.Speaker] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(MeetingFiles.speakers)),
              let file = try? JSONDecoder().decode(SpeakerEmbeddings.self, from: data)
        else { return [] }
        return file.speakers
    }

    /// The names diarization gives: "Speaker 3", "Others".
    public static func isPlaceholder(_ name: String) -> Bool {
        name == SpeakerLabel.others || name.wholeMatch(of: /Speaker \d+/) != nil
    }

    /// Suggestions for the unnamed speakers of `folder`, best first. Each name is suggested for at
    /// most one speaker, and never for a name the meeting already uses.
    public func suggestions(for folder: URL) -> [Suggestion] {
        let voices = Self.voices(in: folder)
        let taken = Set(voices.map(\.name).filter { !Self.isPlaceholder($0) })
        let others = known.filter { $0.meeting.standardizedFileURL != folder.standardizedFileURL && !taken.contains($0.name) }
        var candidates: [Suggestion] = []
        for voice in voices where Self.isPlaceholder(voice.name) {
            let embedding = Self.normalized(voice.embedding)
            var best: [String: (similarity: Double, meetings: Set<URL>)] = [:]
            for other in others {
                let similarity = Self.dot(embedding, other.embedding)
                var entry = best[other.name] ?? (-1, [])
                entry.similarity = max(entry.similarity, similarity)
                entry.meetings.insert(other.meeting)
                best[other.name] = entry
            }
            for (name, entry) in best where entry.similarity >= Self.threshold {
                candidates.append(Suggestion(speaker: voice.name, name: name, similarity: entry.similarity, meetings: entry.meetings.count))
            }
        }
        // Greedy: the closest pairs first.
        var result: [Suggestion] = []
        for candidate in candidates.sorted(by: { $0.similarity > $1.similarity })
        where !result.contains(where: { $0.speaker == candidate.speaker || $0.name == candidate.name }) {
            result.append(candidate)
        }
        return result
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        Double(zip(a, b).reduce(0) { $0 + $1.0 * $1.1 })
    }
}
