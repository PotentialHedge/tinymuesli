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

    /// Shows a meeting (the window opens via SwiftUI's `openWindow`).
    func select(_ folder: URL) {
        let path = Self.path(folder)
        selection = entries.first { Self.path($0.folder) == path }?.folder ?? folder
    }

    /// Reads the meetings folder off the main thread. Previews are only re-read when a transcript changed.
    func reload(store: MeetingStore) {
        guard !loading else { return }
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
                    speakers: summary.speakers, preview: preview, app: summary.app, tags: summary.tags
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
                let inName = ([entry.name, entry.app ?? ""] + entry.speakers + entry.tags).contains {
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

struct MeetingsWindow: View {
    let model: AppModel
    @Bindable var browser: MeetingBrowser

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
            if let folder = browser.selection, let entry = visible.first(where: { $0.folder == folder }) {
                ChatView(folder: folder, highlight: browser.matches == nil ? "" : browser.query,
                         store: model.store, knownTags: knownTags, knownNames: knownNames,
                         onEdited: { browser.reload(store: model.store) })
                    .id(folder)
                    .navigationTitle(entry.name)
                    .navigationSubtitle(entry.start.formatted(date: .abbreviated, time: .shortened))
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "bubble.left.and.bubble.right")
                    .navigationTitle("Meetings")
            }
        }
        .frame(minWidth: 700, minHeight: 420)
        .onChange(of: model.recentMeetings) { browser.reload(store: model.store) }
        .task {
            // Picks up meetings and live transcripts written while the window is open.
            while !Task.isCancelled {
                browser.reload(store: model.store)
                try? await Task.sleep(for: .seconds(3))
            }
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
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(1)
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
private struct AppIcon: View {
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
    /// The sidebar's search: highlighted, with buttons to step through the matches.
    let highlight: String
    let store: MeetingStore
    let knownTags: [String]
    let knownNames: [String]
    let onEdited: () -> Void
    @AppStorage("meetingDetailsShown") private var showsDetails = false
    @State private var transcript = ChatTranscript(metadata: nil, messages: [])
    @State private var modified: Date?
    /// Voices recognised from other meetings, for speakers that aren't named yet.
    @State private var suggestions: [VoiceMatcher.Suggestion] = []
    @State private var renameError: String?
    /// Index into `matchIDs` of the match scrolled to.
    @State private var currentMatch = 0
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
                            isCurrentMatch: matchIDs.indices.contains(currentMatch) && matchIDs[currentMatch] == message.id
                        )
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
                            .symbolEffect(.variableColor.iterative, isActive: transcript.metadata?.status == .recording)
                            .padding(.top, 16)
                    }
                    Color.clear.frame(height: 12).id("bottom")
                }
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(isLive ? .bottom : .top)
            .onChange(of: transcript.messages.count) { old, new in
                // Follow a live meeting, like a chat does.
                if isLive, old > 0, new > old, query.isEmpty {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                // Opened from a search: go to the first match once the transcript is in.
                if old == 0, let first = matchIDs.first { proxy.scrollTo(first, anchor: .center) }
            }
            .onChange(of: query) {
                currentMatch = 0
                if let first = matchIDs.first { withAnimation { proxy.scrollTo(first, anchor: .center) } }
            }
            .onChange(of: currentMatch) {
                guard matchIDs.indices.contains(currentMatch) else { return }
                withAnimation { proxy.scrollTo(matchIDs[currentMatch], anchor: .center) }
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
            ToolbarItem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(MeetingFiles.transcript)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show the transcript files in Finder")
            }
            ToolbarItem {
                Toggle(isOn: $showsDetails) {
                    Label("Details", systemImage: "info.circle")
                }
                .help(showsDetails ? "Hide details" : "Show tags and speakers")
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        .inspector(isPresented: $showsDetails) {
            MeetingDetails(
                folder: folder, transcript: transcript, suggestions: suggestions, knownTags: knownTags, knownNames: knownNames,
                speakerColors: $speakerColors, color: color(for:),
                onEdited: {
                    reloadIfChanged(force: true)
                    onEdited()
                }
            )
            .inspectorColumnWidth(min: 240, ideal: 300, max: 400)
        }
        .task(id: "\(folder.path)|\(transcript.speakers.joined(separator: "|"))") {
            let folder = folder, store = store
            suggestions = await Task.detached(priority: .userInitiated) {
                VoiceMatcher(store: store).suggestions(for: folder)
            }.value
        }
        .alert("Couldn't Rename", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK") {}
        } message: {
            Text(renameError ?? "")
        }
        .task(id: folder) {
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
        if speaker == SpeakerLabel.me { return .accentColor }
        guard speakerColors else { return .gray }
        let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .cyan, .red]
        let others = transcript.speakers.filter { $0 != SpeakerLabel.me }
        let index = others.firstIndex(of: speaker) ?? 0
        return palette[index % palette.count]
    }

    private func suggestion(for speaker: String) -> VoiceMatcher.Suggestion? {
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

    private func reloadIfChanged(force: Bool = false) {
        let urls = [MeetingFiles.transcript, MeetingFiles.json].map(folder.appendingPathComponent)
        let dates = urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let latest = dates.max()
        guard force || latest != modified || transcript.metadata == nil else { return }
        modified = latest
        let folder = folder
        Task.detached(priority: .userInitiated) {
            let loaded = ChatTranscript.load(folder: folder)
            await MainActor.run { transcript = loaded }
        }
    }
}

private struct Bubble: View {
    let message: ChatTranscript.Message
    let color: Color
    let startsGroup: Bool
    let showsSpeakerName: Bool
    /// Shown as "Maybe Ann" with a button that confirms the name.
    let suggestion: VoiceMatcher.Suggestion?
    let confirm: (String) -> Void
    let highlight: String
    let isCurrentMatch: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: message.isMe ? .trailing : .leading, spacing: 2) {
            if startsGroup, showsSpeakerName {
                HStack(spacing: 6) {
                    if let suggestion {
                        Text("Maybe \(suggestion.name)")
                            .help("The voice sounds like \(suggestion.name) from \(suggestion.meetings == 1 ? "another meeting" : "\(suggestion.meetings) other meetings"). This is \(message.speaker) until you confirm.")
                        Button("Confirm") { confirm(suggestion.name) }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                            .help("Name \(message.speaker) “\(suggestion.name)” in this meeting")
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
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    /// The position in the recording, small next to the bubble. Only while the pointer is on the
    /// message; it keeps its space, so bubbles don't move.
    private var time: some View {
        Text(TranscriptRenderer.timestamp(message.start))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            .opacity(isHovering ? 1 : 0)
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
