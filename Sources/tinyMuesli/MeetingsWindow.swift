import AppKit
import SwiftUI
import TinyMuesliCore

/// The Meetings window: every meeting in a list on the left, like Mail or Messages, and the
/// selected one's transcript as a chat on the right.
@MainActor
@Observable
final class MeetingBrowser {
    static let windowID = "meetings"

    struct Entry: Identifiable, Equatable {
        var id: URL { folder }
        let folder: URL
        let name: String
        let start: Date
        let end: Date?
        let status: MeetingMetadata.Status
        let speakers: [String]
        let preview: String?
        let app: String?
        let tags: [String]
        /// Apple Intelligence's title, while the meeting has none of its own.
        let suggestedTitle: String?
    }

    /// A meeting found by the search in the sidebar.
    struct Match: Equatable {
        /// Times the query occurs in the transcript; 0 if only the name, app or a speaker matched.
        let count: Int
        let excerpt: String?
    }

    var selection: URL?
    private(set) var entries: [Entry] = []
    /// Typed into the sidebar's search field. The selected meeting highlights it too.
    var query = ""
    /// Search results by folder; nil when not searching.
    private(set) var matches: [URL: Match]?
    @ObservationIgnored private var previews: [URL: (modified: Date?, text: String?, body: String)] = [:]
    @ObservationIgnored private var loading = false
    /// A reload asked for while one ran (e.g. right after an edit); it runs once that one is done.
    @ObservationIgnored private var reloadAgain = false

    /// Shows a meeting (the window opens via SwiftUI's `openWindow`).
    func select(_ folder: URL) {
        let path = Self.path(folder)
        selection = entries.first { Self.path($0.folder) == path }?.folder ?? folder
    }

    /// Reads the meetings folder off the main thread. Previews are only re-read when a transcript changed.
    func reload(store: MeetingStore) {
        guard !loading else { reloadAgain = true; return }
        loading = true
        let cache = previews
        Task.detached(priority: .userInitiated) {
            let library = MeetingLibrary(store: store)
            var newCache: [URL: (modified: Date?, text: String?, body: String)] = [:]
            var entries: [Entry] = []
            for summary in library.meetings() {
                let folder = URL(fileURLWithPath: summary.path)
                let modified = try? folder.appendingPathComponent(MeetingFiles.transcript)
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let cached = cache[folder].flatMap { $0.modified == modified ? $0 : nil }
                let preview = cached.map(\.text) ?? ChatTranscript.preview(folder: folder)
                let body = cached?.body
                    ?? MeetingProcessor.body(of: folder.appendingPathComponent(MeetingFiles.transcript))
                newCache[folder] = (modified, preview, body)
                entries.append(Entry(
                    folder: folder, name: summary.title ?? MeetingStore.displayName(of: folder, start: summary.start),
                    start: summary.start, end: summary.end,
                    status: MeetingMetadata.Status(rawValue: summary.status) ?? .done,
                    speakers: summary.speakers, preview: preview, app: summary.app, tags: summary.tags,
                    suggestedTitle: summary.title == nil ? MeetingSuggestions.load(folder: folder)?.title : nil
                ))
            }
            await MainActor.run {
                self.previews = newCache
                if self.entries != entries {
                    self.entries = entries
                    // A live transcript grew, or a meeting came or went: results may differ.
                    Task { await self.search() }
                }
                if self.selection == nil { self.selection = entries.first?.folder }
                self.loading = false
                if self.reloadAgain {
                    self.reloadAgain = false
                    self.reload(store: store)
                }
            }
        }
    }

