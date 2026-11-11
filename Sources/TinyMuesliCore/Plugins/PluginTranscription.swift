@preconcurrency import AVFAudio
import Foundation

/// A plugin's `contributes.transcription` as a `TranscriptionProvider`.
///
/// - **Not live** (the default): each track is collected into a temporary AAC file (`.m4a`) and the
///   plugin is called once with `{"method": "transcribe", "file": …}`. It answers `{"phrases": [...]}`.
/// - **Live**: the plugin starts with the recording. Its first stdin line is
///   `{"method": "transcribeLive", "sampleRate": 48000, "encoding": "f32le", …}`, then raw mono
///   32-bit float samples follow until EOF. It writes one phrase per line of stdout as it goes.
///
/// A phrase is `{"start": 1.2, "end": 3.4, "text": "Hello there.", "words": [{"text": "Hello", "start": 1.2,
/// "end": 1.5, "confidence": 0.9}, …]}`, in seconds from the start of the audio. `words` is optional.
public struct PluginTranscriptionProvider: TranscriptionProvider {
    public let plugin: Plugin
    let contribution: PluginManifest.Transcription

    public init?(plugin: Plugin) {
        guard let contribution = plugin.manifest.contributes.transcription else { return nil }
        self.plugin = plugin
        self.contribution = contribution
    }

    public var id: String { plugin.id }
    public var name: String { plugin.name }
    public var isOnDevice: Bool { plugin.manifest.network != true }
    public var transcribesLive: Bool { contribution.live ?? false }
    public var isMultilingual: Bool { contribution.multilingual ?? false }

    public var setupProblem: String? {
        let settings = PluginSettings()
        let missing = plugin.manifest.settings.filter { $0.property.secret == true && settings.value($0.key, $0.property) == nil }
        return missing.isEmpty ? nil : "Needs \(missing.map(\.key).joined(separator: ", ")) (Settings › Plugins)."
    }

    public static let defaultLanguages = ["da-DK", "de-DE", "en-GB", "en-US", "es-ES", "fi-FI", "fr-FR", "it-IT", "nb-NO",
                                   "nl-NL", "pl-PL", "pt-BR", "pt-PT", "sv-SE", "zh-CN"]

    public func offeredLanguages() async -> [Locale] {
        (contribution.languages ?? Self.defaultLanguages).map(Locale.init(identifier:))
    }

    public func makeTranscriber(preferred: Locale?) async throws -> Transcriber {
        // Without extensions such as a region override ("en-US-u-rg-chzzzz").
        let tag = (preferred ?? Locale.current).identifier(.bcp47).components(separatedBy: "-u-")[0]
        return PluginTranscriber(plugin: plugin, contribution: contribution, language: tag, detectLanguage: preferred == nil)
    }
}

struct PluginTranscriber: Transcriber {
    let plugin: Plugin
    let contribution: PluginManifest.Transcription
    let language: String
    /// No language was chosen: the plugin may detect it.
    let detectLanguage: Bool
    /// The model the plugin said it used (`"model"` in its answer), shared with its other-language copies.
    let reported: ReportedModel

    init(plugin: Plugin, contribution: PluginManifest.Transcription, language: String, detectLanguage: Bool,
         reported: ReportedModel = ReportedModel()) {
        self.plugin = plugin
        self.contribution = contribution
        self.language = language
        self.detectLanguage = detectLanguage
        self.reported = reported
    }

    func inLanguage(_ language: String) -> Transcriber {
        PluginTranscriber(plugin: plugin, contribution: contribution, language: language, detectLanguage: false,
                          reported: reported)
    }

    var model: ModelInfo? {
        ModelInfo(id: plugin.id, name: plugin.name, version: plugin.manifest.version, model: reported.value)
    }

    func makeStream(onPhrase: @escaping @Sendable (Phrase) -> Void) -> TranscriptionStream {
        contribution.live == true
            ? LivePluginStream(transcriber: self, onPhrase: onPhrase)
            : FilePluginStream(transcriber: self, onPhrase: onPhrase)
    }

    var request: [String: Any] {
        var request: [String: Any] = ["language": language, "detectLanguage": detectLanguage]
        // A hint for detecting: the languages the user said are spoken in their meetings.
        let spoken = Settings.spokenLanguages
        if !spoken.isEmpty { request["languages"] = spoken }
        return request
    }

    /// One file, one call. A plugin's calls run one at a time (see `PluginQueue`).
    func transcribe(upload file: URL) async throws -> [Phrase] {
        var body = request
        body["method"] = "transcribe"
        body["file"] = file.path
        await PluginQueue.shared.acquire(plugin.id)
        let output: Data
        do {
            output = try await plugin.call(contribution.command, what: "transcribe", request: body)
            await PluginQueue.shared.release(plugin.id)
        } catch {
            await PluginQueue.shared.release(plugin.id)
            throw error
        }
        struct Answer: Decodable {
            var phrases: [PluginPhrase]
            var model: String?
        }
        do {
            let answer = try JSONDecoder().decode(Answer.self, from: output)
            if let model = answer.model { reported.value = model }
            return answer.phrases.map(\.phrase)
        } catch {
            throw PluginError.badOutput(plugin: plugin.name, detail: "\(error)")
        }
    }
}

