import AppKit
import SwiftUI
import TinyMuesliCore

/// A name for an unnamed speaker, and why.
struct SpeakerSuggestion: Equatable {
    enum Reason: Equatable {
        /// The voice matches one named in other meetings.
        case voice(similarity: Double, meetings: Int)
        /// Someone said the name to them (Apple Intelligence, see `MeetingSuggester`).
        case heard(quote: String)
    }

    var speaker: String
    var name: String
    var reason: Reason

    var why: String {
        switch reason {
        case .voice(let similarity, let meetings):
            "The voice matches “\(name)” from \(meetings == 1 ? "another meeting" : "\(meetings) other meetings") (similarity \(Int((similarity * 100).rounded()))%)."
        case .heard(let quote):
            "Someone seems to speak to them as \(name): “\(quote)”"
        }
    }
}

/// The inspector beside a meeting's chat: title, tags, names for the speakers (with suggestions from
/// voices named in other meetings and from Apple Intelligence), and how the chat is drawn.
struct MeetingDetails: View {
    let folder: URL
    let transcript: ChatTranscript
    /// Voices recognised from other meetings (worked out by the chat, which shows them too).
    let suggestions: [SpeakerSuggestion]
    /// Apple Intelligence's title and tags, if it was asked.
    let suggested: MeetingSuggestions?
    /// Tags used on any meeting, most used first, offered for quick adding.
    let knownTags: [String]
    /// Speaker names used in any meeting, most used first, offered as you type a name.
    let knownNames: [String]
    @Binding var speakerColors: Bool
    let color: (String) -> Color
    /// Called after the files changed, so the chat and the list reload.
    let onEdited: () -> Void

    @State private var newTag = ""
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var error: String?

    private var metadata: MeetingMetadata? { transcript.metadata }
    /// The recorder and the final pass rewrite the files from their own copy, so edits wait for them.
    private var canEditTags: Bool { metadata?.status == .done || metadata?.status == .failed }
    private var canRename: Bool { metadata?.status == .done }

    var body: some View {
        Form {
            Section("Title") {
                TextField("Title", text: $title, prompt: Text(metadata?.app ?? "Meeting"))
                    .labelsHidden()
                    .disabled(!canEditTags)
                    .focused($titleFocused)
                    .onSubmit(commitTitle)
                    // Clicking elsewhere saves too, not only Return.
                    .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                if canEditTags, metadata?.title == nil, title.isEmpty, let suggestedTitle = suggested?.title {
                    SuggestionRow(text: suggestedTitle, help: "Suggested by Apple Intelligence from the transcript.") {
                        perform { try MeetingEditor(folder: folder).setTitle(suggestedTitle) }
                    }
                }
            }
            tagsSection
            speakersSection
            Section {
                Toggle("Color Speakers", isOn: $speakerColors)
            } footer: {
                Text("Gives everyone a colour of their own. You're always blue.")
            }
            infoSection
        }
        .formStyle(.grouped)
        // Follows the file, e.g. when an agent sets a title.
        .onChange(of: metadata?.title, initial: true) { title = metadata?.title ?? "" }
        // Closing the inspector or opening another meeting while typing.
        .onDisappear(perform: commitTitle)
        .alert("Couldn't Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func commitTitle() {
        guard canEditTags, MeetingEditor.clean(title) != (metadata?.title ?? "") else { return }
        perform { try MeetingEditor(folder: folder).setTitle(title) }
    }

    // MARK: Tags

    private var tagsSection: some View {
        Section("Tags") {
            let tags = metadata?.tags ?? []
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(tag: tag, onRemove: canEditTags ? { setTags(tags.filter { $0 != tag }) } : nil)
                    }
                }
            }
            TextField("Add Tag", text: $newTag, prompt: Text("Add a tag"))
                .labelsHidden()
                .disabled(!canEditTags)
                .onSubmit {
                    setTags(tags + newTag.split(separator: ",").map(String.init))
                    newTag = ""
                }
            let suggestedTags = (suggested?.tags ?? []).filter { tag in !tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            if canEditTags, !suggestedTags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestedTags, id: \.self) { tag in
                        Button {
                            setTags(tags + [tag])
                        } label: {
                            Label(tag, systemImage: "sparkles")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                        .controlSize(.small)
                        .help("Suggested by Apple Intelligence. Add “\(tag)”")
                    }
                }
            }
            let offered = knownTags.filter { !suggestedTags.contains($0) }.filter { known in !tags.contains { $0.caseInsensitiveCompare(known) == .orderedSame } }.prefix(8)
            if canEditTags, !offered.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(offered), id: \.self) { tag in
                        Button {
                            setTags(tags + [tag])
                        } label: {
                            Label(tag, systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Add “\(tag)”")
                    }
                }
            }
        }
    }

    private func setTags(_ tags: [String]) {
        perform { try MeetingEditor(folder: folder).setTags(tags) }
    }

    // MARK: Speakers

    private var speakersSection: some View {
        Section {
            if transcript.speakers.isEmpty {
                Text("No one has spoken yet.").foregroundStyle(.secondary)
            }
            ForEach(transcript.speakers, id: \.self) { speaker in
                SpeakerRow(
                    speaker: speaker,
                    stats: stats(for: speaker),
                    color: speakerColors || speaker == SpeakerLabel.me ? color(speaker) : .secondary,
                    suggestion: suggestions.first { $0.speaker == speaker },
                    knownNames: knownNames.filter { !transcript.speakers.contains($0) },
                    canRename: canRename,
                    rename: { name in perform { try MeetingEditor(folder: folder).rename(speaker: speaker, to: name) } }
                )
                .id(speaker)
            }
        } header: {
            Text("Speakers")
        } footer: {
            if canRename {
                Text("Names are written into the transcript files. Give two speakers the same name to merge them. Voices you name are recognised in other meetings.")
            } else if metadata?.status != .failed {
                Text("Speakers can be named once the meeting has been transcribed.")
            }
        }
    }

    private func stats(for speaker: String) -> String {
        let messages = transcript.messages.filter { $0.speaker == speaker }
        let seconds = messages.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let count = messages.count == 1 ? "1 message" : "\(messages.count) messages"
        return seconds >= 60 ? "\(count) · \(AppModel.length(seconds))" : count
    }

    // MARK: Info

    /// "German (Switzerland)", or "English, German" for a meeting that switched language.
    static func languages(start: String, switches: [LanguageSwitch]) -> String {
        guard !switches.isEmpty else { return Locale.current.localizedString(forIdentifier: start) ?? start }
        var names: [String] = []
        for tag in [start] + switches.sorted(by: { $0.time < $1.time }).map(\.language) {
            let name = AppModel.languageName(tag)
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: ", ")
    }

    private var infoSection: some View {
        Section("Info") {
            if let metadata {
                LabeledContent("Started", value: metadata.start.formatted(date: .abbreviated, time: .shortened))
                if let end = metadata.end {
                    LabeledContent("Length", value: AppModel.length(end.timeIntervalSince(metadata.start)))
                }
                if let app = metadata.app { LabeledContent("App", value: app) }
                if let language = metadata.language {
                    LabeledContent("Language", value: Self.languages(start: language, switches: metadata.languageSwitches))
                }
                LabeledContent("Status", value: metadata.status.rawValue.capitalized)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(MeetingFiles.transcript)])
            }
        }
    }

    private func perform(_ edit: () throws -> Void) {
        do {
            try edit()
        } catch {
            self.error = error.localizedDescription
        }
        onEdited()
    }
}

