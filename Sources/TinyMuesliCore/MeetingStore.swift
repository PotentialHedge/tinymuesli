import Foundation

/// The on-disk layout. The filesystem is the API, so this is the contract other tools rely on:
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
    /// renamed. Within a month, folders without readable metadata come last, in name order.
    public func recentMeetings(limit: Int = 10) -> [URL] {
        var result: [URL] = []
        for year in Self.subdirectories(root, digits: 4) {
            for month in Self.subdirectories(year, digits: 2) {
                let meetings = Self.subdirectories(month).map { ($0, Self.start(of: $0)) }
                for (meeting, _) in meetings.sorted(by: { a, b in
                    switch (a.1, b.1) {
                    case let (x?, y?) where x != y: x > y
                    case (_?, nil): true
                    case (nil, _?): false
                    default: a.0.lastPathComponent > b.0.lastPathComponent
                    }
                }) {
                    result.append(meeting)
                    if result.count >= limit { return result }
                }
            }
        }
        return result
    }

    /// Every meeting folder, most recent first.
    public func allMeetings() -> [URL] {
        recentMeetings(limit: .max)
    }

    public struct MoveResult: Sendable {
        public var moved = 0
        /// Folders that couldn't be moved, with the reason.
        public var failed: [(folder: URL, reason: String)] = []
    }

    /// Moves meeting folders into `destination`, keeping their `year/month/` path. A name that's
    /// already taken there gets " (2)", " (3)"... Emptied year and month folders are removed.
    public func move(_ meetings: [URL], to destination: MeetingStore) -> MoveResult {
        let fm = FileManager.default
        var result = MoveResult()
        for folder in meetings {
            let month = folder.deletingLastPathComponent()
            let year = month.deletingLastPathComponent()
            let targetMonth = destination.root
                .appendingPathComponent(year.lastPathComponent, isDirectory: true)
                .appendingPathComponent(month.lastPathComponent, isDirectory: true)
            do {
                try fm.createDirectory(at: targetMonth, withIntermediateDirectories: true)
                let base = folder.lastPathComponent
                var target = targetMonth.appendingPathComponent(base, isDirectory: true)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = targetMonth.appendingPathComponent("\(base) (\(n))", isDirectory: true)
                    n += 1
                }
                try fm.moveItem(at: folder, to: target)
                result.moved += 1
            } catch {
                result.failed.append((folder, error.localizedDescription))
            }
            for dir in [month, year] where Self.subdirectories(dir).isEmpty && Self.isEmpty(dir) {
                try? fm.removeItem(at: dir)
            }
        }
        return result
    }

    /// Subfolders, newest name first. `digits` keeps only all-digit names of that length
    /// (year and month folders), so other things in the root aren't taken for meetings.
    private static func subdirectories(_ url: URL, digits: Int? = nil) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { url in
                guard let digits else { return true }
                let name = url.lastPathComponent
                return name.count == digits && name.allSatisfy(\.isASCII) && name.allSatisfy(\.isNumber)
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
