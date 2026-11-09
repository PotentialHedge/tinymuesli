import Foundation

/// The on-disk layout. The filesystem is the API, so this is the contract other tools rely on.
/// New meetings go in `year/month/`; after that, meeting folders can be renamed, moved and
/// grouped into folders of any depth (see `meetingFolders`):
///
///     <root>/2026/11/2026-11-04 1030 Zoom/
///         transcript.md     frontmatter + transcript
///         audio/mic.caf     raw tracks (temporary unless audio retention is on)
///         audio/system.caf
public struct MeetingStore: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings", isDirectory: true)
    }

    /// The folder chosen in the app, else the default. The CLI reads the same setting.
    public static var configuredRoot: URL {
        Settings.meetingsFolder ?? defaultRoot
    }

    public init(root: URL = MeetingStore.configuredRoot) {
        self.root = root
    }

    public static func folderName(start: Date, appName: String?, calendar: Calendar = .current) -> String {
        "\(stamp(start, calendar: calendar)) \(sanitize(appName ?? "Meeting"))"
    }

    /// The name to show for a meeting folder: without the leading timestamp `folderName` adds,
    /// since the date is shown separately. A folder the user renamed keeps its whole name.
    public static func displayName(of folder: URL, start: Date, calendar: Calendar = .current) -> String {
        let name = folder.lastPathComponent
        let prefix = stamp(start, calendar: calendar) + " "
        guard name.hasPrefix(prefix), name.count > prefix.count else { return name }
        return String(name.dropFirst(prefix.count))
    }

    private static func stamp(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    /// Creates a fresh folder for a meeting, adding " (2)", " (3)"... on collisions.
    public func makeMeetingFolder(start: Date, appName: String?, calendar: Calendar = .current) throws -> URL {
        let c = calendar.dateComponents([.year, .month], from: start)
        let month = root
            .appendingPathComponent(String(format: "%04d", c.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", c.month!), isDirectory: true)
        let base = Self.folderName(start: start, appName: appName, calendar: calendar)

        let fm = FileManager.default
        try fm.createDirectory(at: month, withIntermediateDirectories: true)
        var candidate = month.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = month.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    /// Most recent meeting folders first, by the start date in `transcript.md`, so folders can be
    /// renamed. Folders without readable metadata come last, in name order.
    public func recentMeetings(limit: Int = 10) -> [URL] {
        let meetings = meetingFolders().map { ($0, Self.start(of: $0)) }
        return meetings.sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.0.lastPathComponent > b.0.lastPathComponent
            }
        }
        .prefix(max(0, limit)).map(\.0)
    }

    /// Every meeting folder, most recent first.
    public func allMeetings() -> [URL] {
        recentMeetings(limit: .max)
    }

    /// Every meeting folder under the root, at any depth: new meetings go in `year/month/`, but
    /// they can be renamed, moved and grouped into folders of your own. A meeting folder is one
    /// with a `transcript.md` or an `audio/` folder; what's inside it isn't searched further.
    public func meetingFolders() -> [URL] {
        var result: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth < 8 else { return }
            for sub in Self.subdirectories(dir) {
                if Self.isMeeting(sub) {
                    result.append(sub)
                } else {
                    walk(sub, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return result
    }

    static func isMeeting(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: folder.appendingPathComponent(MeetingFiles.transcript).path)
            || (fm.fileExists(atPath: folder.appendingPathComponent(MeetingFiles.audio).path, isDirectory: &isDir) && isDir.boolValue)
    }

    /// The folder's path below the root, e.g. "2026/11/2026-11-04 1030 Zoom" or "Clients/Acme/Kickoff".
    /// Its own name if it isn't below the root.
    public func relativePath(of folder: URL) -> String {
        let base = Self.components(root)
        let parts = Self.components(folder)
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return folder.lastPathComponent }
        return parts.dropFirst(base.count).joined(separator: "/")
    }

    /// Path components with symlinks resolved, since the same folder can be reached as
    /// /var/... and /private/var/...
    private static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }

    public struct MoveResult: Sendable {
        public var moved = 0
        /// Folders that couldn't be moved, with the reason.
        public var failed: [(folder: URL, reason: String)] = []
    }

    /// Moves meeting folders into `destination`, keeping their path below the root (`year/month/`,
    /// or folders of your own). A name that's already taken there gets " (2)", " (3)"... Folders
    /// left empty are removed, up to the root.
    public func move(_ meetings: [URL], to destination: MeetingStore) -> MoveResult {
        let fm = FileManager.default
        var result = MoveResult()
        for folder in meetings {
            let relative = relativePath(of: folder).split(separator: "/").map(String.init)
            let targetParent = relative.dropLast().reduce(destination.root) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            do {
                try fm.createDirectory(at: targetParent, withIntermediateDirectories: true)
                let base = folder.lastPathComponent
                var target = targetParent.appendingPathComponent(base, isDirectory: true)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = targetParent.appendingPathComponent("\(base) (\(n))", isDirectory: true)
                    n += 1
                }
                try fm.moveItem(at: folder, to: target)
                result.moved += 1
            } catch {
                result.failed.append((folder, error.localizedDescription))
            }
            var dir = folder.deletingLastPathComponent()
            for _ in relative.dropLast() {
                guard Self.subdirectories(dir).isEmpty, Self.isEmpty(dir) else { break }
                try? fm.removeItem(at: dir)
                dir = dir.deletingLastPathComponent()
            }
        }
        return result
    }

    /// Subfolders that aren't hidden or packages (like an .app), newest name first.
    private static func subdirectories(_ url: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        return items
            .filter {
                let values = try? $0.resourceValues(forKeys: keys)
                return values?.isDirectory == true && values?.isPackage != true && values?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Start date from the frontmatter, reading only the top of the file.
    public static func start(of meeting: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: meeting.appendingPathComponent(MeetingFiles.transcript)),
              let head = try? handle.read(upToCount: 16_384)
        else { return nil }
        try? handle.close()
        return MeetingMetadata(parsing: String(decoding: head, as: UTF8.self))?.start
    }

    /// Nothing but hidden files (like .DS_Store) left.
    private static func isEmpty(_ url: URL) -> Bool {
        let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return items?.isEmpty == true
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }
}

/// YAML frontmatter at the top of `transcript.md`.
public struct MeetingMetadata: Sendable, Equatable {
    public enum Status: String, Sendable {
        /// Audio is being captured; the transcript below grows live.
        case recording
        /// Capture finished; the final pass hasn't run (yet).
        case recorded
        /// Final pass running: transcription of anything missing, diarization.
        case transcribing
        /// Transcript is final.
        case done
        /// Final pass failed; see `error`. Audio is kept so it can be retried.
        case failed
    }

    public var start: Date
    public var end: Date?
    /// A name you (or an agent) gave the meeting. Without one it's called by its app.
    public var title: String?
    public var app: String?
    public var status: Status
    public var language: String?
    /// Where a track changed language mid-meeting (it starts in `language`).
    public var languageSwitches: [LanguageSwitch] = []
    public var speakers: [String]
    /// Set in the Meetings window; kept when the final pass re-runs.
    public var tags: [String]
    public var error: String?

    public init(start: Date, end: Date? = nil, title: String? = nil, app: String?, status: Status, language: String? = nil,
                speakers: [String] = [], tags: [String] = [], error: String? = nil) {
        self.start = start
        self.end = end
        self.title = title
        self.app = app
        self.status = status
        self.language = language
        self.speakers = speakers
        self.tags = tags
        self.error = error
    }

    public func frontmatter() -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var lines = ["---"]
        if let title { lines.append("title: \(Self.yamlString(title))") }
        lines.append("date: \(iso.string(from: start))")
        if let end {
            lines.append("end: \(iso.string(from: end))")
            lines.append("duration: \(Self.duration(end.timeIntervalSince(start)))")
        }
        if let app { lines.append("app: \(Self.yamlString(app))") }
        if let language { lines.append("language: \(language)") }
        if !languageSwitches.isEmpty {
            lines.append("language-switches: [\(languageSwitches.map(\.frontmatterItem).joined(separator: ", "))]")
        }
        if !speakers.isEmpty { lines.append("speakers: [\(speakers.map(Self.yamlString).joined(separator: ", "))]") }
        if !tags.isEmpty { lines.append("tags: [\(tags.map(Self.yamlString).joined(separator: ", "))]") }
        lines.append("status: \(status.rawValue)")
        if let error { lines.append("error: \(Self.yamlString(error))") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads back what `frontmatter()` wrote. Not a general YAML parser: just our own keys.
    public init?(parsing markdown: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var values: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        let iso = ISO8601DateFormatter()
        guard let start = values["date"].flatMap(iso.date(from:)) else { return nil }
        self.start = start
        end = values["end"].flatMap(iso.date(from:))
        title = values["title"].map(Self.unquote).flatMap { $0.isEmpty ? nil : $0 }
        app = values["app"].map(Self.unquote)
        status = values["status"].flatMap(Status.init(rawValue:)) ?? .recorded
        language = values["language"]
        languageSwitches = values["language-switches"].map(Self.list)?.compactMap(LanguageSwitch.init(frontmatterItem:)) ?? []
        error = values["error"].map(Self.unquote)
        speakers = values["speakers"].map(Self.list) ?? []
        tags = values["tags"].map(Self.list) ?? []
    }

    /// `[a, "b, c"]`: splits at commas outside quotes.
    static func list(_ value: String) -> [String] {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        var items: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for c in value.dropFirst().dropLast() {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\", quoted { current.append(c); escaped = true; continue }
            if c == "\"" { quoted.toggle() }
            if c == ",", !quoted {
                items.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        items.append(current)
        return items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Quote only when needed, so the common case stays readable: `app: Zoom`.
    static func yamlString(_ value: String) -> String {
        let value = value.replacingOccurrences(of: "\n", with: " ")
        let plain = value.allSatisfy { $0.isLetter || $0.isNumber || " ._-()".contains($0) }
        if plain, value.first?.isWhitespace == false, value.last?.isWhitespace == false { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
