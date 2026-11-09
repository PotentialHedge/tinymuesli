import AppKit
import SwiftUI
import TinyMuesliCore

/// The Settings window (⌘, or Settings… in the menu): everything the menu used to hold in its
/// Settings and Permissions submenus, plus adding tinyMuesli to the chat assistants.
struct SettingsView: View {
    let model: AppModel
    let updater: Updater
    let permissions: Permissions
    let onboarding: Onboarding

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(model: model, updater: updater)
            }
            Tab("Recording", systemImage: "waveform") {
                RecordingSettings(model: model)
            }
            Tab("Assistants", systemImage: "bubble.left.and.text.bubble.right") {
                AssistantSettings(model: model)
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionSettings(permissions: permissions, onboarding: onboarding)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let model: AppModel
    let updater: Updater
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { openAtLogin },
                    set: { enabled in
                        loginError = LoginItem.set(enabled)
                        openAtLogin = LoginItem.isEnabled
                    }
                )) {
                    Text("Open at Login")
                    Text(loginError ?? "tinyMuesli can only notice meetings while it's running.")
                }
            }
            Section("Meetings Folder") {
                LabeledContent {
                    HStack {
                        Button("Show in Finder") { model.openMeetingsFolder() }
                        Button("Change…") { model.chooseMeetingsFolder() }
                    }
                } label: {
                    Label {
                        Text(model.meetingsFolderName).truncationMode(.middle)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.store.root.path))
                            .resizable().frame(width: 16, height: 16)
                    }
                }
                if let moving = model.movingText {
                    Text(moving).foregroundStyle(.secondary)
                }
            }
            Section("Updates") {
                Toggle("Check for Updates Automatically", isOn: $updater.checksAutomatically)
                LabeledContent("Version \(Self.version)") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Login items can be changed in System Settings.
            openAtLogin = LoginItem.isEnabled
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

// MARK: - Recording

private struct RecordingSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
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
            } footer: {
                Text("Transcription runs on this Mac. You can switch the language during a meeting from the menu.")
                    .settingsFooter()
            }
            Section {
                Toggle(isOn: $model.followCallMute) {
                    Text("Don't Record Me While Muted in the Call")
                    Text("While the call app shows you as muted, your mic records silence.")
                }
                if model.followCallMute, !model.muteAccessAllowed {
                    LabeledContent("Needs Accessibility access to see the call's mute button.") {
                        Button("Allow…") { model.requestMuteAccess() }
                    }
                    .foregroundStyle(.secondary)
                }
                Toggle(isOn: $model.skipSilence) {
                    Text("Skip Silence While Recording")
                    Text("Stretches without speech are stored as silence, so a quiet room takes almost no space.")
                }
                Toggle(isOn: $model.keepAudio) {
                    Text("Keep Audio After Transcribing")
                    Text("Off: only the transcript is kept.")
                }
                if AppleIntelligence.status != .notEligible {
                    IntelligenceSettings(model: model)
                }
            }
            Section {
                ForEach(apps) { app in
                    Toggle(isOn: Binding(
                        get: { model.alwaysRecord.contains(app.id) },
                        set: { model.setAlwaysRecord(app.id, $0) }
                    )) {
                        Label {
                            Text(app.name)
                        } icon: {
                            if let icon = AppIcon.icon(for: app.name) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                        }
                    }
                }
            } header: {
                Text("Always Record")
            } footer: {
                Text("When these apps use the mic, recording starts without asking. Other apps ask with a notification.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    /// Meeting apps on this Mac, and any chosen before that aren't any more.
    private var apps: [MeetingApp] {
        MeetingApps.known.filter { AppIcon.icon(for: $0.name) != nil || model.alwaysRecord.contains($0.id) }
    }
}

/// The Suggest Titles and Names toggle, and while Apple Intelligence isn't ready, what's in the way:
/// turned off, a language mismatch, or the model still downloading. Checked every second while
/// shown, so turning it on in System Settings, or the download finishing, shows up here.
private struct IntelligenceSettings: View {
    let model: AppModel
    @State private var status = AppleIntelligence.status
    @State private var mismatch = AppleIntelligence.languageMismatch
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        Toggle(isOn: $model.suggestWithAppleIntelligence) {
            Text("Suggest Titles and Names")
            Text("Apple Intelligence suggests a title, tags and speaker names for each meeting, on your Mac.")
        }
        .task {
            guard status != .ready else { return }
            while !Task.isCancelled, status != .ready {
                try? await Task.sleep(for: .seconds(1))
                status = AppleIntelligence.status
                mismatch = AppleIntelligence.languageMismatch
            }
            // Just became ready: catch up on the meetings recorded while it wasn't.
            if status == .ready { model.suggestForEarlierMeetings() }
        }
        if status != .ready {
            LabeledContent {
                if status == .notReady, mismatch == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Open Settings…") { AppleIntelligence.openSettings() }
                }
            } label: {
                Text(title)
                Text(detail)
            }
            LabeledContent("Stuck? Your AI agent can check this Mac's settings and walk you through the fix.") {
                Button(copied ? "Copied" : "Copy Prompt for Agent") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppleIntelligence.fixPrompt(), forType: .string)
                    copied = true
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch status {
        case .ready: "Apple Intelligence is ready"
        case .turnedOff: "Apple Intelligence is turned off"
        case .notReady where mismatch != nil: "Apple Intelligence is waiting for a setting"
        case .notReady, .notEligible: "Apple Intelligence is downloading its model"
        }
    }

    private var detail: String {
        switch status {
        case .ready: ""
        case .turnedOff: "Turn it on in System Settings › Apple Intelligence & Siri. Suggestions start once its model has downloaded."
        case .notReady where mismatch != nil:
            "Your Mac uses \(mismatch?.mac ?? ""), but Siri is set to \(mismatch?.siri ?? ""). macOS only downloads the model when they're the same."
        case .notReady, .notEligible: "This can take a while. Keep your Mac on power and Wi-Fi; suggestions start once it's done."
        }
    }
}

