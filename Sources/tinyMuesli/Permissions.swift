import AppKit
import AVFoundation
import Observation
import TinyMuesliCore
import UserNotifications

/// What tinyMuesli needs from the system, and whether it has it. Shown in onboarding and the menu.
@MainActor
@Observable
final class Permissions {
    enum Kind: CaseIterable, Identifiable {
        case microphone, systemAudio, notifications, accessibility
        var id: Self { self }

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .systemAudio: "System Audio Recording"
            case .notifications: "Notifications"
            case .accessibility: "Accessibility"
            }
        }

        var purpose: String {
            switch self {
            case .microphone: "Records your side of the meeting."
            case .systemAudio: "Records the other participants, from what your Mac plays. No screen recording."
            case .notifications: "Asks whether to record when a meeting starts."
            case .accessibility: "Sees when you mute yourself in the call, so that isn't recorded."
            }
        }

        var symbol: String {
            switch self {
            case .microphone: "mic.fill"
            case .systemAudio: "speaker.wave.2.fill"
            case .notifications: "bell.badge.fill"
            case .accessibility: "mic.slash.fill"
            }
        }

        /// The pane in System Settings where the user can change it.
        var settingsURL: URL {
            switch self {
            case .microphone:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .systemAudio:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
            case .notifications:
                URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
            case .accessibility:
                CallMute.settingsURL
            }
        }
    }

    enum State: Equatable {
        case granted, denied, notDetermined
        /// Can't be checked (e.g. outside the app bundle). Not reported as a problem.
        case unknown
    }

    private(set) var microphone: State
    private(set) var systemAudio: State
    private(set) var notifications: State = .unknown
    private(set) var accessibility: State
    /// Notifications are allowed but show as temporary banners, so a prompt can slip by unnoticed.
    private(set) var notificationsAreTemporary = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Task<Void, Never>?

    init() {
        microphone = Self.microphoneState()
        systemAudio = Self.systemAudioState()
        accessibility = Self.accessibilityState()
        refresh()
        // Settings change behind our back (in System Settings), so look again whenever it matters:
        // when the menu opens, when the app comes forward, and now and then for the menu bar icon.
        for name in [NSMenu.didBeginTrackingNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refresh()
            }
        }
    }

    func state(_ kind: Kind) -> State {
        switch kind {
        case .microphone: microphone
        case .systemAudio: systemAudio
        case .notifications: notifications
        case .accessibility: accessibility
        }
    }

    /// Permissions that are missing (denied or not asked yet). Accessibility only counts while
    /// "Don't Record Me While Muted in the Call" is on: nothing else needs it.
    var missing: [Kind] {
        Kind.allCases.filter { kind in
            [.denied, .notDetermined].contains(state(kind)) && (kind != .accessibility || Settings.followCallMute)
        }
    }

    var allGranted: Bool { missing.isEmpty }

    func refresh() {
        Task { await refreshNow() }
    }

    /// Like `refresh`, but returns once the notifications state (which macOS reports asynchronously)
    /// is known too.
    func refreshNow() async {
        let mic = Self.microphoneState(), system = Self.systemAudioState(), ax = Self.accessibilityState()
        if accessibility != ax { accessibility = ax }
        if microphone != mic { microphone = mic }
        if systemAudio != system { systemAudio = system }
        guard Self.center != nil else { return }
        let (state, temporary) = await Self.notificationState()
        if notifications != state { notifications = state }
        if notificationsAreTemporary != temporary { notificationsAreTemporary = temporary }
    }

    /// Asks for it if the user hasn't been asked yet; otherwise opens System Settings, since macOS
    /// only prompts once.
    func request(_ kind: Kind) async {
        guard state(kind) == .notDetermined else { return openSettings(kind) }
        NSApp.activate()
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .systemAudio:
            _ = await SystemAudioPermission.request()
        case .notifications:
            _ = try? await Self.center?.requestAuthorization(options: [.alert, .sound])
        case .accessibility:
            // macOS's alert only leads to System Settings, where the switch is turned on.
            CallMute.requestAccess()
        }
        refresh()
    }

    func openSettings(_ kind: Kind) {
        // Asking again adds tinyMuesli back to the list if its entry was removed. macOS doesn't
        // always show its alert again, so the pane opens either way.
        if kind == .accessibility { CallMute.requestAccess() }
        NSWorkspace.shared.open(kind.settingsURL)
    }

    // MARK: - Reading the system's state

    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    private static func microphoneState() -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    private static func systemAudioState() -> State {
        switch SystemAudioPermission.status {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .unknown: .unknown
        }
    }

    /// macOS doesn't say whether it has asked, so it counts as asked once tinyMuesli has.
    private static func accessibilityState() -> State {
        if CallMute.isAllowed { return .granted }
        return Settings.askedForAccessibility ? .denied : .notDetermined
    }

    nonisolated private static func notificationState() async -> (State, Bool) {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (.notDetermined, false)
        case .denied:
            return (.denied, false)
        case .authorized, .provisional, .ephemeral:
            // Allowed, but with banners turned off nothing would show up.
            guard settings.alertSetting == .enabled else { return (.denied, false) }
            return (.granted, settings.alertStyle == .banner)
        @unknown default:
            return (.unknown, false)
        }
    }
}

extension Permissions.State {
    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not set up"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied, .notDetermined: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}
