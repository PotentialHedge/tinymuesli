import Foundation

/// Which engine or model produced part of a meeting: the transcriber, the diarizer, the suggestions.
/// Saved with the meeting (`transcript.json`, `suggestions.json`, and in short in `transcript.md`'s
/// frontmatter), so you can tell later what made a transcript, e.g. when comparing engines.
public struct ModelInfo: Codable, Sendable, Equatable {
    /// The provider's id: "apple", a plugin's id, "fluidaudio".
    public var id: String
    /// "Apple SpeechTranscriber", "NVIDIA Parakeet".
    public var name: String
    /// The provider's version: a plugin's, a package's, or macOS's for Apple's engines.
    public var version: String?
    /// The model, when the provider says which (e.g. "mlx-community/parakeet-tdt-0.6b-v3").
    public var model: String?

    public init(id: String, name: String, version: String? = nil, model: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.model = model
    }

    /// One line for the frontmatter and the Meetings window: "NVIDIA Parakeet 0.1.0 (mlx-community/parakeet-tdt-0.6b-v3)".
    public var summary: String {
        [name, version].compactMap { $0 }.joined(separator: " ") + (model.map { " (\($0))" } ?? "")
    }

    /// "macOS 26.2", for Apple's engines, which change with the OS.
    public static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    /// tinyMuesli's own version, when running from the app bundle.
    public static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

/// What made `transcript.json`: the final pass that wrote it.
public struct Processing: Codable, Sendable, Equatable {
    /// When the final pass ran.
    public var date: Date
    /// tinyMuesli's version.
    public var app: String?
    public var transcription: ModelInfo?
    /// Who-spoke-when; nil when diarization didn't run (nobody else on the call, or it failed).
    public var diarization: ModelInfo?

    public init(date: Date = .now, app: String? = ModelInfo.appVersion, transcription: ModelInfo?, diarization: ModelInfo?) {
        self.date = date
        self.app = app
        self.transcription = transcription
        self.diarization = diarization
    }
}
