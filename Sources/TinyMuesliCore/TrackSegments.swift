@preconcurrency import AVFAudio
import Foundation

/// A track is one file, or several when a paused meeting was continued on an input with a different
/// sample rate (e.g. switching from the built-in mic to AirPods): `mic.caf`, `mic-2.caf`, ...
///
/// Each file starts where the previous one ended (the pause is silence at the start of the next),
/// so the track is simply its files played one after another; no other bookkeeping is needed.
public enum TrackSegments {
    /// The track's files in order, starting with `first` (e.g. `audio/mic.caf`). Empty if there are none.
    public static func urls(first: URL) -> [URL] {
        var urls: [URL] = []
        var url = first
        while FileManager.default.fileExists(atPath: url.path) {
            urls.append(url)
            url = segmentURL(first: first, number: urls.count + 1)
        }
        return urls
    }

    /// `mic.caf` → `mic-2.caf`, `mic-3.caf`, ...
    static func segmentURL(first: URL, number: Int) -> URL {
        guard number > 1 else { return first }
        let name = first.deletingPathExtension().lastPathComponent
        return first.deletingLastPathComponent().appendingPathComponent("\(name)-\(number).\(first.pathExtension)")
    }

    /// The track as one file, for the final pass: `first` itself unless there are several, which are
    /// then joined into a temporary file (at the first file's sample rate) that the caller deletes.
    public static func single(first: URL) throws -> (url: URL, isTemporary: Bool) {
        let urls = urls(first: first)
        guard urls.count > 1 else { return (first, false) }
        let joined = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinymuesli-\(UUID().uuidString)-\(first.lastPathComponent)")
        do {
            try join(urls, to: joined)
        } catch {
            try? FileManager.default.removeItem(at: joined)
            throw error
        }
        return (joined, true)
    }

    static func join(_ urls: [URL], to output: URL) throws {
        let firstFile = try AVAudioFile(forReading: urls[0])
        let format = firstFile.processingFormat
        let out = try TrackWriter.makeFile(url: output, sampleRate: format.sampleRate)
        for url in urls {
            let file = url == urls[0] ? firstFile : try AVAudioFile(forReading: url)
            let converter = Converter(to: format)  // mono → mono; passes matching formats through
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate)  // 1 s
            // Check the position: reading at end-of-file throws instead of returning zero frames.
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                if let converted = try converter.convert(buffer) { try out.write(from: converted) }
            }
        }
        out.close()
    }
}

/// The writing side of `TrackSegments`: owns the current file of a track and starts the next one
/// when a resumed capture's sample rate doesn't match.
final class SegmentedTrack {
    private let first: URL
    private let clockStart: UInt64?
    private let speechDetector: SpeechDetectorFactory?
    private let tee: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var count = 1
    private(set) var writer: TrackWriter

    init(url: URL, inputFormat: AVAudioFormat, clockStart: UInt64?, speechDetector: SpeechDetectorFactory? = nil,
         tee: (@Sendable (AVAudioPCMBuffer) -> Void)?) throws {
        first = url
        self.clockStart = clockStart
        self.speechDetector = speechDetector
        self.tee = tee
        writer = try TrackWriter(url: url, inputFormat: inputFormat, clockStart: clockStart, speechDetector: speechDetector?(), tee: tee)
    }

    /// The writer to resume capturing into from `format`: the current one, or a new file if the
    /// sample rate changed. Call only while nothing is capturing.
    func writer(resumingWith format: AVAudioFormat) throws -> TrackWriter {
        do {
            try writer.setInput(format)
            return writer
        } catch TrackWriter.WriteError.sampleRateChanged {
            writer.close()  // first: it writes out what's queued, so endSeconds is final
            let next = try TrackWriter(url: TrackSegments.segmentURL(first: first, number: count + 1), inputFormat: format,
                                       clockStart: clockStart, startSeconds: writer.endSeconds,
                                       speechDetector: speechDetector?(), tee: tee)
            next.muted = writer.muted
            writer = next
            count += 1
            return next
        }
    }

    /// See `TrackWriter.muted`. Carries over to the next file.
    var muted: Bool {
        get { writer.muted }
        set { writer.muted = newValue }
    }

    /// Seconds of track so far, across files.
    var seconds: Double { writer.endSeconds }

    func close() { writer.close() }
}
