import Foundation

/// Installed plugins, one folder each in `~/Library/Application Support/tinyMuesli/Plugins/<id>`, and
/// installing them from GitHub.
///
/// - **From GitHub:** the repository's `tinymuesli-plugin.json` is read at a fixed commit first (to show
///   what it does before anything is downloaded), then that commit's archive is unpacked. Nothing in
///   it runs while installing: no build step. Updating installs the branch's newest commit the same way.
/// - **Linked:** a local folder is linked rather than copied, for developing a plugin.
/// - **Discovery:** repositories with the GitHub topic `tinymuesli-plugin`.
///
/// The network is only used when you search, install or update.
public struct PluginStore: Sendable {
    public static let topic = "tinymuesli-plugin"
    public static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tinyMuesli/Plugins", isDirectory: true)

    public var root: URL
    var github: GitHub

    public init(root: URL = PluginStore.defaultRoot) {
        self.root = root
        self.github = GitHub()
    }

    // MARK: - Installed

    /// Plugins whose manifest loads; broken ones are skipped (see `problems()`).
    public func installed() -> [Plugin] {
        folders().compactMap { try? load($0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Folders that don't hold a valid plugin, and why.
    public func problems() -> [(folder: URL, problem: String)] {
        folders().compactMap { folder in
            do { _ = try load(folder); return nil } catch { return (folder, error.localizedDescription) }
        }
    }

    public func plugin(id: String) -> Plugin? {
        installed().first { $0.id == id }
    }

    private func folders() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        return contents.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    }

    func load(_ folder: URL) throws -> Plugin {
        let directory = folder.resolvingSymlinksInPath()
        let manifest = try PluginManifest.load(from: directory)
        let record = (try? Data(contentsOf: folder.appendingPathComponent(Plugin.InstallRecord.fileName))).flatMap {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Plugin.InstallRecord.self, from: $0)
        } ?? (directory != folder ? Plugin.InstallRecord(source: "local:\(directory.path)", installed: .now) : nil)
        return Plugin(manifest: manifest, directory: directory, install: record)
    }

    public func remove(_ plugin: Plugin, settings: PluginSettings = PluginSettings()) throws {
        let folder = root.appendingPathComponent(plugin.id)
        settings.removeSecrets(of: plugin.manifest)
        try FileManager.default.removeItem(at: folder)  // a linked plugin: only the link
    }

    // MARK: - Installing

    /// Where to install from: "owner/repo", "github.com/owner/repo", a GitHub URL (each optionally
    /// "@branch-or-tag"), or a local folder ("./my-plugin", "~/code/plugin", "/path").
    public enum Source: Sendable, Equatable {
        case github(owner: String, repo: String, ref: String?)
        case local(URL)

        public init?(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") || trimmed.hasPrefix(".") || trimmed.hasPrefix("~") {
                self = .local(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL)
                return
            }
            var rest = trimmed
            for prefix in ["https://", "http://", "www.", "github.com/"] where rest.lowercased().hasPrefix(prefix) {
                rest = String(rest.dropFirst(prefix.count))
            }
            var ref: String?
            if let at = rest.lastIndex(of: "@") {
                ref = String(rest[rest.index(after: at)...])
                rest = String(rest[..<at])
            }
            let parts = rest.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            // ".../tree/<branch>" in a pasted URL.
            if parts.count >= 4, parts[2] == "tree", ref == nil { ref = parts[3...].joined(separator: "/") }
            let valid = /[A-Za-z0-9_.-]+/
            guard parts[0].wholeMatch(of: valid) != nil, repo.wholeMatch(of: valid) != nil else { return nil }
            self = .github(owner: parts[0], repo: repo, ref: ref?.isEmpty == true ? nil : ref)
        }

        public var description: String {
            switch self {
            case .github(let owner, let repo, let ref): "\(owner)/\(repo)" + (ref.map { "@\($0)" } ?? "")
            case .local(let url): url.path
            }
        }
    }

    /// What would be installed, read before anything is downloaded, for the user to agree to.
    public struct Candidate: Sendable {
        public var manifest: PluginManifest
        public var source: Source
        /// The commit that will be installed (GitHub only).
        public var commit: String?
        /// Programs it runs that aren't installed (e.g. "python3").
        public var missingPrograms: [String]
        /// Installed already; installing replaces it.
        public var replaces: Plugin?