/// The model a plugin reported, set from whichever track's call answers.
final class ReportedModel: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Runs a plugin's transcriptions one after another. The final pass transcribes both tracks at once,
/// and a plugin running a model on this Mac then loads it twice: two Parakeet runs (~6 GB each)
/// took a 16 GB Mac to a standstill. A cloud plugin only loses a little time.
actor PluginQueue {
    static let shared = PluginQueue()
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Waits until the plugin is free; call `release` when done.
    func acquire(_ id: String) async {
        if busy.contains(id) {
            await withCheckedContinuation { waiting[id, default: []].append($0) }
        } else {
            busy.insert(id)
        }
    }

    /// Hands the plugin to the next caller, or frees it.
    func release(_ id: String) {
        if var queue = waiting[id], !queue.isEmpty {
            let first = queue.removeFirst()
            waiting[id] = queue.isEmpty ? nil : queue
            first.resume()
        } else {
            busy.remove(id)
        }
    }
}

/// A phrase as plugins write it: like `Phrase`, but `words` may be left out.
struct PluginPhrase: Decodable {
    var start: Double
    var end: Double
    var text: String
    var words: [Word]?

    /// Without word timings, each word gets an even share of the phrase.
    var phrase: Phrase {
        if let words, !words.isEmpty { return Phrase(start: start, end: end, text: text, words: words) }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        let step = parts.isEmpty ? 0 : (end - start) / Double(parts.count)
        let words = parts.enumerated().map { index, part in
            Word(text: (index == 0 ? "" : " ") + part, start: start + Double(index) * step, end: start + Double(index + 1) * step)
        }
        return Phrase(start: start, end: end, text: text, words: words)
    }
}

/// Collects a track's audio into a temporary AAC file, then hands it to the plugin on `finish()`.
final class FilePluginStream: TranscriptionStream, @unchecked Sendable {
    private let transcriber: PluginTranscriber
    private let onPhrase: @Sendable (Phrase) -> Void
    private let lock = NSLock()
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinymuesli-\(UUID().uuidString).m4a")
    private var file: AVAudioFile?
    private var error: Error?

    init(transcriber: PluginTranscriber, onPhrase: @escaping @Sendable (Phrase) -> Void) {
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

/// Streams raw samples to a running plugin and reads phrases back as it writes them.
final class LivePluginStream: TranscriptionStream, @unchecked Sendable {
    private let transcriber: PluginTranscriber
    private let onPhrase: @Sendable (Phrase) -> Void
    /// Writes happen here, never on the audio thread.
    private let queue = DispatchQueue(label: "tinymuesli.plugin-audio")
    private let lock = NSLock()
    private var process: PluginProcess?
    private var startError: Error?
    private var phrases: [Phrase] = []
    private var badLines = 0
    private var started = false
    /// Seconds of audio queued but not yet written; past `maxBacklog` audio is dropped.
    private var backlog = 0.0
    private static let maxBacklog = 30.0
    /// Signalled when the plugin closes its stdout.
    private let readerDone = DispatchSemaphore(value: 0)

    init(transcriber: PluginTranscriber, onPhrase: @escaping @Sendable (Phrase) -> Void) {
        self.transcriber = transcriber
        self.onPhrase = onPhrase
    }

    /// Starts the plugin with the first buffer, whose format it's told about.
    private func start(sampleRate: Double) {
        do {
            let process = try transcriber.plugin.start(transcriber.contribution.command, what: "transcribeLive")
            var header = transcriber.request
            header["method"] = "transcribeLive"
            header["sampleRate"] = sampleRate
            header["channels"] = 1
            header["encoding"] = "f32le"
            header["settings"] = PluginSettings().values(for: transcriber.plugin.manifest).mapValues(\.any)
            header["apiVersion"] = Plugin.apiVersion
            let json = try JSONSerialization.data(withJSONObject: header, options: [.withoutEscapingSlashes])
            process.write(json + Data("\n".utf8))
            lock.withLock { self.process = process }
            let done = readerDone
            Thread.detachNewThread { [weak self] in
                process.readLines { line in self?.received(line) }
                done.signal()
            }
        } catch {
            lock.withLock { startError = error }
        }
    }

    private func received(_ line: Data) {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { return }
        guard let phrase = try? JSONDecoder().decode(PluginPhrase.self, from: line).phrase else {
            lock.withLock { badLines += 1 }
            return
        }
        lock.withLock { phrases.append(phrase) }
        onPhrase(phrase)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let accepted = lock.withLock {
            guard backlog < Self.maxBacklog else { return false }
            backlog += seconds
            return true
        }
        guard accepted else { return }
        let data = Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let sampleRate = buffer.format.sampleRate
        queue.async { [self] in
            if !started {
                started = true
                start(sampleRate: sampleRate)
            }
            lock.withLock { backlog -= seconds }
            lock.withLock { process }?.write(data)
        }
    }

    func finish() async throws -> [Phrase] {
        await withCheckedContinuation { c in queue.async { c.resume() } }  // everything queued is written
        let (process, startError) = lock.withLock { (self.process, self.startError) }
        if let startError { throw startError }
        guard let process else { return [] }  // never got audio
        process.closeInput()
        let done = readerDone
        await withCheckedContinuation { c in DispatchQueue.global().async { done.wait(); c.resume() } }
        let status = await process.waitForExit()
        try transcriber.plugin.check(status: status, command: transcriber.contribution.command, process: process)
        return lock.withLock { phrases }
    }
}
