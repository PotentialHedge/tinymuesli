import Foundation

/// A meeting as the CLI and MCP server describe it.
public struct MeetingSummary: Codable, Sendable, Equatable {
    /// Path relative to the meetings root, e.g. "2026/11/2026-11-04 1030 Zoom".
    public var id: String
    public var path: String
    public var start: Date
    public var end: Date?
    /// Only when one was set.
    public var title: String?
    public var app: String?
    public var status: String
    public var language: String?
    public var speakers: [String]
    public var tags: [String]
    public var error: String?
    /// Apple Intelligence's title (`suggestions.json`), only while the meeting has none of its own.
    public var suggestedTitle: String?
}

/// One paragraph of a transcript that matched a search.
public struct SearchHit: Codable, Sendable, Equatable {
    public var meeting: String
    public var speaker: String
    /// Position in the recording, "HH:MM:SS".
    public var timestamp: String
    /// The text around the match.
    public var excerpt: String
}

/// A speaker of one meeting, as `tinymuesli speakers --json` describes them.
public struct SpeakerInfo: Codable, Sendable, Equatable {
    public struct Suggestion: Codable, Sendable, Equatable {
        public var name: String
        /// Cosine similarity, 0...1, to two decimals.
        public var similarity: Double
        /// How many other meetings that voice was named in.
        public var meetings: Int
    }

    public var name: String
    /// False for the names diarization gives ("Speaker 2", "Others").
    public var named: Bool
    /// Only for speakers that aren't named yet.
    public var suggestion: Suggestion?
}

/// Access to the meetings on disk, shared by the CLI and the MCP server. Reads, plus the edits
/// `MeetingEditor` allows (title, tags, speaker names).
public struct MeetingLibrary: Sendable {
    public let store: MeetingStore

    public init(store: MeetingStore = MeetingStore()) {
        self.store = store
    }

    /// Most recent first. Folders without a readable `transcript.md` aren't meetings to us.
    public func meetings(limit: Int = .max) -> [MeetingSummary] {
        Array(store.recentMeetings(limit: .max).lazy.compactMap(summary(of:)).prefix(max(0, limit)))
    }

    /// Looks a meeting up among those that exist, so an id can never reach outside the root.
    public func folder(id: String) -> URL? {
        store.recentMeetings(limit: .max).first { Self.id(of: $0) == id }
    }

    public func summary(of folder: URL) -> MeetingSummary? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcript), encoding: .utf8),
              let metadata = MeetingMetadata(parsing: text)
        else { return nil }
        return MeetingSummary(
            id: Self.id(of: folder), path: folder.path, start: metadata.start, end: metadata.end, title: metadata.title, app: metadata.app,
            status: metadata.status.rawValue, language: metadata.language, speakers: metadata.speakers,
            tags: metadata.tags, error: metadata.error,
            suggestedTitle: metadata.title == nil ? MeetingSuggestions.load(folder: folder)?.title : nil
        )
    }

    public enum UpdateError: LocalizedError, Equatable {
        case noMeeting(String)
        case noSpeaker(String, speakers: [String])

        public var errorDescription: String? {
            switch self {
            case .noMeeting(let id): "No meeting with id \"\(id)\"."
            case .noSpeaker(let name, let speakers):
                "This meeting has no speaker \"\(name)\". Its speakers are: \(speakers.joined(separator: ", "))."
            }
        }
    }

    /// Sets a meeting's title and tags and renames its speakers, all checked before anything is
    /// written. Nil leaves that part as it is. Shared by the MCP server's `update_meeting` and the
    /// CLI's `update`. Throws `UpdateError` or `MeetingEditor.EditError`.
    @discardableResult
    public func update(id: String, title: String? = nil, tags: [String]? = nil,
                       speakers: [String: String] = [:]) throws -> MeetingSummary {
        guard let folder = folder(id: id), let summary = summary(of: folder) else { throw UpdateError.noMeeting(id) }
        if let unknown = speakers.keys.sorted().first(where: { !summary.speakers.contains($0) }) {
            throw UpdateError.noSpeaker(unknown, speakers: summary.speakers)
        }
        let editor = MeetingEditor(folder: folder)
        if let title { try editor.setTitle(title) }
        if let tags { try editor.setTags(tags) }
        for (old, new) in speakers.sorted(by: { $0.key < $1.key }) {
            try editor.rename(speaker: old, to: new)
        }
        guard let updated = self.summary(of: folder) else { throw CocoaError(.fileReadCorruptFile) }
        return updated
    }

    /// A meeting's speakers in transcript order, each with the voice from another meeting it
    /// sounds like, if any (see `VoiceMatcher`).
    public func speakers(id: String) throws -> [SpeakerInfo] {
        guard let folder = folder(id: id), let summary = summary(of: folder) else { throw UpdateError.noMeeting(id) }
        let suggestions = VoiceMatcher(store: store).suggestions(for: folder)
        return summary.speakers.map { name in
            SpeakerInfo(name: name, named: name == SpeakerLabel.me || !VoiceMatcher.isPlaceholder(name),
                        suggestion: suggestions.first { $0.speaker == name }.map {
                            SpeakerInfo.Suggestion(name: $0.name, similarity: ($0.similarity * 100).rounded() / 100, meetings: $0.meetings)
                        })
        }
    }

    /// Finds `query` in transcripts, ignoring case and accents. Newest meetings first, and in
    /// order of speech within a meeting. Searches `transcript.md`, so meetings in progress count.
    public func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        for folder in store.recentMeetings(limit: .max) {
            let body = MeetingProcessor.body(of: folder.appendingPathComponent(MeetingFiles.transcript))
            for paragraph in body.components(separatedBy: "\n\n") {
                guard let turn = Self.parseTurn(paragraph), let excerpt = Self.excerpt(of: turn.text, around: query) else { continue }
                hits.append(SearchHit(meeting: Self.id(of: folder), speaker: turn.speaker, timestamp: turn.timestamp, excerpt: excerpt))
                if hits.count == limit { return hits }
            }
        }
        return hits
    }

    public static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func id(of folder: URL) -> String {
        folder.pathComponents.suffix(3).joined(separator: "/")
    }

    /// A paragraph as `TranscriptRenderer` writes it: `**Speaker 1** [00:00:04] Text`.
    static func parseTurn(_ paragraph: String) -> (speaker: String, timestamp: String, text: String)? {
        let pattern = /^\*\*(.+?)\*\* \[(\d+:\d\d:\d\d)\] (.*)$/.dotMatchesNewlines()
        guard let match = paragraph.firstMatch(of: pattern) else { return nil }
        return (String(match.1), String(match.2), String(match.3))
    }

    /// A paragraph can run for minutes, so return only the text around the match.
    static func excerpt(of text: String, around query: String, radius: Int = 120) -> String? {
        guard let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}
