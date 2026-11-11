import Foundation

/// An installed plugin: its folder (with `tinymuesli-plugin.json`) and where it came from.
///
/// Plugins are programs, never code loaded into tinyMuesli. Each call starts the program with a
/// JSON request on stdin and reads its answer from stdout (see `docs/plugins.md`), so a plugin can
/// be written in any language and a crash only fails that call.
public struct Plugin: Sendable, Identifiable, Equatable {
    /// Bumped when requests or answers change incompatibly; sent to every call.
    public static let apiVersion = 1

    public var manifest: PluginManifest
    public var directory: URL
    public var install: InstallRecord?
    /// Where its log goes.
    public var logFolder = MeetingAgents.logFolder.appendingPathComponent("plugins")
    public var id: String { manifest.id }
    public var name: String { manifest.name }

    public init(manifest: PluginManifest, directory: URL, install: InstallRecord? = nil) {
        self.manifest = manifest
        self.directory = directory
        self.install = install
    }

    /// Its stderr, and a line per call.
    public var log: URL {
        logFolder.appendingPathComponent("\(id).log")
    }

    /// Where an installed plugin came from, saved as `.install.json` in its folder.
    public struct InstallRecord: Codable, Sendable, Equatable {
        /// "github:owner/repo", or "local:/path" for one linked while developing it.
        public var source: String
        /// The commit installed (GitHub only).
        public var commit: String?
        public var installed: Date

        public static let fileName = ".install.json"

        public var githubRepository: String? {
            source.hasPrefix("github:") ? String(source.dropFirst("github:".count)) : nil
        }
    }

    // MARK: - Calling

    /// Runs `command` with `request` (plus the plugin's settings) as JSON on stdin, and returns stdout.
    func call(_ command: [String], what: String, request: [String: Any], settings: PluginSettings = PluginSettings(),
              environment: [String: String] = [:], timeout: Duration? = nil) async throws -> Data {
        let process = try start(command, what: what, environment: environment)
        var body = request
        body["settings"] = settings.values(for: manifest).mapValues(\.any)
        body["apiVersion"] = Self.apiVersion
        let json = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
        process.write(json + Data("\n".utf8))
        process.closeInput()

        let timer = timeout.map { limit in
            Task.detached {
                try await Task.sleep(for: limit)
                process.timedOut = true
                process.terminate()
            }
        }
        defer { timer?.cancel() }
        let output: Data = await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: process.readAll()) }
        }
        let status = await process.waitForExit()
        if process.timedOut { throw PluginError.timedOut(plugin: name) }
        try check(status: status, command: command, process: process)
        return output
    }

    /// Starts `command` in the plugin's folder, noting the call in its log.
    func start(_ command: [String], what: String, environment: [String: String] = [:]) throws -> PluginProcess {
        appendToLog("--- \(Date.now.formatted(.iso8601)) \(what)\n")
        let logOffset = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        let env = environment.merging([
            "TINYMUESLI_PLUGIN_DIR": directory.path,
            "TINYMUESLI_API_VERSION": String(Self.apiVersion),
        ]) { old, _ in old }
        let process = try PluginProcess(command: command, directory: directory, environment: env, log: log)
        process.logOffset = logOffset
        return process
    }

    func check(status: Int32, command: [String], process: PluginProcess) throws {
        guard status != 0 else { return }
        if status == 127 { throw PluginError.notFound(command.first ?? "") }
        throw PluginError.failed(plugin: name, status: status, log: recentLog(since: process.logOffset))
    }

    /// What the plugin wrote to stderr during a call, for error messages.
    func recentLog(since offset: Int, limit: Int = 400) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? "…" + text.suffix(limit) : text
    }

    func appendToLog(_ text: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// A meeting as plugins see it.
    static func meeting(_ folder: URL, store: MeetingStore, status: MeetingMetadata.Status? = nil) -> [String: Any] {
        var meeting: [String: Any] = [
            "id": MeetingLibrary(store: store).id(of: folder),
            "folder": folder.path,
            "transcript": folder.appendingPathComponent(MeetingFiles.transcript).path,
            "transcriptJSON": folder.appendingPathComponent(MeetingFiles.json).path,
        ]
        if let status { meeting["status"] = status.rawValue }
        return meeting
    }
}
