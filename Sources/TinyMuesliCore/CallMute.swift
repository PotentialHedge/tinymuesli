import AppKit
import ApplicationServices
import Foundation

/// Whether you're muted in the call, read off the call app's mute button through Accessibility.
///
/// No app tells macOS when you mute (Zoom, Teams and Meet keep the mic open while muted), but the
/// mute button says what pressing it would do: "Unmute" while muted, "Mute" while not. Zoom also has
/// it in its menu bar ("Mute Audio" / "Unmute Audio"), Meet as "Turn on/off microphone".
///
/// Errs towards "not muted": a wrongly muted mic loses your words, a wrongly unmuted one only keeps
/// what you said while muted. So anything ambiguous (both kinds of button, or neither) is nil.
public enum CallMute {
    /// Accessibility access, needed to read other apps' buttons.
    public static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's prompt, which leads to System Settings. Returns the current state.
    @discardableResult
    public static func requestAccess() -> Bool {
        let key = "AXTrustedCheckOptionPrompt"  // kAXTrustedCheckOptionPrompt, a global Swift 6 won't touch
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Settings pane where Accessibility access is turned on.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// true: muted, false: unmuted, nil: can't tell (no access, app not running, button not found).
    /// Walks the app's windows and menu bar, so call it off the main thread.
    public static func isMuted(in app: MeetingApp) -> Bool? {
        guard isAllowed else { return nil }
        return classify(labels(in: app), micOnly: app.kind == .browser)
    }

    /// For `tinymuesli mute-state`: the labels that count, what each means, and the verdict.
    public static func explain(_ app: MeetingApp) -> (labels: [(label: String, meaning: String)], muted: Bool?) {
        let micOnly = app.kind == .browser
        let all = labels(in: app)
        let counted = all.compactMap { label in
            meaning(of: label, micOnly: micOnly).map { (label, $0 == .pressToUnmute ? "muted" : "unmuted") }
        }
        return (counted, classify(all, micOnly: micOnly))
    }

    /// Whether any of the app's processes is running.
    public static func isRunning(_ app: MeetingApp) -> Bool { !pids(of: app).isEmpty }

    private static func pids(of app: MeetingApp) -> [pid_t] {
        app.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.map(\.processIdentifier)
    }

    private static func labels(in app: MeetingApp) -> [String] {
        pids(of: app).flatMap(buttonLabels(pid:))
    }

    enum Meaning { case pressToUnmute, pressToMute }

    /// What a button's label says about the mute state, if anything. `micOnly`: only labels that
    /// name the mic count, for browsers, where another tab's video player has an "Unmute" button too.
    static func meaning(of label: String, micOnly: Bool = false) -> Meaning? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if micOnly, !label.contains("mic") { return nil }
        let unmute = ["unmute", "turn on microphone", "turn on mic", "turn on your microphone"]
        let mute = ["mute", "turn off microphone", "turn off mic", "turn off your microphone"]
        // Host controls for other people ("Mute All", "Ask All to Unmute") aren't about you.
        let others = ["mute all", "unmute all", "mute everyone", "mute participants", "mute others"]
        if others.contains(where: label.hasPrefix) { return nil }
        if unmute.contains(where: label.hasPrefix) { return .pressToUnmute }
        if mute.contains(where: label.hasPrefix) { return .pressToMute }
        return nil
    }

    /// Muted only if some button offers to unmute and none offers to mute.
    static func classify(_ labels: [String], micOnly: Bool = false) -> Bool? {
        let meanings = Set(labels.compactMap { meaning(of: $0, micOnly: micOnly) })
        switch (meanings.contains(.pressToUnmute), meanings.contains(.pressToMute)) {
        case (true, false): return true
        case (false, true): return false
        default: return nil
        }
    }

    // MARK: - Reading the Accessibility tree

    private static let roles: Set<String> = [
        kAXButtonRole, kAXMenuItemRole, kAXCheckBoxRole, "AXToggle", kAXPopUpButtonRole,
    ]
    /// Enough for Zoom, Teams and a Meet tab; stops a huge page from stalling the poll.
    private static let maxElements = 4000

    private static func buttonLabels(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium (Chrome, Edge, Arc, Teams' web view) only builds its page tree for assistive apps.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var queue: [AXUIElement] = []
        if let windows: [AXUIElement] = value(app, kAXWindowsAttribute) { queue += windows }
        if let menuBar: AXUIElement = value(app, kAXMenuBarAttribute) { queue.append(menuBar) }

        var labels: [String] = []
        var visited = 0
        while !queue.isEmpty, visited < maxElements {
            let element = queue.removeFirst()
            visited += 1
            if let role: String = value(element, kAXRoleAttribute), roles.contains(role) {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let label: String = value(element, attribute), !label.isEmpty { labels.append(label) }
                }
            }
            if let children: [AXUIElement] = value(element, kAXChildrenAttribute) { queue += children }
        }
        return labels
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
