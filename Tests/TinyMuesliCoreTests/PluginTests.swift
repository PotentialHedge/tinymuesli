import AVFAudio
import Foundation
import Testing
@testable import TinyMuesliCore

/// A throwaway plugin: a manifest and zsh scripts in a temporary folder. Scripts save the request
/// they got as `request.json` in the plugin folder, so tests can check it.
struct TestPlugin {
    let directory: URL
    let plugin: Plugin
    let settings: PluginSettings

    init(_ manifest: String, scripts: [String: String]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: directory.appendingPathComponent(PluginManifest.fileName))
        for (name, body) in scripts {
            try Data(body.utf8).write(to: directory.appendingPathComponent(name))
        }
        var plugin = Plugin(manifest: try PluginManifest.load(from: directory), directory: directory)
        plugin.logFolder = directory.appendingPathComponent("logs")
        self.plugin = plugin
        settings = PluginSettings(file: directory.appendingPathComponent("settings.json"),
                                  keychainService: "com.tinymuesli.tests.\(UUID().uuidString)")
    }

    func request() throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("request.json"))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct PluginManifestTests {
    func manifest(_ id: String, settings: String = "") -> Data {
        Data("""
            {"id": "\(id)", "name": "X", "contributes": {"agent": {"command": ["true"]}\(settings)}}
            """.utf8)
    }

    @Test func suggestsMultilingualTranscribersThatOfferEveryLanguage() async throws {
        func provider(_ id: String, multilingual: Bool, languages: [String]) throws -> PluginTranscriptionProvider {
            let manifest = try PluginManifest.decode(Data("""
                {"id": "\(id)", "name": "\(id)", "contributes": {"transcription": {"command": ["true"],
                 "multilingual": \(multilingual), "languages": ["\(languages.joined(separator: "\", \""))"]}}}
                """.utf8))
            return PluginTranscriptionProvider(plugin: Plugin(manifest: manifest, directory: URL(filePath: "/tmp")))!
        }
        let providers: [any TranscriptionProvider] = [
            TranscriptionProviders.apple,
            try provider("one-at-a-time", multilingual: false, languages: ["de-DE", "en-US"]),
            try provider("no-german", multilingual: true, languages: ["en-US", "fr-FR"]),
            try provider("mixes", multilingual: true, languages: ["de-DE", "en-GB", "fr-FR"]),
        ]
        // Regions don't matter: Swiss German and American English are German and English.
        let found = await TranscriptionProviders.multilingual(for: ["de-CH", "en-US"], among: providers)
        #expect(found.map(\.id) == ["mixes"])
    }

    @Test func checksIdsAndSettingNamespaces() throws {
        #expect(throws: Never.self) { try PluginManifest.decode(manifest("good-one")) }
        #expect(throws: PluginManifest.Problem.badID("Bad_ID")) { try PluginManifest.decode(manifest("Bad_ID")) }
        #expect(throws: PluginManifest.Problem.reservedID("apple")) { try PluginManifest.decode(manifest("apple")) }
        let outside = #", "configuration": {"properties": {"other.key": {"type": "string"}}}"#
        #expect(throws: PluginManifest.Problem.settingOutsideNamespace("other.key")) {
            try PluginManifest.decode(manifest("mine", settings: outside))
        }
        #expect(throws: PluginManifest.Problem.nothingContributed) {
            try PluginManifest.decode(Data(#"{"id": "x", "name": "X", "contributes": {}}"#.utf8))
        }
    }

    @Test func ordersSettingsLikeVSCode() throws {
        let m = try PluginManifest.decode(manifest("p", settings: """
            , "configuration": {"properties": {
              "p.b": {"type": "string"}, "p.a": {"type": "string"}, "p.z": {"type": "boolean", "order": 1}}}
            """))
        #expect(m.settings.map(\.key) == ["p.z", "p.a", "p.b"])
    }
}

@Suite struct PluginSettingsTests {
    let properties: [String: PluginManifest.Property] = [
        "p.model": .init(type: .string, default: .string("v2"), enum: [.string("v1"), .string("v2")]),
        "p.on": .init(type: .boolean, default: .bool(false)),
        "p.count": .init(type: .integer, minimum: 1, maximum: 10),
        "p.name": .init(type: .string),
    ]

