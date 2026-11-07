import AppKit
import SwiftUI
import TinyMuesliCore

/// Shows a meeting's transcript as a chat: the user on the right, everyone else on the left.
/// One window per meeting; opening a meeting again brings its window forward.
@MainActor
final class ChatViewer: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]

    func open(_ folder: URL, title: String) {
        let key = folder.standardizedFileURL.resolvingSymlinksInPath().path
        if let window = windows[key] {
            return bringToFront(window)
        }
        let hosting = NSHostingController(rootView: ChatView(folder: folder))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.subtitle = folder.lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 560, height: 720))
        window.contentMinSize = NSSize(width: 360, height: 300)
        // Cascade from the last one so several meetings don't stack exactly.
        if let last = windows.values.first(where: \.isVisible) {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }
        windows[key] = window
        bringToFront(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }

    private func bringToFront(_ window: NSWindow) {
        // A menu bar app isn't frontmost, so the window would open behind others.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

// MARK: - View

private struct ChatView: View {
    let folder: URL
    @State private var transcript = ChatTranscript(metadata: nil, messages: [])
    @State private var modified: Date?
    @State private var query = ""

    private var isLive: Bool {
        guard let status = transcript.metadata?.status else { return false }
        return status == .recording || status == .recorded || status == .transcribing
    }

    private var shown: [ChatTranscript.Message] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return transcript.messages }
        return transcript.messages.filter {
            $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.speaker.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    let messages = shown
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
                            showsSpeakerName: transcript.speakers.count > 2 || !message.isMe && transcript.speakers.count > 1,
                            highlight: query
                        )
                        .id(message.id)
                    }
                    if transcript.messages.isEmpty {
                        Text(isLive ? "Nothing said yet." : "This meeting has no transcript.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else if !query.isEmpty, shown.isEmpty {
                        Text("No messages match “\(query)”.")
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
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .searchable(text: $query, placement: .toolbar, prompt: "Search transcript")
        .toolbar {
            ToolbarItem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(MeetingFiles.transcript)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show the transcript files in Finder")
            }
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
                    transcript.speakers.isEmpty ? nil : transcript.speakers.joined(separator: ", "),
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
        let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .cyan, .red]
        let others = transcript.speakers.filter { $0 != SpeakerLabel.me }
        let index = others.firstIndex(of: speaker) ?? 0
        return palette[index % palette.count]
    }

    private func reloadIfChanged() {
        let urls = [MeetingFiles.transcript, MeetingFiles.json].map(folder.appendingPathComponent)
        let dates = urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let latest = dates.max()
        guard latest != modified || transcript.metadata == nil else { return }
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
    let highlight: String

    var body: some View {
        VStack(alignment: message.isMe ? .trailing : .leading, spacing: 2) {
            if startsGroup, showsSpeakerName {
                Text(message.speaker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.isMe ? Color.secondary : color)
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
    }

    /// The position in the recording, small next to the bubble.
    private var time: some View {
        Text(TranscriptRenderer.timestamp(message.start))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.bottom, 4)
    }

    private var attributed: AttributedString {
        var text = AttributedString(message.text)
        let q = highlight.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return text }
        var search = text.startIndex..<text.endIndex
        while let range = text[search].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = .yellow.opacity(0.6)
            text[range].foregroundColor = .black
            search = range.upperBound..<text.endIndex
        }
        return text
    }
}
