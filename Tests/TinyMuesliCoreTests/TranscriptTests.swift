@preconcurrency import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import TinyMuesliCore

/// Builds a phrase whose words are spaced 0.5 s apart starting at `start`.
private func phrase(_ text: String, at start: Double, step: Double = 0.5) -> Phrase {
    let tokens = text.split(separator: " ").map(String.init)
    let words = tokens.enumerated().map { i, token in
        Word(text: (i == 0 ? "" : " ") + token, start: start + Double(i) * step, end: start + Double(i) * step + 0.4, confidence: 0.9)
    }
    return Phrase(start: start, end: words.last!.end, text: words.map(\.text).joined(), words: words)
}

@Suite struct TranscriptBuilderTests {
    @Test func micIsMeAndSystemWithoutDiarizationIsOthers() {
        let segments = TranscriptBuilder.segments(
            mic: [phrase("hello there", at: 0)],
            system: [phrase("hi back", at: 2)],
            turns: nil
        )
        #expect(segments.map(\.speaker) == ["Me", "Others"])
        #expect(segments.map(\.track) == [.mic, .system])
        #expect(segments[0].text == "hello there")
    }

    @Test func splitsSystemPhraseAtSpeakerChange() {
        // Words at 10.0, 10.5, ... 12.5. Speaker "B" takes over at 11.5.
        let p = phrase("one two three four five six", at: 10)
        let turns = [SpeakerTurn(speaker: "B", start: 9, end: 11.45), SpeakerTurn(speaker: "A", start: 11.5, end: 13)]
        let segments = TranscriptBuilder.segments(mic: [], system: [p], turns: turns)
        #expect(segments.map(\.text) == ["one two three", "four five six"])
        // Numbered by first appearance, not by the diarizer's ids.
        #expect(segments.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(segments[1].start == 11.5)
    }

    @Test func singleBoundaryWordJoinsCloserNeighbour() {
        // "I" (at 20.0) falls in A's turn, but sits right before B's words; the gap before it is long.
        let words = [
            Word(text: "afternoon.", start: 18.0, end: 18.6),
            Word(text: " I", start: 20.0, end: 20.1),
            Word(text: " can", start: 20.15, end: 20.4),
            Word(text: " help", start: 20.45, end: 20.8),
        ]
        let p = Phrase(start: 18, end: 20.8, text: "afternoon. I can help", words: words)
        let turns = [SpeakerTurn(speaker: "A", start: 17, end: 20.12), SpeakerTurn(speaker: "B", start: 20.12, end: 21)]
        let segments = TranscriptBuilder.segments(mic: [], system: [p], turns: turns)
        #expect(segments.map(\.text) == ["afternoon.", "I can help"])
    }

    @Test func wordStretchedOverPauseGoesToNextSpeaker() {
        // Real case: "I" was timed 21.06–22.32, absorbing the pause before B started at ~22.
        let words = [
            Word(text: "Friday", start: 20.2, end: 20.5),
            Word(text: " afternoon.", start: 20.5, end: 20.94),
            Word(text: " I", start: 21.06, end: 22.32),
            Word(text: " can", start: 22.32, end: 22.5),
            Word(text: " have", start: 22.5, end: 22.8),
        ]
        let p = Phrase(start: 20.2, end: 22.8, text: "Friday afternoon. I can have", words: words)
        let turns = [SpeakerTurn(speaker: "A", start: 16, end: 21.5), SpeakerTurn(speaker: "B", start: 21.9, end: 26)]
        let segments = TranscriptBuilder.segments(mic: [], system: [p], turns: turns)
        #expect(segments.map(\.text) == ["Friday afternoon.", "I can have"])
    }

