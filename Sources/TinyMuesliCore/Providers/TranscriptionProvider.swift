import Foundation

/// A speech-to-text backend: Apple's on-device `SpeechAnalyzer`, or a plugin's
/// (`PluginTranscriptionProvider`, e.g. a cloud service). Everything downstream only sees `Transcriber`.
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
    /// Handles meetings that mix languages by itself. Otherwise it transcribes one language at a
    /// time, and tinyMuesli switches when it hears another (see `LanguageDetector`).
    var isMultilingual: Bool { get }
    /// Languages for the picker.
    func offeredLanguages() async -> [Locale]
    /// A transcriber for `preferred` (nil: the system language, or the provider's own choice).
    func makeTranscriber(preferred: Locale?) async throws -> Transcriber
}

public enum TranscriptionProviders {
    public static let apple = AppleSpeechProvider()

    /// Apple's, then each installed plugin's.
    public static func all(plugins: [Plugin] = PluginStore().installed()) -> [any TranscriptionProvider] {
        [apple] + plugins.compactMap(PluginTranscriptionProvider.init(plugin:))
    }

    public static func provider(id: String, plugins: [Plugin] = PluginStore().installed()) -> (any TranscriptionProvider)? {
        all(plugins: plugins).first { $0.id == id }
    }

    /// The one chosen in Settings, else Apple's (also when the chosen plugin was removed).
    public static var selected: any TranscriptionProvider {
        provider(id: Settings.transcriptionProvider) ?? apple
    }

    /// Of `providers`, the multilingual ones that offer every one of `languages` (BCP-47 tags; only
    /// the language counts, not the region), in their given order.
    public static func multilingual(for languages: [String], among providers: [any TranscriptionProvider]) async -> [any TranscriptionProvider] {
        let wanted = Set(languages.map(LanguageMonitor.code))
        var found: [any TranscriptionProvider] = []
        for provider in providers where provider.isMultilingual {
            let offered = Set(await provider.offeredLanguages().map { LanguageMonitor.code($0.identifier(.bcp47)) })
            if wanted.isSubset(of: offered) { found.append(provider) }
        }
        return found
    }
}

/// Apple's `SpeechAnalyzer`: on-device, live, OS-managed models.
public struct AppleSpeechProvider: TranscriptionProvider {
    public let id = "apple"
    public let name = "Apple (on this Mac)"
    public let isOnDevice = true
    public let transcribesLive = true
    public var setupProblem: String? { nil }
    public let isMultilingual = false

    public func offeredLanguages() async -> [Locale] {
        await AppleSpeechTranscriber.offeredLocales()
    }

    public func makeTranscriber(preferred: Locale?) async throws -> Transcriber {
        try await AppleSpeechTranscriber.make(preferred: preferred)
    }
}
