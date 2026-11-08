import Foundation

/// An MCP server over the meeting files. It reads transcripts, and can set a meeting's title,
/// tags and speaker names (nothing else is ever changed or deleted): one JSON-RPC message per line on stdin and stdout.
///
/// Written by hand because a few dozen lines of JSON don't justify a dependency in an app that
/// counts its megabytes. It has tools only, no prompts or resources.
///
/// The meetings folder is looked up on every tool call, so a server an agent started earlier
/// follows the folder when it's changed in the app, and says so once.
public final class MCPServer {
    private let root: () -> URL
    public var version: String
    /// The folder the last tool call used.
    private var lastRoot: URL?

    /// Newest first. We use nothing that differs between these, so any of them works.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Always serves `library`'s folder.
    public convenience init(library: MeetingLibrary, version: String = "0") {
        let root = library.store.root
        self.init(root: { root }, version: version)
    }

    /// `root` is asked for the meetings folder before each tool call.
    public init(root: @escaping () -> URL, version: String = "0") {
        self.root = root
        self.version = version
    }

    /// A note for the agent when the folder changed since the last tool call. Ids are relative
    /// to the folder, so they keep working; paths it saw earlier don't.
    private func folderChangeNotice(now current: URL) -> String? {
        defer { lastRoot = current }
        guard let lastRoot, lastRoot.standardizedFileURL.path != current.standardizedFileURL.path else { return nil }
        func name(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
        return "Note: the meetings folder has moved from \(name(lastRoot)) to \(name(current)) since your last call. "
            + "Meeting ids still work; file paths from earlier results are out of date."
    }

    /// Handles one incoming line. Returns the line to send back; notifications get none.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return encoded(error: -32700, "Parse error", id: NSNull())
        }
        guard let message = parsed as? [String: Any], let method = message["method"] as? String else {
            return encoded(error: -32600, "Invalid request", id: (parsed as? [String: Any])?["id"] ?? NSNull())
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        do {
            return encoded(["jsonrpc": "2.0", "id": id, "result": try result(method: method, params: params)])
        } catch let error as RPCError {
            return encoded(error: error.code, error.message, id: id)
        } catch {
            return encoded(error: -32603, "\(error)", id: id)
        }
    }

    /// Runs until stdin closes.
    public func run() {
        while let line = readLine() {
            guard !line.isEmpty, let response = handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }

    private struct RPCError: Error {
        var code: Int
        var message: String
    }

    /// Bad arguments or a missing meeting: reported to the model as a tool result, so it can recover.
    private struct ToolError: Error {
        var message: String
    }

    private func result(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "tinymuesli", "version": version],
                "instructions": Self.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
                throw RPCError(code: -32602, message: "Unknown tool")
            }
            let current = root()
            let notice = folderChangeNotice(now: current)
            func content(_ text: String) -> [[String: String]] {
                [["type": "text", "text": text]] + (notice.map { [["type": "text", "text": $0]] } ?? [])
            }
            do {
                let text = try call(tool: name, arguments: params["arguments"] as? [String: Any] ?? [:],
                                    library: MeetingLibrary(store: MeetingStore(root: current)))
                return ["content": content(text), "isError": false]
            } catch let error as ToolError {
                return ["content": content(error.message), "isError": true]
            }
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(tool: String, arguments: [String: Any], library: MeetingLibrary) throws -> String {
        switch tool {
        case "list_meetings":
            return try json(library.meetings(limit: arguments["limit"] as? Int ?? 20))
        case "search_transcripts":
            guard let query = arguments["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError(message: "query is required")
            }
            return try json(library.search(query, limit: arguments["limit"] as? Int ?? 20))
        case "get_transcript":
            guard let id = arguments["meeting"] as? String else { throw ToolError(message: "meeting is required") }
            guard let folder = library.folder(id: id) else {
                throw ToolError(message: "No meeting with id \"\(id)\". list_meetings gives the ids.")
            }
            let format = arguments["format"] as? String ?? "markdown"
            guard format == "markdown" || format == "json" else { throw ToolError(message: "format must be markdown or json") }
            let file = format == "json" ? MeetingFiles.json : MeetingFiles.transcript
            guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else {
                throw ToolError(message: "\(file) doesn't exist for this meeting yet. It's written when the final pass finishes; markdown is available during the meeting.")
            }
            // JSON stays parseable; the markdown gets a note about what's missing.
            guard format == "markdown" else { return text }
            return text + (Self.curationNote(folder: folder, id: id, library: library).map { "\n\n---\n" + $0 } ?? "")
        case "update_meeting":
            guard let id = arguments["meeting"] as? String else { throw ToolError(message: "meeting is required") }
            var speakers: [String: String] = [:]
            for (old, new) in arguments["speakers"] as? [String: Any] ?? [:] {
                guard let new = new as? String else { throw ToolError(message: "Speaker names must be strings.") }
                speakers[old] = new
            }
            do {
                return try json(library.update(id: id, title: arguments["title"] as? String,
                                               tags: arguments["tags"] as? [String], speakers: speakers))
            } catch MeetingLibrary.UpdateError.noMeeting(let id) {
                throw ToolError(message: "No meeting with id \"\(id)\". list_meetings gives the ids.")
            } catch let error as MeetingLibrary.UpdateError {
                throw ToolError(message: error.localizedDescription)
            } catch let error as MeetingEditor.EditError {
                throw ToolError(message: error.localizedDescription)
            }
        default:
            throw ToolError(message: "Unknown tool \(tool)")
        }
    }

