import Foundation

/// Opens a chat about one meeting. The chat gets only the meeting's id and a request to read it
/// through tinyMuesli's MCP server, so no transcript goes into a URL.
public enum ChatHandoff {
    public enum Service: String, CaseIterable, Sendable {
        case claude, chatGPT

        public var name: String {
            switch self {
            case .claude: "Claude"
            case .chatGPT: "ChatGPT"
            }
        }

        /// The Claude app, which has tinyMuesli's MCP server, if it's installed; else the web.
        func base(appInstalled: Bool) -> String {
            switch self {
            case .claude: appInstalled ? "claude://claude.ai/new" : "https://claude.ai/new"
            case .chatGPT: "https://chatgpt.com/"
            }
        }
    }

    public static func prompt(meetingID: String, title: String?) -> String {
        let name = title.map { "\"\($0)\" (id \(meetingID))" } ?? "with id \(meetingID)"
        return "I want to talk about my meeting \(name). Read it with tinyMuesli's MCP tools (get_transcript), then let's chat about it."
    }

    public static func url(for service: Service, meetingID: String, title: String?, appInstalled: Bool) -> URL? {
        guard var components = URLComponents(string: service.base(appInstalled: appInstalled)) else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: prompt(meetingID: meetingID, title: title))]
        // URLQueryItem leaves "+" alone, which servers read as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = query
        return components.url
    }
}
