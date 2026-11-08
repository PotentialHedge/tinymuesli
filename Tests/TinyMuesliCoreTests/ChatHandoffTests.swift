import Foundation
import Testing
@testable import TinyMuesliCore

@Suite struct ChatHandoffTests {
    let start = ISO8601DateFormatter().date(from: "2026-11-07T14:01:00Z")!
    let utc = TimeZone(identifier: "UTC")!

    @Test func namesTheMeetingByTitleOrApp() {
        let titled = ChatHandoff.prompt(title: "ETH RC Sync", app: "Discord", start: start, timeZone: utc)
        #expect(titled.hasPrefix("Let's talk about my meeting \"ETH RC Sync\" from "))
        #expect(titled.contains("14:01") || titled.contains("2:01"))
        #expect(titled.hasSuffix("You can read it with tinyMuesli."))
        #expect(ChatHandoff.prompt(title: nil, app: "Zoom", start: start, timeZone: utc).hasPrefix("Let's talk about my Zoom meeting from "))
    }

    @Test func putsThePromptInTheURL() throws {
        let url = try #require(ChatHandoff.url(for: .chatGPT, prompt: "Q4 + roadmap", appInstalled: false))
        #expect(url.absoluteString == "https://chatgpt.com/?q=Q4%20%2B%20roadmap")
    }

    @Test func opensTheChatGPTAppWhenInstalled() throws {
        let app = try #require(ChatHandoff.url(for: .chatGPT, prompt: "Q4 + roadmap", appInstalled: true))
        #expect(app.absoluteString == "codex://threads/new?prompt=Q4%20%2B%20roadmap&mode=work")
        #expect(ChatHandoff.Service.chatGPT.appProbe.scheme == "codex")
        #expect(ChatHandoff.Service.claude.appProbe.scheme == "claude")
    }

    @Test func opensTheClaudeAppWhenInstalled() throws {
        let app = try #require(ChatHandoff.url(for: .claude, prompt: "hi", appInstalled: true))
        #expect(app.absoluteString == "claude://claude.ai/new?q=hi")
        let web = try #require(ChatHandoff.url(for: .claude, prompt: "hi", appInstalled: false))
        #expect(web.absoluteString == "https://claude.ai/new?q=hi")
    }
}
