import Foundation

/// Something that runs after a meeting's final pass: the user's shell hook, or an AI agent like
/// Claude Code that reads the meeting through tinyMuesli's MCP server and acts on it.
///
/// Agents are compiled in and listed in `MeetingAgents.all`; the hook always runs if it's installed,
/// the others when they're turned on in Settings › Assistants.
public protocol MeetingAgent: Sendable {
    /// Stable id, saved in settings, e.g. "claude-code".
    var id: String { get }
    var name: String { get }
    /// Where its output goes.
    var log: URL { get }
    /// Returns when it's done. `status` is `done`, or `failed` if transcription failed.
    func run(folder: URL, status: MeetingMetadata.Status) async -> AgentOutcome
}

public enum AgentOutcome: Sendable, Equatable {
    /// Its program isn't there (no hook, Claude Code not installed).
    case notInstalled
    /// Nothing to do for this meeting (e.g. an AI agent after a failed transcription).
    case skipped
    case exited(Int32)
    case couldNotLaunch(String)
}

public enum MeetingAgents {
    /// The agents that can be turned on in Settings (the hook needs no switch: installing it is the switch).
    public static func optional(binaryPath: String) -> [any MeetingAgent] {
        [ClaudeCodeAgent(binaryPath: binaryPath, prompt: Settings.claudeCodePrompt)]
    }

    /// What runs after a final pass: the hook, then each agent turned on.
    public static func enabled(binaryPath: String) -> [any MeetingAgent] {
        let on = Settings.enabledAgents
        return [MeetingEndHook()] + optional(binaryPath: binaryPath).filter { on.contains($0.id) }
    }

    public static let logFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/tinyMuesli")
}

/// Runs a program for a meeting, with its output appended to a log.
enum AgentProcess {
    static func environment(folder: URL, status: MeetingMetadata.Status) -> [String: String] {
        ["TINYMUESLI_MEETING_DIR": folder.path,
         "TINYMUESLI_TRANSCRIPT_MD": folder.appendingPathComponent(MeetingFiles.transcript).path,
         "TINYMUESLI_TRANSCRIPT_JSON": folder.appendingPathComponent(MeetingFiles.json).path,
         "TINYMUESLI_STATUS": status.rawValue]
    }

    static func run(executable: URL, arguments: [String], folder: URL, environment: [String: String],
                    log: URL) async -> AgentOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = openLog(log, for: folder)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: .exited($0.terminationStatus)) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .couldNotLaunch("\(error)"))
            }
        }
    }

    /// Appends to the log. A program still runs if the log can't be opened.
    private static func openLog(_ log: URL, for folder: URL) -> FileHandle {
        let fm = FileManager.default
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return .nullDevice }
        _ = try? handle.seekToEnd()
        let stamp = Date.now.formatted(.iso8601)
        try? handle.write(contentsOf: Data("--- \(stamp) \(folder.lastPathComponent)\n".utf8))
        return handle
    }
}
