@preconcurrency import AVFAudio
import Foundation

/// One meeting being recorded: a folder, two tracks (mic = "Me", system = everyone else),
/// and the metadata in `transcript.md`.
///
/// Keeping the tracks separate means we always know which words were yours. Diarization
/// only has to separate the remote speakers.
///
/// With a transcriber, each track is also transcribed live and `transcript.md` grows as the
/// meeting goes on. `finishLiveTranscription()` hands those phrases to the final pass.
@MainActor
public final class RecordingSession {
    public let folder: URL
    public let appID: String?
    public let appName: String?
    public let startedAt: Date
    /// Set when this recording carries on a meeting that had already been finished (see `init(resuming:)`).
    public let resumedAt: Date?
    /// Set while capture is paused: the meeting app left the mic, but the meeting may yet continue.
    public private(set) var pausedAt: Date?
    /// Non-fatal problems, e.g. system audio failed but the mic is recording.
    public private(set) var warnings: [String] = []

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber?
    private let speechDetector: SpeechDetectorFactory?
    private let live: LiveTranscript
    /// Seconds into the meeting where this recording's audio starts (0 unless resumed).
    private let offset: Double
    private var streams: [Track: LanguageSwitchingStream] = [:]
    private var monitors: [Track: MonitorBox] = [:]
    private var checking: Set<Track> = []
    /// Languages you turned down per track, so they aren't suggested again this meeting.
    private var declined: [Track: Set<String>] = [:]

    /// Languages that can be suggested (those the engine supports). Empty = no language checks.
    public var offeredLanguages: [Locale] = []
    /// Called when a track sounds like it's in another language. Answer with
    /// `switchLanguage(_:)` or `decline(_:)`.
    public var onLanguageSuggestion: ((LanguageSuggestion) -> Void)?

    /// `speechDetector`: if given, stretches without speech are recorded as silence (see `SpeechGate`).
    public init(store: MeetingStore, app: MeetingApp?, transcriber: Transcriber? = nil,
                speechDetector: SpeechDetectorFactory? = nil, now: Date = .now) throws {
        folder = try store.makeMeetingFolder(start: now, appName: app?.name)
        appID = app?.id
        appName = app?.name
        startedAt = now
        resumedAt = nil
        offset = 0
        self.transcriber = transcriber
        self.speechDetector = speechDetector
        live = LiveTranscript(
            url: folder.appendingPathComponent(MeetingFiles.transcript),
            metadata: MeetingMetadata(start: now, app: app?.name, status: .recording, language: transcriber?.language)
        )
    }

    public enum ResumeError: LocalizedError {
        case notFinished

        public var errorDescription: String? {
            switch self {
            case .notFinished: "Only a meeting that has been transcribed can be resumed."
            }
        }
    }

    /// Carries on a meeting that has already been finished and transcribed, in its folder. The new
    /// audio is a part of its own, starting `now` into the meeting (so transcript times keep
    /// counting from its start); the final pass adds it after the transcript so far (see
    /// `MeetingMetadata.resumed`). Audio kept from before moves to `audio-1/` (`audio-2/`...).
    /// `app`: the meeting app now on the mic, if any; the meeting keeps its own name.
    public init(resuming folder: URL, app: MeetingApp?, transcriber: Transcriber? = nil,
                speechDetector: SpeechDetectorFactory? = nil, now: Date = .now) throws {
        let md = folder.appendingPathComponent(MeetingFiles.transcript)
        guard var metadata = (try? String(contentsOf: md, encoding: .utf8)).flatMap(MeetingMetadata.init(parsing:)),
              metadata.status == .done
        else { throw ResumeError.notFinished }
        let earlier = (try? MeetingProcessor.document(in: folder).segments) ?? []

        let fm = FileManager.default
        let audio = folder.appendingPathComponent(MeetingFiles.audio)
        if fm.fileExists(atPath: audio.path) {
            var n = 1
            while fm.fileExists(atPath: folder.appendingPathComponent("\(MeetingFiles.audio)-\(n)").path) { n += 1 }
            try fm.moveItem(at: audio, to: folder.appendingPathComponent("\(MeetingFiles.audio)-\(n)"))
        }

        self.folder = folder
        appID = app?.id
        appName = metadata.app
        startedAt = metadata.start
        resumedAt = now
        offset = max(0, now.timeIntervalSince(metadata.start))
        self.transcriber = transcriber
        self.speechDetector = speechDetector
        metadata.status = .recording
        metadata.end = nil
        metadata.error = nil
        metadata.resumed = now
        if metadata.language == nil { metadata.language = transcriber?.language }
        live = LiveTranscript(url: md, metadata: metadata, earlier: earlier, offset: offset)
    }

