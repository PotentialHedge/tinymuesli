import AppKit
import Foundation
import TinyMuesliCore
import Observation
import os

@MainActor
@Observable
final class AppModel {
    enum Status {
        case idle
        /// A meeting app is on the mic and we've asked whether to record.
        case detected(MeetingApp)
        /// `following`: the meeting app whose leaving the mic ends the recording (nil: manual stop only).
        case recording(RecordingSession, following: MeetingApp?)
    }

    /// A meeting whose app left the mic less than `continueWindow` ago. Its capture is paused rather
    /// than finished, so if another meeting starts soon after (a dropped call, a meeting that moved
    /// to another link), it can continue in the same folder. Finished when the window runs out, or
    /// as soon as another recording starts.
    struct EndedMeeting {
        let session: RecordingSession
        let finishesAt: Date
    }

    private(set) var status: Status = .idle
    private(set) var ended: EndedMeeting?
    /// Some other app (meeting app or not) is using the mic.
    private(set) var micInUse = false
    private(set) var lastError: String?
    private(set) var recentMeetings: [MeetingSummary] = []
    /// Bundle IDs of apps the user wants recorded without asking.
    private(set) var alwaysRecord: Set<String>
    /// How many meetings are being moved to a newly chosen folder.
    private(set) var movingMeetings: Int?
    /// Meeting folders whose final pass (transcription, speaker ID) is running.
    private(set) var processing: Set<URL> = []
    /// Transcription languages this Mac supports (loaded at launch).
    private(set) var languages: [Locale] = []
    /// BCP-47 tag, nil = system default.
    var language: String? = Settings.language?.identifier(.bcp47) {
        didSet { Settings.language = language.map(Locale.init(identifier:)) }
    }
    /// The picker's entries: one per language rather than one per regional variant.
    var languageChoices: [LanguageChoice] {
        LanguageChoice.choices(from: languages, selected: language)
    }
    /// Regional variants of the chosen language, when there's more than one to choose from.
    var languageVariants: [LanguageChoice.Variant] {
        let variants = languageChoices.first { $0.tag == language }?.variants ?? []
        return variants.count > 1 ? variants : []
    }
    var keepAudio = Settings.keepAudio {
        didSet { Settings.keepAudio = keepAudio }
    }
    var suggestWithAppleIntelligence = Settings.suggestWithAppleIntelligence {
        didSet {
            Settings.suggestWithAppleIntelligence = suggestWithAppleIntelligence
            if suggestWithAppleIntelligence { suggestForEarlierMeetings() }
        }
    }
    var skipSilence = Settings.skipSilence {
        didSet {
            Settings.skipSilence = skipSilence
            if skipSilence { loadSpeechDetector() }
        }
    }

    /// Don't record your mic while the call app shows you as muted (needs Accessibility access).
    var followCallMute = Settings.followCallMute {
        didSet {
            Settings.followCallMute = followCallMute
            applyMute()
        }
    }
    /// "Mute Me" in the menu: your mic records silence until turned off again. Per recording.
    var muteMe = false {
        didSet { applyMute() }
    }
    /// The call app shows you as muted (see `CallMute`).
    private(set) var callMuted = false
    /// Accessibility access, which following the call's mute needs. Updated by the poll.
    private(set) var muteAccessAllowed = CallMute.isAllowed
    /// Your mic is recording silence right now.
    var micMuted: Bool { muteMe || (followCallMute && callMuted) }

    /// A meeting is being recorded, paused, processed or moved, so the app shouldn't quit for an update.
    var isBusy: Bool { quitBlocker != nil }

    /// What quitting now would cut off, most important first (nil: nothing, quit away).
    enum QuitBlocker {
        /// Recording, or paused and waiting to be continued. Stopping it keeps everything recorded.
        case recording(paused: Bool)
        /// Moving meetings to another folder. Quitting part-way leaves them split between the two.
        case moving
        /// A final pass. Quitting stops it, and it starts over at the next launch.
        case processing
    }

    var quitBlocker: QuitBlocker? {
        if isRecording { return .recording(paused: false) }
        if ended != nil { return .recording(paused: true) }
        if movingMeetings != nil { return .moving }
        if !processing.isEmpty { return .processing }
        return nil
    }

    /// Readies everything for quitting now: stops the recording (and a paused one), so their audio
    /// is complete and their final pass runs at the next launch, and deletes meetings that were
    /// waiting for their final pass to finish first.
    func prepareToQuit() {
        stopRecording(notify: false)
        finishEndedMeeting()
        for folder in pendingDeletion { trash(folder) }
        pendingDeletion = []
    }

