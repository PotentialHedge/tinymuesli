import Foundation
import Testing
@testable import TinyMuesliCore

@Suite struct MeetingEditorTests {
    private func makeMeeting(voices: [String: [Float]] = [:]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let segments = [
            Segment(start: 0, end: 2, speaker: "Me", track: .mic, text: "Hi."),
            Segment(start: 3, end: 5, speaker: "Speaker 1", track: .system, text: "Hello."),
            Segment(start: 6, end: 8, speaker: "Speaker 2", track: .system, text: "Hey there."),
        ]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let document = TranscriptDocument(start: start, end: start + 60, app: "Zoom", language: "en-US", segments: segments)
        try document.encoded().write(to: folder.appendingPathComponent(MeetingFiles.json))
        let metadata = MeetingMetadata(start: start, end: start + 60, app: "Zoom", status: .done, speakers: document.speakers)
        try (metadata.frontmatter() + "\n" + TranscriptRenderer.markdown(segments) + "\n")
            .write(to: folder.appendingPathComponent(MeetingFiles.transcript), atomically: true, encoding: .utf8)
        var file = SpeakerEmbeddings(diarization: Diarization(turns: [], embeddings: [:]))
        file.speakers = voices.map { SpeakerEmbeddings.Speaker(name: $0.key, embedding: $0.value) }
        try file.encoded().write(to: folder.appendingPathComponent(MeetingFiles.speakers))
        return folder
    }

    @Test func resumedRoundTripsThroughFrontmatter() {
        var metadata = MeetingMetadata(start: Date(timeIntervalSince1970: 1_800_000_000), app: nil, status: .done)
        metadata.resumed = metadata.start + 5400
        let parsed = MeetingMetadata(parsing: metadata.frontmatter())
        #expect(parsed?.resumed == metadata.resumed)
        #expect(parsed?.audioOffset == 5400)
    }

    @Test func tagsRoundTripThroughFrontmatter() {
        let metadata = MeetingMetadata(start: Date(timeIntervalSince1970: 0), app: "Zoom", status: .done,
                                       speakers: ["Me", "Ann, B"], tags: ["standup", "q4: plan"])
        let parsed = MeetingMetadata(parsing: metadata.frontmatter())
        #expect(parsed?.tags == ["standup", "q4: plan"])
        #expect(parsed?.speakers == ["Me", "Ann, B"])
    }