    /// You're muted: the mic track records silence until unmuted, so it stays aligned with the other.
    public var micMuted: Bool {
        get { mic.muted }
        set { mic.muted = newValue }
    }

    public var transcriptURL: URL { folder.appendingPathComponent(MeetingFiles.transcript) }
    public var audioFolder: URL { folder.appendingPathComponent(MeetingFiles.audio, isDirectory: true) }

    public func start() throws {
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        live.update { _ in }

        // Both tracks are written against this clock, so their timelines line up.
        let clockStart = mach_absolute_time()
        var failures = 0
        do {
            try mic.start(url: folder.appendingPathComponent(MeetingFiles.micAudio), clockStart: clockStart,
                          speechDetector: speechDetector, tee: tee(for: .mic))
        } catch {
            failures += 1
            warnings.append("Microphone not recording: \(error)")
        }
        do {
            try system.start(url: folder.appendingPathComponent(MeetingFiles.systemAudio), clockStart: clockStart,
                             speechDetector: speechDetector, tee: tee(for: .system))
        } catch {
            failures += 1
            warnings.append("System audio not recording: \(error)")
        }
        if failures == 2 {
            stop()
            throw RecordingError.nothingToRecord(warnings)
        }
    }

    /// Stops capturing but keeps the tracks open, so `resume()` can carry on with the same meeting.
    public func pause(now: Date = .now) {
        guard pausedAt == nil else { return }
        mic.pause()
        system.pause()
        pausedAt = now
        live.update { $0.end = now }
    }

    /// Carries on recording after `pause()`. The pause becomes silence in both tracks, so they stay
    /// aligned and transcript times keep counting from the start of the meeting. A track whose
    /// device changed sample rate continues in a second file (see `TrackSegments`). Throws if
    /// neither track could restart; the session is then still paused.
    public func resume() throws {
        guard pausedAt != nil else { return }
        var errors: [String] = []
        do { try mic.resume() } catch { errors.append("Microphone not recording: \(error)") }
        do { try system.resume() } catch { errors.append("System audio not recording: \(error)") }
        if errors.count == 2 {
            throw RecordingError.nothingToRecord(errors)
        }
        warnings += errors
        pausedAt = nil
        live.update { $0.end = nil }
    }

    public func stop(now: Date = .now) {
        let now = pausedAt ?? now
        mic.stop()
        system.stop()
        if system.secondsWritten == 0, !warnings.contains(where: { $0.hasPrefix("System audio not recording") }) {
            // The tap started but never delivered a buffer: usually permission, so say where to look.
            warnings.append("No system audio was captured, so other participants are missing. Check System Settings → Privacy & Security → Screen & System Audio Recording.")
        }
        live.update {
            $0.end = now
            $0.status = .recorded
        }
    }

    /// The language each track is being transcribed in now.
    public func language(of track: Track) -> String? {
        streams[track]?.language ?? transcriber?.language
    }

    /// Transcribes `suggestion.track` in the suggested language from where that language seemed
    /// to start (or from as far back as audio is kept).
    public func switchLanguage(_ suggestion: LanguageSuggestion) {
        switchLanguage(of: suggestion.track, to: suggestion.language, from: suggestion.from)
    }

