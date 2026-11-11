import Foundation
import Testing
@testable import TinyMuesliCore

@Suite struct ElevenLabsTests {
    func response(_ words: [(String, String, Double, Double)]) -> Data {
        let items = words.map { text, type, start, end in
            ["text": text, "type": type, "start": start, "end": end, "logprob": -0.1] as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: ["language_code": "en", "text": "", "words": items])
    }

    @Test func splitsPhrasesAtSentenceEndsAndPauses() throws {
        let data = response([
            ("Hi", "word", 0.0, 0.3), (" ", "spacing", 0.3, 0.35), ("there.", "word", 0.35, 0.8),
            (" ", "spacing", 0.8, 0.9), ("So", "word", 0.9, 1.1), (" ", "spacing", 1.1, 1.2),
            ("(laughs)", "audio_event", 1.2, 1.5), ("anyway", "word", 1.5, 1.9),
            ("next", "word", 4.0, 4.3),
        ])
        let phrases = try ElevenLabsTranscriber.phrases(fromResponse: data)
        #expect(phrases.map(\.text) == ["Hi there.", "So anyway", "next"])
        #expect(phrases[0].words.map(\.text) == ["Hi", " there."])
        #expect(phrases[1].start == 0.9 && phrases[1].end == 1.9)
        #expect(abs((phrases[0].words[0].confidence ?? 0) - exp(-0.1)) < 1e-9)
    }

    @Test func rejectsUnreadableResponses() {
        #expect(throws: ElevenLabsError.self) { try ElevenLabsTranscriber.phrases(fromResponse: Data("{}".utf8)) }
    }

    @Test func writesMultipartBody() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("a.m4a")
        try Data("AUDIO".utf8).write(to: audio)
        let body = dir.appendingPathComponent("body")
        try ElevenLabsTranscriber.writeMultipart(fields: ["model_id": "scribe_v2"], file: audio, boundary: "B", to: body)
        let text = try String(contentsOf: body, encoding: .utf8)
        #expect(text == "--B\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v2\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nAUDIO\r\n--B--\r\n")
    }
}

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
