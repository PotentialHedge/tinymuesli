import Foundation
import Testing
@testable import TinyMuesliCore

@Suite struct ChatTranscriptTests {
    @Test func joinsCloseSegmentsOfOneSpeaker() {
        let segments = [
            Segment(start: 0, end: 2, speaker: "Me", track: .mic, text: "Hi."),
            Segment(start: 3, end: 5, speaker: "Me", track: .mic, text: "Shall we start?"),
            Segment(start: 5.5, end: 8, speaker: "Speaker 1", track: .system, text: "Sure."),
            Segment(start: 20, end: 22, speaker: "Speaker 1", track: .system, text: "After a pause."),
        ]
        let messages = ChatTranscript.messages(from: segments)
        #expect(messages.map(\.text) == ["Hi. Shall we start?", "Sure.", "After a pause."])
        #expect(messages.map(\.isMe) == [true, false, false])
        #expect(messages.map(\.id) == [0, 1, 2])
        #expect(messages[0].end == 5)
    }

    @Test func splitsLongMessages() {
        let sentence = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let segments = (0..<3).map { Segment(start: Double($0), end: Double($0) + 0.9, speaker: "Me", track: .mic, text: sentence) }
        #expect(ChatTranscript.messages(from: segments).count == 3)
    }

    @Test func readsLiveMarkdown() {
        let body = "**Me** [00:00:03] Thanks for joining.\n\n**Others** [00:01:05] Sure, the importer is done."
        let messages = ChatTranscript.messages(fromMarkdown: body)
        #expect(messages.map(\.speaker) == ["Me", "Others"])
        #expect(messages.map(\.isMe) == [true, false])
        #expect(messages.map(\.start) == [3, 65])
        #expect(messages[0].end == 65)
    }
}