    @Test func setsTagsKeepingTheTranscript() throws {
        let folder = try makeMeeting()
        try MeetingEditor(folder: folder).setTags([" standup ", "Standup", "", "roadmap"])
        let text = try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcript), encoding: .utf8)
        #expect(MeetingMetadata(parsing: text)?.tags == ["standup", "roadmap"])
        #expect(text.contains("**Speaker 1** [00:00:03] Hello."))
    }

    @Test func renamesASpeakerInEveryFile() throws {
        let folder = try makeMeeting(voices: ["Speaker 1": [1, 0], "Speaker 2": [0, 1]])
        try MeetingEditor(folder: folder).rename(speaker: "Speaker 1", to: "Ann **[x]**")
        let text = try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcript), encoding: .utf8)
        #expect(text.contains("**Ann x** [00:00:03] Hello."))
        #expect(MeetingMetadata(parsing: text)?.speakers == ["Me", "Ann x", "Speaker 2"])
        let chat = ChatTranscript.load(folder: folder)
        #expect(chat.speakers == ["Me", "Ann x", "Speaker 2"])
        #expect(VoiceMatcher.voices(in: folder).map(\.name).sorted() == ["Ann x", "Speaker 2"])
    }

    @Test func mergesSpeakersGivenTheSameName() throws {
        let folder = try makeMeeting()
        let editor = MeetingEditor(folder: folder)
        try editor.rename(speaker: "Speaker 2", to: "Speaker 1")
        #expect(ChatTranscript.load(folder: folder).speakers == ["Me", "Speaker 1"])
        #expect(throws: MeetingEditor.EditError.reservedName("Me")) { try editor.rename(speaker: "Speaker 1", to: "Me") }
    }

    @Test func mergesIntoAnExistingSpeakerOnly() throws {
        let folder = try makeMeeting(voices: ["Speaker 1": [1, 0], "Speaker 2": [0, 1]])
        let editor = MeetingEditor(folder: folder)
        #expect(throws: MeetingEditor.EditError.unknownSpeaker("Ann")) { try editor.merge(speaker: "Speaker 1", into: "Ann") }
        #expect(throws: MeetingEditor.EditError.reservedName("Me")) { try editor.merge(speaker: "Speaker 1", into: "Me") }
        try editor.merge(speaker: "Speaker 1", into: "Speaker 2")
        let text = try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcript), encoding: .utf8)
        #expect(MeetingMetadata(parsing: text)?.speakers == ["Me", "Speaker 2"])
        // Both voices are kept under the one name, so either is recognised in other meetings.
        #expect(VoiceMatcher.voices(in: folder).map(\.name) == ["Speaker 2", "Speaker 2"])
    }

    @Test func suggestsNamedVoicesFromOtherMeetings() throws {
        let earlier = try makeMeeting(voices: ["Ann": [1, 0, 0], "Bob": [0, 1, 0]])
        let later = try makeMeeting(voices: ["Speaker 1": [0.1, 0.9, 0], "Speaker 2": [0.9, 0.2, 0.1], "Speaker 3": [0, 0, 1]])
        let matcher = VoiceMatcher(known: VoiceMatcher.voices(in: earlier).map {
            VoiceMatcher.KnownVoice(name: $0.name, meeting: earlier, embedding: VoiceMatcher.normalized($0.embedding))
        })
        let suggestions = matcher.suggestions(for: later)
        #expect(Set(suggestions.map { "\($0.speaker)=\($0.name)" }) == ["Speaker 1=Bob", "Speaker 2=Ann"])
        #expect(matcher.suggestions(for: earlier).isEmpty)
    }

    @Test func splitsMeWhenOfferedAndMergesAVoiceBack() throws {
        let folder = try makeMeeting(voices: ["Speaker 1": [1, 0], "Speaker 2": [0, 1]])
        let offer = MicVoices(segments: [
            Segment(start: 0, end: 1, speaker: "Me", track: .mic, text: "Hi."),
            Segment(start: 1, end: 2, speaker: "Voice 1", track: .mic, text: "Hello from the room."),
        ], embeddings: ["Voice 1": [0.5, 0.5]])
        try offer.encoded().write(to: folder.appendingPathComponent(MeetingFiles.micVoices))
        let editor = MeetingEditor(folder: folder)
        #expect(editor.micVoices == offer)
        try editor.splitMe()

        let chat = ChatTranscript.load(folder: folder)
        #expect(chat.speakers == ["Me", "Speaker 3", "Speaker 1", "Speaker 2"])
        #expect(chat.messages.first { $0.speaker == "Speaker 3" }?.isMe == false)
        #expect(editor.micVoices == nil)
        #expect(VoiceMatcher.voices(in: folder).map(\.name) == ["Speaker 1", "Speaker 2", "Speaker 3"])

        // Someone from the call can't become Me; a voice from the mic can go back.
        #expect(throws: MeetingEditor.EditError.reservedName("Me")) { try editor.merge(speaker: "Speaker 1", into: "Me") }
        try editor.merge(speaker: "Speaker 3", into: "Me")
        #expect(ChatTranscript.load(folder: folder).speakers == ["Me", "Speaker 1", "Speaker 2"])
        // "Me" isn't a voice to recognise elsewhere.
        #expect(VoiceMatcher.voices(in: folder).map(\.name) == ["Speaker 1", "Speaker 2"])
    }
}