private struct SpeakerRow: View {
    let speaker: String
    let stats: String
    let color: Color
    let suggestion: SpeakerSuggestion?
    let knownNames: [String]
    let canRename: Bool
    let rename: (String) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool
    /// Set once renamed, so losing focus or disappearing afterwards doesn't rename again.
    @State private var renamed = false

    private var isMe: Bool { speaker == SpeakerLabel.me }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                if isMe || !canRename {
                    Text(isMe ? "Me" : speaker)
                } else {
                    TextField("Name", text: $name, prompt: Text(speaker))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, focused in if !focused { commit() } }
                        .onDisappear(perform: commit)
                        .textInputSuggestions {
                            ForEach(completions, id: \.self) { known in
                                Text(known).textInputCompletion(known)
                            }
                        }
                }
                Spacer()
                Text(isMe ? "Microphone" : stats)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let suggestion, canRename {
                HStack(spacing: 6) {
                    Image(systemName: icon(suggestion.reason))
                        .foregroundStyle(.secondary)
                    Text("Maybe **\(suggestion.name)**")
                    Spacer()
                    Button("Confirm") { rename(suggestion.name) }
                        .controlSize(.small)
                }
                .font(.callout)
                .help(suggestion.why)
            }
        }
        .onAppear { name = speaker }
    }

    private func icon(_ reason: SpeakerSuggestion.Reason) -> String {
        switch reason {
        case .voice: "waveform"
        case .heard: "sparkles"
        }
    }

    /// Names already used elsewhere that start with (or contain) what's typed; the voice match first.
    private var completions: [String] {
        let typed = name.trimmingCharacters(in: .whitespaces)
        var names = knownNames
        if let suggestion { names = [suggestion.name] + names.filter { $0 != suggestion.name } }
        guard !typed.isEmpty, typed != speaker else { return Array(names.prefix(8)) }
        let prefix = names.filter { $0.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
        let inside = names.filter { !prefix.contains($0) && $0.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return Array((prefix + inside).filter { $0 != typed }.prefix(8))
    }

    private func commit() {
        guard !renamed else { return }
        let trimmed = MeetingEditor.clean(name)
        if trimmed.isEmpty || trimmed == speaker {
            if name != speaker { name = speaker }
        } else {
            renamed = true
            rename(trimmed)
        }
    }
}

/// "✨ Suggested title · Use".
private struct SuggestionRow: View {
    let text: String
    let help: String
    let use: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Use", action: use)
                .controlSize(.small)
        }
        .font(.callout)
        .help(help)
    }
}

private struct TagChip: View {
    let tag: String
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(tag)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove “\(tag)”")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

/// Lays out views in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if var last = rows.last, last.width + spacing + size.width <= width {
                last.indices.append(index)
                last.width += spacing + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