    /// Asks the agent to fill in what's missing: a title, tags, names for "Speaker n". Voices
    /// recognised from other meetings and names already in use are listed, so names stay consistent.
    static func curationNote(folder: URL, id: String, library: MeetingLibrary) -> String? {
        guard let summary = library.summary(of: folder), summary.status == "done" else { return nil }
        let unnamed = summary.speakers.filter(VoiceMatcher.isPlaceholder)
        var missing: [String] = []
        if summary.title == nil { missing.append("a title") }
        if summary.tags.isEmpty { missing.append("tags") }
        if !unnamed.isEmpty { missing.append("names for \(unnamed.joined(separator: ", "))") }
        guard !missing.isEmpty else { return nil }

        let list = missing.count > 1 ? missing.dropLast().joined(separator: ", ") + " and " + missing.last! : missing[0]
        var lines = ["Note from tinyMuesli: this meeting is missing \(list). "
            + "If the transcript or the user makes them clear, set them with update_meeting(meeting: \"\(id)\", …), "
            + "and tell the user what you set. Only name a speaker when you're confident (people often name each other in greetings); otherwise ask the user."]
        let suggestions = VoiceMatcher(store: library.store).suggestions(for: folder)
        if !suggestions.isEmpty {
            lines.append("Voices recognised from earlier meetings: " + suggestions.map {
                "\($0.speaker) sounds like \($0.name) (\(Int(($0.similarity * 100).rounded()))% match)"
            }.joined(separator: "; ") + ".")
        }
        let names = knownNames(library: library)
        if !unnamed.isEmpty, !names.isEmpty {
            lines.append("Names used in other meetings (reuse the same spelling): \(names.prefix(30).joined(separator: ", ")).")
        }
        let tags = knownTags(library: library)
        if summary.tags.isEmpty, !tags.isEmpty {
            lines.append("Tags in use (prefer these): \(tags.prefix(30).joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }

    /// Speaker names given in any meeting, most frequent first.
    public static func knownNames(library: MeetingLibrary) -> [String] {
        ranked(library.meetings().flatMap { $0.speakers.filter { $0 != SpeakerLabel.me && !VoiceMatcher.isPlaceholder($0) } })
    }

    public static func knownTags(library: MeetingLibrary) -> [String] {
        ranked(library.meetings().flatMap(\.tags))
    }

    private static func ranked(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try MeetingLibrary.encoded(value), as: UTF8.self)
    }

    private func encoded(error code: Int, _ message: String, id: Any) -> String? {
        encoded(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encoded(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static let instructions = """
        tinyMuesli records and transcribes the user's meetings on their Mac. Each meeting has a title, tags \
        and speaker names, which start out empty ("Speaker 1", "Speaker 2"…; "Me" is the user). Whenever you \
        read a meeting and can tell what it was about or who spoke, fill them in with update_meeting: a short \
        title, a few lowercase tags (reuse existing ones), and real names for the speakers. Names you set \
        let tinyMuesli recognise those voices in later meetings. Only name people you're confident about, \
        and tell the user what you changed.
        """

    nonisolated(unsafe) private static let tools: [[String: Any]] = [
        tool("list_meetings", "List recorded meetings, most recent first, with their id, time, title, app, tags, speakers and status. A status of \"recording\" means the meeting is in progress.", properties: [
            "limit": ["type": "integer", "description": "How many to return (default 20)"],
        ]),
        tool("get_transcript", "Read a meeting's transcript. While a meeting is in progress, markdown is available and remote speech is labelled \"Others\".", properties: [
            "meeting": ["type": "string", "description": "Meeting id from list_meetings"],
            "format": ["type": "string", "enum": ["markdown", "json"], "description": "markdown (default): frontmatter and readable turns. json: timed segments."],
        ], required: ["meeting"]),
        tool("search_transcripts", "Find text in all transcripts, ignoring case and accents. Returns the meeting id, speaker, position and surrounding text of each match, newest meetings first.", properties: [
            "query": ["type": "string", "description": "Text to find"],
            "limit": ["type": "integer", "description": "How many matches to return (default 20)"],
        ], required: ["query"]),
        tool("update_meeting", "Set a finished meeting's title, tags and speaker names. Do this whenever you've read a meeting and can tell what it was about or who the speakers are, and tell the user what you set. Names are written into the transcript, and named voices are recognised in later meetings. Renaming two speakers to the same name merges them.", properties: [
            "meeting": ["type": "string", "description": "Meeting id from list_meetings"],
            "title": ["type": "string", "description": "A short title, e.g. \"Q4 roadmap with Ann\". An empty string removes it."],
            "tags": ["type": "array", "items": ["type": "string"], "description": "Replaces the tags. Short and lowercase, e.g. [\"roadmap\", \"acme\"]; reuse tags from other meetings."],
            "speakers": ["type": "object", "additionalProperties": ["type": "string"], "description": "Current name to new name, e.g. {\"Speaker 1\": \"Ann Lee\"}. \"Me\" can't be renamed."],
        ], required: ["meeting"], readOnly: false),
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String] = [],
                             readOnly: Bool = true) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": readOnly ? ["readOnlyHint": true]
                : ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
        ]
    }
}
