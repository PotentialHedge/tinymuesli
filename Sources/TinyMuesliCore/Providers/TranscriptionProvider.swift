import Foundation

/// A speech-to-text backend: Apple's on-device `SpeechAnalyzer`, or a cloud service like ElevenLabs.
///
/// Providers are compiled in (no dynamic loading); adding one means adding a type that conforms and
/// listing it in `TranscriptionProviders.all`. Everything downstream only sees `Transcriber`.
public protocol TranscriptionProvider: Sendable {
    /// Stable id, saved in settings and taken by the CLI's `--provider`, e.g. "apple".
    var id: String { get }
    /// Shown in Settings, e.g. "Apple (on this Mac)".
    var name: String { get }
    /// Audio never leaves the Mac.
    var isOnDevice: Bool { get }
    /// Gets audio while recording, so `transcript.md` grows during the meeting. Providers that
    /// don't transcribe each track's file in the final pass instead.
    var transcribesLive: Bool { get }
    /// Why it can't be used right now (e.g. no API key), or nil when it's ready.
    var setupProblem: String? { get }
    /// Languages for the picker.
    func offeredLanguages() async -> [Locale]
    /// A transcriber for `preferred` (nil: the system language, or the provider's own choice).
    func makeTranscriber(preferred: Locale?) async throws -> Transcriber
}

public enum TranscriptionProviders {
    public static let apple = AppleSpeechProvider()
    public static let elevenLabs = ElevenLabsProvider()

    public static let all: [any TranscriptionProvider] = [apple, elevenLabs]

    public static func provider(id: String) -> (any TranscriptionProvider)? {
        all.first { $0.id == id }
    }

    /// The one chosen in Settings, else Apple's.
    public static var selected: any TranscriptionProvider {
        provider(id: Settings.transcriptionProvider) ?? apple
    }
}

/// Apple's `SpeechAnalyzer`: on-device, live, OS-managed models.
public struct AppleSpeechProvider: TranscriptionProvider {
    public let id = "apple"
    public let name = "Apple (on this Mac)"
    public let isOnDevice = true
    public let transcribesLive = true
    public var setupProblem: String? { nil }

    public func offeredLanguages() async -> [Locale] {
        await AppleSpeechTranscriber.offeredLocales()
    }

    public func makeTranscriber(preferred: Locale?) async throws -> Transcriber {
        try await AppleSpeechTranscriber.make(preferred: preferred)
    }
}