    @Test func loneWordBetweenRunsJoinsCloserNeighbour() {
        let words = [
            Word(text: "yes", start: 0, end: 0.3),
            Word(text: " we", start: 0.35, end: 0.5),
            Word(text: " can", start: 0.55, end: 0.8),
            Word(text: " do", start: 2.0, end: 2.2),
            Word(text: " it", start: 2.25, end: 2.4),
        ]
        let p = Phrase(start: 0, end: 2.4, text: "yes we can do it", words: words)
        // The diarizer flips to B for "can" alone.
        let turns = [
            SpeakerTurn(speaker: "A", start: 0, end: 0.52),
            SpeakerTurn(speaker: "B", start: 0.52, end: 0.85),
            SpeakerTurn(speaker: "A", start: 1.9, end: 3),
        ]
        let segments = TranscriptBuilder.segments(mic: [], system: [p], turns: turns)
        #expect(segments.map(\.text) == ["yes we can do it"])
    }

    @Test func wordOutsideAnyTurnGoesToNearest() {
        let p = phrase("late word", at: 30)
        let turns = [SpeakerTurn(speaker: "X", start: 0, end: 5), SpeakerTurn(speaker: "Y", start: 28, end: 29.5)]
        let segments = TranscriptBuilder.segments(mic: [], system: [p], turns: turns)
        #expect(segments.map(\.speaker) == ["Speaker 2"])
    }

    @Test func mergedTimelineIsSortedByStart() {
        let segments = TranscriptBuilder.segments(
            mic: [phrase("first", at: 0), phrase("third", at: 10)],
            system: [phrase("second", at: 5)],
            turns: [SpeakerTurn(speaker: "s", start: 4, end: 6)]
        )
        #expect(segments.map(\.text) == ["first", "second", "third"])
    }

    @Test func splitsTheMicIntoVoicesAndKeepsMeForTheMainOne() {
        // Me speaks 0-10 s, someone else 20-30 s, and a 1 s blip the diarizer called a third voice.
        let mic = [phrase("one two three four five six seven eight nine ten eleven twelve", at: 0),
                   phrase("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda", at: 20),
                   phrase("blip blop", at: 40)]
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 10), SpeakerTurn(speaker: "B", start: 20, end: 30),
                     SpeakerTurn(speaker: "C", start: 40, end: 41)]
        let voices = TranscriptBuilder.micVoices(mic: mic, diarization: Diarization(turns: turns, embeddings: ["B": [1], "C": [2]]),
                                                 minimumSpeech: 3)
        #expect(voices?.segments.map(\.speaker) == ["Me", "Voice 1", "Me"])
        #expect(voices?.embeddings == ["Voice 1": [1]])

        // Applied to a call's transcript: the new voice is numbered after the system's speakers.
        let system = Segment(start: 15, end: 16, speaker: "Speaker 2", track: .system, text: "hi")
        let applied = voices!.applied(to: [Segment(start: 0, end: 50, speaker: "Me", track: .mic, text: "all of it"), system])
        #expect(applied.segments.map(\.speaker) == ["Me", "Speaker 2", "Speaker 3", "Me"])
        #expect(applied.names == ["Voice 1": "Speaker 3"])
    }

    @Test func oneVoiceOnTheMicIsNoSplit() {
        let mic = [phrase("one two three four five six seven eight nine ten eleven twelve", at: 0)]
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 5.8), SpeakerTurn(speaker: "B", start: 5.8, end: 6.5)]
        #expect(TranscriptBuilder.micVoices(mic: mic, diarization: Diarization(turns: turns, embeddings: [:])) == nil)
    }
}

