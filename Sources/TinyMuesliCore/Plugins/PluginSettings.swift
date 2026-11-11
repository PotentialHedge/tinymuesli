import Foundation
import Security

/// Plugin settings, like VS Code's `settings.json`: one flat JSON object in
/// `~/.config/tinymuesli/settings.json`, keyed by setting ("elevenlabs.model": "scribe_v2"), which you
/// can also edit by hand. Settings marked `secret` live in the login keychain instead.
public struct PluginSettings: Sendable {
    public var file: URL
    /// Keychain service prefix (tests use their own).
    public var keychainService: String

    public static let defaultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/tinymuesli/settings.json")

    public init(file: URL = PluginSettings.defaultFile, keychainService: String = "com.tinymuesli.plugin-secret") {
        self.file = file
        self.keychainService = keychainService
    }

    /// Everything in `settings.json` (including keys of plugins no longer installed).
    public func all() -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues(JSONValue.init(any:))
    }

    /// The value in effect: the saved one if it fits the setting, else its default.
    public func value(_ key: String, _ property: PluginManifest.Property) -> JSONValue? {
        let saved = property.secret == true ? secret(key).map(JSONValue.string) : all()[key]
        if let saved, Self.fits(saved, property) { return saved }
        return property.default
    }

    /// Each of the plugin's settings with its value in effect (unset ones without a default are left out).
    public func values(for manifest: PluginManifest) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for (key, property) in manifest.settings {
            if let value = value(key, property) { values[key] = value }
        }
        return values
    }

    /// Saves a value; nil (or the default) removes it, so `settings.json` only holds what was changed.
    public func set(_ key: String, _ value: JSONValue?, property: PluginManifest.Property) throws {
        if property.secret == true {
            setSecret(key, value.flatMap { if case .string(let s) = $0, !s.isEmpty { s } else { nil } })
            return
        }
        if let value, !Self.fits(value, property) { throw Problem.wrongType(key, property.type) }
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        if let value, value != property.default { object[key] = value.any } else { object[key] = nil }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }

    /// Parses a value typed as text (the CLI, a text field) for the setting.
    public static func parse(_ text: String, for property: PluginManifest.Property) -> JSONValue? {
        let value: JSONValue?
        switch property.type {
        case .string: value = .string(text)
        case .boolean: value = ["true", "yes", "on", "1"].contains(text.lowercased()) ? .bool(true)
            : ["false", "no", "off", "0"].contains(text.lowercased()) ? .bool(false) : nil
        case .number: value = Double(text).map(JSONValue.number)
        case .integer: value = Int(text).map { .number(Double($0)) }
        }
        return value.flatMap { fits($0, property) ? $0 : nil }
    }

    static func fits(_ value: JSONValue, _ property: PluginManifest.Property) -> Bool {
        if let options = property.enum, !options.contains(value) { return false }
        switch (property.type, value) {
        case (.string, .string), (.boolean, .bool): return true
        case (.number, .number(let n)), (.integer, .number(let n)):
            if property.type == .integer, n != n.rounded() { return false }
            if let min = property.minimum, n < min { return false }
            if let max = property.maximum, n > max { return false }
            return true
        default: return false
        }
    }

    public enum Problem: Error, LocalizedError {
        case wrongType(String, PluginManifest.Property.Kind)
        public var errorDescription: String? {
            switch self {
            case .wrongType(let key, let kind): "\(key) takes a \(kind.rawValue) (one of the allowed values, if it lists them)."
            }
        }
    }

    // MARK: - Secrets

    public func secret(_ key: String) -> String? {
        var query = secretQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { return nil }
        return value
    }

    public func setSecret(_ key: String, _ value: String?) {
        let query = secretQuery(key)
        SecItemDelete(query as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "tinyMuesli plugin setting \(key)"
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Removes a plugin's secrets (when it's removed). Its `settings.json` entries stay, as VS Code's do.
    public func removeSecrets(of manifest: PluginManifest) {
        for (key, property) in manifest.settings where property.secret == true { setSecret(key, nil) }
    }

    private func secretQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: key]
    }
}