    /// Searches names, apps, speakers and whole transcripts off the main thread.
    func search() async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { matches = nil; return }
        let entries = entries
        let bodies = previews.mapValues(\.body)
        let found = await Task.detached(priority: .userInitiated) {
            var found: [URL: Match] = [:]
            for entry in entries {
                let inText = ChatTranscript.matches(in: bodies[entry.folder] ?? "", query: query)
                let inName = ([entry.name, entry.app ?? "", entry.suggestedTitle ?? ""] + entry.speakers + entry.tags).contains {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
                if inText.count > 0 || inName { found[entry.folder] = Match(count: inText.count, excerpt: inText.excerpt) }
            }
            return found
        }.value
        // Typing on while this ran: a newer search will set the results.
        guard query == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        matches = found
        // Like Mail: show a result rather than a meeting the search hides.
        if let selection, found[selection] == nil {
            self.selection = entries.first { found[$0.folder] != nil }?.folder
        }
    }

    static func path(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The meeting open in the window: its transcript and voice suggestions. The chat loads them and
/// the details inspector shows them; the inspector belongs to the split view (so the three columns
/// share the window properly), not to the chat, so they meet here.
@MainActor
@Observable
final class MeetingSession {
    private(set) var folder: URL?
    var transcript = ChatTranscript(metadata: nil, messages: [])
    /// Voices recognised from other meetings, for speakers that aren't named yet.
    var voices: [VoiceMatcher.Suggestion] = []
    /// Apple Intelligence's title, tags and speaker names (`suggestions.json`).
    var suggested: MeetingSuggestions?
    @ObservationIgnored var suggestedModified: Date?

    /// A name for each unnamed speaker: the voice match if there is one, else a name someone said to them.
    var suggestions: [SpeakerSuggestion] {
        var result = voices.map { SpeakerSuggestion(speaker: $0.speaker, name: $0.name, reason: .voice(similarity: $0.similarity, meetings: $0.meetings)) }
        for heard in suggested?.speakers ?? [] where VoiceMatcher.isPlaceholder(heard.speaker)
            && transcript.speakers.contains(heard.speaker) && !transcript.speakers.contains(heard.name)
            && !result.contains(where: { $0.speaker == heard.speaker || $0.name == heard.name }) {
            result.append(SpeakerSuggestion(speaker: heard.speaker, name: heard.name, reason: .heard(quote: heard.quote)))
        }
        return result
    }
    /// Bumped after an edit in the inspector, so the chat reloads at once.
    var editCount = 0
    @ObservationIgnored var modified: Date?

    func show(_ folder: URL) {
        guard folder != self.folder else { return }
        self.folder = folder
        transcript = ChatTranscript(metadata: nil, messages: [])
        voices = []
        suggested = nil
        modified = nil
        suggestedModified = nil
    }
}

/// Me is always the accent colour; everyone else grey, or a colour each when `colored`.
func speakerColor(_ speaker: String, speakers: [String], colored: Bool) -> Color {
    if speaker == SpeakerLabel.me { return .accentColor }
    guard colored else { return .gray }
    let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .cyan, .red]
    let index = speakers.filter { $0 != SpeakerLabel.me }.firstIndex(of: speaker) ?? 0
    return palette[index % palette.count]
}

struct MeetingsWindow: View {
    let model: AppModel
    @Bindable var browser: MeetingBrowser
    /// Whether the details inspector is open; the chat's toolbar button toggles it. Remembered
    /// for the next time the window opens.
    @State private var showsDetails = UserDefaults.standard.bool(forKey: Self.detailsShownKey)
    private static let detailsShownKey = "meetingDetailsShown"
    @AppStorage("chatSpeakerColors") private var speakerColors = false
    @State private var session = MeetingSession()