    @Test func storesOnlyWhatDiffersFromTheDefault() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = PluginSettings(file: file)
        #expect(settings.value("p.model", properties["p.model"]!) == .string("v2"))
        try settings.set("p.model", .string("v1"), property: properties["p.model"]!)
        try settings.set("p.count", PluginSettings.parse("3", for: properties["p.count"]!), property: properties["p.count"]!)
        try settings.set("p.on", .bool(false), property: properties["p.on"]!)  // the default: not written
        #expect(settings.all() == ["p.model": .string("v1"), "p.count": .number(3)])
        #expect(try String(contentsOf: file, encoding: .utf8).contains(#""p.count" : 3"#))
        try settings.set("p.model", nil, property: properties["p.model"]!)
        #expect(settings.value("p.model", properties["p.model"]!) == .string("v2"))
    }

    @Test func rejectsValuesThatDontFit() throws {
        let settings = PluginSettings(file: FileManager.default.temporaryDirectory.appendingPathComponent("unused.json"))
        #expect(PluginSettings.parse("v3", for: properties["p.model"]!) == nil)
        #expect(PluginSettings.parse("11", for: properties["p.count"]!) == nil)
        #expect(PluginSettings.parse("2.5", for: properties["p.count"]!) == nil)
        #expect(PluginSettings.parse("yes", for: properties["p.on"]!) == .bool(true))
        #expect(throws: PluginSettings.Problem.self) { try settings.set("p.on", .string("x"), property: properties["p.on"]!) }
    }

    @Test func handEditedValuesOfTheWrongTypeFallBackToTheDefault() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"p.on": "yes please", "p.name": "Ann"}"#.utf8).write(to: file)
        let settings = PluginSettings(file: file)
        #expect(settings.value("p.on", properties["p.on"]!) == .bool(false))
        #expect(settings.value("p.name", properties["p.name"]!) == .string("Ann"))
    }

    @Test func secretsGoToTheKeychain() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        let settings = PluginSettings(file: file, keychainService: "com.tinymuesli.tests.\(UUID().uuidString)")
        let key = PluginManifest.Property(type: .string, secret: true)
        defer { settings.setSecret("p.key", nil) }
        try settings.set("p.key", .string("s3cret"), property: key)
        #expect(settings.value("p.key", key) == .string("s3cret"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite(.serialized) struct PluginRuntimeTests {
    static let transcribeManifest = """
        {"id": "fake", "name": "Fake", "contributes": {
          "transcription": {"command": ["/bin/zsh", "transcribe.sh"]},
          "configuration": {"properties": {"fake.greeting": {"type": "string", "default": "Hello"}}}}}
        """

    @Test func transcribesAFileThroughThePlugin() async throws {
        let test = try TestPlugin(Self.transcribeManifest, scripts: ["transcribe.sh": """
            read -r line; print -r -- "$line" > request.json
            greeting=$(print -r -- "$line" | /usr/bin/jq -r '.settings["fake.greeting"]')
            print -r -- '{"phrases": [{"start": 0.5, "end": 1.5, "text": "'$greeting' there"}]}'
            """])
        defer { test.remove() }
        let transcriber = PluginTranscriber(plugin: test.plugin, contribution: test.plugin.manifest.contributes.transcription!,
                                            language: "de-DE", detectLanguage: false)
        // A second of silence, fed as `transcribe(file:)` does.
        let stream = transcriber.makeStream { _ in }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        stream.append(buffer)
        let phrases = try await stream.finish()
        #expect(phrases.map(\.text) == ["Hello there"])
        // Words without timings are spread over the phrase.
        #expect(phrases[0].words.map(\.text) == ["Hello", " there"])
        #expect(phrases[0].words[1].start == 1.0)
        let request = try test.request()
        #expect(request["method"] as? String == "transcribe")
        #expect(request["language"] as? String == "de-DE")
        #expect(request["apiVersion"] as? Int == Plugin.apiVersion)
        let file = try #require(request["file"] as? String)
        #expect(file.hasSuffix(".m4a"))
        #expect(!FileManager.default.fileExists(atPath: file))  // deleted afterwards
    }

    @Test func streamsLiveAudioAndReadsPhrasesAsTheyCome() async throws {
        let manifest = """
            {"id": "live", "name": "Live", "contributes": {"transcription": {"command": ["/bin/zsh", "live.sh"], "live": true}}}
            """
        // Reads the header, counts the audio bytes until EOF, then says how many samples it got.
        let test = try TestPlugin(manifest, scripts: ["live.sh": """
            read -r line; print -r -- "$line" > request.json
            print -r -- '{"start": 0, "end": 0.1, "text": "started"}'
            bytes=$(/usr/bin/wc -c | /usr/bin/tr -d ' ')
            print -r -- '{"start": 1, "end": 2, "text": "'$(( bytes / 4 ))' samples"}'
            """])
        defer { test.remove() }
        let transcriber = PluginTranscriber(plugin: test.plugin, contribution: test.plugin.manifest.contributes.transcription!,
                                            language: "en-US", detectLanguage: true)
        let heard = Heard()
        let stream = transcriber.makeStream { heard.add($0.text) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        for _ in 0..<3 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            stream.append(buffer)
        }
        let phrases = try await stream.finish()
        #expect(phrases.map(\.text) == ["started", "14400 samples"])
        #expect(heard.texts == ["started", "14400 samples"])
        let request = try test.request()
        #expect(request["method"] as? String == "transcribeLive")
        #expect(request["sampleRate"] as? Double == 48000)
        #expect(request["detectLanguage"] as? Bool == true)
    }

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ text: String) { lock.withLock { list.append(text) } }
        var texts: [String] { lock.withLock { list } }
    }

    @Test func reportsWhatAFailingPluginSaid() async throws {
        let test = try TestPlugin(Self.transcribeManifest, scripts: ["transcribe.sh": """
            print -u2 "invalid API key"; exit 3
            """])
        defer { test.remove() }
        do {
            _ = try await test.plugin.call(["/bin/zsh", "transcribe.sh"], what: "test", request: [:], settings: test.settings)
            Issue.record("should have failed")
        } catch let error as PluginError {
            #expect(error == .failed(plugin: "Fake", status: 3, log: "invalid API key"))
        }
    }

    @Test func saysWhichProgramIsMissing() async throws {
        let test = try TestPlugin(Self.transcribeManifest, scripts: [:])
        defer { test.remove() }
        await #expect(throws: PluginError.notFound("no-such-program-xyz")) {
            try await test.plugin.call(["no-such-program-xyz"], what: "test", request: [:], settings: test.settings)
        }
        #expect(await PluginStore.missingPrograms([["no-such-program-xyz", "a"], ["/bin/zsh"], ["zsh"]]) == ["no-such-program-xyz"])
    }

    @Test func stopsAPluginThatTakesTooLong() async throws {
        let test = try TestPlugin(Self.transcribeManifest, scripts: ["slow.sh": "sleep 30"])
        defer { test.remove() }
        await #expect(throws: PluginError.timedOut(plugin: "Fake")) {
            try await test.plugin.call(["/bin/zsh", "slow.sh"], what: "test", request: [:], settings: test.settings,
                                       timeout: .milliseconds(300))
        }
    }

    /// A plugin is its own responsible process, so macOS doesn't let it use tinyMuesli's permissions.
    @Test func pluginsDontInheritTheAppsPermissions() async throws {
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
        let responsible = unsafeBitCast(symbol, to: Responsible.self)
        let test = try TestPlugin(Self.transcribeManifest, scripts: [:])
        defer { test.remove() }
        let process = try test.plugin.start(["/bin/sleep", "5"], what: "test")
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(responsible(process.pid) == process.pid)
        #expect(responsible(process.pid) != responsible(getpid()))
    }

    @Test func runsAgentsSuggestionsAndActions() async throws {
        let manifest = """
            {"id": "all", "name": "All", "contributes": {
              "agent": {"command": ["/bin/zsh", "agent.sh"]},
              "suggestions": {"command": ["/bin/zsh", "suggest.sh"]},
              "actions": [{"id": "send", "title": "Send", "command": ["/bin/zsh", "action.sh"]}]}}
            """
        let test = try TestPlugin(manifest, scripts: [
            "agent.sh": #"read -r line; print -r -- "$line" > request.json; print -r -- "$1 $TINYMUESLI_STATUS" > agent.txt"#,
            "suggest.sh": #"print -r -- '{"title": "Weekly Sync", "tags": ["team"]}'"#,
            "action.sh": #"print -r -- '{"message": "Sent", "open": "https://example.com/x"}'"#,
        ])
        defer { test.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("2026-11-04 1030 Zoom")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)

        let agent = try #require(PluginAgent(plugin: test.plugin, store: store))
        #expect(await agent.run(folder: folder, status: .done) == .exited(0))
        #expect(try String(contentsOf: test.directory.appendingPathComponent("agent.txt"), encoding: .utf8)
            == "\(folder.path) done\n")
        let meeting = try #require(try test.request()["meeting"] as? [String: Any])
        #expect(meeting["id"] as? String == "2026-11-04 1030 Zoom")

        let result = try await PluginAction(plugin: test.plugin, action: test.plugin.manifest.contributes.actions![0])
            .run(folder: folder, store: store)
        #expect(result == .init(message: "Sent", open: URL(string: "https://example.com/x")))
        #expect(PluginAction.result(from: Data("done\n".utf8)) == .init(message: "done", open: nil))

        // Suggestions need a finished transcript.
        let metadata = MeetingMetadata(start: .now, app: "Zoom", status: .done)
        try (metadata.frontmatter() + "\n**Me** [00:00:01] Hi.\n").write(to: folder.appendingPathComponent(MeetingFiles.transcript),
                                                                      atomically: true, encoding: .utf8)
        let suggestions = try await #require(PluginSuggestionProvider(plugin: test.plugin)).suggest(folder: folder, store: store)
        #expect(suggestions.title == "Weekly Sync" && suggestions.tags == ["team"])
        #expect(MeetingSuggestions.load(folder: folder)?.title == "Weekly Sync")
    }
}