        public var commitURL: URL? {
            guard case .github(let owner, let repo, _) = source, let commit else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/tree/\(commit)")
        }
    }

    public func candidate(_ source: Source) async throws -> Candidate {
        let manifest: PluginManifest
        var commit: String?
        switch source {
        case .local(let url):
            manifest = try PluginManifest.load(from: url)
        case .github(let owner, let repo, let ref):
            let sha = try await github.commit(owner: owner, repo: repo, ref: ref)
            guard let data = try await github.file(owner: owner, repo: repo, commit: sha, path: PluginManifest.fileName) else {
                throw StoreError.noManifest("\(owner)/\(repo)")
            }
            manifest = try PluginManifest.decode(data)
            commit = sha
        }
        let missing = await Self.missingPrograms(manifest.commands.map(\.command))
        return Candidate(manifest: manifest, source: source, commit: commit, missingPrograms: missing,
                         replaces: plugin(id: manifest.id))
    }

    /// Installs what `candidate` described (the same commit, so what was agreed to is what's installed).
    @discardableResult
    public func install(_ candidate: Candidate) async throws -> Plugin {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(candidate.manifest.id)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }

        switch candidate.source {
        case .local(let url):
            try replace(destination) { try fm.createSymbolicLink(at: destination, withDestinationURL: url) }
        case .github(let owner, let repo, _):
            guard let commit = candidate.commit else { throw StoreError.noManifest("\(owner)/\(repo)") }
            let archive = try await github.archive(owner: owner, repo: repo, commit: commit)
            defer { try? fm.removeItem(at: archive) }
            let unpacked = try Self.unpack(archive, into: staging)
            let manifest = try PluginManifest.load(from: unpacked)
            guard manifest == candidate.manifest else { throw StoreError.changed }
            let record = Plugin.InstallRecord(source: "github:\(owner)/\(repo)", commit: commit, installed: .now)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: unpacked.appendingPathComponent(Plugin.InstallRecord.fileName))
            try replace(destination) { try fm.moveItem(at: unpacked, to: destination) }
        }
        return try load(destination)
    }

    /// Puts the new copy in place, keeping the old one until it's there.
    private func replace(_ destination: URL, with make: () throws -> Void) throws {
        let fm = FileManager.default
        let old = root.appendingPathComponent(".old-\(UUID().uuidString)")
        let existed = (try? destination.checkResourceIsReachable()) == true
            || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil
        if existed { try fm.moveItem(at: destination, to: old) }
        do {
            try make()
            if existed { try? fm.removeItem(at: old) }
        } catch {
            if existed { try? fm.moveItem(at: old, to: destination) }
            throw error
        }
    }

    /// Unpacks a GitHub archive (`.tar.gz` with one top folder) and returns that folder.
    static func unpack(_ archive: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // No absolute paths or "..": bsdtar refuses them by default; -P would allow them.
        tar.arguments = ["-xzf", archive.path, "-C", folder.path]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw StoreError.badArchive }
        let top = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath)
        guard top.count == 1 else { throw StoreError.badArchive }
        return top[0]
    }

    /// Programs (first words of commands) not found on the login PATH. Relative ones ("./run") are the plugin's own.
    static func missingPrograms(_ commands: [[String]]) async -> [String] {
        let programs = Set(commands.compactMap(\.first).filter { !$0.contains("/") })
        guard !programs.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "for p in \"$@\"; do command -v \"$p\" >/dev/null || print -r -- \"$p\"; done", "check"] + programs.sorted()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: - Discovery

    public struct Listing: Sendable, Identifiable, Equatable {
        public var owner: String
        public var repo: String
        public var description: String?
        public var stars: Int
        public var updated: Date?
        public var url: URL
        public var id: String { "\(owner)/\(repo)" }
    }

    /// Repositories tagged `tinymuesli-plugin`, most stars first, optionally matching `query`.
    public func search(_ query: String = "") async throws -> [Listing] {
        try await github.search(topic: Self.topic, query: query)
    }

    /// The newest commit of an installed GitHub plugin's branch, when it differs from the installed one.
    public func availableUpdate(for plugin: Plugin) async throws -> String? {
        guard let repository = plugin.install?.githubRepository, let source = Source(repository),
              case .github(let owner, let repo, let ref) = source else { return nil }
        let newest = try await github.commit(owner: owner, repo: repo, ref: ref)
        return newest == plugin.install?.commit ? nil : newest
    }

    public enum StoreError: Error, LocalizedError, CustomStringConvertible {
        case noManifest(String)
        case badArchive
        case changed
        case notFound(String)
        case github(Int, String)

        public var errorDescription: String? {
            switch self {
            case .noManifest(let repo): "\(repo) has no \(PluginManifest.fileName), so it isn't a tinyMuesli plugin."
            case .badArchive: "The plugin's download couldn't be unpacked."
            case .changed: "The plugin changed while it was downloading. Try again."
            case .notFound(let what): "GitHub has no public repository or branch \(what)."
            case .github(let status, let message): "GitHub answered \(status): \(message)"
            }
        }

        public var description: String { errorDescription ?? "Plugin store error" }
    }
}

