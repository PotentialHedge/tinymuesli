import Foundation

/// Asks Claude Code (`claude -p`, headless) to act on a finished meeting. It gets tinyMuesli's MCP
/// server for this run, so it can read the meeting and set its title, tags and speaker names, and
/// whatever else the user's own Claude Code setup gives it (other MCP servers, allowed tools, skills).
///
/// `claude` is found through a login shell, so it's the same one the user runs in Terminal, signed in
/// the same way.
public struct ClaudeCodeAgent: MeetingAgent {
    public let id = "claude-code"
    public let name = "Claude Code"
    /// The tinyMuesli binary, for the MCP server.
    public var binaryPath: String
    /// What to ask; the meeting's id and paths are added after it.
    public var prompt: String
    public var store: MeetingStore
    public var log: URL

    public init(binaryPath: String, prompt: String, store: MeetingStore = MeetingStore(),
                log: URL = MeetingAgents.logFolder.appendingPathComponent("claude-code.log")) {
        self.binaryPath = binaryPath
        self.prompt = prompt
        self.store = store
        self.log = log
    }

    public static let defaultPrompt = """
        A meeting recorded by tinyMuesli just finished. Read its transcript with tinyMuesli's \
        get_transcript tool. If it has no title, tags or names for its speakers yet, set them with \
        update_meeting where the transcript makes them clear (don't guess names). Then reply with a \
        short summary: what was decided, and a to-do list with who does what.
        """

    /// The exit status `zsh -lc` gives when `claude` isn't on the login PATH.
    static let notFound: Int32 = 127

    public func run(folder: URL, status: MeetingMetadata.Status) async -> AgentOutcome {
        guard status == .done else { return .skipped }
        let outcome = await AgentProcess.run(
            executable: URL(fileURLWithPath: "/bin/zsh"), arguments: arguments(folder: folder), folder: folder,
            environment: AgentProcess.environment(folder: folder, status: status), log: log)
        return outcome == .exited(Self.notFound) ? .notInstalled : outcome
    }

    /// `zsh -lc 'exec claude "$@"' tinymuesli <claude's arguments>`: the arguments are passed as-is,
    /// never parsed by the shell.
    func arguments(folder: URL) -> [String] {
        let mcp: [String: Any] = ["mcpServers": ["tinymuesli": [
            "command": binaryPath, "args": ["mcp", "--root", store.root.path]]]]
        let mcpJSON = (try? JSONSerialization.data(withJSONObject: mcp, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ["-lc", "command -v claude >/dev/null || exit \(Self.notFound); exec claude \"$@\"", "tinymuesli",
                "-p", fullPrompt(folder: folder),
                "--mcp-config", mcpJSON,
                "--allowedTools", "mcp__tinymuesli",
                "--output-format", "text"]
    }

    func fullPrompt(folder: URL) -> String {
        let id = MeetingLibrary(store: store).id(of: folder)
        return """
            \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))

            Meeting id (for tinyMuesli's tools): \(id)
            Meeting folder: \(folder.path)
            Transcript: \(folder.appendingPathComponent(MeetingFiles.transcript).path)
            """
    }
}
