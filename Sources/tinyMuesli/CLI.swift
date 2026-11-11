import Foundation
import TinyMuesliCore

/// The same binary doubles as a CLI: `tinymuesli <command>` once installed (the cask and install.sh link
/// it onto the PATH), else `tinyMuesli.app/Contents/MacOS/tinyMuesli <command>`.
@MainActor
enum CLI {
    static let commands: Set<String> = ["mic-users", "mute-state", "record", "transcribe", "languages", "list", "show", "search", "speakers", "update", "suggest", "mcp", "help", "--help", "-h"]

    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "mic-users": return micUsers()
        case "mute-state": return muteState()
        case "record": return record(Array(args.dropFirst()))
        case "transcribe": return transcribe(Array(args.dropFirst()))
        case "languages": return languages()
        case "list": return list(Array(args.dropFirst()))
        case "show": return show(Array(args.dropFirst()))
        case "search": return search(Array(args.dropFirst()))
        case "speakers": return speakers(Array(args.dropFirst()))
        case "update": return update(Array(args.dropFirst()))
        case "suggest": return suggest(Array(args.dropFirst()))
        case "share": return share(Array(args.dropFirst()))
        case "import": return importShared(Array(args.dropFirst()))
        case "mcp": return mcp(Array(args.dropFirst()))
        case "help", "--help", "-h":
            print(usage)
            return 0
        default:
            _ = fail("tinymuesli: unknown command \"\(args.first ?? "")\"\n\n" + usage)
            return 2
        }
    }

    static let usage = """
        usage: tinymuesli <command>

          mic-users                 List processes using the microphone and the meeting app each maps to
          mute-state                Whether each running meeting app shows you as muted, and the buttons that say so
          record [--seconds N]      Record mic + system audio (default 10s) into a new meeting folder
                 [--root DIR]       Meetings root (default: the app's setting, else ~/Meetings)
                 [--no-transcribe]  Skip the transcription pass afterwards
          transcribe FOLDER         (Re)run transcription + speaker identification on a meeting folder
                 [--language TAG]   e.g. en-US, de-DE (default: the app's setting, else the system language)
                 [--no-diarize]     Label remote speech "Others" instead of Speaker 1..n
                 [--delete-audio]   Delete audio/ afterwards (kept by default here, so you can re-run)
          languages                 List transcription languages supported on this Mac
          list [--limit N]          List meetings, most recent first
          show MEETING              Print a meeting's transcript.md (MEETING: an id from list, or a folder)
          search QUERY [--limit N]  Find text in all transcripts
          speakers MEETING          A meeting's speakers, with the voice from another meeting each sounds like
          update MEETING            Change a finished meeting (what's left out stays as it is):
                 [--title TEXT]     Its title; "" removes it
                 [--tags A,B]       Replaces its tags; "" removes them
                 [--speaker OLD=NEW]  Renames a speaker; repeat for more. Two the same name are merged
          suggest MEETING           Ask Apple Intelligence for a title, tags and speaker names (saved
                                    as suggestions.json; nothing is changed until you update)
          share MEETING             Save a finished meeting as a web page to send: it shows the transcript, and
                 [--output FILE]    anyone with tinyMuesli can add the meeting from it ("Me" becomes your name)
                 [--name NAME]      The name for "Me" (default: your macOS account's full name)
          import PAGE               Add a meeting from a page made by share (or a tinymuesli://import link)
          mcp                       Run the MCP server on stdin/stdout

          list, show, search, speakers, update, suggest and import also take --json. All but record's options and
          mcp also take --root DIR.
        """

    /// Reads the same buttons the app does, to check mute detection during a call. Needs Accessibility
    /// access for the terminal it runs in.
    private static func muteState() -> Int32 {
        guard CallMute.isAllowed else {
            CallMute.requestAccess()
            print("Needs Accessibility access for this terminal: System Settings → Privacy & Security → Accessibility.")
            return 1
        }
        let running = MeetingApps.known.filter(CallMute.isRunning)
        if running.isEmpty { print("No meeting app is running.") }
        for app in running {
            let (labels, muted) = CallMute.explain(app)
            let verdict = switch muted {
            case true?: "muted"
            case false?: "not muted"
            case nil: "can't tell (recorded as not muted)"
            }
            print("\(app.name): \(verdict)")
            for (label, meaning) in labels { print("  \(meaning)\t\(label)") }
        }
        return 0
    }

    private static func micUsers() -> Int32 {
        do {
            let processes = try AudioProcesses.usingMicrophone()
            if processes.isEmpty { print("No process is using the microphone.") }
            for p in processes {
                let app = MeetingApps.match(bundleID: p.bundleID).map { "→ \($0.name)" } ?? "(not a meeting app)"
                print("\(p.pid)\t\(p.bundleID.isEmpty ? "-" : p.bundleID)\t\(p.name)\t\(app)")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    private static func record(_ args: [String]) -> Int32 {
        var seconds: TimeInterval = 10
        var transcribe = true
        var store = MeetingStore()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--seconds" where i + 1 < args.count:
                seconds = TimeInterval(args[i + 1]) ?? seconds
                i += 2
            case "--root" where i + 1 < args.count:
                store = MeetingStore(root: URL(fileURLWithPath: args[i + 1], isDirectory: true))
                i += 2
            case "--no-transcribe":
                transcribe = false
                i += 1
            default:
                print(usage)
                return 1
            }
        }

        var granted: Bool?
        Task { granted = await MicRecorder.requestPermission() }
        while granted == nil { RunLoop.main.run(until: .now + 0.1) }
        if granted == false { print("warning: no microphone permission; mic track will be silent") }

        do {
            let transcriber = transcribe ? wait { try? await AppleSpeechTranscriber.make(preferred: Settings.language) } : nil
            let speechDetector = Settings.skipSilence ? wait { try? await SileroSpeechDetector.load() } : nil
            let session = try RecordingSession(store: store, app: nil, transcriber: transcriber, speechDetector: speechDetector)
            try session.start()
            session.warnings.forEach { print("warning: \($0)") }
            print("Recording for \(Int(seconds))s into \(session.folder.path)")
            RunLoop.main.run(until: .now + seconds)
            session.stop()
            let captured = session.capturedSeconds()
            print(String(format: "Captured mic %.1fs, system %.1fs", captured.mic, captured.system))
            session.writeErrors().forEach { print("write error: \($0)") }
            guard let transcriber else { return 0 }

            print("Transcribing…")
            let processor = MeetingProcessor(transcriber: transcriber, diarizer: FluidDiarizer(), keepAudio: true)
            let folder = session.folder
            let result = try wait { () async throws -> MeetingProcessor.Result in
                let live = await session.finishLiveTranscription()
                return try await processor.process(folder: folder, live: live, log: { print($0) })
            }
            result.warnings.forEach { print("warning: \($0)") }
            print("Wrote \(result.document.segments.count) segments, speakers: \(result.document.speakers.joined(separator: ", "))")
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    private static func transcribe(_ args: [String]) -> Int32 {
        var folder: URL?
        var language: Locale? = Settings.language
        var diarize = true
        var keepAudio = true
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--language" where i + 1 < args.count:
                language = Locale(identifier: args[i + 1])
                i += 2
            case "--no-diarize":
                diarize = false
                i += 1
            case "--delete-audio":
                keepAudio = false
                i += 1
            case let arg where !arg.hasPrefix("-") && folder == nil:
                folder = URL(fileURLWithPath: arg, isDirectory: true)
                i += 1
            default:
                print(usage)
                return 1
            }
        }
        guard let folder else {
            print(usage)
            return 1
        }

        do {
            let started = Date()
            let (language, diarize, keepAudio) = (language, diarize, keepAudio)
            let result = try wait { () async throws -> MeetingProcessor.Result in
                let transcriber = try await AppleSpeechTranscriber.make(preferred: language)
                print("Language: \(transcriber.language)")
                let processor = MeetingProcessor(
                    transcriber: transcriber,
                    diarizer: diarize ? FluidDiarizer() : nil,
                    keepAudio: keepAudio
                )
                return try await processor.process(folder: folder, log: { print($0) })
            }
            result.warnings.forEach { print("warning: \($0)") }
            print(String(format: "Wrote %d segments in %.1fs, speakers: %@", result.document.segments.count,
                         Date().timeIntervalSince(started), result.document.speakers.joined(separator: ", ")))
            print(folder.appendingPathComponent(MeetingFiles.transcript).path)
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    private static func languages() -> Int32 {
        let locales = wait { await AppleSpeechTranscriber.offeredLocales() }
        for locale in locales {
            print("\(locale.identifier(.bcp47))\t\(Locale.current.localizedString(forIdentifier: locale.identifier) ?? "")")
        }
        return 0
    }

    // MARK: - Reading meetings

    private struct LibraryOptions {
        var positional: [String] = []
        var store = MeetingStore()
        /// Set with --root, rather than taken from the app's setting.
        var fixedRoot = false
        var limit: Int?
        var json = false

        init?(_ args: [String]) {
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--root" where i + 1 < args.count:
                    store = MeetingStore(root: URL(fileURLWithPath: args[i + 1], isDirectory: true))
                    fixedRoot = true
                    i += 2
                case "--limit" where i + 1 < args.count:
                    guard let value = Int(args[i + 1]), value >= 0 else { return nil }
                    limit = value
                    i += 2
                case "--json":
                    json = true
                    i += 1
                case let arg where !arg.hasPrefix("--"):
                    positional.append(arg)
                    i += 1
                default:
                    return nil
                }
            }
        }
    }

    private static func usageError() -> Int32 {
        fail(usage)
    }

    /// Errors go to stderr, so piping `--json` output never picks them up.
    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    private static func printJSON(_ value: some Encodable) -> Int32 {
        do {
            print(String(decoding: try MeetingLibrary.encoded(value), as: UTF8.self))
            return 0
        } catch {
            return fail("error: \(error)")
        }
    }

    private static func list(_ args: [String]) -> Int32 {
        guard let options = LibraryOptions(args), options.positional.isEmpty else { return usageError() }
        let meetings = MeetingLibrary(store: options.store).meetings(limit: options.limit ?? .max)
        if options.json { return printJSON(meetings) }
        for meeting in meetings {
            print("\(meeting.id)\t\(meeting.status)\t\(meeting.speakers.joined(separator: ", "))")
        }
        return 0
    }

    private static func show(_ args: [String]) -> Int32 {
        guard let options = LibraryOptions(args), options.positional.count == 1, options.limit == nil else { return usageError() }
        let reference = options.positional[0]
        let path = URL(fileURLWithPath: reference, isDirectory: true)
        let hasTranscript = FileManager.default.fileExists(atPath: path.appendingPathComponent(MeetingFiles.transcript).path)
        guard let folder = MeetingLibrary(store: options.store).folder(id: reference) ?? (hasTranscript ? path : nil) else {
            return fail("error: no meeting \"\(reference)\" (see tinymuesli list)")
        }
        let file = options.json ? MeetingFiles.json : MeetingFiles.transcript
        guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else {
            return fail("error: \(file) doesn't exist yet for this meeting")
        }
        print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        return 0
    }

    private static func search(_ args: [String]) -> Int32 {
        guard let options = LibraryOptions(args), options.positional.count == 1 else { return usageError() }
        let hits = MeetingLibrary(store: options.store).search(options.positional[0], limit: options.limit ?? 20)
        if options.json { return printJSON(hits) }
        for hit in hits {
            print("\(hit.meeting) [\(hit.timestamp)] \(hit.speaker): \(hit.excerpt)")
        }
        return 0
    }

    private static func speakers(_ args: [String]) -> Int32 {
        guard let options = LibraryOptions(args), options.positional.count == 1, options.limit == nil else { return usageError() }
        let speakers: [SpeakerInfo]
        do {
            speakers = try MeetingLibrary(store: options.store).speakers(id: options.positional[0])
        } catch {
            return fail("error: \(error.localizedDescription) (see tinymuesli list)")
        }
        if options.json { return printJSON(speakers) }
        for speaker in speakers {
            let match = speaker.suggestion.map { "\tsounds like \($0.name) (\(Int(($0.similarity * 100).rounded()))%)" } ?? ""
            print(speaker.name + match)
        }
        return 0
    }

    private static func update(_ args: [String]) -> Int32 {
        var title: String?
        var tags: [String]?
        var speakers: [String: String] = [:]
        var rest: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--title" where i + 1 < args.count:
                title = args[i + 1]
                i += 2
            case "--tags" where i + 1 < args.count:
                tags = args[i + 1].split(separator: ",").map(String.init)
                i += 2
            case "--speaker" where i + 1 < args.count:
                let pair = args[i + 1]
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    return fail("error: --speaker takes OLD=NEW, e.g. --speaker \"Speaker 1=Ann Lee\"")
                }
                speakers[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
                i += 2
            default:
                rest.append(args[i])
                i += 1
            }
        }
        guard let options = LibraryOptions(rest), options.positional.count == 1, options.limit == nil else { return usageError() }
        guard title != nil || tags != nil || !speakers.isEmpty else { return fail("error: nothing to change; see tinymuesli help") }
        let meeting: MeetingSummary
        do {
            meeting = try MeetingLibrary(store: options.store).update(id: options.positional[0], title: title, tags: tags, speakers: speakers)
        } catch {
            return fail("error: \(error.localizedDescription)")
        }
        if options.json { return printJSON(meeting) }
        print("\(meeting.title ?? "(no title)")\t\(meeting.tags.joined(separator: ", "))\t\(meeting.speakers.joined(separator: ", "))")
        return 0
    }

    private static func suggest(_ args: [String]) -> Int32 {
        guard let options = LibraryOptions(args), options.positional.count == 1, options.limit == nil else { return usageError() }
        guard let folder = MeetingLibrary(store: options.store).folder(id: options.positional[0]) else {
            return fail("error: no meeting \"\(options.positional[0])\" (see tinymuesli list)")
        }
        let suggester = MeetingSuggester(store: options.store, excluding: folder)
        let suggestions: MeetingSuggestions
        do {
            suggestions = try wait { try await suggester.suggest(folder: folder) { FileHandle.standardError.write(Data("note: \($0)\n".utf8)) } }
        } catch {
            return fail("error: \(error.localizedDescription)")
        }
        if options.json { return printJSON(suggestions) }
        print("title\t\(suggestions.title ?? "-")")
        print("tags\t\(suggestions.tags.joined(separator: ", "))")
        for speaker in suggestions.speakers {
            print("\(speaker.speaker)\tmaybe \(speaker.name)\t“\(speaker.quote)”")
        }
        return 0
    }

    private static func share(_ args: [String]) -> Int32 {
        var output: String?
        var name = NSFullUserName()
        var rest: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--output" where i + 1 < args.count:
                output = args[i + 1]
                i += 2
            case "--name" where i + 1 < args.count:
                name = args[i + 1]
                i += 2
            default:
                rest.append(args[i])
                i += 1
            }
        }
        guard let options = LibraryOptions(rest), options.positional.count == 1, options.limit == nil, !options.json else { return usageError() }
        guard let folder = MeetingLibrary(store: options.store).folder(id: options.positional[0]) else {
            return fail("error: no meeting \"\(options.positional[0])\" (see tinymuesli list)")
        }
        do {
            let shared = try SharedMeeting(folder: folder, sharedBy: name)
            let url = URL(fileURLWithPath: output ?? shared.fileName)
            try shared.html().write(to: url, atomically: true, encoding: .utf8)
            print(url.path)
            return 0
        } catch {
            return fail("error: \(error.localizedDescription)")
        }
    }

    private static func importShared(_ args: [String]) -> Int32 {
        guard let options = LibraryOptions(args), options.positional.count == 1, options.limit == nil else { return usageError() }
        let source = options.positional[0]
        do {
            let shared = if let url = URL(string: source), SharedMeeting.isImportLink(url) {
                try SharedMeeting(importURL: url)
            } else {
                try SharedMeeting(html: String(contentsOfFile: source, encoding: .utf8))
            }
            let result = try shared.add(to: options.store)
            let library = MeetingLibrary(store: options.store)
            if options.json, let summary = library.summary(of: result.folder) { return printJSON(summary) }
            print("\(result.added ? "added" : "already there")\t\(library.id(of: result.folder))")
            return 0
        } catch {
            return fail("error: \(error.localizedDescription)")
        }
    }

    private static func mcp(_ args: [String]) -> Int32 {
        guard let options = LibraryOptions(args), options.positional.isEmpty, options.limit == nil, !options.json else { return usageError() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // Without --root, follow the app's setting: a server outlives a change of folder.
        let root = options.fixedRoot ? { options.store.root } : { MeetingStore.configuredRoot }
        MCPServer(root: root, version: version).run()
        return 0
    }

    /// Runs async work from the synchronous CLI entry point, keeping the main run loop alive.
    private static func wait<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        while result == nil { RunLoop.main.run(until: .now + 0.05) }
        return try result!.get()
    }

    private static func wait<T>(_ work: @escaping @Sendable () async -> T) -> T {
        try! wait { () async throws -> T in await work() }
    }
}
