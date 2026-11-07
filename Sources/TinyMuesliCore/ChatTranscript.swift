import Foundation

/// A meeting's transcript as chat messages, for the chat viewer.
///
/// Reads `transcript.json` when it's there (final, with tracks), else the paragraphs of
/// `transcript.md`, so a meeting still being recorded shows its live transcript.
public struct ChatTranscript: Sendable, Equatable {
    public struct Message: Sendable, Equatable, Identifiable {
        public var id: Int
        public var speaker: String
        /// Said by the user (mic track).
        public var isMe: Bool
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
                result.append(Message(id: result.count, speaker: segment.speaker, isMe: segment.track == .mic,
                                      start: segment.start, end: segment.end, text: segment.text))
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
                                  start: start, end: start, text: turn.text.trimmingCharacters(in: .whitespacesAndNewlines)))
            if i > 0 { result[i - 1].end = max(result[i - 1].start, start) }
        }
        return result
    }

    static func seconds(_ timestamp: String) -> Double {
        timestamp.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}
