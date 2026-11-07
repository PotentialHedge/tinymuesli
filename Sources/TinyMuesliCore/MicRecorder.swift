@preconcurrency import AVFAudio
import AVFoundation
import Foundation

/// Records the local microphone ("Me") with Apple's voice processing turned on.
///
/// Voice processing does echo cancellation: without it, if you're not wearing headphones,
/// the mic also picks up the other participants from your speakers, and they'd get
/// transcribed twice, once as "Me".
public final class MicRecorder {
    private let engine = AVAudioEngine()
    private var track: SegmentedTrack?

    public init() {}

    public var secondsWritten: Double { track?.seconds ?? 0 }
    public var writeError: Error? { track?.writer.lastError }

    /// While muted the mic stays open but the track records silence, so nothing said is kept or
    /// transcribed. Kept open rather than released so unmuting is instant and the call app's audio
    /// processing isn't disturbed.
    public var muted = false {
        didSet { track?.muted = muted }
    }

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start(url: URL, clockStart: UInt64? = nil, speechDetector: SpeechDetectorFactory? = nil,
                      tee: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) throws {
        let format = try prepareInput()
        let track = try SegmentedTrack(url: url, inputFormat: format, clockStart: clockStart,
                                       speechDetector: speechDetector, tee: tee)
        track.muted = muted
        self.track = track
        try capture(format: format, into: track.writer)
    }

    /// Releases the mic but keeps the track open, so `resume()` carries on in the same file.
    public func pause() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The time paused becomes silence in the track. If the mic now has another sample rate (a
    /// different device), the track continues in a new file. Does nothing if the track never started.
    public func resume() throws {
        guard let track else { return }
        let format = try prepareInput()
        try capture(format: format, into: track.writer(resumingWith: format))
    }

    private func prepareInput() throws -> AVAudioFormat {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // By default voice processing ducks all other audio, which would turn the meeting down.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        return input.outputFormat(forBus: 0)
    }

    private func capture(format: AVAudioFormat, into writer: TrackWriter) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(writing: writer))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    /// Built in a nonisolated static context so the block never inherits an actor.
    private static func tapBlock(writing writer: TrackWriter) -> AVAudioNodeTapBlock {
        { @Sendable buffer, when in writer.write(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil) }
    }

    public func stop() {
        pause()
        track?.close()
    }
}
