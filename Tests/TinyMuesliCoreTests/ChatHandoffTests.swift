import Foundation
import Testing
@testable import TinyMuesliCore

@Suite struct ChatHandoffTests {
    @Test func asksToReadTheMeetingThroughMCP() throws {
        let url = try #require(ChatHandoff.url(for: .chatGPT, meetingID: "2026/11/2026-11-04 1030 Zoom", title: "Q4 + roadmap", appInstalled: false))
        #expect(url.absoluteString.hasPrefix("https://chatgpt.com/?q="))
        #expect(!url.absoluteString.contains("+"))
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == ChatHandoff.prompt(meetingID: "2026/11/2026-11-04 1030 Zoom", title: "Q4 + roadmap"))
        #expect(q?.contains("get_transcript") == true)
    }

    @Test func opensTheClaudeAppWhenInstalled() throws {
        let app = try #require(ChatHandoff.url(for: .claude, meetingID: "a/b/c", title: nil, appInstalled: true))
        #expect(app.absoluteString.hasPrefix("claude://claude.ai/new?q="))
        let web = try #require(ChatHandoff.url(for: .claude, meetingID: "a/b/c", title: nil, appInstalled: false))
        #expect(web.absoluteString.hasPrefix("https://claude.ai/new?q="))
    }
}