/// The few GitHub API calls the store needs. Unauthenticated (60 requests an hour), which is plenty.
struct GitHub: Sendable {
    var api = URL(string: "https://api.github.com")!

    private func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("tinyMuesli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func json(_ url: URL) async throws -> Any {
        let (data, status) = try await get(url)
        guard status == 200 else {
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            throw PluginStore.StoreError.github(status, message ?? "")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// The commit `ref` (default: the default branch) points at.
    func commit(owner: String, repo: String, ref: String?) async throws -> String {
        let ref = ref ?? "HEAD"
        let encoded = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
        let object: Any
        do {
            object = try await json(api.appendingPathComponent("repos/\(owner)/\(repo)/commits/\(encoded)"))
        } catch PluginStore.StoreError.github(404, _), PluginStore.StoreError.github(422, _) {
            throw PluginStore.StoreError.notFound("\(owner)/\(repo)" + (ref == "HEAD" ? "" : "@\(ref)"))
        }
        guard let sha = (object as? [String: Any])?["sha"] as? String, sha.wholeMatch(of: /[0-9a-f]{40}/) != nil else {
            throw PluginStore.StoreError.github(200, "no commit for \(ref)")
        }
        return sha
    }

    /// A file at a commit, or nil if it isn't there.
    func file(owner: String, repo: String, commit: String, path: String) async throws -> Data? {
        let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(commit)/\(path)")!
        let (data, status) = try await get(url)
        if status == 404 { return nil }
        guard status == 200 else { throw PluginStore.StoreError.github(status, "") }
        return data
    }

    /// Downloads the commit's `.tar.gz` to a temporary file.
    func archive(owner: String, repo: String, commit: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://codeload.github.com/\(owner)/\(repo)/tar.gz/\(commit)")!)
        request.setValue("tinyMuesli", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw PluginStore.StoreError.github(status, "download failed") }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("tinymuesli-plugin-\(UUID().uuidString).tar.gz")
        try FileManager.default.moveItem(at: file, to: kept)
        return kept
    }

    func search(topic: String, query: String) async throws -> [PluginStore.Listing] {
        var components = URLComponents(url: api.appendingPathComponent("search/repositories"), resolvingAgainstBaseURL: false)!
        let terms = query.trimmingCharacters(in: .whitespaces)
        components.queryItems = [
            URLQueryItem(name: "q", value: "topic:\(topic)" + (terms.isEmpty ? "" : " \(terms)")),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "per_page", value: "50"),
        ]
        let object = try await json(components.url!)
        let items = (object as? [String: Any])?["items"] as? [[String: Any]] ?? []
        let dates = ISO8601DateFormatter()
        return items.compactMap { item in
            guard let name = item["name"] as? String, let owner = (item["owner"] as? [String: Any])?["login"] as? String,
                  let url = (item["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return PluginStore.Listing(owner: owner, repo: name, description: item["description"] as? String,
                                       stars: item["stargazers_count"] as? Int ?? 0,
                                       updated: (item["pushed_at"] as? String).flatMap(dates.date(from:)), url: url)
        }
    }
}
