import Foundation
import Security

/// API keys for cloud providers, kept in the login keychain (never in preferences or meeting files).
/// An environment variable wins, so the CLI can be used without touching the keychain.
public enum APIKeys {
    public enum Service: String, Sendable {
        case elevenLabs = "elevenlabs"

        var environmentVariable: String {
            switch self {
            case .elevenLabs: "ELEVENLABS_API_KEY"
            }
        }

        var keychainService: String { "com.tinymuesli.api-key.\(rawValue)" }
    }

    public static func key(for service: Service) -> String? {
        if let value = ProcessInfo.processInfo.environment[service.environmentVariable], !value.isEmpty {
            return value
        }
        var query = baseQuery(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// Saves `key`, or removes the saved one when it's nil or empty.
    public static func set(_ key: String?, for service: Service) {
        let query = baseQuery(service)
        SecItemDelete(query as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "tinyMuesli \(service.rawValue) API key"
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func baseQuery(_ service: Service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service.keychainService,
         kSecAttrAccount as String: "default"]
    }
}