@Suite struct PluginStoreTests {
    @Test func parsesSources() {
        #expect(PluginStore.Source("ann/tinymuesli-deepgram") == .github(owner: "ann", repo: "tinymuesli-deepgram", ref: nil))
        #expect(PluginStore.Source("https://github.com/ann/plug.git") == .github(owner: "ann", repo: "plug", ref: nil))
        #expect(PluginStore.Source("github.com/ann/plug@v1.2") == .github(owner: "ann", repo: "plug", ref: "v1.2"))
        #expect(PluginStore.Source("https://github.com/ann/plug/tree/dev") == .github(owner: "ann", repo: "plug", ref: "dev"))
        #expect(PluginStore.Source("/tmp/plug") == .local(URL(fileURLWithPath: "/tmp/plug")))
        #expect(PluginStore.Source("nonsense") == nil)
        #expect(PluginStore.Source("a/b c") == nil)
    }

    @Test func linksALocalPluginAndRemovesIt() async throws {
        let test = try TestPlugin(PluginRuntimeTests.transcribeManifest, scripts: [:])
        defer { test.remove() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginStore(root: root)
        let candidate = try await store.candidate(.local(test.directory))
        #expect(candidate.manifest.id == "fake" && candidate.replaces == nil)
        let installed = try await store.install(candidate)
        #expect(installed.install?.source == "local:\(test.directory.resolvingSymlinksInPath().path)")
        #expect(store.installed().map(\.id) == ["fake"])
        #expect(TranscriptionProviders.all(plugins: store.installed()).map(\.id) == ["apple", "fake"])
        // Installing again replaces it.
        _ = try await store.install(try await store.candidate(.local(test.directory)))
        #expect(store.installed().count == 1)
        try store.remove(installed, settings: test.settings)
        #expect(store.installed().isEmpty)
        #expect(FileManager.default.fileExists(atPath: test.directory.path))  // only the link went
    }

    @Test func unpacksAGitHubArchive() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let top = work.appendingPathComponent("src/ann-plug-abc1234")
        try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: top.appendingPathComponent(PluginManifest.fileName))
        let archive = work.appendingPathComponent("a.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", work.appendingPathComponent("src").path, "ann-plug-abc1234"]
        try tar.run()
        tar.waitUntilExit()
        let unpacked = try PluginStore.unpack(archive, into: work.appendingPathComponent("out"))
        #expect(unpacked.lastPathComponent == "ann-plug-abc1234")
        #expect(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent(PluginManifest.fileName).path))
    }
}
