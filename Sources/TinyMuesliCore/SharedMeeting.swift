import Compression
import Foundation

/// A meeting packed to send to someone: a web page that shows the transcript as a chat, and
/// carries the meeting itself in its "Add to tinyMuesli" link (`tinymuesli://import?data=…`), so
/// anyone with tinyMuesli can add it to their meetings in one click.
///
/// Only the transcript goes in: title, tags, times and who said what. No audio and no voice
/// prints (`speakers.json`), which would let the recipient recognise these people's voices.
/// "Me" becomes the sharer's name, since on the recipient's Mac "Me" is them.
public struct SharedMeeting: Codable, Sendable, Equatable {
    public var version = 1
    public var title: String?
    public var tags: [String]
    /// Who shared it. Their lines, "Me" in their copy, carry this name.
    public var sharedBy: String
    public var transcript: TranscriptDocument

    public enum ShareError: LocalizedError, Equatable {
        case notFinished
        case unreadable
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notFinished: "This meeting can be shared once it has been transcribed."
            case .unreadable: "This isn't a meeting shared from tinyMuesli, or it's damaged."
            case .tooLarge: "This shared meeting is too large to add."
            }
        }
    }

    public init(title: String?, tags: [String], sharedBy: String, transcript: TranscriptDocument) {
        self.title = title
        self.tags = tags
        self.sharedBy = sharedBy
        self.transcript = transcript
    }

    /// A finished meeting, with "Me" renamed to `sharedBy`.
    public init(folder: URL, sharedBy: String = NSFullUserName()) throws {
        let text = try String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcript), encoding: .utf8)
        guard let metadata = MeetingMetadata(parsing: text), metadata.status == .done else { throw ShareError.notFinished }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: folder.appendingPathComponent(MeetingFiles.json)))
        let name = sharedBy.trimmingCharacters(in: .whitespacesAndNewlines)
        let me = name.isEmpty || name == SpeakerLabel.me ? "Host" : name
        let segments = document.segments.map { s in
            var s = s
            if s.speaker == SpeakerLabel.me { s.speaker = me }
            return s
        }
        self.init(title: metadata.title, tags: metadata.tags, sharedBy: me,
                  transcript: TranscriptDocument(start: document.start, end: document.end ?? metadata.end, app: document.app ?? metadata.app,
                                                 language: document.language ?? metadata.language, segments: segments))
    }

    // MARK: - Payload

    /// The meeting as compact JSON, deflated and base64url-encoded: safe in a URL and in HTML.
    public func payload() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(self)
        guard let deflated = Self.deflate(json) else { throw ShareError.unreadable }
        return deflated.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Payloads larger than this aren't read (a meeting of several hours is a few hundred KB).
    static let maxPayload = 8_000_000
    /// Nor anything that inflates to more than this.
    static let maxJSON = 64_000_000

    public init(payload: String) throws {
        guard payload.utf8.count <= Self.maxPayload else { throw ShareError.tooLarge }
        var base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let deflated = Data(base64Encoded: base64), let json = Self.inflate(deflated, limit: Self.maxJSON) else {
            throw ShareError.unreadable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let meeting = try? decoder.decode(SharedMeeting.self, from: json), meeting.version == 1 else {
            throw ShareError.unreadable
        }
        self = meeting
    }

    private static func deflate(_ data: Data) -> Data? {
        // Deflated JSON is never larger than this for our input, plus a little for incompressible text.
        let capacity = data.count + data.count / 10 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return output.prefix(written)
    }

    /// Nil if it isn't deflated data, or inflates to `limit` bytes or more.
    private static func inflate(_ data: Data, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var output = Data(count: limit)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, limit,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < limit else { return nil }
        return output.prefix(written)
    }

    // MARK: - Import link

    public static let importHost = "import"

    /// `tinymuesli://import?data=<payload>`: adds the meeting, after asking.
    public func importURL() throws -> URL {
        var components = URLComponents()
        components.scheme = MeetingLink.scheme
        components.host = Self.importHost
        components.queryItems = [URLQueryItem(name: "data", value: try payload())]
        return components.url!
    }

    /// Whether a link is an import link, whatever it carries.
    public static func isImportLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == MeetingLink.scheme && url.host?.lowercased() == importHost
    }

    public init(importURL url: URL) throws {
        guard Self.isImportLink(url),
              let data = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value
        else { throw ShareError.unreadable }
        try self.init(payload: data)
    }

    /// The meeting in a page from `html()`, for adding a saved page by hand (`tinymuesli import`).
    public init(html: String) throws {
        let pattern = /tinymuesli:\/\/import\?data=([A-Za-z0-9_-]+)/
        guard let match = html.firstMatch(of: pattern) else { throw ShareError.unreadable }
        try self.init(payload: String(match.1))
    }

    // MARK: - Adding to a library

    /// Someone in this meeting besides the sharer, in order of first appearance.
    public var speakers: [String] { transcript.speakers }

    /// What the meeting is called: its title, else its app.
    public var name: String { title ?? transcript.app ?? "Meeting" }

    /// The meeting already in `store`, if this one was added before: same start and the same words.
    public func existing(in store: MeetingStore) -> URL? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let texts = transcript.segments.map(\.text)
        for folder in store.meetingFolders() {
            guard let start = MeetingStore.start(of: folder), abs(start.timeIntervalSince(transcript.start)) < 1,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(MeetingFiles.json)),
                  let document = try? decoder.decode(TranscriptDocument.self, from: data)
            else { continue }
            if document.segments.map(\.text) == texts { return folder }
        }
        return nil
    }

    /// Writes the meeting as a new folder in `store` (finished, so it can be named and tagged like
    /// any other), unless it's there already. Returns its folder.
    @discardableResult
    public func add(to store: MeetingStore) throws -> (folder: URL, added: Bool) {
        if let folder = existing(in: store) { return (folder, false) }
        let document = TranscriptDocument(start: transcript.start, end: transcript.end, app: transcript.app,
                                          language: transcript.language, segments: transcript.segments)
        let metadata = MeetingMetadata(start: document.start, end: document.end,
                                       title: title.flatMap { $0.isEmpty ? nil : $0 }, app: document.app, status: .done,
                                       language: document.language, speakers: document.speakers,
                                       tags: MeetingEditor.cleanTags(tags))
        let folder = try store.makeMeetingFolder(start: document.start, appName: document.app)
        do {
            try document.encoded().write(to: folder.appendingPathComponent(MeetingFiles.json), options: .atomic)
            let body = TranscriptRenderer.markdown(document.segments)
            let text = metadata.frontmatter() + (body.isEmpty ? "" : "\n" + body + "\n")
            try text.write(to: folder.appendingPathComponent(MeetingFiles.transcript), atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return (folder, true)
    }

    // MARK: - File

    /// A file name for the page: the meeting's name and date, without characters Finder refuses.
    public var fileName: String {
        let day = transcript.start.formatted(.iso8601.year().month().day())
        let cleaned = String(name.map { "/:\\".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "Meeting" : cleaned) \(day).html"
    }

    /// Writes the page into a fresh temporary folder, for sharing.
    public func writeTemporaryPage() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinyMuesli Shared", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try html().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
