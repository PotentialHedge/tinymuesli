import Foundation

/// A model that suggests a finished meeting's title, tags and speaker names (`suggestions.json`).
/// Apple Intelligence, or a plugin's (`PluginSuggestionProvider`).
public protocol SuggestionProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var isOnDevice: Bool { get }
    /// Ready to use now (e.g. Apple Intelligence on and its model downloaded).
    var isAvailable: Bool { get }
    /// Works out the suggestions and writes them to `suggestions.json`. `store` gives the titles
    /// and tags of other meetings, to suggest in the same style.
    @discardableResult
    func suggest(folder: URL, store: MeetingStore, log: @escaping @Sendable (String) -> Void) async throws -> MeetingSuggestions
}

public enum SuggestionProviders {
    public static let apple = AppleIntelligenceSuggestions()
    public static func all(plugins: [Plugin] = PluginStore().installed()) -> [any SuggestionProvider] {
        [apple] + plugins.compactMap(PluginSuggestionProvider.init(plugin:))
    }

    /// The one chosen in Settings, else Apple Intelligence.
    public static var selected: any SuggestionProvider {
        all().first { $0.id == Settings.suggestionProvider } ?? apple
    }
}

/// Apple's on-device model, through `MeetingSuggester`.
public struct AppleIntelligenceSuggestions: SuggestionProvider {
    public let id = "apple-intelligence"
    public let name = "Apple Intelligence"
    public let isOnDevice = true
    public var isAvailable: Bool { MeetingSuggester.isAvailable }

    @discardableResult
    public func suggest(folder: URL, store: MeetingStore, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MeetingSuggestions {
        let suggester = await Task.detached(priority: .utility) { MeetingSuggester(store: store, excluding: folder) }.value
        return try await suggester.suggest(folder: folder, log: log)
    }
}
