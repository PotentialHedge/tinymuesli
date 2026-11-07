@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import TinyMuesliCore

/// Words 1 s apart from `start`, each lasting 0.8 s.
private func phrase(_ text: String, at start: Double, confidence: Double = 0.9) -> Phrase {
    let words = text.split(separator: " ").enumerated().map { i, token in
        Word(text: (i == 0 ? "" : " ") + token, start: start + Double(i), end: start + Double(i) + 0.8, confidence: confidence)
    }
    return Phrase(start: start, end: words.last!.end, text: words.map(\.text).joined(), words: words)
}

private let ten = "one two three four five six seven eight nine ten"
private func english(_: String) -> [String: Double] { ["en": 0.95] }
private func german(_: String) -> [String: Double] { ["de": 0.95] }

@Suite struct LanguageMonitorTests {
    @Test func lowConfidenceTriggersOnceThereIsEnoughSpeech() {
        var monitor = LanguageMonitor(language: "en-US")
        #expect(monitor.add(phrase(ten, at: 0, confidence: 0.3), identify: english) == nil)  // 8 s of speech
        let reason = monitor.add(phrase(ten, at: 10, confidence: 0.3), identify: english)
        guard case .lowConfidence(let score) = reason else { Issue.record("no check: \(String(describing: reason))"); return }
        #expect(abs(score - 0.3) < 0.001)
        #expect(monitor.windowStart == 0)
    }

    @Test func confidentSpeechInTheRightLanguageDoesNotTrigger() {
        var monitor = LanguageMonitor(language: "en-US")
        for i in 0..<10 {
            #expect(monitor.add(phrase(ten, at: Double(i) * 10), identify: english) == nil)
        }
    }

    @Test func textInAnotherLanguageTriggersEvenWhenConfident() {
        // Swiss German writes English speech out as English, with confidence barely lower.
        var monitor = LanguageMonitor(language: "de-CH")
        _ = monitor.add(phrase(ten, at: 0, confidence: 0.75), identify: english)
        #expect(monitor.add(phrase(ten, at: 10, confidence: 0.75), identify: english) == .textLooksLike("en"))
    }

    @Test func waitsBetweenChecks() {
        var monitor = LanguageMonitor(language: "en-US")
        _ = monitor.add(phrase(ten, at: 0, confidence: 0.3), identify: english)
        #expect(monitor.add(phrase(ten, at: 10, confidence: 0.3), identify: english) != nil)
        #expect(monitor.add(phrase(ten, at: 20, confidence: 0.3), identify: english) == nil)
        #expect(monitor.add(phrase(ten, at: 110, confidence: 0.3), identify: english) == nil)  // window refilling
        #expect(monitor.add(phrase(ten, at: 120, confidence: 0.3), identify: english) != nil)
    }

    @Test func judgesOnlyWhatComesAfterASwitch() {
        var monitor = LanguageMonitor(language: "en-US")
        _ = monitor.add(phrase(ten, at: 0, confidence: 0.3), identify: german)
        #expect(monitor.add(phrase(ten, at: 10, confidence: 0.3), identify: german) != nil)
        monitor.switched(to: "de-CH")
        #expect(monitor.language == "de")
        // German text is now the expected language; the old low scores are gone.
        #expect(monitor.add(phrase(ten, at: 20), identify: german) == nil)
        #expect(monitor.add(phrase(ten, at: 30), identify: german) == nil)
    }
}

@Suite struct LanguageDetectorTests {
    private let offered = ["de-AT", "de-CH", "de-DE", "en-GB", "en-US", "fr-FR"].map(Locale.init(identifier:))

    @Test func candidatesStartWithWhatTheTextLooksLike() {
        let candidates = LanguageDetector.candidates(
            text: "Gut, Dunmachhen wir Jets", current: "en-US", offered: offered,
            preferred: ["en-US", "fr-FR"], identify: german
        )
        #expect(candidates.first?.hasPrefix("de") == true)
        #expect(candidates.contains("fr-FR"))
        #expect(!candidates.contains { $0.hasPrefix("en") })
    }

    @Test func candidatesUseYourOwnVariant() {
        let candidates = LanguageDetector.candidates(
            text: "", current: "en-US", offered: offered, preferred: ["en-US", "de-CH"], identify: { _ in [:] }
        )
        #expect(candidates == ["de-CH"])
    }

    @Test func candidatesSkipLanguagesTheEngineLacks() {
        let candidates = LanguageDetector.candidates(
            text: "", current: "en-US", offered: offered, preferred: ["ja-JP"], identify: { _ in ["it": 0.9] }
        )
        #expect(candidates.isEmpty)
    }

