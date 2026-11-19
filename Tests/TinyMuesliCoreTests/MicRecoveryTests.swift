import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import TinyMuesliCore

/// The mic stopping mid-meeting (e.g. AirPods connecting) and capture being rebuilt: the mic track
/// must still line up with, and be as long as, the system track.
@Suite struct MicRecoveryTests {
    let start: UInt64 = 1_000
    func at(_ seconds: Double) -> UInt64 { start + AudioConvertNanosToHostTime(UInt64(seconds * 1e9)) }

    func mono(rate: Double = 48_000, seconds: Double, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: value, count: Int(frames))
        return buffer
    }

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func samples(of url: URL) throws -> (rate: Double, values: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (file.processingFormat.sampleRate, Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
    }

    /// Mic records 0–1 s, stops, is restarted at 3 s on the same rate and records to 4 s; the meeting
    /// ends at 6 s. System audio plays the whole time.
    @Test func restartedMicStaysAlignedAndAsLongAsSystemAudio() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let micURL = folder.appendingPathComponent("mic.caf")
        let systemURL = folder.appendingPathComponent("system.caf")
        let chunk = mono(seconds: 1, value: 0.5)

        let mic = try SegmentedTrack(url: micURL, inputFormat: chunk.format, clockStart: start, tee: nil)
        let system = try SegmentedTrack(url: systemURL, inputFormat: chunk.format, clockStart: start, tee: nil)
        for second in 0..<6 { system.writer.write(chunk, hostTime: at(Double(second))) }
        mic.writer.write(chunk, hostTime: at(0))
        // Capture rebuilt on a new engine: same track, same file.
        let restarted = try mic.writer(resumingWith: chunk.format)
        #expect(restarted === mic.writer)
        restarted.write(chunk, hostTime: at(3))
        mic.close(endingAt: at(6))
        system.close(endingAt: at(6))

        #expect(abs(mic.seconds - 6) < 0.01)
        #expect(abs(mic.seconds - system.seconds) < 0.01)
        #expect(TrackSegments.urls(first: micURL).count == 1)
        let (rate, values) = try samples(of: micURL)
        #expect(abs(Double(values.count) / rate - 6) < 0.1)
        #expect(abs(values[Int(rate * 0.5)] - 0.5) < 0.1)  // before it stopped
        #expect(abs(values[Int(rate * 2)]) < 0.05)         // the gap is silence
        #expect(abs(values[Int(rate * 3.5)] - 0.5) < 0.1)  // after the restart, at its true time
        #expect(abs(values[Int(rate * 5)]) < 0.05)         // padded to the end
    }

    /// The new input runs at another rate (e.g. AirPods in call mode): a second file, same timeline.
    @Test func restartAtAnotherRateKeepsTheTimeline() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let micURL = folder.appendingPathComponent("mic.caf")
        let mic = try SegmentedTrack(url: micURL, inputFormat: mono(seconds: 0, value: 0).format, clockStart: start, tee: nil)
        mic.writer.write(mono(seconds: 1, value: 0.5), hostTime: at(0))
        let slow = mono(rate: 24_000, seconds: 1, value: 0.5)
        try mic.writer(resumingWith: slow.format).write(slow, hostTime: at(2))
        mic.close(endingAt: at(5))

        #expect(TrackSegments.urls(first: micURL).map(\.lastPathComponent) == ["mic.caf", "mic-2.caf"])
        #expect(abs(mic.seconds - 5) < 0.01)
        let joined = try TrackSegments.single(first: micURL)
        defer { try? FileManager.default.removeItem(at: joined.url) }
        let (rate, values) = try samples(of: joined.url)
        #expect(abs(Double(values.count) / rate - 5) < 0.1)
        #expect(abs(values[Int(rate * 2.5)] - 0.5) < 0.1)
    }

    /// The input changed while the mic was still starting: the first file is empty, the second
    /// carries the whole timeline, and the two still join up.
    @Test func restartBeforeAnyAudioStillJoinsUp() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let micURL = folder.appendingPathComponent("mic.caf")
        let slow = mono(rate: 24_000, seconds: 0, value: 0)
        let mic = try SegmentedTrack(url: micURL, inputFormat: slow.format, clockStart: start, tee: nil)
        let fast = mono(seconds: 1, value: 0.5)
        try mic.writer(resumingWith: fast.format).write(fast, hostTime: at(3))
        mic.close(endingAt: at(5))

        #expect(abs(mic.seconds - 5) < 0.01)
        let joined = try TrackSegments.single(first: micURL)
        defer { try? FileManager.default.removeItem(at: joined.url) }
        let (rate, values) = try samples(of: joined.url)
        #expect(abs(Double(values.count) / rate - 5) < 0.1)
        #expect(abs(values[Int(rate * 3.5)] - 0.5) < 0.1)
    }

    @Test func aTrackThatNeverGotAudioIsNotPadded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinymuesli-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TrackWriter(url: url, inputFormat: mono(seconds: 0, value: 0).format, clockStart: start)
        writer.close(endingAt: at(10))
        #expect(writer.framesWritten == 0)  // so "no system audio was captured" is still noticed
    }

    @Test func watchdogWaitsForAStallThenBacksOff() {
        var watchdog = MicWatchdog()
        #expect(!watchdog.shouldRestart(silentFor: 1, now: 100))
        #expect(watchdog.shouldRestart(silentFor: MicWatchdog.stallSeconds, now: 100))

        watchdog.attempted(at: 100)
        #expect(!watchdog.shouldRestart(silentFor: 5, now: 101))
        #expect(watchdog.shouldRestart(silentFor: 6, now: 103))  // 3 s after the first try
        watchdog.attempted(at: 103)
        #expect(!watchdog.shouldRestart(silentFor: 8, now: 108))
        #expect(watchdog.shouldRestart(silentFor: 9, now: 109))  // then 6 s
        for _ in 0..<10 { watchdog.attempted(at: 109) }
        #expect(watchdog.backoff == MicWatchdog.maxBackoffSeconds)

        watchdog.recovered()
        #expect(watchdog.shouldRestart(silentFor: MicWatchdog.stallSeconds, now: 110))
    }
}
