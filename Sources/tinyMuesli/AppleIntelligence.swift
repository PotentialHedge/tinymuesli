import AppKit
import FoundationModels

/// Whether Apple's on-device language model (Apple Intelligence, through `FoundationModels`) can be
/// used on this Mac, and what's in the way if not.
///
/// The framework is there on every macOS tinyMuesli runs on (26+); what varies is the Mac (Apple
/// silicon), whether Apple Intelligence is turned on, and whether its model has finished downloading.
enum AppleIntelligence {
    enum Status: Equatable {
        case ready
        /// Not an Apple silicon Mac (or not one Apple Intelligence supports): nothing to set up.
        case notEligible
        case turnedOff
        /// Turned on, but the model isn't there yet: still downloading, or held back by a setting
        /// such as Siri's language not matching the Mac's.
        case notReady
    }

    static var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available: .ready
        case .unavailable(.deviceNotEligible): .notEligible
        case .unavailable(.appleIntelligenceNotEnabled): .turnedOff
        case .unavailable: .notReady
        }
    }

    /// The Mac's and Siri's languages, when they differ. Apple Intelligence only turns on (and only
    /// downloads its model) when they're the same: an English (US) Mac with Siri in English (UK) waits forever.
    static var languageMismatch: (mac: String, siri: String)? {
        guard let macID = Locale.preferredLanguages.first, let siriID = siriLanguage else { return nil }
        let mac = Locale.Language(identifier: macID), siri = Locale.Language(identifier: siriID)
        // A Mac language without a region ("Deutsch") takes it from the Region setting.
        let macRegion = mac.region ?? Locale.current.region
        guard mac.languageCode != siri.languageCode || (siri.region != nil && macRegion != siri.region) else { return nil }
        return (displayName(macID), displayName(siriID))
    }

    /// Siri's language, e.g. "en-GB" (not public API: Siri's own preferences, readable since tinyMuesli isn't sandboxed).
    private static var siriLanguage: String? {
        let domain = "com.apple.assistant.backedup" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("Session Language" as CFString, domain)
            ?? CFPreferencesCopyAppValue("Language" as CFString, domain)
        return (value as? String).map { $0.replacingOccurrences(of: "_", with: "-") }
    }

    private static func displayName(_ id: String) -> String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    /// System Settings › Apple Intelligence & Siri.
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
    }

    /// For the user's AI agent: what tinyMuesli found, and how to work out the rest with them.
    static func fixPrompt() -> String {
        let state = switch status {
        case .ready: "ready"
        case .notEligible: "not supported on this Mac"
        case .turnedOff: "turned off (Apple Intelligence isn't enabled)"
        case .notReady: "not ready (Apple Intelligence is on, but its model isn't available yet)"
        }
        var found = "macOS reports Apple Intelligence's on-device model as \(state)."
        if let mismatch = languageMismatch {
            found += " The Mac's language is \(mismatch.mac), but Siri's is \(mismatch.siri)."
        }
        return """
        Help me get Apple Intelligence's on-device model (the FoundationModels framework) working on \
        my Mac, so tinyMuesli can use it. \(found)

        Please:
        1. Check the macOS version and chip (`sw_vers`, `uname -m`): it needs macOS 26 or later on Apple silicon.
        2. Compare the Mac's language (first entry of `defaults read -g AppleLanguages`) with Siri's \
        (`defaults read com.apple.assistant.backedup "Session Language"`). Apple Intelligence only turns \
        on and downloads its model when they're the same language and variant (e.g. both English (UK)), \
        and one it supports.
        3. Check there's enough free disk space (`df -h /`): the model needs about 7 GB.
        4. Tell me exactly what to change, in System Settings › Apple Intelligence & Siri and \
        General › Language & Region, and open the pane: \
        `open "x-apple.systempreferences:com.apple.Siri-Settings.extension"`. Don't change these with \
        `defaults write`; I'll make the changes myself.
        5. Once that's done the model downloads in the background (keep the Mac on power and Wi-Fi). \
        To check whether it's ready, if the Swift toolchain is installed, run a file containing \
        `import FoundationModels` and `print(SystemLanguageModel.default.availability)` with `swift`. \
        It prints `available` when it's done.
        """
    }
}
