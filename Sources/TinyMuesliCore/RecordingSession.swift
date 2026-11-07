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
    /// Set while capture is paused: the meeting app left the mic, but the meeting may yet continue.
    public private(set) var pausedAt: Date?
    /// Non-fatal problems, e.g. system audio failed but the mic is recording.
    public private(set) var warnings: [String] = []

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private let transcriber: Transcriber?
    private let speechDetector: SpeechDetectorFactory?
    private let live: LiveTranscript
    private var streams: [Track: TranscriptionStream] = [:]

    /// `speechDetector`: if given, stretches without speech are recorded as silence (see `SpeechGate`).
    public init(store: MeetingStore, app: MeetingApp?, transcriber: Transcriber? = nil,
                speechDetector: SpeechDetectorFactory? = nil, now: Date = .now) throws {
        folder = try store.makeMeetingFolder(start: now, appName: app?.name)
        appID = app?.id
        appName = app?.name
        startedAt = now
        self.transcriber = transcriber
        self.speechDetector = speechDetector
        live = LiveTranscript(
            url: folder.appendingPathComponent(MeetingFiles.transcript),
            metadata: MeetingMetadata(start: now, app: app?.name, status: .recording, language: transcriber?.language)
        )
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
        let stream = transcriber.makeStream { phrase in live.add(phrase, track: track) }
        streams[track] = stream
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
