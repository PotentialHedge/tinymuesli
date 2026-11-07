@preconcurrency import AVFAudio
import CoreAudio
import Foundation
import Synchronization

/// Writes one mono audio track to disk as AAC in a CAF container.
///
/// CAF instead of M4A because an M4A is unreadable until it's finalised; if tinyMuesli crashes
/// mid-meeting, the audio in a CAF can still be recovered. Mono, because transcription and
/// diarization don't need stereo.
///
/// Tracks share the session's host clock: when buffers arrive later than the samples written
/// so far account for (the system tap delivers nothing while the output device is idle), the gap
/// is filled with silence. So t seconds into mic.caf and system.caf are the same moment.
///
/// `write` is called from one audio thread and must not block it, so it only mixes down into a
/// lock-free ring. A queue drains the ring every 50 ms to encode, write to disk and feed the tee.
/// If that falls so far behind that the ring fills, the lost audio becomes silence (by the rule
/// above) and `lastError` reports it.
///
/// With a speech detector, stretches without speech are written as zeros (see `SpeechGate`).
/// So is everything written while `muted`.
public final class TrackWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let tee: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Host time (mach ticks) of the track's start. nil: no alignment, just append.
    private let clockStart: UInt64?
    /// Where in the track this file's sample 0 is, for a file that continues an earlier one.
    private let startFrame: AVAudioFramePosition
    /// The input's layout. Only changed by `setInput`, while nothing is capturing.
    private var channels: Int
    private var isInterleaved: Bool
    private let sampleRate: Double
    private let ring = FrameRing()
    private let queue = DispatchQueue(label: "tinymuesli.track-writer", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let isClosed = Atomic<Bool>(false)
    private let isMuted = Atomic<Bool>(false)
    /// Written to the file in batches, so the tee gets sensible buffers rather than one per slot.
    private var pending: AVAudioPCMBuffer?
    private let gate: SpeechGate?
    private static let batchFrames: AVAudioFrameCount = 4096

    /// Guards the two values below, which the queue updates and anyone may read. Never taken by `write`.
    private let lock = NSLock()
    private var _framesWritten: AVAudioFramePosition = 0
    private var _lastError: Error?

    public var framesWritten: AVAudioFramePosition { lock.withLock { _framesWritten } }
    public var lastError: Error? { lock.withLock { _lastError } }
    public var secondsWritten: Double { Double(framesWritten) / sampleRate }
    /// Where this file ends in the track: where a file continuing it starts.
    public var endSeconds: Double { Double(startFrame + framesWritten) / sampleRate }

    public enum WriteError: Error, CustomStringConvertible {
        case droppedFrames(Int)
        /// From `setInput`: the file keeps its first input's rate, so continue in a new file.
        case sampleRateChanged(from: Double, to: Double)

        public var description: String {
            switch self {
            case .droppedFrames(let frames): "\(frames) audio frames were dropped because writing fell behind"
            case .sampleRateChanged(let from, let to): "The input changed from \(Int(from)) Hz to \(Int(to)) Hz"
            }
        }
    }

    /// `inputFormat` must be Float32 (what both Core Audio taps and AVAudioEngine deliver);
    /// any channel count, interleaved or not. Channels are averaged down to mono.
    /// `tee` receives each mono buffer as it's written (for live transcription); it owns the buffer.
    /// `startSeconds`: where in the track this file starts, if it continues an earlier file
    /// (`endSeconds` of that one). The gap from there to the first buffer becomes silence.
    /// `speechDetector`: if given, stretches without speech are written as zeros.
    public init(url: URL, inputFormat: AVAudioFormat, clockStart: UInt64? = nil, startSeconds: Double = 0,
                speechDetector: SpeechDetector? = nil, tee: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) throws {
        guard inputFormat.commonFormat == .pcmFormatFloat32 else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported input format \(inputFormat)",
            ])
        }
        file = try Self.makeFile(url: url, sampleRate: inputFormat.sampleRate)
        channels = Int(inputFormat.channelCount)
        isInterleaved = inputFormat.isInterleaved
        sampleRate = file.processingFormat.sampleRate
        let format = file.processingFormat
        gate = speechDetector.map { SpeechGate(detector: $0, format: format) }
        startFrame = AVAudioFramePosition((startSeconds * sampleRate).rounded())
        self.tee = tee
        self.clockStart = clockStart
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.activate()
    }

    deinit {
        timer.cancel()
    }

    /// A mono AAC file at 32 kbps: plenty for speech, which transcription and diarization see at
    /// 16 kHz. The encoder's default (~64 kbps) doubles the size for nothing. 32 kbps is the lowest
    /// it accepts for mono at 48 kHz, but too much at 8 kHz (narrowband Bluetooth headsets), so
    /// the encoder picks the bitrate if it refuses ours.
    static func makeFile(url: URL, sampleRate: Double) throws -> AVAudioFile {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            settings[AVEncoderBitRateKey] = nil
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    /// For resuming a paused track from a newly started capture, whose device may have a different
    /// channel layout. Call only while nothing is writing. The sample rate can't change (it throws
    /// `WriteError.sampleRateChanged`): continue in a new file instead (see `SegmentedTrack`).
    public func setInput(_ format: AVAudioFormat) throws {
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Unsupported input format \(format)"])
        }
        guard format.sampleRate == sampleRate else {
            throw WriteError.sampleRateChanged(from: sampleRate, to: format.sampleRate)
        }
        queue.sync {
            channels = Int(format.channelCount)
            isInterleaved = format.isInterleaved
        }
    }

    /// While muted, audio is written as silence: the track keeps its length (so it stays aligned
    /// with the others) but holds nothing. Takes effect within one drain (~50 ms).
    public var muted: Bool {
        get { isMuted.load(ordering: .relaxed) }
        set { isMuted.store(newValue, ordering: .relaxed) }
    }

    /// Gaps shorter than this are jitter, not missing audio.
    static let gapTolerance = 0.1

    /// `hostTime`: when the buffer's first sample was captured (mach ticks), if known.
    /// The buffer must be in the writer's `inputFormat`.
    public func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        enqueue(buffer.audioBufferList, firstBuffer: 0, frames: Int(buffer.frameLength), hostTime: hostTime)
    }

    /// For Core Audio IOProcs, which hand us a raw buffer list in `inputFormat`. The track starts at
    /// `firstBuffer`, for when a device has put buffers of its own in front of it.
    public func write(bufferList: UnsafePointer<AudioBufferList>, firstBuffer: Int = 0, hostTime: UInt64? = nil) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard firstBuffer < list.count else { return }
        let bytesPerFrame = MemoryLayout<Float>.size * (isInterleaved ? channels : 1)
        enqueue(bufferList, firstBuffer: firstBuffer, frames: Int(list[firstBuffer].mDataByteSize) / bytesPerFrame, hostTime: hostTime)
    }

    /// Runs on the audio thread: no locks, no allocation.
    private func enqueue(_ list: UnsafePointer<AudioBufferList>, firstBuffer: Int, frames: Int, hostTime: UInt64?) {
        guard frames > 0, !isClosed.load(ordering: .relaxed) else { return }
        ring.write(frames: frames, hostTime: hostTime) { out, offset, count in
            Self.mix(list, firstBuffer: firstBuffer, channels: channels, interleaved: isInterleaved,
                     offset: offset, frames: count, into: out)
        }
    }

    /// Runs on `queue`.
    private func drain() {
        do {
            var failure: Error?
            ring.drain { samples, hostTime in
                guard failure == nil else { return }
                do { try self.add(samples, hostTime: hostTime) } catch { failure = error }
            }
            if let failure { throw failure }
            try flush()
        } catch {
            pending = nil
            lock.withLock { _lastError = error }
        }
    }

    private func add(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64?) throws {
        let queued = AVAudioFramePosition(pending?.frameLength ?? 0) + (gate?.heldFrames ?? 0)
        if let missing = Self.missingFrames(at: hostTime, clockStart: clockStart, written: startFrame + framesWritten + queued,
                                            sampleRate: sampleRate) {
            try flush()
            try writeSilence(frames: missing)
        }
        if let current = pending, current.frameLength + AVAudioFrameCount(samples.count) > current.frameCapacity {
            try flush()
        }
        guard let batch = pending ?? AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.batchFrames),
              let out = batch.floatChannelData?[0], let source = samples.baseAddress
        else { throw CocoaError(.featureUnsupported) }
        if muted {
            (out + Int(batch.frameLength)).update(repeating: 0, count: samples.count)
        } else {
            (out + Int(batch.frameLength)).update(from: source, count: samples.count)
        }
        batch.frameLength += AVAudioFrameCount(samples.count)
        pending = batch
    }

    private func flush() throws {
        guard let batch = pending else { return }
        pending = nil
        try append(batch)
    }

    private func append(_ mono: AVAudioPCMBuffer) throws {
        guard let gate else { return try write(mono) }
        for decided in gate.process(mono) { try write(decided) }
    }

    private func write(_ mono: AVAudioPCMBuffer) throws {
        try file.write(from: mono)
        lock.withLock { _framesWritten += AVAudioFramePosition(mono.frameLength) }
        tee?(mono)
    }

    private func writeSilence(frames: AVAudioFramePosition) throws {
        var remaining = frames
        let chunk = AVAudioFramePosition(sampleRate)
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, chunk))
            guard let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { return }
            silence.frameLength = n  // freshly allocated buffers are zeroed
            try append(silence)
            remaining -= AVAudioFramePosition(n)
        }
    }

    /// Frames of silence needed so a buffer captured at `hostTime` lands at its true position.
    static func missingFrames(at hostTime: UInt64?, clockStart: UInt64?, written: AVAudioFramePosition,
                              sampleRate: Double) -> AVAudioFramePosition? {
        guard let hostTime, let clockStart, hostTime > clockStart else { return nil }
        let seconds = Double(AudioConvertHostTimeToNanos(hostTime - clockStart)) / 1e9
        let expected = AVAudioFramePosition(seconds * sampleRate)
        let missing = expected - written
        return Double(missing) > gapTolerance * sampleRate ? missing : nil
    }

    /// Writes out everything queued, so call it after the audio stops. Later writes are ignored.
    public func close() {
        guard !isClosed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        timer.cancel()
        queue.sync {
            drain()
            do {
                for decided in gate?.flush() ?? [] { try write(decided) }
            } catch {
                lock.withLock { _lastError = _lastError ?? error }
            }
            if ring.droppedFrames > 0 {
                lock.withLock { _lastError = _lastError ?? WriteError.droppedFrames(ring.droppedFrames) }
            }
            file.close()
        }
    }

    /// Averages all channels into `out`. Done by hand because AVAudioConverter silently outputs
    /// zeros for channel layouts it doesn't know, like the 3-channel voice-processing input.
    /// `offset` and `frames` count from the start of the list's buffers. Safe on the audio thread.
    static func mix(_ list: UnsafePointer<AudioBufferList>, firstBuffer: Int = 0, channels: Int, interleaved: Bool,
                    offset: Int, frames: Int, into out: UnsafeMutablePointer<Float>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let scale = 1 / Float(channels)
        if interleaved {
            // One raw buffer: L R L R ...
            guard let raw = buffers[firstBuffer].mData else { return }
            let samples = raw.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += samples[(offset + frame) * channels + ch] }
                out[frame] = sum * scale
            }
        } else {
            guard firstBuffer + channels <= buffers.count else { return }
            for frame in 0..<frames { out[frame] = 0 }
            for ch in 0..<channels {
                guard let raw = buffers[firstBuffer + ch].mData else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { out[frame] += samples[offset + frame] * scale }
            }
        }
    }
}
