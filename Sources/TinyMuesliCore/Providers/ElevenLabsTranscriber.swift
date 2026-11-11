@preconcurrency import AVFAudio
import Foundation

/// ElevenLabs Scribe (cloud). Not live: each track's audio is uploaded in the final pass, so
/// `transcript.md` only fills in once the meeting has ended. Speakers still come from tinyMuesli's
/// own diarizer, so labels and voice prints work as with Apple's engine.
public struct ElevenLabsProvider: TranscriptionProvider {
    public let id = "elevenlabs"
    public let name = "ElevenLabs Scribe (cloud)"
    public let isOnDevice = false
    public let transcribesLive = false

    public var setupProblem: String? {
        APIKeys.key(for: .elevenLabs) == nil ? "Needs an ElevenLabs API key." : nil
    }

    /// Scribe detects the language itself; these are just the ones offered to pin it.
    public func offeredLanguages() async -> [Locale] {
        ["da-DK", "de-DE", "en-GB", "en-US", "es-ES", "fi-FI", "fr-FR", "it-IT", "nb-NO", "nl-NL", "pl-PL",
         "pt-BR", "pt-PT", "sv-SE", "zh-CN"].map(Locale.init(identifier:))
    }

    public func makeTranscriber(preferred: Locale?) async throws -> Transcriber {
        guard let key = APIKeys.key(for: .elevenLabs) else { throw ElevenLabsError.noAPIKey }
        // No language chosen: let Scribe detect it (it also copes with a meeting that changes language).
        // Without extensions such as a region override ("en-US-u-rg-chzzzz").
        let tag = (preferred ?? Locale.current).identifier(.bcp47).components(separatedBy: "-u-")[0]
        return ElevenLabsTranscriber(apiKey: key, language: tag, pinsLanguage: preferred != nil)
    }
}

public enum ElevenLabsError: Error, CustomStringConvertible {
    case noAPIKey
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case .noAPIKey: "No ElevenLabs API key (add one in Settings › Recording, or set ELEVENLABS_API_KEY)."
        case .http(let code, let body): "ElevenLabs answered \(code): \(body.prefix(300))"
        case .badResponse: "ElevenLabs sent a response tinyMuesli couldn't read."
        }
    }
}

public struct ElevenLabsTranscriber: Transcriber {
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    public static let model = "scribe_v2"

    let apiKey: String
    public let language: String
    /// Send `language` to Scribe; otherwise it detects the language.
    let pinsLanguage: Bool

    public func inLanguage(_ language: String) -> Transcriber {
        ElevenLabsTranscriber(apiKey: apiKey, language: language, pinsLanguage: true)
    }

    public func makeStream(onPhrase: @escaping @Sendable (Phrase) -> Void) -> TranscriptionStream {
        ElevenLabsStream(transcriber: self, onPhrase: onPhrase)
    }

    /// Uploads an audio file and returns its phrases.
    func transcribe(upload file: URL) async throws -> [Phrase] {
        let boundary = "tinymuesli-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("\(boundary).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        var fields = ["model_id": Self.model, "timestamps_granularity": "word", "diarize": "false",
                      "tag_audio_events": "false"]
        if pinsLanguage, let code = Locale(identifier: language).language.languageCode?.identifier {
            fields["language_code"] = code
        }
        try Self.writeMultipart(fields: fields, file: file, boundary: boundary, to: body)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30 * 60  // a long meeting takes a while
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ElevenLabsError.http(status, String(decoding: data, as: UTF8.self)) }
        return try Self.phrases(fromResponse: data)
    }

    /// Streams the file into the body instead of loading it into memory.
    static func writeMultipart(fields: [String: String], file: URL, boundary: String, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    // MARK: - Response

    struct Response: Decodable {
        struct Word: Decodable {
            var text: String
            var type: String
            var start: Double?
            var end: Double?
            var logprob: Double?
        }
        var words: [Word]
    }

    /// A new phrase starts after a sentence ends, or at a pause.
    static let pause = 1.0

    /// Scribe's words (with separate `spacing` items) as phrases: sentence-sized, each word keeping
    /// its leading space, as `AppleSpeechTranscriber` gives them.
    static func phrases(fromResponse data: Data) throws -> [Phrase] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw ElevenLabsError.badResponse }
        var phrases: [Phrase] = []
        var words: [Word] = []
        var spaceBefore = false
        func flush() {
            guard let first = words.first, let last = words.last else { return }
            phrases.append(Phrase(start: first.start, end: last.end, text: words.map(\.text).joined(), words: words))
            words = []
        }
        for item in response.words {
            switch item.type {
            case "spacing":
                spaceBefore = true
            case "word":
                guard let start = item.start, let end = item.end else { continue }
                if let last = words.last, start - last.end >= pause || last.text.endsWithSentence { flush() }
                let text = (spaceBefore && !words.isEmpty ? " " : "") + item.text
                words.append(Word(text: text, start: start, end: end, confidence: item.logprob.map { exp($0) }))
                spaceBefore = false
            default:
                continue  // audio events (laughter etc.)
            }
        }
        flush()
        return phrases
    }
}

private extension String {
    var endsWithSentence: Bool {
        guard let last = trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!。？！".contains(last)
    }
}

/// Collects a track's audio into a temporary AAC file, then uploads it on `finish()`.
final class ElevenLabsStream: TranscriptionStream, @unchecked Sendable {
    private let transcriber: ElevenLabsTranscriber
    private let onPhrase: @Sendable (Phrase) -> Void
    private let lock = NSLock()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinymuesli-\(UUID().uuidString).m4a")
    private var file: AVAudioFile?
    private var error: Error?

    init(transcriber: ElevenLabsTranscriber, onPhrase: @escaping @Sendable (Phrase) -> Void) {
        self.transcriber = transcriber
        self.onPhrase = onPhrase
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard error == nil else { return }
        do {
            if file == nil {
                let format = buffer.format
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
            }
            try file?.write(from: buffer)
        } catch {
            self.error = error
        }
    }

    func finish() async throws -> [Phrase] {
        let (file, error) = lock.withLock { (self.file, self.error) }
        defer { try? FileManager.default.removeItem(at: url) }
        if let error { throw error }
        guard let file else { return [] }  // no audio
        file.close()
        let phrases = try await transcriber.transcribe(upload: url)
        phrases.forEach(onPhrase)
        return phrases
    }
}
