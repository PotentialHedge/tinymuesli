import AVFAudio
import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import TinyMuesliCore

@Suite struct FrameRingTests {
    func fill(_ value: Float) -> (UnsafeMutablePointer<Float>, Int, Int) -> Void {
        { out, _, count in out.update(repeating: value, count: count) }
    }

    func contents(of ring: FrameRing) -> (samples: [Float], hostTimes: [UInt64?]) {
        var samples: [Float] = []
        var hostTimes: [UInt64?] = []
        ring.drain { samples += $0; hostTimes.append($1) }
        return (samples, hostTimes)
    }

    @Test func splitsLargeBuffersAndTimesOnlyTheFirstSlot() {
        let ring = FrameRing(slotFrames: 4, slotCount: 8)
        ring.write(frames: 10, hostTime: 7) { out, offset, count in
            for i in 0..<count { out[i] = Float(offset + i) }
        }
        let result = contents(of: ring)
        #expect(result.samples == (0..<10).map(Float.init))
        #expect(result.hostTimes == [7, nil, nil])
    }

    @Test func dropsAndCountsWhatDoesNotFit() {
        let ring = FrameRing(slotFrames: 4, slotCount: 2)
        ring.write(frames: 4, hostTime: nil, fill: fill(1))
        ring.write(frames: 8, hostTime: nil, fill: fill(2))
        #expect(ring.droppedFrames == 4)
        #expect(contents(of: ring).samples == [1, 1, 1, 1, 2, 2, 2, 2])
    }

    @Test func reusesSlotsOnceDrained() {
        let ring = FrameRing(slotFrames: 4, slotCount: 2)
        for value in 1...5 {
            ring.write(frames: 4, hostTime: nil, fill: fill(Float(value)))
            #expect(contents(of: ring).samples == [Float](repeating: Float(value), count: 4))
        }
        #expect(ring.droppedFrames == 0)
    }
}

@Suite struct TrackWriterTests {
    func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tinymuesli-writer-\(UUID().uuidString).caf")
    }

    func stereo(frames: Int, left: Float, right: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            samples[frame * 2] = left
            samples[frame * 2 + 1] = right
        }
        return buffer
    }

    @Test func closingWritesEverythingToAReadableFile() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = stereo(frames: 512, left: 0.1, right: 0.3)
        let writer = try TrackWriter(url: url, inputFormat: source.format)
        for _ in 0..<94 { writer.write(source) }  // about a second
        writer.close()

        #expect(writer.framesWritten == 94 * 512)
        #expect(writer.lastError == nil)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - writer.secondsWritten) < 0.1)
    }

    /// 32 kbps where the encoder takes it; at 8 kHz it doesn't, and the file must still work.
    @Test(arguments: [8_000.0, 16_000, 24_000, 44_100, 48_000])
    func encodesSpeechAt32kbps(sampleRate: Double) throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try TrackWriter.makeFile(url: url, sampleRate: sampleRate)
        let seconds = 30  // long enough that the container's fixed overhead doesn't count
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sampleRate))!
        buffer.frameLength = buffer.frameCapacity
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<seconds {
            // Noise: the worst case for the encoder (~72 kbps at the default bitrate).
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float.random(in: -0.3...0.3, using: &rng) }
            try file.write(from: buffer)
        }
        file.close()

        let read = try AVAudioFile(forReading: url)
        #expect(abs(Double(read.length) / sampleRate - Double(seconds)) < 0.1)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        let kbps = Double(size * 8) / Double(seconds) / 1000
        if sampleRate >= 16_000 { #expect(kbps < 45, "\(kbps) kbps") }
    }

    @Test func teeGetsMonoAudioInOrderAndInBatches() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let received = Mutex<[[Float]]>([])
        let source = stereo(frames: 128, left: 0, right: 0)
        let writer = try TrackWriter(url: url, inputFormat: source.format) { buffer in
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            received.withLock { $0.append(samples) }
        }
        for value in 0..<100 {
            writer.write(stereo(frames: 128, left: Float(value), right: Float(value)))
        }
        writer.close()

        let batches = received.withLock { $0 }
        let expected = (0..<100).flatMap { [Float](repeating: Float($0), count: 128) }
        #expect(batches.flatMap { $0 } == expected)
        #expect(batches.count < 100)
    }

    @Test func writesSilenceWhileMutedButKeepsTheLength() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let received = Mutex<[Float]>([])
        let source = stereo(frames: 4096, left: 0.5, right: 0.5)
        let writer = try TrackWriter(url: url, inputFormat: source.format) { buffer in
            received.withLock { $0 += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)) }
        }
        writer.muted = true
        writer.write(source)
        writer.close()

        #expect(writer.framesWritten == 4096)
        #expect(received.withLock { $0 }.allSatisfy { $0 == 0 })
    }

    @Test func fillsGapsWithSilenceSoTracksStayAligned() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let start: UInt64 = 1_000
        let source = stereo(frames: 480, left: 1, right: 1)
        let writer = try TrackWriter(url: url, inputFormat: source.format, clockStart: start)
        writer.write(source, hostTime: start)
        writer.write(source, hostTime: start + AudioConvertNanosToHostTime(2_000_000_000))
        writer.close()

        #expect(abs(writer.secondsWritten - 2.01) < 0.001)
    }

    @Test func resumesFromAnInputWithAnotherLayout() throws {
        // A paused track picking up again on a different mic: deinterleaved 3-channel, same rate.
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let received = Mutex<[Float]>([])
        let first = stereo(frames: 4, left: 0.2, right: 0.4)
        let writer = try TrackWriter(url: url, inputFormat: first.format) { buffer in
            received.withLock { $0 += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)) }
        }
        writer.write(first)

        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let second = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout),
                                      frameCapacity: 2)!
        second.frameLength = 2
        for ch in 0..<3 { second.floatChannelData![ch][0] = 0.6; second.floatChannelData![ch][1] = 0.6 }
        try writer.setInput(second.format)
        writer.write(second)
        writer.close()

        let expected: [Float] = [0.3, 0.3, 0.3, 0.3, 0.6, 0.6]
        let samples = received.withLock { $0 }
        #expect(samples.count == expected.count)
        #expect(zip(samples, expected).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func refusesAnInputAtAnotherSampleRate() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TrackWriter(url: url, inputFormat: stereo(frames: 1, left: 0, right: 0).format)
        defer { writer.close() }
        let slower = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        #expect(throws: (any Error).self) { try writer.setInput(slower) }
    }

    @Test func ignoresWritesAfterClose() throws {
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = stereo(frames: 480, left: 1, right: 1)
        let writer = try TrackWriter(url: url, inputFormat: source.format)
        writer.write(source)
        writer.close()
        writer.write(source)
        writer.close()
        #expect(writer.framesWritten == 480)
    }

    @Test func readsRawBufferListsFromALaterBuffer() throws {
        // Two leading device buffers, then a stereo tap that's interleaved in one buffer.
        let url = url()
        defer { try? FileManager.default.removeItem(at: url) }
        let received = Mutex<[Float]>([])
        let tap = stereo(frames: 4, left: 0.5, right: 0.5)
        let writer = try TrackWriter(url: url, inputFormat: tap.format) { buffer in
            received.withLock { $0 += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)) }
        }
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { list.unsafeMutablePointer.deallocate() }
        var device = [Float](repeating: -9, count: 8)
        device.withUnsafeMutableBytes { bytes in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            list[1] = tap.audioBufferList.pointee.mBuffers
            writer.write(bufferList: list.unsafePointer, firstBuffer: 1)
            writer.close()
        }
        #expect(received.withLock { $0 } == [0.5, 0.5, 0.5, 0.5])
    }
}