    private var visible: [MeetingBrowser.Entry] {
        let deleting = Set(model.pendingDeletion.map(MeetingBrowser.path))
        return browser.entries.filter {
            !deleting.contains(MeetingBrowser.path($0.folder)) && (browser.matches.map { [folder = $0.folder] in $0[folder] != nil } ?? true)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $browser.selection) {
                ForEach(visible) { entry in
                    MeetingRow(entry: entry, isOngoing: isOngoing(entry), match: browser.matches?[entry.folder], query: browser.query)
                        .tag(entry.folder)
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
                            }
                            Divider()
                            Button("Delete Meeting…", role: .destructive) { model.confirmDelete(entry.folder) }
                        }
                }
            }
            .searchable(text: $browser.query, placement: .sidebar, prompt: "Search Meetings")
            .task(id: browser.query) {
                // Wait for a pause in typing.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await browser.search()
            }
            .overlay {
                if visible.isEmpty, browser.matches != nil {
                    ContentUnavailableView.search(text: browser.query)
                } else if visible.isEmpty {
                    ContentUnavailableView("No Meetings", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Recorded meetings show up here."))
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            // The details inspector shares the chat's column, laid out by SwiftUI: .inspector
            // widened the window each time it opened (see InspectorPanel).
            InspectorPanel(isPresented: $showsDetails, contentMinWidth: Self.chatMinWidth, widths: 240...400,
                           idealWidth: 300, widthKey: "meetingDetailsWidth") {
                detail
            } inspector: {
                inspector
            }
            .navigationTitle(selectedEntry?.name ?? "Meetings")
            .navigationSubtitle(selectedEntry?.start.formatted(date: .abbreviated, time: .shortened) ?? "")
        }
        .frame(minHeight: 420)
        .onChange(of: showsDetails) { _, shown in UserDefaults.standard.set(shown, forKey: Self.detailsShownKey) }
        .onChange(of: model.recentMeetings) { browser.reload(store: model.store) }
        .task {
            // Picks up meetings and live transcripts written while the window is open.
            while !Task.isCancelled {
                browser.reload(store: model.store)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private static let chatMinWidth: CGFloat = 360

    private var selectedEntry: MeetingBrowser.Entry? {
        browser.selection.flatMap { folder in visible.first { $0.folder == folder } }
    }

    @ViewBuilder private var detail: some View {
        if let entry = selectedEntry {
            ChatView(folder: entry.folder, session: session, highlight: browser.matches == nil ? "" : browser.query,
                     store: model.store, showsDetails: $showsDetails, onEdited: { browser.reload(store: model.store) })
                .id(entry.folder)
        } else {
            ContentUnavailableView("No Meeting Selected", systemImage: "bubble.left.and.bubble.right")
        }
    }

    @ViewBuilder private var inspector: some View {
        if let folder = browser.selection, session.folder == folder {
            MeetingDetails(
                folder: folder, transcript: session.transcript, suggestions: session.suggestions, suggested: session.suggested,
                knownTags: knownTags, knownNames: knownNames, speakerColors: $speakerColors,
                color: { [session, speakerColors] in speakerColor($0, speakers: session.transcript.speakers, colored: speakerColors) },
                onEdited: {
                    session.editCount += 1
                    browser.reload(store: model.store)
                }
            )
            // A fresh inspector per meeting, so a half-typed name is saved to the right one.
            .id(folder)
        } else {
            ContentUnavailableView("No Meeting Selected", systemImage: "info.circle")
        }
    }

    /// Speaker names given in any meeting, most used first.
    private var knownNames: [String] {
        Self.ranked(browser.entries.flatMap { $0.speakers.filter { $0 != SpeakerLabel.me && !VoiceMatcher.isPlaceholder($0) } })
    }

    private static func ranked(_ values: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// Every tag in use, most used first.
    private var knownTags: [String] {
        var counts: [String: Int] = [:]
        for tag in browser.entries.flatMap(\.tags) { counts[tag, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    private func isOngoing(_ entry: MeetingBrowser.Entry) -> Bool {
        guard case .recording(let session, _) = model.status else { return false }
        return MeetingBrowser.path(session.folder) == MeetingBrowser.path(entry.folder)
    }
}

/// A row as Mail draws one: name and date on top, then details and the start of the transcript.
private struct MeetingRow: View {
    let entry: MeetingBrowser.Entry
    let isOngoing: Bool
    let match: MeetingBrowser.Match?
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(app: entry.app)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    if let suggested = entry.suggestedTitle {
                        Text("\(Image(systemName: "sparkles")) \(suggested)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Suggested by Apple Intelligence. Use it, or give your own, in the meeting's details.")
                    } else {
                        Text(entry.name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if isOngoing {
                        Text("Live")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                    } else {
                        Text(Self.dateLabel(entry.start))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                if !entry.tags.isEmpty {
                    Label(entry.tags.joined(separator: ", "), systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        // Today's rows already show the time on the right.
        var parts = Calendar.current.isDateInToday(entry.start) ? [] : [entry.start.formatted(date: .omitted, time: .shortened)]
        switch entry.status {
        case .recording where isOngoing: parts.append("Recording")
        case .recording, .recorded: parts.append("Waiting to transcribe")
        case .transcribing: parts.append("Transcribing…")
        case .failed: parts.append("Failed")
        case .done:
            if let end = entry.end { parts.append(AppModel.length(end.timeIntervalSince(entry.start))) }
        }
        let people = entry.speakers.count
        if people > 1 { parts.append("\(people) people") }
        if let match, match.count > 0 { parts.append(match.count == 1 ? "1 match" : "\(match.count) matches") }
        return parts.joined(separator: " · ")
    }

    /// The start of the transcript, or while searching, the text around the first match in bold.
    private var snippet: AttributedString {
        guard let excerpt = match?.excerpt else {
            return AttributedString(entry.preview ?? (isOngoing ? "Nothing said yet." : "No transcript."))
        }
        var text = AttributedString(excerpt)
        var search = text.startIndex..<text.endIndex
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while !q.isEmpty, let range = text[search].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .subheadline.bold()
            text[range].foregroundColor = .primary
            search = range.upperBound..<text.endIndex
        }
        return text
    }

    /// Like Mail: the time today, "Yesterday", the weekday this week, else the date.
    static func dateLabel(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// The meeting app's icon, like a contact picture in Messages.
struct AppIcon: View {
    let app: String?

    var body: some View {
        Group {
            if let icon = Self.icon(for: app) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.gray.gradient, in: Circle())
            }
        }
        .frame(width: 32, height: 32)
    }

    @MainActor private static var cache: [String: NSImage?] = [:]

    @MainActor static func icon(for app: String?) -> NSImage? {
        guard let app else { return nil }
        if let cached = cache[app] { return cached }
        let url = MeetingApps.known.first { $0.name == app }
            .flatMap { known in ([known.id] + known.bundleIDs).lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first }
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[app] = icon
        return icon
    }
}

// MARK: - View

private struct ChatView: View {
    let folder: URL
    let session: MeetingSession
    /// The sidebar's search: highlighted, with buttons to step through the matches.
    let highlight: String
    let store: MeetingStore
    @Binding var showsDetails: Bool
    let onEdited: () -> Void
    /// System Settings → Accessibility → Display → Reduce motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var transcript: ChatTranscript { session.folder == folder ? session.transcript : ChatTranscript(metadata: nil, messages: []) }
    private var suggestions: [SpeakerSuggestion] { session.folder == folder ? session.suggestions : [] }
    @State private var renameError: String?
    /// Index into `matchIDs` of the match scrolled to.
    @State private var currentMatch = 0
    /// The message under the pointer, which shows its time.
    @State private var hoveredMessage: Int?
    /// Where each visible bubble is, for finding the hovered one. Not observed: it changes on
    /// every layout, and nothing needs to redraw when it does.
    @State private var bubbleFrames = BubbleFrames()
    /// Assistants with tinyMuesli's MCP server, for the chat button. Read from their config files
    /// when the window appears and whenever the app comes to the front, not on every redraw.
    @State private var chatServices = ChatHandoff.Service.withMCPServer
    private static let chatSpace = "chat"
    /// One colour per speaker instead of grey bubbles. Off by default; Me is always blue.
    @AppStorage("chatSpeakerColors") private var speakerColors = false

    private var isLive: Bool {
        guard let status = transcript.metadata?.status else { return false }
        return status == .recording || status == .recorded || status == .transcribing
    }

    private var query: String { highlight.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Messages containing the search, in order.
    private var matchIDs: [Int] {
        guard !query.isEmpty else { return [] }
        return transcript.messages.filter {
            $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.map(\.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    let messages = transcript.messages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        if let divider = divider(before: message, previous: previous) {
                            Text(divider)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 18)
                                .padding(.bottom, 6)
                        }
                        Bubble(
                            message: message,
                            color: color(for: message.speaker),
                            startsGroup: previous?.speaker != message.speaker || divider(before: message, previous: previous) != nil,
                            showsSpeakerName: !message.isMe && transcript.speakers.count > 1,
                            suggestion: transcript.metadata?.status == .done ? suggestion(for: message.speaker) : nil,
                            confirm: { rename(message.speaker, to: $0) },
                            highlight: query,
                            isCurrentMatch: matchIDs.indices.contains(currentMatch) && matchIDs[currentMatch] == message.id,
                            showsTime: hoveredMessage == message.id
                        )
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.chatSpace)) } action: { frame in
                            bubbleFrames.frames[message.id] = frame
                        }
                        .onDisappear { bubbleFrames.frames[message.id] = nil }
                        .id(message.id)
                    }
                    if transcript.messages.isEmpty {
                        Text(isLive ? "Nothing said yet." : "This meeting has no transcript.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    if isLive {
                        Label(liveLabel, systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, isActive: transcript.metadata?.status == .recording && !reduceMotion)
                            .padding(.top, 16)
                    }
                    Color.clear.frame(height: 12).id("bottom")
                }
                .padding(.horizontal, 16)
                .coordinateSpace(.named(Self.chatSpace))
                // One hover region for the whole chat rather than one per bubble: while a column
                // animates, SwiftUI re-checks every hover region on every frame.
                .onContinuousHover(coordinateSpace: .named(Self.chatSpace)) { phase in
                    var hovered: Int?
                    if case .active(let point) = phase {
                        hovered = bubbleFrames.frames.first { $0.value.contains(point) }?.key
                    }
                    if hovered != hoveredMessage { hoveredMessage = hovered }
                }
            }
            .defaultScrollAnchor(isLive ? .bottom : .top)
            .onChange(of: transcript.messages.count) { old, new in
                // Follow a live meeting, like a chat does.
                if isLive, old > 0, new > old, query.isEmpty {
                    withAnimation(motion(.default)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                // Opened from a search: go to the first match once the transcript is in.
                if old == 0, let first = matchIDs.first { proxy.scrollTo(first, anchor: .center) }
            }
            .onChange(of: query) {
                currentMatch = 0
                if let first = matchIDs.first { withAnimation(motion(.default)) { proxy.scrollTo(first, anchor: .center) } }
            }
            .onChange(of: currentMatch) {
                guard matchIDs.indices.contains(currentMatch) else { return }
                withAnimation(motion(.default)) { proxy.scrollTo(matchIDs[currentMatch], anchor: .center) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            if !query.isEmpty {
                ToolbarItem {
                    let count = matchIDs.count
                    ControlGroup {
                        Button { currentMatch = (currentMatch - 1 + count) % count } label: {
                            Label("Previous Match", systemImage: "chevron.up")
                        }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        Button { currentMatch = (currentMatch + 1) % count } label: {
                            Label("Next Match", systemImage: "chevron.down")
                        }
                        .keyboardShortcut("g", modifiers: .command)
                    } label: {
                        Text("Matches")
                    }
                    .disabled(count == 0)
                    .help(count == 0 ? "No matches in this meeting" : "Match \(min(currentMatch, count - 1) + 1) of \(count)")
                }
            }
            // Only the assistants that have tinyMuesli's MCP server, since that's how they read the meeting.
            ForEach(chatServices, id: \.self) { service in
                ToolbarItem {
                    Button { openChat(in: service) } label: {
                        Label {
                            Text("Chat in \(service.name)")
                        } icon: {
                            if let icon = Self.appIcon(for: service) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                            }
                        }
                    }
                    .help("Chat about this meeting in \(service.name), which reads it through tinyMuesli")
                }
            }
            ToolbarItem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(MeetingFiles.transcript)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show the transcript files in Finder")
            }
            ToolbarItem {
                Button {
                    withAnimation(motion(.default)) { showsDetails.toggle() }
                } label: {
                    Label("Details", systemImage: showsDetails ? "info.circle.fill" : "info.circle")
                }
                .help(showsDetails ? "Hide details" : "Show tags and speakers")
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        .task(id: "\(folder.path)|\(transcript.speakers.joined(separator: "|"))") {
            let folder = folder, store = store
            let found = await Task.detached(priority: .userInitiated) {
                VoiceMatcher(store: store).suggestions(for: folder)
            }.value
            if session.folder == folder { session.voices = found }
        }
        .alert("Couldn't Rename", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK") {}
        } message: {
            Text(renameError ?? "")
        }
        .onChange(of: session.editCount) { reloadIfChanged(force: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let now = ChatHandoff.Service.withMCPServer
            if now != chatServices { chatServices = now }
        }
        .task(id: folder) {
            session.show(folder)
            // Reload when the transcript changes: it grows live while recording and is rewritten
            // by the final pass.
            while !Task.isCancelled {
                reloadIfChanged()
                try? await Task.sleep(for: .seconds(isLive ? 1.5 : 5))
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            if let metadata = transcript.metadata {
                Text(metadata.start.formatted(date: .complete, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                let details = [
                    metadata.app,
                    metadata.end.map { AppModel.length($0.timeIntervalSince(metadata.start)) },
                    transcript.speakers.isEmpty ? nil
                        : transcript.speakers.map { suggestion(for: $0).map { "Maybe \($0.name)" } ?? $0 }.joined(separator: ", "),
                ].compactMap { $0 }
                Text(details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if metadata.status == .failed, let error = metadata.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var liveLabel: String {
        switch transcript.metadata?.status {
        case .recording: "Recording…"
        case .transcribing: "Identifying speakers…"
        default: "Waiting to be transcribed…"
        }
    }

    /// A time between messages, as a chat app shows: at the start and after a pause of 2 min or more.
    private func divider(before message: ChatTranscript.Message, previous: ChatTranscript.Message?) -> String? {
        guard previous == nil || message.start - previous!.end >= 120 else { return nil }
        guard let start = transcript.metadata?.start else { return TranscriptRenderer.timestamp(message.start) }
        return start.addingTimeInterval(message.start).formatted(date: .omitted, time: .shortened)
    }

    private func color(for speaker: String) -> Color {
        speakerColor(speaker, speakers: transcript.speakers, colored: speakerColors)
    }

    /// No movement when Reduce Motion is on: panels and scrolling jump instead of sliding.
    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    private func suggestion(for speaker: String) -> SpeakerSuggestion? {
        suggestions.first { $0.speaker == speaker }
    }

    /// Confirming a "Maybe Ann" in the chat.
    private func rename(_ speaker: String, to name: String) {
        do {
            try MeetingEditor(folder: folder).rename(speaker: speaker, to: name)
        } catch {
            renameError = error.localizedDescription
        }
        reloadIfChanged(force: true)
        onEdited()
    }

    /// The installed app for a service, if any: its icon is the chat button's.
    private static func appURL(for service: ChatHandoff.Service) -> URL? {
        service.bundleIdentifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    @MainActor private static var iconCache: [ChatHandoff.Service: NSImage?] = [:]

    @MainActor private static func appIcon(for service: ChatHandoff.Service) -> NSImage? {
        if let cached = iconCache[service] { return cached }
        let icon = appURL(for: service).map { NSWorkspace.shared.icon(forFile: $0.path) }
        iconCache[service] = icon
        return icon
    }

    private func openChat(in service: ChatHandoff.Service) {
        // Asks for the app that opens the service's own scheme, not just its bundle id: the older
        // ChatGPT app (com.openai.chat) doesn't take codex:// links.
        let appInstalled = NSWorkspace.shared.urlForApplication(toOpen: service.appProbe) != nil
        guard let metadata = transcript.metadata,
              let url = ChatHandoff.url(for: service, prompt: ChatHandoff.prompt(title: metadata.title, app: metadata.app, start: metadata.start),
                                        appInstalled: appInstalled) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reloadIfChanged(force: Bool = false) {
        let suggestionsFile = folder.appendingPathComponent(MeetingFiles.suggestions)
        let suggestedModified = try? suggestionsFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if force || suggestedModified != session.suggestedModified {
            session.suggestedModified = suggestedModified
            session.suggested = MeetingSuggestions.load(folder: folder)
        }
        let urls = [MeetingFiles.transcript, MeetingFiles.json].map(folder.appendingPathComponent)
        let dates = urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let latest = dates.max()
        guard force || latest != session.modified || transcript.metadata == nil else { return }
        session.modified = latest
        let folder = folder, session = session
        Task.detached(priority: .userInitiated) {
            let loaded = ChatTranscript.load(folder: folder)
            await MainActor.run {
                // Another meeting may have been opened meanwhile.
                if session.folder == folder { session.transcript = loaded }
            }
        }
    }
}

private struct Bubble: View {
    let message: ChatTranscript.Message
    let color: Color
    let startsGroup: Bool
    let showsSpeakerName: Bool
    /// Shown as "Maybe Ann" with a button that confirms the name.
    let suggestion: SpeakerSuggestion?
    let confirm: (String) -> Void
    let highlight: String
    let isCurrentMatch: Bool
    let showsTime: Bool
    @State private var namingOther = false
    @State private var otherName = ""

    var body: some View {
        VStack(alignment: message.isMe ? .trailing : .leading, spacing: 2) {
            if startsGroup, showsSpeakerName {
                HStack(spacing: 6) {
                    if let suggestion {
                        Text("Maybe \(suggestion.name)")
                            .help("\(suggestion.why) This is \(message.speaker) until you confirm.")
                        Button("Confirm") { confirm(suggestion.name) }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                            .help("Name \(message.speaker) “\(suggestion.name)” in this meeting")
                        Button("Other Name…") {
                            otherName = suggestion.name
                            namingOther = true
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                        .help("Give \(message.speaker) a different name in this meeting")
                        .popover(isPresented: $namingOther, arrowEdge: .bottom) {
                            OtherNameForm(speaker: message.speaker, name: $otherName) { name in
                                namingOther = false
                                confirm(name)
                            }
                        }
                    } else {
                        Text(message.speaker)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(color == .gray ? Color.secondary : color)
                .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if message.isMe { Spacer(minLength: 60); time }
                Text(attributed)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(message.isMe ? Color.white : Color.primary)
                    .background(
                        message.isMe ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                if !message.isMe { time; Spacer(minLength: 60) }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isMe ? .trailing : .leading)
        .padding(.top, startsGroup ? 10 : 3)
        .animation(.easeOut(duration: 0.15), value: showsTime)
    }

    /// The position in the recording, small next to the bubble. Only while the pointer is on the
    /// message; it keeps its space, so bubbles don't move.
    private var time: some View {
        Text(TranscriptRenderer.timestamp(message.start))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            .opacity(showsTime ? 1 : 0)
    }

    private var attributed: AttributedString {
        var text = AttributedString(message.text)
        let q = highlight.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return text }
        var search = text.startIndex..<text.endIndex
        while let range = text[search].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = isCurrentMatch ? .orange : .yellow.opacity(0.6)
            text[range].foregroundColor = .black
            search = range.upperBound..<text.endIndex
        }
        return text
    }
}

/// The popover behind "Other Name…": a field prefilled with the suggestion, renamed on Return.
private struct OtherNameForm: View {
    let speaker: String
    @Binding var name: String
    let rename: (String) -> Void
    @FocusState private var focused: Bool

    private var cleaned: String { MeetingEditor.clean(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name \(speaker)")
                .font(.headline)
            TextField("Name", text: $name)
                .frame(width: 200)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !cleaned.isEmpty else { return }
        rename(cleaned)
    }
}

/// Bubble frames in the chat's coordinate space, keyed by message id.
private final class BubbleFrames {
    var frames: [Int: CGRect] = [:]
}
