import Foundation

/// Opens a chat about one meeting. The chat gets only a line naming the meeting; it reads the
/// meeting through tinyMuesli's MCP server, so no transcript goes into a URL.
public enum ChatHandoff {
    public enum Service: String, CaseIterable, Sendable {
        case claude, chatGPT

        public var name: String {
            switch self {
            case .claude: "Claude"
            case .chatGPT: "ChatGPT"
            }
        }

        /// The apps that read this service's MCP config, preferred first.
        public var bundleIdentifiers: [String] {
            switch self {
            case .claude: [ClaudeDesktopConfig.bundleIdentifier]
            case .chatGPT: CodexConfig.bundleIdentifiers
            }
        }

        /// Whether tinyMuesli's MCP server is in this service's config, so a chat there can read meetings.
        public var hasMCPServer: Bool {
            switch self {
            case .claude: ClaudeDesktopConfig.isInstalled()
            case .chatGPT: CodexConfig.isInstalled()
            }
        }

        /// The services that have tinyMuesli's MCP server.
        public static var withMCPServer: [Service] { allCases.filter(\.hasMCPServer) }

        /// The desktop app's link for a new chat. There's no web fallback: chatgpt.com and claude.ai
        /// can't reach tinyMuesli's local MCP server, so a chat there couldn't read the meeting. The
        /// ChatGPT app's `codex://` scheme is undocumented: it's the URL the app itself builds from a
        /// `chatgpt.com/?q=` link. Work mode is where it uses local tools from `~/.codex/config.toml`.
        var base: String {
            switch self {
            case .claude: "claude://claude.ai/new"
            case .chatGPT: "codex://threads/new"
            }
        }

        /// The query that carries the prompt, and any other the app needs.
        func query(prompt: String) -> [URLQueryItem] {
            switch self {
            case .claude: [URLQueryItem(name: "q", value: prompt)]
            case .chatGPT: [URLQueryItem(name: "prompt", value: prompt), URLQueryItem(name: "mode", value: "work")]
            }
        }

        /// A URL whose app, if one handles it, means the app is installed and takes chat links.
        public var appProbe: URL { URL(string: base)! }
    }

    /// Names the meeting the way you would (title, else app, and when it was) rather than by id,
    /// so the prompt reads like something you typed. The assistant finds it with list_meetings.
    public static func prompt(title: String?, app: String?, start: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = timeZone
        let name = title.map { "my meeting \"\($0)\"" } ?? app.map { "my \($0) meeting" } ?? "my meeting"
        return "Let's talk about \(name) from \(start.formatted(style)). You can read it with tinyMuesli."
    }

    public static func url(for service: Service, prompt: String) -> URL? {
        guard var components = URLComponents(string: service.base) else { return nil }
        components.queryItems = service.query(prompt: prompt)
        // URLQueryItem leaves "+" alone, which servers read as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = query
        return components.url
    }
}
