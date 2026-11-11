import Foundation

/// A plugin's `tinymuesli-plugin.json`, at the root of its repository. Shaped like a VS Code
/// extension's `package.json`: what it adds is under `contributes`, its settings under
/// `contributes.configuration.properties` (same keys as VS Code, plus `secret`).
///
/// ```json
/// {
///   "id": "elevenlabs",
///   "name": "ElevenLabs Scribe",
///   "version": "0.1.0",
///   "description": "Transcribes meetings with ElevenLabs Scribe (cloud).",
///   "network": true,
///   "contributes": {
///     "transcription": { "command": ["python3", "main.py", "transcribe"], "live": false },
///     "configuration": {
///       "properties": {
///         "elevenlabs.apiKey": { "type": "string", "secret": true, "description": "Your API key." },
///         "elevenlabs.model": { "type": "string", "enum": ["scribe_v2", "scribe_v1"], "default": "scribe_v2" }
///       }
///     }
///   }
/// }
/// ```
public struct PluginManifest: Codable, Sendable, Equatable {
    public static let fileName = "tinymuesli-plugin.json"

    /// Lowercase letters, digits and dashes; also the prefix of its setting keys ("elevenlabs.model").
    public var id: String
    public var name: String
    public var version: String?
    public var description: String?
    public var publisher: String?
    /// The plugin says it connects to the internet (shown before installing; not enforced).
    public var network: Bool?
    public var contributes: Contributes

    public struct Contributes: Codable, Sendable, Equatable {
        public var transcription: Transcription?
        public var suggestions: Command?
        public var agent: Command?
        public var actions: [Action]?
        public var configuration: Configuration?
    }

    /// A program to run: the first element is looked up on the login shell's PATH, or relative to the plugin.
    public struct Command: Codable, Sendable, Equatable {
        public var command: [String]
    }

    public struct Transcription: Codable, Sendable, Equatable {
        public var command: [String]
        /// Gets audio while recording (raw samples on stdin) rather than a file after the meeting.
        public var live: Bool?
        /// BCP-47 tags to offer in the language picker. Default: a common set.
        public var languages: [String]?
        /// Transcribes speech that mixes languages, between sentences and within them, without being
        /// told which language comes when. Suggested to people who speak more than one in meetings.
        public var multilingual: Bool?
    }

    /// An item in a meeting's menu.
    public struct Action: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var command: [String]
    }

    public struct Configuration: Codable, Sendable, Equatable {
        public var title: String?
        public var properties: [String: Property]
    }

    /// One setting, as in VS Code's `contributes.configuration`.
    public struct Property: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case string, boolean, number, integer
        }
        public var type: Kind
        public var `default`: JSONValue?
        public var description: String?
        public var markdownDescription: String?
        public var `enum`: [JSONValue]?
        public var enumDescriptions: [String]?
        public var order: Int?
        public var minimum: Double?
        public var maximum: Double?
        /// Kept in the keychain instead of `settings.json` (an API key).
        public var secret: Bool?

        /// Shown under the setting. Markdown is shown as plain text.
        public var help: String? { description ?? markdownDescription }
    }

    // MARK: - Checks

    public enum Problem: Error, LocalizedError, Equatable {
        case badID(String)
        case reservedID(String)
        case emptyCommand(String)
        case settingOutsideNamespace(String)
        case nothingContributed

        public var errorDescription: String? {
            switch self {
            case .badID(let id): "The plugin id \"\(id)\" may only have lowercase letters, digits and dashes."
            case .reservedID(let id): "The plugin id \"\(id)\" is taken by something built in."
            case .emptyCommand(let what): "The plugin's \(what) has an empty command."
            case .settingOutsideNamespace(let key): "The setting \"\(key)\" must start with the plugin's id and a dot."
            case .nothingContributed: "The plugin doesn't contribute anything."
            }
        }
    }

    /// Ids of built-in providers and agents, which plugins can't use.
    public static let reservedIDs: Set<String> = ["apple", "apple-intelligence", "hook", "claude-code", "tinymuesli"]

    public func validate() throws {
        guard id.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,63}/) != nil else { throw Problem.badID(id) }
        guard !Self.reservedIDs.contains(id) else { throw Problem.reservedID(id) }
        let c = contributes
        guard c.transcription != nil || c.suggestions != nil || c.agent != nil || !(c.actions ?? []).isEmpty
        else { throw Problem.nothingContributed }
        if let t = c.transcription, t.command.isEmpty { throw Problem.emptyCommand("transcription") }
        if let s = c.suggestions, s.command.isEmpty { throw Problem.emptyCommand("suggestions") }
        if let a = c.agent, a.command.isEmpty { throw Problem.emptyCommand("agent") }
        for action in c.actions ?? [] where action.command.isEmpty { throw Problem.emptyCommand("action \"\(action.id)\"") }
        for key in c.configuration?.properties.keys ?? [:].keys where !key.hasPrefix(id + ".") {
            throw Problem.settingOutsideNamespace(key)
        }
    }

    public static func load(from directory: URL) throws -> PluginManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent(fileName))
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> PluginManifest {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    /// Settings in the order to show them: by `order`, then by key.
    public var settings: [(key: String, property: Property)] {
        (contributes.configuration?.properties ?? [:])
            .map { (key: $0.key, property: $0.value) }
            .sorted { ($0.property.order ?? .max, $0.key) < ($1.property.order ?? .max, $1.key) }
    }

    /// Every program it can run, for checking they're installed and for showing before install.
    public var commands: [(what: String, command: [String])] {
        var all: [(String, [String])] = []
        if let t = contributes.transcription { all.append(("Transcription", t.command)) }
        if let s = contributes.suggestions { all.append(("Suggestions", s.command)) }
        if let a = contributes.agent { all.append(("After each meeting", a.command)) }
        for action in contributes.actions ?? [] { all.append(("“\(action.title)”", action.command)) }
        return all
    }
}

/// Any JSON value: setting values and defaults.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .null: try container.encodeNil()
        }
    }

    /// For `JSONSerialization`.
    public var any: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .number(let value): value == value.rounded() && abs(value) < 1e15 ? Int64(value) as Any : value
        case .null: NSNull()
        }
    }

    public init?(any: Any) {
        switch any {
        case let value as String: self = .string(value)
        // NSNumber bridges to both; check for a boolean first.
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): self = .bool(value.boolValue)
        case let value as NSNumber: self = .number(value.doubleValue)
        case is NSNull: self = .null
        default: return nil
        }
    }

    public var display: String {
        switch self {
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value == value.rounded() ? String(Int64(value)) : String(value)
        case .null: ""
        }
    }
}