    private(set) var store = MeetingStore()
    /// A gap shorter than this (a device switch, a reconnect) doesn't interrupt the recording at all.
    /// A longer one pauses it, and the meeting app coming back prompts to continue.
    @ObservationIgnored private var detector = MeetingDetector(gracePeriod: 5)
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    /// What the last poll saw, so only changes get logged.
    @ObservationIgnored private var lastMicUsers: [String] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.tinymuesli.tinyMuesli", category: "detection")
    @ObservationIgnored private let notifications = NotificationController()
    /// Shared so the CoreML models stay loaded between meetings.
    @ObservationIgnored private let diarizer = FluidDiarizer()
    /// For `skipSilence`. nil until its model has loaded; until then meetings record everything.
    @ObservationIgnored private var speechDetector: SpeechDetectorFactory?
    @ObservationIgnored private var loadingSpeechDetector = false
    /// A `CallMute` check is running (it walks another app's UI, so it runs off the main thread).
    @ObservationIgnored private var checkingMute = false

    private static let alwaysRecordKey = "alwaysRecord"
    static let continueWindow: TimeInterval = 5 * 60

    init() {
        alwaysRecord = Set(UserDefaults.standard.stringArray(forKey: Self.alwaysRecordKey) ?? [])
        notifications.onAction = { [weak self] action in self?.handle(action) }
        notifications.setUp()
        if skipSilence { loadSpeechDetector() }
        refreshRecentMeetings()
        startPolling()
        Task {
            languages = await AppleSpeechTranscriber.offeredLocales()
            resumeUnfinishedMeetings()
            suggestForEarlierMeetings()
        }
    }

    // MARK: - Detection

    /// Polling every 2s is cheap (a handful of property reads) and simpler than
    /// juggling Core Audio listeners on every process object.
    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func poll() {
        let processes = (try? AudioProcesses.usingMicrophone()) ?? []
        if micInUse != !processes.isEmpty { micInUse = !processes.isEmpty }
        // Persisted (notice level) so a meeting that didn't start or stop can be explained afterwards:
        // log show --last 1d --predicate 'subsystem == "com.tinymuesli.tinyMuesli"'
        let micUsers = processes.map { "\($0.bundleID) (\($0.pid))" }.sorted()
        if micUsers != lastMicUsers {
            lastMicUsers = micUsers
            log.notice("Mic users: \(micUsers.isEmpty ? "none" : micUsers.joined(separator: ", "), privacy: .public)")
        }
        let apps = MeetingApps.active(in: processes)
        for event in detector.update(activeApps: apps, now: .now) {
            log.notice("Detector: \(String(describing: event), privacy: .public)")
            handle(event)
        }
        checkCallMute()
    }

    // MARK: - Muting

    /// Reads the call app's mute button, so what you say while muted isn't recorded.
    private func checkCallMute() {
        let allowed = CallMute.isAllowed
        if muteAccessAllowed != allowed { muteAccessAllowed = allowed }
        guard followCallMute, allowed, !checkingMute, case .recording(let session, let following) = status,
              let app = following ?? detector.current
        else { return }
        checkingMute = true
        Task {
            let muted = await Task.detached { CallMute.isMuted(in: app) }.value
            checkingMute = false
            // The recording may have ended (or another started) while the check ran.
            guard case .recording(let current, _) = status, current === session else { return }
            setCallMuted(muted ?? false)
        }
    }

    private func setCallMuted(_ muted: Bool) {
        guard callMuted != muted else { return }
        callMuted = muted
        applyMute()
    }

    private func applyMute() {
        guard case .recording(let session, _) = status, session.micMuted != micMuted else { return }
        session.micMuted = micMuted
        log.notice("Mic track \(self.micMuted ? "muted" : "unmuted", privacy: .public)")
    }

    func requestMuteAccess() {
        if !CallMute.requestAccess() { NSWorkspace.shared.open(CallMute.settingsURL) }
    }

    private func handle(_ event: MeetingDetector.Event) {
        switch event {
        case .started(let app):
            if case .recording = status { return }
            // Shortly after a meeting ended, ask even for "always record" apps: this may be that
            // meeting carrying on.
            if alwaysRecord.contains(app.id), ended == nil {
                startRecording(app: app)
            } else {
                status = .detected(app)
                notifications.promptToRecord(app, previous: ended.map { Self.title(of: $0.session) })
            }

        case .ended(let app):
            notifications.removePrompt()
            switch status {
            case .recording(let session, let following) where following == app:
                pause(session)
            case .detected:
                status = .idle
            default:
                break
            }
        }
    }