    @Test func suggestsOnlyAClearlyBetterLanguage() {
        // English heard as German by the English model: far apart.
        #expect(LanguageDetector.best(current: 0.45, scores: [("de-CH", 0.86)], textLanguage: "de")?.language == "de-CH")
        // A little better is noise…
        #expect(LanguageDetector.best(current: 0.78, scores: [("en-US", 0.83)], textLanguage: nil) == nil)
        // …unless the words read as that language too.
        #expect(LanguageDetector.best(current: 0.78, scores: [("en-US", 0.83)], textLanguage: "en")?.language == "en-US")
        // Not when every language does badly (music, crosstalk).
        #expect(LanguageDetector.best(current: 0.2, scores: [("de-CH", 0.5)], textLanguage: "de") == nil)
    }
}

@Suite struct LanguageSwitchTests {
    @Test func roundTripsThroughFrontmatter() throws {
        var meta = MeetingMetadata(start: Date(timeIntervalSince1970: 1_800_000_000), app: "Zoom", status: .recording, language: "en-US")
        meta.languageSwitches = [LanguageSwitch(track: .system, time: 312.5, language: "de-CH"), LanguageSwitch(track: .mic, time: 0, language: "fr-FR")]
        let text = meta.frontmatter()
        #expect(text.contains("language-switches: [system 312.5 de-CH, mic 0.0 fr-FR]"))
        #expect(try #require(MeetingMetadata(parsing: text)).languageSwitches == meta.languageSwitches)
    }

    @Test func legsFollowTheTracksSwitches() {
        let switches = [
            LanguageSwitch(track: .system, time: 0, language: "de-CH"),
            LanguageSwitch(track: .mic, time: 60, language: "de-CH"),
            LanguageSwitch(track: .system, time: 120, language: "en-US"),
        ]
        #expect(MeetingProcessor.legs(of: .system, switches: switches).map(\.start) == [0, 120])
        #expect(MeetingProcessor.legs(of: .system, switches: switches).map(\.language) == ["de-CH", "en-US"])
        #expect(MeetingProcessor.legs(of: .mic, switches: switches).map(\.language) == [nil, "de-CH"])
    }

    @Test func clipsPhrasesToAStretchOfTime() throws {
        let p = phrase("a b c d", at: 10)  // words at 10, 11, 12, 13
        #expect(p.clipped(to: 0..<100) == p)
        #expect(try #require(p.clipped(to: 0..<12)).text == "a b")
        #expect(try #require(p.clipped(to: 12..<100)).text == "c d")
        #expect(p.clipped(to: 20..<30) == nil)
        #expect(p.shifted(by: 5).words.map(\.start) == [15, 16, 17, 18])
    }
}

// MARK: - Switching while recording

/// Hears whatever phrases its language is given, relative to the start of its audio.
private struct ScriptedTranscriber: Transcriber {
    var language: String
    let script: [String: [Phrase]]
    func inLanguage(_ language: String) -> Transcriber { ScriptedTranscriber(language: language, script: script) }
    func makeStream(onPhrase: @escaping @Sendable (Phrase) -> Void) -> TranscriptionStream {
        ScriptedStream(phrases: script[language] ?? [])
    }
}

private final class ScriptedStream: TranscriptionStream, @unchecked Sendable {
    let phrases: [Phrase]
    init(phrases: [Phrase]) { self.phrases = phrases }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> [Phrase] { phrases }
}

@Suite struct LanguageSwitchingStreamTests {
    private func second() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        return buffer
    }

    @Test func switchKeepsOldWordsBeforeAndNewWordsAfter() async throws {
        let engine = ScriptedTranscriber(language: "en-US", script: [
            "en-US": [phrase("hello there gut dann machen", at: 0)],  // words at 0…4
            // The new leg's audio starts at the switch: its times count from there.
            "de-CH": [phrase("gut dann machen wir", at: 0)],
        ])
        let stream = LanguageSwitchingStream(language: "en-US", makeTranscriber: engine.inLanguage) { _ in }
        for _ in 0..<6 { stream.append(second()) }
        #expect(stream.duration == 6)
        #expect(stream.audio(from: 2.5)?.start == 2)

        let start = stream.switchLanguage(to: "de-CH", from: 2)
        #expect(start == 2)
        #expect(stream.language == "de-CH")
        let phrases = try await stream.finish()
        #expect(phrases.map(\.text) == ["hello there", "gut dann machen wir"])
        #expect(phrases[1].start == 2)
    }

    @Test func switchCannotReachBeforeTheCurrentLeg() async throws {
        let engine = ScriptedTranscriber(language: "en-US", script: [:])
        let stream = LanguageSwitchingStream(language: "en-US", makeTranscriber: engine.inLanguage) { _ in }
        for _ in 0..<4 { stream.append(second()) }
        #expect(stream.switchLanguage(to: "de-CH", from: 3) == 3)
        #expect(stream.switchLanguage(to: "en-US", from: 1) == 3)
    }
}
