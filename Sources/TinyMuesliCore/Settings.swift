import Foundation

/// User preferences shared by the app and the CLI. Stored under the app's bundle id, so the CLI
/// sees the same values even when run outside the app bundle.
public enum Settings {
    static let bundleID = "com.tinymuesli.tinyMuesli"
    /// Inside the bundle that domain is `.standard` (a suite named after your own bundle id doesn't work).
    nonisolated(unsafe) static let defaults = Bundle.main.bundleIdentifier == bundleID
        ? .standard
        : UserDefaults(suiteName: bundleID) ?? .standard

    /// The app was called Muesli up to 0.1.2. Copies its preferences (meetings folder, language,
    /// always-record apps, update settings) and copies its hook folder, once, the first time
    /// tinyMuesli runs. Leaves anything tinyMuesli already has alone.
    /// Nothing was saved yet by tinyMuesli or by Muesli before it: a new install (or a reinstall
    /// after deleting the preferences). Set by `noteFirstLaunch()` before anything writes settings.
    public private(set) nonisolated(unsafe) static var isFirstLaunch = false

    /// Call first thing at launch, before `migrateFromMuesli()` and before Sparkle saves its state.
    public static func noteFirstLaunch() {
        let domains = [bundleID, "dev.muesli.Muesli"].compactMap { UserDefaults.standard.persistentDomain(forName: $0) }
        isFirstLaunch = domains.allSatisfy(\.isEmpty)
    }

    public static func migrateFromMuesli() {
        let oldBundleID = "dev.muesli.Muesli"
        if UserDefaults.standard.persistentDomain(forName: bundleID)?.isEmpty ?? true,
           let old = UserDefaults.standard.persistentDomain(forName: oldBundleID), !old.isEmpty {
            UserDefaults.standard.setPersistentDomain(old, forName: bundleID)
            CFPreferencesAppSynchronize(bundleID as CFString)
        }
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let (oldHooks, newHooks) = (config.appendingPathComponent("muesli"), config.appendingPathComponent("tinymuesli"))
        if !FileManager.default.fileExists(atPath: newHooks.path) {
            try? FileManager.default.copyItem(at: oldHooks, to: newHooks)
        }
    }

    /// Transcription language. nil = the system language (or the closest supported one).
    public static var language: Locale? {
        get { defaults.string(forKey: "language").map(Locale.init(identifier:)) }
        set { defaults.set(newValue?.identifier(.bcp47), forKey: "language") }
    }

    /// Keep `audio/` after a successful transcription. Off by default: transcript only.
    public static var keepAudio: Bool {
        get { defaults.bool(forKey: "keepAudio") }
        set { defaults.set(newValue, forKey: "keepAudio") }
    }

    /// Record stretches without speech as silence, so a quiet room takes almost no space.
    /// Off by default.
    public static var skipSilence: Bool {
        get { defaults.bool(forKey: "skipSilence") }
        set { defaults.set(newValue, forKey: "skipSilence") }
    }

    /// While the call app shows you as muted, record silence on your mic track. On by default.
    public static var followCallMute: Bool {
        get { defaults.object(forKey: "followCallMute") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "followCallMute") }
    }

    /// Ask Apple Intelligence for each finished meeting's title, tags and speaker names. On by default;
    /// does nothing on a Mac without it.
    public static var suggestWithAppleIntelligence: Bool {
        get { defaults.object(forKey: "suggestWithAppleIntelligence") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "suggestWithAppleIntelligence") }
    }

    /// Where meeting folders go. nil = `MeetingStore.defaultRoot` (~/Meetings).
    public static var meetingsFolder: URL? {
        get { defaults.string(forKey: "meetingsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.standardizedFileURL.path, forKey: "meetingsFolder") }
    }

    /// The welcome window has been through (or closed). It shows on first launch only.
    public static var completedOnboarding: Bool {
        get { defaults.bool(forKey: "completedOnboarding") }
        set { defaults.set(newValue, forKey: "completedOnboarding") }
    }

    /// The welcome window opened on first launch but hasn't been through yet (e.g. the app was quit
    /// while it was open). Set to `false` rather than left unset, which tells it apart from someone
    /// upgrading from a version without onboarding.
    public static var onboardingInProgress: Bool {
        defaults.object(forKey: "completedOnboarding") as? Bool == false
    }
}
