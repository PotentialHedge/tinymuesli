import AppKit

/// Keeps one menu bar app per user, whichever copy it is (`/Applications`, `build/`, a direct run of the
/// binary, `open -n`): two would each show an icon and both record the same meeting. CLI runs don't take
/// part, so `tinymuesli list` etc. work while the app runs.
///
/// An exclusive `flock` on a file in Caches: the kernel drops it when the process exits, so a crash never
/// leaves it stuck.
enum SingleInstance {
    /// Held for the life of the process; never closed.
    nonisolated(unsafe) private static var lockDescriptor: Int32 = -1

    /// Takes the lock, or, if another copy has it, brings that one forward and exits. Waits up to a
    /// second first, so a copy that is quitting for an update or relaunch has time to let go.
    static func claimOrExit() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tinyMuesli", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("app.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return } // Can't tell; better a second copy than none.

        for attempt in 0..<10 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockDescriptor = fd
                return
            }
            if attempt < 9 { usleep(100_000) }
        }

        FileHandle.standardError.write(Data("tinyMuesli is already running (it's in the menu bar).\n".utf8))
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me }) {
            other.activate()
        }
        exit(0)
    }
}