@Suite struct TrackSegmentsTests {
    func mono(rate: Double, seconds: Double, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: value, count: Int(frames))
        return buffer
    }

    @Test func resumingAtAnotherRateContinuesInANewFileThatJoinsUp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("mic.caf")
        let start: UInt64 = 1_000
        let at = { (seconds: Double) in start + AudioConvertNanosToHostTime(UInt64(seconds * 1e9)) }

        let fast = mono(rate: 48_000, seconds: 1, value: 0.5)
        let track = try SegmentedTrack(url: first, inputFormat: fast.format, clockStart: start, tee: nil)
        track.writer.write(fast, hostTime: start)
        #expect(try track.writer(resumingWith: fast.format) === track.writer)  // same rate: same file

        // Paused at 1 s, resumed at 3 s on a 24 kHz device.
        let slow = mono(rate: 24_000, seconds: 1, value: 0.5)
        let second = try track.writer(resumingWith: slow.format)
        second.write(slow, hostTime: at(3))
        track.close()

        let urls = TrackSegments.urls(first: first)
        #expect(urls.map(\.lastPathComponent) == ["mic.caf", "mic-2.caf"])
        #expect(abs(track.seconds - 4) < 0.01)
        #expect(try AVAudioFile(forReading: urls[1]).length == 3 * 24_000)  // 2 s of pause + 1 s

        let joined = try TrackSegments.single(first: first)
        defer { try? FileManager.default.removeItem(at: joined.url) }
        #expect(joined.isTemporary)
        let file = try AVAudioFile(forReading: joined.url)
        #expect(file.processingFormat.sampleRate == 48_000)
        #expect(abs(Double(file.length) / 48_000 - 4) < 0.1)

        // The pause is silence, and the second recording lands at 3 s.
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        #expect(abs(samples[48_000 * 2]) < 0.05)
        #expect(abs(samples[Int(48_000 * 3.5)] - 0.5) < 0.1)
    }

    @Test func aSingleFileIsUsedAsIs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinymuesli-\(UUID().uuidString).caf")
        let writer = try TrackWriter(url: url, inputFormat: mono(rate: 48_000, seconds: 0, value: 0).format)
        writer.close()
        defer { try? FileManager.default.removeItem(at: url) }
        let single = try TrackSegments.single(first: url)
        #expect(single.url == url && !single.isTemporary)
        #expect(TrackSegments.urls(first: url.deletingLastPathComponent().appendingPathComponent("missing.caf")).isEmpty)
    }
}
