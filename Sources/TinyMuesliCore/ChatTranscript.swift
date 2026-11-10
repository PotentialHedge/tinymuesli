import Foundation

/// A meeting's transcript as chat messages, for the chat viewer.
///
/// Reads `transcript.json` when it's there (final, with tracks), else the paragraphs of
/// `transcript.md`, so a meeting still being recorded shows its live transcript.
public struct ChatTranscript: Sendable, Equatable {
    public struct Message: Sendable, Equatable, Identifiable {
        public var id: Int
        public var speaker: String
        /// Said by the user ("Me": the mic track, less any other voices split off it).
        public var isMe: Bool
        /// Heard through the microphone, not the computer (so it can be merged into "Me").
        public var fromMic: Bool
        /// Seconds from the start of the recording.
        public var start: Double
        public var end: Double
        public var text: String
    }

    public var metadata: MeetingMetadata?
    public var messages: [Message]
    /// Everyone who speaks, in order of first appearance.
    public var speakers: [String]

    public init(metadata: MeetingMetadata?, messages: [Message]) {
        self.metadata = metadata
        self.messages = messages
        var seen: [String] = []
        for m in messages where !seen.contains(m.speaker) { seen.append(m.speaker) }
        speakers = seen
    }

    public static func load(folder: URL) -> ChatTranscript {
        let md = folder.appendingPathComponent(MeetingFiles.transcript)
        let metadata = (try? String(contentsOf: md, encoding: .utf8)).flatMap(MeetingMetadata.init(parsing:))
        // While recording or transcribing, a transcript.json from an earlier pass may be stale.
        let final = metadata.map { $0.status == .done || $0.status == .failed } ?? true
        if final, let data = try? Data(contentsOf: folder.appendingPathComponent(MeetingFiles.json)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let document = try? decoder.decode(TranscriptDocument.self, from: data) {
                return ChatTranscript(metadata: metadata, messages: messages(from: document.segments))
            }
        }
        return ChatTranscript(metadata: metadata, messages: messages(fromMarkdown: MeetingProcessor.body(of: md)))
    }

    /// The start of what was said, for a list of meetings: the first few turns of `transcript.md`.
    public static func preview(folder: URL, maxLength: Int = 160) -> String? {
        let body = MeetingProcessor.body(of: folder.appendingPathComponent(MeetingFiles.transcript))
        var text = ""
        for paragraph in body.components(separatedBy: "\n\n") {
            guard let turn = MeetingLibrary.parseTurn(paragraph) else { continue }
            text += (text.isEmpty ? "" : " ") + turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= maxLength { break }
        }
        guard !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }

    /// How often `query` occurs in a transcript body (ignoring case and accents), and the text
    /// around the first match, for search results in the list of meetings.
    public static func matches(in body: String, query: String) -> (count: Int, excerpt: String?) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return (0, nil) }
        var count = 0
        var excerpt: String?
        for paragraph in body.components(separatedBy: "\n\n") {
            guard let turn = MeetingLibrary.parseTurn(paragraph) else { continue }
            var search = turn.text.startIndex..<turn.text.endIndex
            while let range = turn.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: search) {
                count += 1
                if excerpt == nil {
                    excerpt = MeetingLibrary.excerpt(of: turn.text, around: query, radius: 60).map { "\(turn.speaker): \($0)" }
                }
                search = range.upperBound..<turn.text.endIndex
            }
        }
        return (count, excerpt)
    }

    /// Joins consecutive segments of one speaker into a message, as long as they follow closely and
    /// the message stays short enough to read as one bubble.
    public static func messages(from segments: [Segment], maxPause: Double = 4, maxLength: Int = 320) -> [Message] {
        var result: [Message] = []
        for segment in segments {
            if var last = result.last, last.speaker == segment.speaker,
               segment.start - last.end < maxPause, last.text.count + segment.text.count < maxLength {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                result[result.count - 1] = last
            } else {
                result.append(Message(id: result.count, speaker: segment.speaker, isMe: segment.speaker == SpeakerLabel.me,
                                      fromMic: segment.track == .mic, start: segment.start, end: segment.end, text: segment.text))
            }
        }
        return result
    }

    /// `transcript.md` has one paragraph per turn and no end times; each paragraph ends where the next begins.
    static func messages(fromMarkdown body: String) -> [Message] {
        let turns = body.components(separatedBy: "\n\n").compactMap(MeetingLibrary.parseTurn)
        var result: [Message] = []
        for (i, turn) in turns.enumerated() {
            let start = seconds(turn.timestamp)
            result.append(Message(id: i, speaker: turn.speaker, isMe: turn.speaker == SpeakerLabel.me,
                                  fromMic: turn.speaker == SpeakerLabel.me, start: start, end: start, text: turn.text.trimmingCharacters(in: .whitespacesAndNewlines)))
            if i > 0 { result[i - 1].end = max(result[i - 1].start, start) }
        }
        return result
    }

    static func seconds(_ timestamp: String) -> Double {
        timestamp.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}
