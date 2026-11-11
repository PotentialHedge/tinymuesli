import Foundation
import Testing
@testable import TinyMuesliCore


@Suite struct ClaudeCodeAgentTests {
    @Test func passesPromptAndMCPServerWithoutTheShellParsingThem() {
        let root = URL(fileURLWithPath: "/tmp/Meetings", isDirectory: true)
        let agent = ClaudeCodeAgent(binaryPath: "/Apps/tinyMuesli", prompt: "Summarise $(rm -rf ~)",
                                    store: MeetingStore(root: root))
        let args = agent.arguments(folder: root.appendingPathComponent("2026-11-04 1030 Zoom"))
        #expect(args[0] == "-lc")
        #expect(!args[1].contains("Summarise"))  // the script is fixed; the prompt is an argument
        let prompt = args[args.firstIndex(of: "-p")! + 1]
        #expect(prompt.hasPrefix("Summarise $(rm -rf ~)"))
        #expect(prompt.contains("Meeting id (for tinyMuesli's tools): 2026-11-04 1030 Zoom"))
        let mcp = args[args.firstIndex(of: "--mcp-config")! + 1]
        #expect(mcp == #"{"mcpServers":{"tinymuesli":{"args":["mcp","--root","/tmp/Meetings"],"command":"/Apps/tinyMuesli"}}}"#)
        #expect(args[args.firstIndex(of: "--allowedTools")! + 1] == "mcp__tinymuesli")
    }

    @Test func skipsFailedMeetings() async {
        let agent = ClaudeCodeAgent(binaryPath: "/x", prompt: "p")
        #expect(await agent.run(folder: URL(fileURLWithPath: "/tmp"), status: .failed) == .skipped)
    }
}