@Suite struct TranscriptRendererTests {
    @Test func oneParagraphPerTurn() {
        let segments = [
            Segment(start: 3.7, end: 5, speaker: "Me", track: .mic, text: "Hi."),
            Segment(start: 5.2, end: 6, speaker: "Me", track: .mic, text: "Shall we start?"),
            Segment(start: 3725, end: 3730, speaker: "Speaker 1", track: .system, text: "Sure."),
        ]
        #expect(TranscriptRenderer.markdown(segments) == """
            **Me** [00:00:03] Hi. Shall we start?

            **Speaker 1** [01:02:05] Sure.
            """)
    }

    @Test func longPauseStartsNewParagraph() {
        let segments = [
            Segment(start: 0, end: 1, speaker: "Me", track: .mic, text: "One."),
            Segment(start: 60, end: 61, speaker: "Me", track: .mic, text: "Two."),
        ]
        #expect(TranscriptRenderer.markdown(segments).components(separatedBy: "\n\n").count == 2)
    }

    @Test func documentListsSpeakersInOrderOfAppearance() throws {
        let doc = TranscriptDocument(start: .now, end: nil, app: "Zoom", language: "en-US", segments: [
            Segment(start: 0, end: 1, speaker: "Speaker 1", track: .system, text: "a"),
            Segment(start: 1, end: 2, speaker: "Me", track: .mic, text: "b"),
            Segment(start: 2, end: 3, speaker: "Speaker 1", track: .system, text: "c"),
        ])
        #expect(doc.speakers == ["Speaker 1", "Me"])
        let decoded = try JSONDecoder.iso.decode(TranscriptDocument.self, from: doc.encoded())
        #expect(decoded.segments == doc.segments)
    }
}

@Suite struct MetadataParsingTests {
    @Test func roundTrips() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meta = MeetingMetadata(start: start, end: start + 90, app: "Microsoft Teams", status: .failed,
                                   language: "de-DE", speakers: ["Me", "Speaker 1"], error: "Bad \"thing\": happened")
        let parsed = MeetingMetadata(parsing: meta.frontmatter() + "\n**Me** [00:00:00] Hallo\n")
        #expect(parsed == meta)
    }

    @Test func rejectsTextWithoutFrontmatter() {
        #expect(MeetingMetadata(parsing: "# Notes") == nil)
    }
}

// MARK: - Final pass with fake engines

private struct FakeTranscriber: Transcriber {
    var language = "en-US"
    let phrases: [Phrase]
    func inLanguage(_ language: String) -> Transcriber { FakeTranscriber(language: language, phrases: phrases) }
    func makeStream(onPhrase: @escaping @Sendable (Phrase) -> Void) -> TranscriptionStream { FakeStream(phrases: phrases) }
}

private final class FakeStream: TranscriptionStream, @unchecked Sendable {
    let phrases: [Phrase]
    init(phrases: [Phrase]) { self.phrases = phrases }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> [Phrase] { phrases }
}

private struct FakeDiarizer: Diarizer {
    var fails = false
    /// What the microphone track hears; one voice by default.
    var mic: Diarization?
    func prepare() async throws {}
    func diarize(file: URL) async throws -> Diarization {
        if fails { throw CocoaError(.fileReadUnknown) }
        if let mic, file.lastPathComponent.hasPrefix("mic") { return mic }
        return Diarization(turns: [SpeakerTurn(speaker: "7", start: 0, end: 100)], embeddings: ["7": [0.1, 0.2]])
    }
}

@Suite struct MeetingProcessorTests {
    /// A meeting folder with a frontmatter-only transcript and two short silent tracks.
    private func makeFolder(app: String? = "Zoom") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinymuesli-test-\(UUID().uuidString)")
            .appendingPathComponent("2026-11-04 1030 Zoom")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("audio"), withIntermediateDirectories: true)
        let meta = MeetingMetadata(start: .now, end: .now + 60, app: app, status: .recorded)
        try meta.frontmatter().write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        for name in ["mic", "system"] {
            let writer = try TrackWriter(url: folder.appendingPathComponent("audio/\(name).caf"), inputFormat: format)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            writer.write(buffer)
            writer.close()
        }
        return folder
    }

    @Test func writesTranscriptAndDeletesAudio() async throws {
        let folder = try makeFolder()
        let processor = MeetingProcessor(
            transcriber: FakeTranscriber(phrases: [phrase("good morning", at: 1)]),
            diarizer: FakeDiarizer(), keepAudio: false
        )
        let live: [Track: [Phrase]] = [.mic: [phrase("hello", at: 0)]]
        let result = try await processor.process(folder: folder, live: live)

        #expect(result.document.speakers == ["Me", "Speaker 1"])
        let md = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(md.contains("status: done"))
        #expect(md.contains("app: Zoom"))
        #expect(md.contains("speakers: [Me, Speaker 1]"))
        #expect(md.contains("**Speaker 1** [00:00:01] good morning"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("speakers.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio").path))
    }

    /// Two people on the mic: split right away without a meeting app, only offered in a call.
    @Test(arguments: [nil, "Zoom"]) func splitsMeWhenTheMicHearsTwoVoices(app: String?) async throws {
        let folder = try makeFolder(app: app)
        let mic = Diarization(turns: [SpeakerTurn(speaker: "a", start: 0, end: 10), SpeakerTurn(speaker: "b", start: 20, end: 30)],
                              embeddings: ["a": [1, 0], "b": [0, 1]])
        let processor = MeetingProcessor(transcriber: FakeTranscriber(phrases: []), diarizer: FakeDiarizer(mic: mic), keepAudio: true)
        // Both over the 5 s of speech a voice needs to count; the first says more, so it's Me.
        func words(_ n: Int) -> String { Array(repeating: "word", count: n).joined(separator: " ") }
        let live: [Track: [Phrase]] = [.mic: [phrase(words(19), at: 0), phrase(words(16), at: 20)]]
        let result = try await processor.process(folder: folder, live: live)
        let offer = folder.appendingPathComponent(MeetingFiles.micVoices)
        if app == nil {
            #expect(result.document.speakers == ["Me", "Speaker 1"])
            #expect(!FileManager.default.fileExists(atPath: offer.path))
            #expect(VoiceMatcher.voices(in: folder).map(\.name) == ["Speaker 1"])
        } else {
            #expect(result.document.speakers == ["Me"])
            #expect(MeetingEditor(folder: folder).micVoices?.voices == ["Voice 1"])
        }
    }

    @Test func keepsAudioWhenAsked() async throws {
        let folder = try makeFolder()
        let processor = MeetingProcessor(transcriber: FakeTranscriber(phrases: []), diarizer: nil, keepAudio: true)
        _ = try await processor.process(folder: folder)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio/mic.caf").path))
    }

    @Test func diarizationFailureFallsBackToOthers() async throws {
        let folder = try makeFolder()
        let processor = MeetingProcessor(
            transcriber: FakeTranscriber(phrases: [phrase("hi", at: 1)]),
            diarizer: FakeDiarizer(fails: true), keepAudio: false
        )
        let result = try await processor.process(folder: folder)
        #expect(result.document.speakers == ["Me", "Others"])
        #expect(result.warnings.count == 1)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@Suite struct ClockAlignmentTests {
    /// Host ticks for `seconds` after `start`.
    private func ticks(_ seconds: Double, after start: UInt64) -> UInt64 {
        start + AudioConvertNanosToHostTime(UInt64(seconds * 1e9))
    }

    @Test func fillsGapWhenBuffersArriveLate() {
        let start: UInt64 = 1_000_000_000
        // Nothing written yet, first buffer captured 8 s in: 8 s of silence first.
        let missing = TrackWriter.missingFrames(at: ticks(8, after: start), clockStart: start, written: 0, sampleRate: 48_000)
        #expect(missing.map { abs($0 - 384_000) <= 1 } == true)
    }

    @Test func ignoresJitterAndEarlyBuffers() {
        let start: UInt64 = 1_000_000_000
        #expect(TrackWriter.missingFrames(at: ticks(1.05, after: start), clockStart: start, written: 48_000, sampleRate: 48_000) == nil)
        #expect(TrackWriter.missingFrames(at: ticks(0.5, after: start), clockStart: start, written: 48_000, sampleRate: 48_000) == nil)
        #expect(TrackWriter.missingFrames(at: nil, clockStart: start, written: 0, sampleRate: 48_000) == nil)
    }
}