    /// Transcribes both tracks in `language` from now on.
    public func switchLanguage(to language: String) {
        for track in streams.keys {
            switchLanguage(of: track, to: language, from: streams[track]!.duration)
        }
    }

    public func switchLanguage(of track: Track, to language: String, from time: Double) {
        guard let stream = streams[track], stream.language != language else { return }
        let start = stream.switchLanguage(to: language, from: time)
        live.cut(track, from: start)
        monitors[track]?.switched(to: language)
        // In meeting time, like the transcript: a resumed meeting's audio starts partway in.
        live.update { $0.languageSwitches.append(LanguageSwitch(track: track, time: start + offset, language: language)) }
    }

    public func decline(_ suggestion: LanguageSuggestion) {
        declined[suggestion.track, default: []].insert(suggestion.language)
    }

    /// The monitor thinks `track` may be in another language: compare languages on its recent audio.
    private func checkLanguage(of track: Track) {
        guard !checking.contains(track), let stream = streams[track], let monitor = monitors[track],
              let start = monitor.windowStart, let audio = stream.audio(from: start) else { return }
        let offered = offeredLanguages.filter { !(declined[track]?.contains($0.identifier(.bcp47)) ?? false) }
        guard !offered.isEmpty else { return }
        checking.insert(track)
        let (current, text) = (stream.language, monitor.text)
        Task {
            defer { checking.remove(track) }
            guard let suggestion = await LanguageDetector.check(
                track: track, audio: audio, current: current, text: text, offered: offered
            ) else { return }
            // Still recording in the language that was checked, and not turned down meanwhile.
            guard streams[track]?.language == current, !(declined[track]?.contains(suggestion.language) ?? false) else { return }
            onLanguageSuggestion?(suggestion)
        }
    }

    /// Waits for live transcription to catch up with the end of the recording. Tracks whose live
    /// transcription failed are left out, so the final pass transcribes them from the file.
    public func finishLiveTranscription() async -> [Track: [Phrase]] {
        var result: [Track: [Phrase]] = [:]
        for (track, stream) in streams {
            do {
                result[track] = try await stream.finish()
            } catch {
                warnings.append("Live transcription of \(track.rawValue) failed: \(error)")
            }
        }
        streams = [:]
        return result
    }

    private func tee(for track: Track) -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        guard let transcriber else { return nil }
        let live = live
        let monitor = MonitorBox(language: transcriber.language)
        let stream = LanguageSwitchingStream(language: transcriber.language, makeTranscriber: transcriber.inLanguage) { phrase in
            live.add(phrase, track: track)
            if monitor.add(phrase) {
                Task { @MainActor [weak self] in self?.checkLanguage(of: track) }
            }
        }
        streams[track] = stream
        monitors[track] = monitor
        return { stream.append($0) }
    }

    /// Seconds of audio captured per track (for diagnostics).
    public func capturedSeconds() -> (mic: Double, system: Double) {
        (mic.secondsWritten, system.secondsWritten)
    }

    /// Last write error per track, if any (for diagnostics).
    public func writeErrors() -> [String] {
        [("mic", mic.writeError), ("system", system.writeError)].compactMap { name, error in
            error.map { "\(name): \($0)" }
        }
    }
}

public enum RecordingError: Error, CustomStringConvertible {
    case nothingToRecord([String])

    public var description: String {
        switch self {
        case .nothingToRecord(let reasons): "Couldn't record anything. " + reasons.joined(separator: " ")
        }
    }
}

/// A `LanguageMonitor` that phrases can be added to from any thread.
private final class MonitorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: LanguageMonitor

    init(language: String) {
        monitor = LanguageMonitor(language: language)
    }

    /// True when it's time to check the language.
    func add(_ phrase: Phrase) -> Bool {
        lock.withLock { monitor.add(phrase) != nil }
    }

    func switched(to language: String) {
        lock.withLock { monitor.switched(to: language) }
    }

    var windowStart: Double? { lock.withLock { monitor.windowStart } }
    var text: String { lock.withLock { monitor.text } }
}
