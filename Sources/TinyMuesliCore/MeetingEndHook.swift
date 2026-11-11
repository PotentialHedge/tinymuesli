import Foundation

/// Runs the user's `on-meeting-end` executable after a meeting's final pass.
///
/// It gets the meeting folder as its argument and working directory, and `TINYMUESLI_*` environment
/// variables. Its output goes to a log file. Nothing waits for it, so a slow hook holds nothing up.
public struct MeetingEndHook: MeetingAgent {
    public let id = "hook"
    public let name = "on-meeting-end hook"
    public var executable: URL
    public var log: URL

    public typealias Outcome = AgentOutcome

    public init(
        executable: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tinymuesli/hooks/on-meeting-end"),
        log: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/tinyMuesli/on-meeting-end.log")
    ) {
        self.executable = executable
        self.log = log
    }

    /// Returns when the hook exits.
    public func run(folder: URL, status: MeetingMetadata.Status) async -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .notInstalled }
        return await AgentProcess.run(executable: executable, arguments: [folder.path], folder: folder,
                                      environment: AgentProcess.environment(folder: folder, status: status), log: log)
    }
}
