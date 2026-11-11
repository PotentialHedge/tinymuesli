import Foundation

/// A plugin's `contributes.suggestions`. Request: `{"method": "suggest", "meeting": {…}, "transcript": "…markdown…",
/// "knownTitles": [...], "knownTags": [...], "myName": "…"}`. Answer: `{"title": "…", "tags": [...],
/// "speakers": [{"speaker": "Speaker 1", "name": "Ann", "quote": "Thanks, Ann"}]}`, each optional.
public struct PluginSuggestionProvider: SuggestionProvider {
    public let plugin: Plugin
    let command: [String]

    public init?(plugin: Plugin) {
        guard let command = plugin.manifest.contributes.suggestions?.command else { return nil }
        self.plugin = plugin
        self.command = command
    }

    public var id: String { plugin.id }
    public var name: String { plugin.name }
    public var isOnDevice: Bool { plugin.manifest.network != true }
    public var isAvailable: Bool { true }

    @discardableResult
    public func suggest(folder: URL, store: MeetingStore, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> MeetingSuggestions {
        let transcript = ChatTranscript.load(folder: folder)
        guard transcript.metadata?.status == .done else { throw MeetingSuggester.Failure.notTranscribed }
        let markdown = (try? String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcript), encoding: .utf8)) ?? ""
        let known = await Task.detached(priority: .utility) { MeetingSuggester(store: store, excluding: folder) }.value
        let request: [String: Any] = [
            "method": "suggest", "meeting": Plugin.meeting(folder, store: store, status: .done), "transcript": markdown,
            "knownTitles": known.knownTitles, "knownTags": known.knownTags, "myName": known.myName,
        ]
        let output = try await plugin.call(command, what: "suggest \(folder.lastPathComponent)", request: request,
                                           timeout: .seconds(600))
        struct Answer: Decodable {
            var title: String?
            var tags: [String]?
            var speakers: [MeetingSuggestions.SpeakerName]?
        }
        let answer: Answer
        do { answer = try JSONDecoder().decode(Answer.self, from: output) } catch {
            throw PluginError.badOutput(plugin: plugin.name, detail: "\(error)")
        }
        let suggestions = MeetingSuggestions(title: answer.title, tags: answer.tags ?? [], speakers: answer.speakers ?? [],
                                             created: .now)
        try suggestions.save(to: folder)
        return suggestions
    }
}

/// A plugin's `contributes.agent`, run after each meeting while it's turned on. Like the hook it gets
/// the meeting folder as its last argument and `TINYMUESLI_*` variables (its working directory is the
/// plugin's folder), plus a request on stdin: `{"method": "meetingEnded", "meeting": {…, "status": "done"}}`.
public struct PluginAgent: MeetingAgent {
    public let plugin: Plugin
    let command: [String]
    var store: MeetingStore

    public init?(plugin: Plugin, store: MeetingStore = MeetingStore()) {
        guard let command = plugin.manifest.contributes.agent?.command else { return nil }
        self.plugin = plugin
        self.command = command
        self.store = store
    }

    public var id: String { plugin.id }
    public var name: String { plugin.name }
    public var log: URL { plugin.log }

    public func run(folder: URL, status: MeetingMetadata.Status) async -> AgentOutcome {
        let request: [String: Any] = ["method": "meetingEnded", "meeting": Plugin.meeting(folder, store: store, status: status)]
        do {
            _ = try await plugin.call(command + [folder.path], what: "meetingEnded \(folder.lastPathComponent)", request: request,
                                      environment: AgentProcess.environment(folder: folder, status: status))
            return .exited(0)
        } catch PluginError.notFound {
            return .notInstalled
        } catch PluginError.failed(_, let status, _) {
            return .exited(status)
        } catch {
            return .couldNotLaunch(error.localizedDescription)
        }
    }
}

/// An item a plugin adds to a meeting's menu (`contributes.actions`). Request:
/// `{"method": "action", "action": "<id>", "meeting": {…}}`. It may answer `{"message": "Sent to Notion",
/// "open": "https://…"}` (both optional), or plain text, shown as the message.
public struct PluginAction: Sendable, Identifiable {
    public let plugin: Plugin
    public let action: PluginManifest.Action

    public init(plugin: Plugin, action: PluginManifest.Action) {
        self.plugin = plugin
        self.action = action
    }

    public var id: String { "\(plugin.id).\(action.id)" }
    public var title: String { action.title }

    public struct Result: Sendable, Equatable {
        public var message: String?
        public var open: URL?
    }

    public func run(folder: URL, store: MeetingStore = MeetingStore()) async throws -> Result {
        let request: [String: Any] = ["method": "action", "action": action.id, "meeting": Plugin.meeting(folder, store: store)]
        let output = try await plugin.call(action.command, what: "\(action.id) \(folder.lastPathComponent)", request: request,
                                           environment: AgentProcess.environment(folder: folder, status: .done),
                                           timeout: .seconds(600))
        return Self.result(from: output)
    }

    static func result(from output: Data) -> Result {
        if let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] {
            return Result(message: object["message"] as? String, open: (object["open"] as? String).flatMap(URL.init(string:)))
        }
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(message: text.isEmpty ? nil : String(text.prefix(1000)), open: nil)
    }
}
