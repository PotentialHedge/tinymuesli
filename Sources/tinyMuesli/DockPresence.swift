import AppKit

/// tinyMuesli launches as a menu bar app (`LSUIElement`). While one of its windows is open
/// (Meetings, the welcome guide, an update prompt), it becomes a regular app with a Dock icon, a
/// place in ⌘Tab and its own menu bar. Closing the last window goes back to the menu bar only.
@MainActor
enum DockPresence {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Becoming key covers windows opened by the user; occlusion covers ones ordered front
        // without activating (the welcome guide at login). Closing is posted before the window goes.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { update() }
        })
    }

    private static func update() {
        let wanted: NSApplication.ActivationPolicy = NSApp.windows.contains(where: isAppWindow) ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        // The window was opened by activating the app while it was still an accessory, which doesn't
        // put its menus in the menu bar: activate again now that it has some.
        if wanted == .regular, NSApp.keyWindow != nil { NSApp.activate() }
    }

    /// A titled window that's open, minimised included. Not panels (open panels, alerts) or
    /// the menu bar extra's window.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
    }
}