    private func handle(_ action: NotificationController.Action) {
        switch action {
        case .record(let appID):
            guard case .detected(let app) = status, app.id == appID else { return }
            startRecording(app: app)
        case .alwaysRecord(let appID):
            setAlwaysRecord(appID, true)
            if case .detected(let app) = status, app.id == appID { startRecording(app: app) }
        case .continueMeeting(let appID):
            guard case .detected(let app) = status, app.id == appID else { return }
            // The window may have run out since the prompt was shown: then record it anew.
            if ended != nil { continueMeeting() } else { startRecording(app: app) }
        case .resumeMeeting(let folder):
            if let ended, Self.samePath(ended.session.folder, folder) {
                continueMeeting()
            } else if !isRecording {
                // Too late to continue that one (the notice is updated when the window closes, but
                // may have been answered just before): record anew rather than ignore the click.
                startRecording(app: detector.current)
                lastError = "That meeting had already finished, so this is a new recording."
            }
        case .openMeeting(let folder):
            guard FileManager.default.fileExists(atPath: folder.path) else {
                lastError = "\(folder.lastPathComponent) isn't there any more. It may have been moved or deleted."
                return
            }
            NSWorkspace.shared.open(folder)
        case .deleteMeeting(let folder):
            confirmDelete(folder)
        case .switchLanguage:
            acceptLanguageSuggestion()
        case .keepLanguage:
            declineLanguageSuggestion()
        }
    }

    // MARK: - Recording

    var currentApp: MeetingApp? {
        switch status {
        case .idle: nil
        case .detected(let app): app
        case .recording(_, let following): following
        }
    }

    func startRecording(app: MeetingApp?) {
        if case .recording = status { return }
        notifications.removePrompt()
        finishEndedMeeting()  // starting afresh: the ended meeting won't be continued
        Task {
            guard await MicRecorder.requestPermission() else {
                lastError = "tinyMuesli needs microphone access. Enable it in System Settings → Privacy & Security → Microphone."
                return
            }
            // Without a transcriber we still record; the final pass will report the problem.
            let transcriber = try? await AppleSpeechTranscriber.make(preferred: language.map(Locale.init(identifier:)))
            do {
                if skipSilence, speechDetector == nil { loadSpeechDetector() }  // for the next meeting
                let session = try RecordingSession(store: store, app: app, transcriber: transcriber,
                                                   speechDetector: skipSilence ? speechDetector : nil)
                session.offeredLanguages = languages
                session.onLanguageSuggestion = { [weak self, weak session] suggestion in
                    guard let self, let session else { return }
                    self.suggest(suggestion, in: session)
                }
                try session.start()
                lastError = session.warnings.first
                muteMe = false
                callMuted = false
                status = .recording(session, following: app)
                applyMute()
                refreshRecentMeetings()
                // Fetch the diarization models now (first time only) so they're ready at the end.
                Task { [diarizer] in try? await diarizer.prepare() }
            } catch {
                lastError = "\(error)"
            }
        }
    }

    /// Fetches the speech detection model (first time only) and keeps it loaded.
    private func loadSpeechDetector() {
        guard speechDetector == nil, !loadingSpeechDetector else { return }
        loadingSpeechDetector = true
        Task {
            defer { loadingSpeechDetector = false }
            do {
                speechDetector = try await SileroSpeechDetector.load()
            } catch {
                lastError = "Couldn't load speech detection, so silence is recorded as usual: \(error)"
            }
        }
    }

    /// - Parameter notify: post the "meeting ended" notice (not when the next meeting starts at once).
    func stopRecording(notify: Bool = true) {
        guard case .recording(let session, _) = status else { return }
        if notify { notifyEnded(session, continuable: false) }
        finish(session)
        // If the meeting app is still on the mic, offer to record it again (without a new prompt).
        status = detector.current.map(Status.detected) ?? .idle
    }

    /// Ends the current recording and starts another, for when one meeting runs into the next.
    func startNewMeeting() {
        stopRecording(notify: false)
        startRecording(app: detector.current)
    }

    /// Carries on recording the meeting that ended in the last `continueWindow`.
    func continueMeeting() {
        guard let session = ended?.session, !isRecording else { return }
        notifications.removePrompt()
        notifications.removeMeetingEnded(folder: session.folder)
        clearEndedMeeting()
        do {
            try session.resume()
            log.notice("Continuing recording of \(session.folder.lastPathComponent, privacy: .public)")
            lastError = session.warnings.last
            callMuted = false  // until the next check
            status = .recording(session, following: detector.current)
            applyMute()
        } catch {
            finish(session)
            startRecording(app: detector.current)
            lastError = "Couldn't continue the meeting, so this is a new one. \(error)"
        }
    }

    /// Finishes the ended meeting now instead of waiting for the window to run out.
    func finishEndedMeeting() {
        guard let session = ended?.session else { return }
        clearEndedMeeting()
        // It can't be continued any more: take that option off its notice, without showing it again.
        notifyEnded(session, continuable: false, quietly: true)
        finish(session)
    }