// MARK: - Assistants

private struct AssistantSettings: View {
    let model: AppModel
    @State private var added = Set(ChatHandoff.Service.withMCPServer)
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                assistant(.claude, app: AppModel.claudeApp) { model.addToClaudeDesktop() }
                assistant(.chatGPT, app: AppModel.chatGPTApp) { model.addToChatGPT(confirm: true) }
            } footer: {
                Text("Adds tinyMuesli's MCP server, so the assistant can list, search and read your meetings. Nothing leaves your Mac until you ask it about one.")
                    .settingsFooter()
            }
            Section {
                LabeledContent {
                    Button(copied ? "Copied" : "Copy Prompt") {
                        model.copyAgentPrompt()
                        copied = true
                    }
                } label: {
                    Text("Prompt for Agents")
                    Text("Explains where your meetings are and how to search them. Paste it into an agent's instructions, or a coding agent that can run commands.")
                }
            }
        }
        .formStyle(.grouped)
        // The configs can change outside tinyMuesli, and adding to Claude finishes after a restart.
        .task {
            while !Task.isCancelled {
                let now = Set(ChatHandoff.Service.withMCPServer)
                if now != added { added = now }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private func assistant(_ service: ChatHandoff.Service, app: URL?, add: @escaping () -> Void) -> some View {
        LabeledContent {
            if added.contains(service) {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Add…", action: add)
                    .disabled(app == nil)
            }
        } label: {
            Label {
                Text(service.name)
                if app == nil, !added.contains(service) { Text("Not installed") }
            } icon: {
                if let app {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.dashed")
                }
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    let permissions: Permissions
    let onboarding: Onboarding

    var body: some View {
        Form {
            Section {
                ForEach(Permissions.Kind.allCases) { kind in
                    let state = permissions.state(kind)
                    LabeledContent {
                        switch state {
                        case .granted:
                            Label(state.label, systemImage: state.symbol).foregroundStyle(.green)
                        case .notDetermined:
                            Button("Allow…") { onboarding.allow(kind) }
                        case .denied:
                            Button("Open System Settings…") { permissions.openSettings(kind) }
                        case .unknown:
                            Label(state.label, systemImage: state.symbol).foregroundStyle(.secondary)
                        }
                    } label: {
                        Label {
                            Text(kind.title)
                            Text(kind == .notifications && permissions.notificationsAreTemporary
                                 ? "\(kind.purpose) Tip: choose Persistent in System Settings so prompts stay until you answer."
                                 : kind.purpose)
                        } icon: {
                            Image(systemName: kind.symbol)
                                .foregroundStyle(state == .granted ? Color.accentColor : .orange)
                                .frame(width: 20)
                        }
                    }
                }
            }
            Section {
                LabeledContent {
                    Button("Show Welcome Guide…") { onboarding.show() }
                } label: {
                    Text("Welcome Guide")
                    Text("Walks through the permissions again, step by step.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }
}

private extension Text {
    func settingsFooter() -> some View {
        font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
