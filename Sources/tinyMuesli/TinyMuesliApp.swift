import AppKit
import TinyMuesliCore
import SwiftUI

struct TinyMuesliApp: App {
    @State private var model: AppModel
    @State private var updater: Updater
    @State private var permissions: Permissions
    @State private var onboarding: Onboarding
    @State private var chats = ChatViewer()

    init() {
        let model = AppModel()
        let permissions = Permissions()
        let onboarding = Onboarding(model: model, permissions: permissions)
        _model = State(initialValue: model)
        _updater = State(initialValue: Updater { model.isBusy })
        _permissions = State(initialValue: permissions)
        _onboarding = State(initialValue: onboarding)
        OngoingPill.install()
        // Once the app has finished launching, so the window can come to the front.
        DispatchQueue.main.async { onboarding.showIfNeeded() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, updater: updater, permissions: permissions, onboarding: onboarding, chats: chats)
        } label: {
            Image(systemName: menuBarSymbol)
        }
    }

    /// Flags missing permissions while nothing else is going on.
    private var menuBarSymbol: String {
        if case .idle = model.status, model.processing.isEmpty, !permissions.allGranted {
            return "waveform.badge.exclamationmark"
        }
        return model.statusSymbol
    }
}

private struct MenuContent: View {
    let model: AppModel
    let updater: Updater
    let permissions: Permissions
    let onboarding: Onboarding
    let chats: ChatViewer

    var body: some View {
        @Bindable var model = model
        @Bindable var updater = updater
        // Anything missing goes first: without it, meetings aren't noticed or recorded properly.
        if !permissions.allGranted {
            ForEach(permissions.missing) { kind in
                Button {
                    onboarding.allow(kind)
                } label: {
                    Label(Self.fixTitle(kind, permissions.state(kind)), systemImage: "exclamationmark.triangle.fill")
                }
            }
            Divider()
        }
        Text(model.statusText)
        if let muted = model.mutedText {
            Text(muted)
        }
        if let ended = model.endedText {
            Text(ended)
        }
        if let processing = model.processingText {
            Text(processing)
        }
        if let moving = model.movingText {
            Text(moving)
        }

        switch model.status {
        case .idle:
            Button("Start Recording") { model.startRecording(app: nil) }
        case .detected(let app):
            Button("Record \(app.name) Meeting") { model.startRecording(app: app) }
        case .recording:
            Button("Stop Recording") { model.stopRecording() }
            Button("Start New Meeting") { model.startNewMeeting() }
            Toggle("Mute Me", isOn: $model.muteMe)
            if model.followCallMute, !model.muteAccessAllowed {
                Button("Allow Accessibility to Notice When You Mute…") { model.requestMuteAccess() }
            }
        }
        if let ended = model.ended {
            Button("Continue \(AppModel.title(of: ended.session))") { model.continueMeeting() }
            Button("Finish \(AppModel.title(of: ended.session)) Now") { model.finishEndedMeeting() }
        }

        if let app = model.currentApp {
            Toggle("Always Record \(app.name)", isOn: Binding(
                get: { model.alwaysRecord.contains(app.id) },
                set: { model.setAlwaysRecord(app.id, $0) }
            ))
        }

        if let error = model.lastError {
            let summary = AppModel.menuSummary(of: error)
            if summary == error {
                Text(error)
            } else {
                Button(summary) { model.showLastError() }
            }
        }

        Divider()

        ForEach(model.recentDays) { day in
            Section(day.title) {
                ForEach(day.meetings, id: \.folder) { meeting in
                    Button(meeting.title) { chats.open(meeting.folder, title: meeting.title) }
                        .badge(meeting.isOngoing ? Text(OngoingPill.label) : meeting.length.map { Text($0) })
                }
            }
        }
        Button("Open Meetings Folder") { model.openMeetingsFolder() }
        Button("Copy Prompt for Agent") { model.copyAgentPrompt() }
        Button("Add to Claude Desktop…") { model.addToClaudeDesktop() }
        if AppModel.chatGPTApp != nil {
            Button("Add to ChatGPT…") { model.addToChatGPT(confirm: true) }
        }

        Divider()

        Picker("Language", selection: $model.language) {
            Text("System Default").tag(String?.none)
            ForEach(model.languageChoices, id: \.self) { choice in
                Text(choice.name).tag(Optional(choice.tag))
            }
        }
        if !model.languageVariants.isEmpty {
            Picker("Variant", selection: $model.language) {
                ForEach(model.languageVariants, id: \.self) { variant in
                    Text(variant.name).tag(Optional(variant.tag))
                }
            }
        }
        Menu("Settings") {
            Toggle("Keep Audio After Transcribing", isOn: $model.keepAudio)
            Toggle("Skip Silence While Recording", isOn: $model.skipSilence)
            Toggle("Don't Record Me While Muted in the Call", isOn: $model.followCallMute)
            Button("Meetings Folder: \(model.meetingsFolderName)…") { model.chooseMeetingsFolder() }
            Toggle("Open at Login", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { enabled in
                    if let error = LoginItem.set(enabled) { model.report(error) }
                }
            ))
            Divider()
            Toggle("Check for Updates Automatically", isOn: $updater.checksAutomatically)
        }
        Menu {
            ForEach(Permissions.Kind.allCases) { kind in
                let state = permissions.state(kind)
                Button {
                    onboarding.allow(kind)
                } label: {
                    Label("\(kind.title): \(state.label)", systemImage: state.symbol)
                }
            }
            Divider()
            Button("Welcome Guide…") { onboarding.show() }
        } label: {
            // No icon: one would indent every other item in this section.
            Text(permissions.allGranted ? "Permissions: All Set" : "Permissions: \(permissions.missing.count) Missing")
        }
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Quit tinyMuesli") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "Allow Microphone Access…", or where to turn it on once macOS won't ask again.
    private static func fixTitle(_ kind: Permissions.Kind, _ state: Permissions.State) -> String {
        let what = switch kind {
        case .microphone: "Microphone Access"
        case .systemAudio: "System Audio Recording"
        case .notifications: "Notifications"
        }
        return state == .notDetermined ? "Allow \(what)…" : "Turn On \(what) in Settings…"
    }
}

/// NSMenu draws `.badge` as a gray pill and can't color it. When a menu opens, the "Ongoing" badge
/// is swapped for a red pill drawn at the end of the item's title.
@MainActor
enum OngoingPill {
    static let label = "Ongoing"
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { note in
            // Posted on the main thread (queue: .main), where the menu lives.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                if let menu { restyle(menu) }
            }
        }
    }

    private static func restyle(_ menu: NSMenu) {
        let font = menu.font ?? NSFont.menuFont(ofSize: 0)
        for item in menu.items where item.badge?.stringValue == label {
            let title = NSMutableAttributedString(string: item.title + "  ", attributes: [.font: font])
            title.append(NSAttributedString(attachment: pill(font: font)))
            item.badge = nil
            item.attributedTitle = title
        }
    }

    private static func pill(font: NSFont) -> NSTextAttachment {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize - 2, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        let size = NSSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centre the pill on the title's capitals.
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        return attachment
    }
}
