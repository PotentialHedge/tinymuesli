@preconcurrency import AVFAudio
import CoreAudio
import Foundation

/// Records everything the Mac plays (the other meeting participants) using a Core Audio
/// process tap. This needs only the "System Audio Recording" permission, not Screen Recording.
///
/// Setup: a global tap → a private aggregate device that contains the tap → an IOProc that
/// receives the tapped audio.
public final class SystemAudioRecorder {
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var track: SegmentedTrack?
    private let queue = DispatchQueue(label: "tinymuesli.system-audio", qos: .userInitiated)

    public init() {}

    public var secondsWritten: Double { track?.seconds ?? 0 }
    public var writeError: Error? { track?.writer.lastError }

    public func start(url: URL, clockStart: UInt64? = nil, speechDetector: SpeechDetectorFactory? = nil,
                      tee: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) throws {
        do {
            let format = try makeTap()
            let track = try SegmentedTrack(url: url, inputFormat: format, clockStart: clockStart,
                                       speechDetector: speechDetector, tee: tee)
            self.track = track
            try capture(format: format, into: track.writer)
        } catch {
            stop()
            throw error
        }
    }

    /// Removes the tap but keeps the track open, so `resume()` carries on in the same file.
    public func pause() {
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        queue.sync {}  // drain any in-flight callback

        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    /// The time paused becomes silence in the track. If the output now runs at another sample rate,
    /// the track continues in a new file. Does nothing if the track never started.
    public func resume() throws {
        guard let track else { return }
        do {
            let format = try makeTap()
            try capture(format: format, into: track.writer(resumingWith: format))
        } catch {
            pause()
            throw error
        }
    }

    /// Creates the tap and the aggregate device that delivers it; returns the tap's format.
    private func makeTap() throws -> AVAudioFormat {
        // Leave our own process out of the tap (it might play sounds later).
        let ownProcess = try? AudioObjectID.process(for: getpid())
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        tap.uuid = UUID()
        tap.name = "tinyMuesli"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create system audio tap")

        var streamDescription = try tapID.read(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError(status: -1, operation: "read tap format")
        }

        // Tap only, no hardware sub-devices. Adding the output device as a sub-device would also
        // open its input stream if it has one (AirPods, headsets), which can drop Bluetooth
        // headphones into low-quality call mode and puts extra buffers in front of the tap's.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "tinyMuesli System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")
        return format
    }

    private func capture(format: AVAudioFormat, into writer: TrackWriter) throws {
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue, Self.ioBlock(writing: writer, format: format)),
            "create IOProc"
        )
        try check(AudioDeviceStart(aggregateID, ioProcID), "start system audio capture")
    }

    /// Built in a nonisolated static context so the block never inherits an actor.
    ///
    /// The tap's buffers are the last ones in the aggregate's input buffer list. Normally they're
    /// the only ones, but taking them from the end keeps this correct if a device ever adds its own.
    private static func ioBlock(writing writer: TrackWriter, format: AVAudioFormat) -> AudioDeviceIOBlock {
        let tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        return { @Sendable _, inputData, inputTime, _, _ in
            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard buffers.count >= tapBufferCount else { return }
            writer.write(bufferList: inputData, firstBuffer: buffers.count - tapBufferCount, hostTime: hostTime)
        }
    }

    /// `endingAt`: when the recording ended (host time); if nothing was playing at the end (the tap
    /// delivers nothing then), the track is padded with silence up to it.
    public func stop(endingAt end: UInt64? = nil) {
        pause()
        track?.close(endingAt: end)
    }
}