    /// The meeting app left the mic: pause, and finish only if nothing continues it in time.
    private func pause(_ session: RecordingSession) {
        finishEndedMeeting()  // can't be set while recording, but never strand one
        log.notice("Pausing recording of \(session.folder.lastPathComponent, privacy: .public)")
        session.pause()
        status = .idle
        ended = EndedMeeting(session: session, finishesAt: .now + Self.continueWindow)
        notifyEnded(session, continuable: true)
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.continueWindow))
            guard !Task.isCancelled, let self else { return }
            finishEndedMeeting()
            // An "always record" app that started meanwhile was only asked about; nobody answered.
            if case .detected(let app) = status, alwaysRecord.contains(app.id) { startRecording(app: app) }
        }
    }

    private func clearEndedMeeting() {
        finishTask?.cancel()
        finishTask = nil
        ended = nil
    }

    private func finish(_ session: RecordingSession) {
        if languageSuggestion?.session === session { clearLanguageSuggestion() }
        log.notice("Stopping recording of \(session.folder.lastPathComponent, privacy: .public)")
        session.stop()
        lastError = session.warnings.last
        refreshRecentMeetings()
        process(session.folder) { await session.finishLiveTranscription() }
    }

    private var isRecording: Bool {
        if case .recording = status { true } else { false }
    }

    private func notifyEnded(_ session: RecordingSession, continuable: Bool, quietly: Bool = false) {
        let length = Self.length((session.pausedAt ?? .now).timeIntervalSince(session.startedAt))
        notifications.meetingEnded(Self.title(of: session), folder: session.folder, length: length,
                                   continuableUntil: continuable ? ended?.finishesAt : nil, quietly: quietly)
    }

    // MARK: - Language

    /// A track of the current meeting sounds like it's in another language; waiting for an answer.
    private(set) var languageSuggestion: (suggestion: LanguageSuggestion, session: RecordingSession)?

    private func suggest(_ suggestion: LanguageSuggestion, in session: RecordingSession) {
        guard case .recording(let current, _) = status, current === session else { return }
        languageSuggestion = (suggestion, session)
        let language = Self.languageName(suggestion.language)
        let currentName = session.language(of: suggestion.track).map(Self.languageName) ?? "another language"
        let who = suggestion.track == .mic ? "You seem" : "The others seem"
        notifications.suggestLanguage(
            title: "\(who) to be speaking \(language)",
            body: "The transcript is in \(currentName). Switch to \(language)? It's redone from \(TranscriptRenderer.timestamp(suggestion.from))."
        )
    }

    /// Menu wording for the pending suggestion, e.g. "Switch Others to German".
    var languageSuggestionTitle: String? {
        languageSuggestion.map { pending in
            let who = pending.suggestion.track == .mic ? "Me" : "Others"
            return "Switch \(who) to \(Self.languageName(pending.suggestion.language))"
        }
    }

    func acceptLanguageSuggestion() {
        guard let pending = languageSuggestion else { return }
        pending.session.switchLanguage(pending.suggestion)
        clearLanguageSuggestion()
    }

    func declineLanguageSuggestion() {
        guard let pending = languageSuggestion else { return }
        pending.session.decline(pending.suggestion)
        clearLanguageSuggestion()
    }

    private func clearLanguageSuggestion() {
        languageSuggestion = nil
        notifications.removeLanguageSuggestion()
    }

    /// The language the current meeting is transcribed in (your track's), for the menu.
    var meetingLanguage: String? {
        guard case .recording(let session, _) = status else { return nil }
        return session.language(of: .mic)
    }

    /// Transcribes the current meeting in `language` from now on, both tracks.
    func switchMeetingLanguage(to language: String) {
        guard case .recording(let session, _) = status else { return }
        clearLanguageSuggestion()
        session.switchLanguage(to: language)
    }

    /// "German" for "de-CH": the variant rarely matters to say which language it is.
    static func languageName(_ tag: String) -> String {
        let code = Locale.Language(identifier: tag).languageCode?.identifier ?? tag
        return Locale.current.localizedString(forLanguageCode: code) ?? tag
    }

    // MARK: - Deleting

    /// Meetings to delete once their final pass is done (it's still reading and writing the folder).
    private(set) var pendingDeletion: Set<URL> = []

    /// Asks first: a deleted meeting can only be got back from the Trash.
    func confirmDelete(_ folder: URL) {
        // "Zoom from 7 Nov 2026 at 10:30"
        let name = MeetingStore.start(of: folder).map {
            "\(MeetingStore.displayName(of: folder, start: $0)) from \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? folder.lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(name)”?"
        alert.informativeText = "Its transcript and any audio are moved to the Trash."
        let delete = alert.addButton(withTitle: "Delete Meeting")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteMeeting(folder)
    }

    /// Stops it if it's still being recorded or can be continued, then moves it to the Trash.
    func deleteMeeting(_ folder: URL) {
        notifications.removeMeetingEnded(folder: folder)
        var session: RecordingSession?
        if let ended, Self.samePath(ended.session.folder, folder) {
            session = ended.session
            clearEndedMeeting()
        } else if case .recording(let current, _) = status, Self.samePath(current.folder, folder) {
            session = current
            status = detector.current.map(Status.detected) ?? .idle
        }
        if let processingFolder = processing.first(where: { Self.samePath($0, folder) }) {
            pendingDeletion.insert(processingFolder)
            return
        }
        guard let session else { return trash(folder) }
        // No final pass; just let live transcription let go of the folder first.
        session.stop()
        Task {
            _ = await session.finishLiveTranscription()
            trash(folder)
        }
    }

    private func trash(_ folder: URL) {
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            lastError = "Couldn't delete \(folder.lastPathComponent): \(error.localizedDescription)"
        }
        refreshRecentMeetings()
    }

    /// How menus and prompts name a meeting, e.g. "Zoom from 10:30".
    static func title(of session: RecordingSession) -> String {
        "\(session.appName ?? "Meeting") from \(session.startedAt.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Folders

    /// Something still writes to the meeting's folder (recording, waiting to be continued, the
    /// final pass, a pending delete), so it mustn't move.
    func isInUse(_ folder: URL) -> Bool {
        var busy = processing.map(Self.path) + pendingDeletion.map(Self.path)
        if case .recording(let session, _) = status { busy.append(Self.path(session.folder)) }
        if let ended { busy.append(Self.path(ended.session.folder)) }
        let path = Self.path(folder)
        return busy.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// Moves meetings and folders into a folder of the meetings folder ("" for the folder itself).
    /// Returns where each one went; ones in use or that failed stay, with an alert.
    func move(_ items: [URL], into parent: String) -> [URL: URL] {
        var moved: [URL: URL] = [:]
        var problems: [String] = []
        for item in items {
            if isInUse(item) {
                problems.append(MeetingStore.isMeeting(item)
                    ? "“\(item.lastPathComponent)” is still being recorded or transcribed. Move it once it's done."
                    : "“\(item.lastPathComponent)” has a meeting that's still being recorded or transcribed. Move it once that's done.")
                continue
            }
            do {
                let target = try store.moveItem(item, into: parent)
                if target != item { moved[item] = target }
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        refreshRecentMeetings()
        if !problems.isEmpty { showFolderError("Couldn't Move", problems.joined(separator: "\n\n")) }
        return moved
    }

    /// Returns the new folder's path, or nil (after an alert) if it couldn't be made.
    func createFolder(named name: String, in parent: String) -> String? {
        do {
            return try store.createFolder(named: name, in: parent)
        } catch {
            showFolderError("Couldn't Make the Folder", error.localizedDescription)
            return nil
        }
    }

    /// Returns the folder's new path, or nil (after an alert) if it couldn't be renamed.
    func renameFolder(_ path: String, to name: String) -> String? {
        let folder = store.url(ofFolder: path)
        guard !isInUse(folder) else {
            showFolderError("Couldn't Rename", "“\(folder.lastPathComponent)” has a meeting that's still being recorded or transcribed. Rename it once that's done.")
            return nil
        }
        do {
            let renamed = try store.renameFolder(path, to: name)
            refreshRecentMeetings()
            return renamed
        } catch {
            showFolderError("Couldn't Rename", error.localizedDescription)
            return nil
        }
    }

    /// Asks first, saying how many meetings go with it; returns whether it went to the Trash.
    @discardableResult
    func confirmDeleteFolder(_ path: String) -> Bool {
        let folder = store.url(ofFolder: path)
        guard !isInUse(folder) else {
            showFolderError("Couldn't Delete", "“\(folder.lastPathComponent)” has a meeting that's still being recorded or transcribed. Delete it once that's done.")
            return false
        }
        let count = store.meetings(inFolder: path).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(folder.lastPathComponent)”?"
        alert.informativeText = switch count {
        case 0: "The folder is moved to the Trash."
        case 1: "The folder and the meeting in it, with its transcript and any audio, are moved to the Trash."
        default: "The folder and the \(count) meetings in it, with their transcripts and any audio, are moved to the Trash."
        }
        let delete = alert.addButton(withTitle: count == 0 ? "Delete Folder" : "Delete Folder and Meetings")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        for meeting in store.meetings(inFolder: path) { notifications.removeMeetingEnded(folder: meeting) }
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } catch {
            showFolderError("Couldn't Delete", error.localizedDescription)
            return false
        }
        refreshRecentMeetings()
        return true
    }

    private func showFolderError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Final pass

    /// Transcribes (what wasn't done live) and identifies speakers, then tidies up the folder.
    private func process(_ folder: URL, live: @escaping @MainActor () async -> [Track: [Phrase]] = { [:] }) {
        guard !processing.contains(folder) else { return }
        processing.insert(folder)
        let (language, keepAudio, diarizer) = (language, keepAudio, diarizer)
        Task {
            defer {
                processing.remove(folder)
                if pendingDeletion.remove(folder) != nil { trash(folder) }
                refreshRecentMeetings()
            }
            let phrases = await live()
            var outcome = MeetingMetadata.Status.failed
            defer { runHook(folder: folder, status: outcome) }
            do {
                let transcriber = try await AppleSpeechTranscriber.make(preferred: language.map(Locale.init(identifier:)))
                let processor = MeetingProcessor(transcriber: transcriber, diarizer: diarizer, keepAudio: keepAudio)
                let result = try await processor.process(folder: folder, live: phrases)
                if let warning = result.warnings.first { lastError = warning }
                outcome = .done
                suggest(for: folder)
            } catch {
                if !pendingDeletion.contains(folder) { lastError = "Transcription failed: \(error)" }
            }
        }
    }

    /// Not awaited: a slow hook shouldn't keep the meeting showing as processing.
    private func runHook(folder: URL, status: MeetingMetadata.Status) {
        guard !pendingDeletion.contains(folder) else { return }  // it's about to go
        let hook = MeetingEndHook()
        Task {
            switch await hook.run(folder: folder, status: status) {
            case .notInstalled, .exited(0):
                break
            case .exited(let code):
                lastError = "on-meeting-end hook exited with status \(code). See \(hook.log.path)."
            case .couldNotLaunch(let reason):
                lastError = "Couldn't run the on-meeting-end hook: \(reason)"
            }
        }
    }

    // MARK: - Suggestions

    /// Meetings waiting for Apple Intelligence, one at a time: the model runs one request at once anyway.
    private var suggestionQueue: [URL] = []
    private var suggesting = false

    /// Asks Apple Intelligence for a title, tags and speaker names, saved as `suggestions.json`
    /// (after the final pass, which reset the speakers, so earlier suggestions are replaced).
    func suggest(for folder: URL) {
        guard suggestWithAppleIntelligence, MeetingSuggester.isAvailable,
              !suggestionQueue.contains(where: { Self.samePath($0, folder) }) else { return }
        suggestionQueue.append(folder)
        runSuggestions()
    }

    /// Finished meetings that have never had suggestions, newest first.
    func suggestForEarlierMeetings() {
        guard suggestWithAppleIntelligence, MeetingSuggester.isAvailable else { return }
        let store = store
        Task {
            let folders = await Task.detached(priority: .utility) {
                store.recentMeetings(limit: 100).filter { folder in
                    let md = folder.appendingPathComponent(MeetingFiles.transcript)
                    return !FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingFiles.suggestions).path)
                        && (try? String(contentsOf: md, encoding: .utf8)).flatMap(MeetingMetadata.init(parsing:))?.status == .done
                }
            }.value
            folders.forEach(suggest(for:))
        }
    }

    private func runSuggestions() {
        guard !suggesting, !suggestionQueue.isEmpty else { return }
        suggesting = true
        let folder = suggestionQueue.removeFirst()
        let store = store
        Task {
            defer {
                suggesting = false
                runSuggestions()
            }
            // Not while it's being re-transcribed or deleted; it comes back after its final pass.
            guard !processing.contains(folder), !pendingDeletion.contains(folder) else { return }
            let suggester = await Task.detached(priority: .utility) { MeetingSuggester(store: store, excluding: folder) }.value
            do {
                try await suggester.suggest(folder: folder)
                refreshRecentMeetings()
            } catch {
                // Quietly: suggestions are a nicety, and the meeting is fine without them.
                print("Suggestions for \(folder.lastPathComponent) failed: \(error)")
            }
        }
    }

    /// Meetings interrupted by a quit or crash still have their audio: finish them now.
    /// Failed ones are left alone (re-run with `tinymuesli transcribe`), so a bad file can't loop.
    private func resumeUnfinishedMeetings() {
        let unfinished: Set<MeetingMetadata.Status> = [.recording, .recorded, .transcribing]
        for folder in store.recentMeetings(limit: 20) {
            let md = folder.appendingPathComponent(MeetingFiles.transcript)
            guard let text = try? String(contentsOf: md, encoding: .utf8),
                  let metadata = MeetingMetadata(parsing: text), unfinished.contains(metadata.status),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingFiles.audio).path)
            else { continue }
            process(folder)
        }
    }

    // MARK: - Settings & files

    func setAlwaysRecord(_ appID: String, _ enabled: Bool) {
        if enabled { alwaysRecord.insert(appID) } else { alwaysRecord.remove(appID) }
        UserDefaults.standard.set(alwaysRecord.sorted(), forKey: Self.alwaysRecordKey)
    }

    func refreshRecentMeetings() {
        recentMeetings = MeetingLibrary(store: store).meetings(limit: 5)
    }

    struct RecentDay: Identifiable {
        var id: String { title }
        let title: String
        let meetings: [RecentMeeting]
    }

    struct RecentMeeting {
        let folder: URL
        let title: String
        /// Nil while recording, or if the end wasn't written.
        let length: String?
        /// Being recorded right now.
        let isOngoing: Bool
    }

    /// Recent meetings grouped by the day they started, newest first.
    var recentDays: [RecentDay] {
        let calendar = Calendar.current
        var days: [RecentDay] = []
        var recordingPath: String?
        if case .recording(let session, _) = status { recordingPath = session.folder.standardizedFileURL.resolvingSymlinksInPath().path }
        for meeting in recentMeetings {
            let folder = URL(fileURLWithPath: meeting.path)
            if pendingDeletion.contains(where: { Self.samePath($0, folder) }) { continue }
            let day = Self.dayTitle(meeting.start, calendar: calendar)
            // Apple Intelligence's title until the meeting gets one of its own, marked like in the meetings list.
            let name = meeting.title ?? meeting.suggestedTitle.map { "✨ \($0)" }
                ?? MeetingStore.displayName(of: folder, start: meeting.start, calendar: calendar)
            let entry = RecentMeeting(
                folder: folder,
                title: "\(meeting.start.formatted(date: .omitted, time: .shortened)) · \(name)",
                length: meeting.end.map { Self.length($0.timeIntervalSince(meeting.start)) },
                isOngoing: folder.standardizedFileURL.resolvingSymlinksInPath().path == recordingPath
            )
            if days.last?.title == day {
                days[days.count - 1] = RecentDay(title: day, meetings: days[days.count - 1].meetings + [entry])
            } else {
                days.append(RecentDay(title: day, meetings: [entry]))
            }
        }
        return days
    }

    /// "45 min", "1 hr, 5 min".
    static func length(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "<1 min" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        let style = Date.FormatStyle().weekday(.wide).day().month(.wide)
        return date.formatted(sameYear ? style : style.year())
    }

    func openMeetingsFolder() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.root)
    }

    /// A menu item doesn't wrap, so a long message would stretch the whole menu.
    /// Keeps the first sentence, cut at a word boundary if that is still too long.
    static func menuSummary(of message: String, limit: Int = 70) -> String {
        var summary = message
        if let end = summary.range(of: ". ") ?? summary.range(of: ": ") {
            summary = String(summary[..<end.lowerBound])
        }
        guard summary.count > limit else { return summary == message ? message : summary + "…" }
        let cut = summary.prefix(limit)
        let head = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return head.trimmingCharacters(in: .punctuationCharacters) + "…"
    }

    /// Shows a problem from outside the model (e.g. a menu action) in the menu.
    func report(_ error: String) {
        lastError = error
    }

    func showLastError() {
        guard let lastError else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "tinyMuesli"
        alert.informativeText = lastError
        alert.runModal()
    }

    /// Where new meetings go. Offers to move the existing ones along.
    func chooseMeetingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.root
        panel.prompt = "Choose"
        panel.message = "Choose where tinyMuesli saves meetings."
        // A menu bar app isn't frontmost, so the panel would open behind other windows.
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL,
              Self.samePath(url, store.root) == false else { return }

        let old = store
        // A meeting folder can't go inside itself, and ones already in the new folder (if it's
        // inside the old one) stay where they are.
        let movable = old.allMeetings().filter {
            !Self.path(url).hasPrefix(Self.path($0) + "/") && !Self.path($0).hasPrefix(Self.path(url) + "/")
        }
        guard !movable.isEmpty else { return setMeetingsFolder(url) }

        let alert = NSAlert()
        let count = movable.count == 1 ? "your meeting" : "your \(movable.count) meetings"
        alert.messageText = "Move \(count) to “\(url.lastPathComponent)”?"
        alert.informativeText = """
            They're in \(meetingsFolderName). If you leave them there, tinyMuesli and your agents won't \
            see them any more.
            """
        alert.addButton(withTitle: "Move Meetings")
        alert.addButton(withTitle: "Leave Them")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            setMeetingsFolder(url)
            moveMeetings(movable, from: old)
        case .alertSecondButtonReturn:
            setMeetingsFolder(url)
        default:
            return
        }
    }

    func setMeetingsFolder(_ url: URL) {
        let url = url.standardizedFileURL
        Settings.meetingsFolder = Self.samePath(url, MeetingStore.defaultRoot) ? nil : url
        store = MeetingStore(root: url)
        refreshRecentMeetings()
    }

    /// Moves meetings into the current folder in the background. Ones still being recorded,
    /// waiting to be continued or being transcribed are left behind: something is writing to them.
    private func moveMeetings(_ meetings: [URL], from old: MeetingStore) {
        var busy = Set(processing.map(Self.path))
        if case .recording(let session, _) = status { busy.insert(Self.path(session.folder)) }
        if let ended { busy.insert(Self.path(ended.session.folder)) }
        let toMove = meetings.filter { !busy.contains(Self.path($0)) }
        let leftBehind = meetings.count - toMove.count
        let (oldName, new) = (meetingsFolderName(old.root), store)

        movingMeetings = toMove.count
        Task {
            let result = await Task.detached { old.move(toMove, to: new) }.value
            movingMeetings = nil
            refreshRecentMeetings()
            var problems: [String] = []
            if !result.failed.isEmpty {
                let first = result.failed[0]
                problems.append("Couldn't move \(result.failed.count) meeting(s), e.g. \(first.folder.lastPathComponent): \(first.reason)")
            }
            if leftBehind > 0 {
                problems.append("Left \(leftBehind) meeting(s) in \(oldName) that were still in use; move them by hand later.")
            }
            if !problems.isEmpty { lastError = problems.joined(separator: " ") }
        }
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        path(a) == path(b)
    }

    private func meetingsFolderName(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The meetings folder for the menu, with the home directory as ~.
    var meetingsFolderName: String {
        meetingsFolderName(store.root)
    }

    func copyAgentPrompt() {
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentPrompt.text(binaryPath: binary), forType: .string)
    }

    /// Adds the MCP server to the Claude desktop app, which only reads its config at launch. Claude
    /// also writes that file while running, so it's quit first rather than edited underneath it.
    func addToClaudeDesktop() {
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopConfig.bundleIdentifier)
        NSApp.activate()

        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Restart Claude to add tinyMuesli?"
            alert.informativeText = "Claude only loads tools when it starts, so tinyMuesli will quit it, add itself, and open it again."
            alert.addButton(withTitle: "Restart Claude")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        Task {
            running.forEach { $0.terminate() }
            for _ in 0..<100 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let alert = NSAlert()
            if running.contains(where: { !$0.isTerminated }) {
                alert.messageText = "Claude didn't quit"
                alert.informativeText = "Quit Claude, then click Add… next to Claude in Settings again."
            } else {
                do {
                    try ClaudeDesktopConfig.install(binaryPath: binary)
                    alert.messageText = "Added tinyMuesli to Claude"
                    alert.informativeText = """
                        Ask Claude about your meetings in any chat. For better answers, paste the prompt from \
                        Settings › Assistants › Copy Prompt into your Claude settings or a project's instructions.
                        """
                    if !running.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeDesktopConfig.bundleIdentifier) {
                        try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                } catch {
                    alert.messageText = "Couldn't add tinyMuesli to Claude"
                    alert.informativeText = "\(error)"
                }
            }
            NSApp.activate()
            alert.runModal()
        }
    }

    /// The ChatGPT (or Codex) app, if installed: its local MCP servers live in Codex's config.
    static var chatGPTApp: URL? {
        CodexConfig.bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static var claudeApp: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeDesktopConfig.bundleIdentifier)
    }

    /// Adds the MCP server to ChatGPT's Codex config. Returns an error message if that failed.
    @discardableResult
    func addToChatGPT(confirm: Bool = false) -> String? {
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var problem: String?
        do {
            try CodexConfig.install(binaryPath: binary)
        } catch {
            problem = "Couldn't add tinyMuesli to ChatGPT: \(error.localizedDescription)"
        }
        if confirm {
            let alert = NSAlert()
            alert.messageText = problem == nil ? "Added tinyMuesli to ChatGPT" : "Couldn't add tinyMuesli to ChatGPT"
            alert.informativeText = problem ?? """
                It's in ~/.codex/config.toml, where the ChatGPT app and Codex find local tools. If ChatGPT \
                is open, quit and reopen it, then ask about your meetings.
                """
            NSApp.activate()
            alert.runModal()
        }
        return problem
    }

    // MARK: - Menu bar presentation

    var statusSymbol: String {
        switch status {
        case .idle: processing.isEmpty ? "waveform" : "ellipsis.circle"
        case .detected: "mic.circle"
        // Muted, whether by "Mute Me" or the call app: the mic track is recording silence.
        case .recording: micMuted ? "mic.slash.circle.fill" : "record.circle.fill"
        }
    }

    /// Shown under the main status line while an ended meeting can still be continued.
    var endedText: String? {
        guard let ended else { return nil }
        let until = ended.finishesAt.formatted(date: .omitted, time: .shortened)
        return "\(Self.title(of: ended.session)) ended; can be continued until \(until)"
    }

    /// Shown while meetings move to a newly chosen folder.
    var movingText: String? {
        movingMeetings.map { $0 == 1 ? "Moving 1 meeting…" : "Moving \($0) meetings…" }
    }

    /// Shown under the main status line while a final pass runs (it can overlap a new recording).
    var processingText: String? {
        switch processing.count {
        case 0: nil
        case 1: "Transcribing \(processing.first!.lastPathComponent)…"
        default: "Transcribing \(processing.count) meetings…"
        }
    }

    var statusText: String {
        switch status {
        case .idle:
            return micInUse ? "Microphone in use" : "No meeting detected"
        case .detected(let app):
            return "\(app.name) is using the microphone"
        case .recording(let session, _):
            let since = session.startedAt.formatted(date: .omitted, time: .shortened)
            return "Recording \(session.appName ?? "meeting") since \(since)"
        }
    }

    /// Shown under the status line while your mic isn't being recorded.
    var mutedText: String? {
        guard case .recording = status, micMuted else { return nil }
        return muteMe ? "Muted: your mic isn't recorded" : "You're muted in the call: your mic isn't recorded"
    }
}
