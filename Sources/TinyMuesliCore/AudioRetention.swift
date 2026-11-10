import Foundation

/// Audio stays a while after the final pass even when it isn't kept, in case the meeting needs
/// transcribing again (a better diarizer, a wrong language). The final pass leaves an `.expires`
/// file in `audio/` with the time it may go; `expired(in:)` finds the folders whose time has come.
/// Audio without one (kept on purpose, or from before) is never deleted.
public enum AudioRetention {
    public static let marker = ".expires"
    /// How long the app keeps audio it doesn't keep for good.
    public static let grace: TimeInterval = 24 * 60 * 60

    /// Marks `audio` (a meeting's audio folder) for deletion at `date`.
    public static func expire(_ audio: URL, at date: Date) {
        guard FileManager.default.fileExists(atPath: audio.path) else { return }
        let iso = ISO8601DateFormatter()
        try? iso.string(from: date).write(to: audio.appendingPathComponent(marker), atomically: true, encoding: .utf8)
    }

    /// Kept for good: takes off an earlier pass's mark.
    public static func keep(_ audio: URL) {
        try? FileManager.default.removeItem(at: audio.appendingPathComponent(marker))
    }

    /// When `audio` may be deleted, if it's marked.
    public static func expiry(of audio: URL) -> Date? {
        guard let text = try? String(contentsOf: audio.appendingPathComponent(marker), encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Marked audio folders whose time has passed: `audio/`, and `audio-1/`... from before a
    /// meeting was resumed. Only of meetings that are done (a failed one keeps its audio to retry).
    public static func expired(in store: MeetingStore, now: Date = .now) -> [URL] {
        store.meetingFolders().flatMap { folder -> [URL] in
            let audios = MeetingStore.subdirectories(folder).filter {
                $0.lastPathComponent == MeetingFiles.audio
                    || $0.lastPathComponent.wholeMatch(of: /audio-\d+/) != nil
            }
            guard audios.contains(where: { expiry(of: $0).map { $0 <= now } ?? false }) else { return [] }
            let md = folder.appendingPathComponent(MeetingFiles.transcript)
            guard (try? String(contentsOf: md, encoding: .utf8)).flatMap(MeetingMetadata.init(parsing:))?.status == .done
            else { return [] }
            return audios.filter { expiry(of: $0).map { $0 <= now } ?? false }
        }
    }
}
