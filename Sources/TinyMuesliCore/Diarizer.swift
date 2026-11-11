import FluidAudio
import Foundation

/// "Who spoke when" on the system track. Only the remote side needs this: the mic is always "Me".
public protocol Diarizer: Sendable {
    /// Downloads models if needed. Safe to call repeatedly.
    func prepare() async throws
    func diarize(file: URL) async throws -> Diarization
    /// The models, saved with the meeting.
    nonisolated var model: ModelInfo? { get }
}

extension Diarizer {
    public nonisolated var model: ModelInfo? { nil }
}

public struct Diarization: Sendable {
    public var turns: [SpeakerTurn]
    /// One voice embedding per diarizer speaker id. The basis for recognising people across
    /// meetings later (a local voice-print DB); for now they're saved next to the transcript.
    public var embeddings: [String: [Float]]

    public init(turns: [SpeakerTurn], embeddings: [String: [Float]]) {
        self.turns = turns
        self.embeddings = embeddings
    }
}

/// FluidAudio's offline pipeline: pyannote segmentation + WeSpeaker embeddings + VBx clustering,
/// on CoreML. Best quality of its diarizers for whole files, which is what the final pass has.
/// Models (~30 MB) download from Hugging Face on first use into
/// `~/Library/Application Support/FluidAudio/Models`.
public actor FluidDiarizer: Diarizer {
    private var manager: OfflineDiarizerManager?

    /// Keep `version` in step with FluidAudio in Package.resolved.
    public nonisolated let model: ModelInfo? = ModelInfo(id: "fluidaudio", name: "FluidAudio", version: "0.18.2",
                                                         model: "pyannote segmentation + WeSpeaker + VBx")

    public init() {
        // FluidAudio logs every pipeline step at debug level to stderr.
        AppLogger.minimumLevel = .warning
    }

    public func prepare() async throws {
        _ = try await loadedManager()
    }

    public func diarize(file: URL) async throws -> Diarization {
        // The manager isn't Sendable. The actor owns it; process() only reads the loaded models.
        nonisolated(unsafe) let manager = try await loadedManager()
        let result = try await manager.process(file)
        let turns = result.segments.map {
            SpeakerTurn(
                speaker: $0.speakerId,
                start: Double($0.startTimeSeconds).rounded(toPlaces: 2),
                end: Double($0.endTimeSeconds).rounded(toPlaces: 2)
            )
        }
        return Diarization(turns: turns, embeddings: result.speakerDatabase ?? [:])
    }

    private func loadedManager() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        var config = OfflineDiarizerConfig()
        // One speaker at a time: simpler to attribute words to.
        config.exclusiveSegments = true
        nonisolated(unsafe) let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        self.manager = manager
        return manager
    }
}
