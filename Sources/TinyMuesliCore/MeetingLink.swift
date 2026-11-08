import Foundation

/// `tinymuesli://meeting?id=<meeting id>` opens the Meetings window on that meeting, for launchers
/// and scripts (`open "tinymuesli://meeting?id=2026/11/2026-11-04%201030%20Zoom"`).
public enum MeetingLink {
    public static let scheme = "tinymuesli"
    static let host = "meeting"

    public static func url(for id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }

    /// The meeting id in a link, or nil if it isn't a meeting link.
    public static func id(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme, components.host?.lowercased() == host,
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty
        else { return nil }
        return id
    }
}
