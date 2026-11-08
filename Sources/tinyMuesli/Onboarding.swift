import AppKit
import SwiftUI
import TinyMuesliCore

/// The welcome window: how tinyMuesli works, the permissions it needs, which apps to record
/// without asking, Apple Intelligence (on Macs that have it), and the AI apps and Raycast it works with. Shows on first launch, and at the permissions page on every launch until they're all allowed;
/// "Show Welcome Guide…" in Settings › Permissions opens it again.
///
/// It opens in the middle of the screen. While macOS asks for a permission, it moves so that the
/// system's prompt sits in the middle of it and explains around it what to click (see `PromptGuide`).
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let permissions: Permissions
    private let state = OnboardingState()
    private var window: NSWindow?

    init(model: AppModel, permissions: Permissions) {
        self.model = model
        self.permissions = permissions
    }

    /// On first launch, including a reinstall that kept the meetings, and again on every launch until
    /// it's been through (quitting the app while it's open doesn't count). After that, at the
    /// permissions page for as long as one is missing: tinyMuesli can't record a meeting without all of them.
    func showIfNeeded() {
        if !Settings.completedOnboarding, Settings.isFirstLaunch {
            // On by default: tinyMuesli can only notice meetings while it's running. The last page (and
            // Settings) can turn it off.
            if !LoginItem.isEnabled, let error = LoginItem.set(true) { model.report(error) }
            Settings.completedOnboarding = false
            return show()
        }
        if Settings.onboardingInProgress { return show() }
        // Someone upgrading from a version without onboarding only sees it if a permission is missing.
        Settings.completedOnboarding = true
        Task {
            await permissions.refreshNow()
            if !permissions.allGranted { show(at: .permissions) }
        }
    }

    /// Opens the window in the middle of the screen (or brings it forward, where it is).
    func show(at step: OnboardingState.Step? = nil) {
        if let step {
            state.go(to: step)
        } else if !permissions.allGranted, state.step.rawValue > OnboardingState.Step.permissions.rawValue {
            // Nothing after the permissions page works without them.
            state.go(to: .permissions)
        }
        if window == nil {
            let view = OnboardingView(
                model: model, permissions: permissions, state: state,
                allow: { [weak self] kind in self?.allow(kind) },
                bringToFront: { [weak self] in self?.bringToFront() },
                finish: { [weak self] in self?.window?.close() }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to tinyMuesli"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            // Size it now: SwiftUI would only do so later, and centring needs the size. The content
            // runs under the title bar, which SwiftUI adds on top of its own height.
            let titleBar = window.frame.height - window.contentLayoutRect.height
            let fitting = hosting.view.fittingSize
            window.setContentSize(NSSize(width: fitting.width, height: fitting.height + titleBar))
            moveToCenter(animated: false)
        } else if state.guide == nil {
            moveToCenter(animated: true)
        }
        bringToFront()
    }

    private func bringToFront() {
        // A menu bar app isn't frontmost, so the window would open behind others.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is refused if the app wasn't opened by the user (e.g. at login): show it anyway.
        window?.orderFrontRegardless()
    }

    /// Exactly in the middle of the screen with the pointer (`NSWindow.center()` puts it higher up).
    private func moveToCenter(animated: Bool) {
        guard let window, let screen = NSScreen.withMouse ?? window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame, size = window.frame.size
        let origin = NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded())
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: animated)
    }

    // MARK: - Guiding through a permission prompt

    /// Asks for a permission, guiding the user through macOS's prompt. If macOS won't ask (any more),
    /// opens System Settings instead.
    func allow(_ kind: Permissions.Kind) {
        guard permissions.state(kind) == .notDetermined else { return permissions.openSettings(kind) }
        show(at: .permissions)
        guard state.guide == nil else { return }

        let guide = PromptGuide(kind: kind)
        state.guide = guide
        // The prompt is a new window: note the ones already there before asking.
        let locator = PromptLocator(kind: kind)
        let request = Task { await permissions.request(kind) }
        Task {
            if let prompt = await locator.find(), state.guide?.id == guide.id {
                place(around: prompt.bounds)
                follow(prompt.number, of: locator, guide: guide.id, from: prompt.bounds)
            } else if kind == .notifications, state.guide?.id == guide.id {
                placeBelowNotifications()
            }
            await request.value
            endGuide(guide.id)
        }
    }

    /// Keeps the window around the prompt if it still moves or changes size.
    private func follow(_ number: Int, of locator: PromptLocator, guide id: UUID, from start: CGRect) {
        Task {
            var last = start
            while state.guide?.id == id {
                try? await Task.sleep(for: .milliseconds(250))
                guard state.guide?.id == id, let bounds = locator.bounds(of: number) else { return }
                if bounds != last {
                    last = bounds
                    place(around: bounds)
                }
            }
        }
    }

    /// Back to the middle once the prompt is answered (or the user went back to setup).
    func endGuide(_ id: UUID? = nil) {
        guard let guide = state.guide, id == nil || guide.id == id else { return }
        state.guide = nil
        moveToCenter(animated: true)
        bringToFront()
    }

    /// Moves the window so the prompt sits in it a little above the middle, leaving room above it for
    /// what to click and below for why.
    private func place(around promptInCG: CGRect) {
        guard let window else { return }
        let prompt = NSScreen.appKitRect(fromCG: promptInCG)
        let screen = NSScreen.screens.first { $0.frame.intersects(prompt) } ?? window.screen ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = window.frame.size
        let above = ((size.height - prompt.height) * 0.42).rounded()
        var origin = NSPoint(x: (prompt.midX - size.width / 2).rounded(), y: prompt.maxY + above - size.height)
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        bringToFront()
        // Where the prompt is, in the window's top-left coordinates (the view draws around it).
        let rect = CGRect(x: prompt.minX - origin.x, y: origin.y + size.height - prompt.maxY,
                          width: prompt.width, height: prompt.height)
        state.guide?.placement = .around(rect)
    }

    /// The notifications prompt is a banner in the top right corner: sit just below it, pointing up.
    private func placeBelowNotifications() {
        guard let window, let screen = NSScreen.withMouse ?? window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame, size = window.frame.size
        // Banners are about 344 wide, 16 from the right edge and roughly 80 tall.
        let bannerMidX = area.maxX - 16 - 172
        let origin = NSPoint(x: area.maxX - size.width - 12, y: area.maxY - 96 - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        bringToFront()
        state.guide?.placement = .belowBanner(arrowX: bannerMidX - origin.x)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early counts too: the menu shows what's still missing, and the next launch opens
        // the permissions page again. (Quitting doesn't close it, so the next launch opens it again.)
        Settings.completedOnboarding = true
        state.guide = nil
        window = nil
    }
}

/// Which page the window is on, and whether it's guiding through a prompt.
@MainActor
@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable {
        case welcome, permissions, apps, intelligence, agents, ready
    }

    /// The pages this Mac gets: Apple Intelligence only where it's supported (Apple silicon).
    let steps = Step.allCases.filter { $0 != .intelligence || AppleIntelligence.status != .notEligible }

    private(set) var step = Step.welcome
    private(set) var forward = true
    var guide: PromptGuide?

    func go(to next: Step) {
        guard next != step else { return }
        forward = next.rawValue > step.rawValue
        // With Reduce Motion, pages fade instead of sliding (see the transition).
        withAnimation(.smooth(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0.35)) { step = next }
    }
}

private struct OnboardingView: View {
    let model: AppModel
    let permissions: Permissions
    let state: OnboardingState
    let allow: (Permissions.Kind) -> Void
    let bringToFront: () -> Void
    let finish: () -> Void

    typealias Step = OnboardingState.Step
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let guide = state.guide {
                PromptGuideView(guide: guide) { [state] in
                    // Leave the prompt to macOS; just stop pointing at it.
                    state.guide = nil
                    bringToFront()
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    ZStack {
                        page(state.step)
                            .id(state.step)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: state.forward ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: state.forward ? .leading : .trailing).combined(with: .opacity)
                            ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    footer
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: state.guide == nil)
        .frame(width: 560, height: 580)
    }

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: WelcomePage(meetingsFolder: model.meetingsFolderName)
        case .permissions: PermissionsPage(permissions: permissions, allow: allow, bringToFront: bringToFront)
        case .apps: AppsPage(model: model)
        case .intelligence: IntelligencePage()
        case .agents: AgentsPage(model: model)
        case .ready: ReadyPage(model: model)
        }
    }

    private var footer: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(state.steps, id: \.self) { s in
                    Circle()
                        .fill(s == state.step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
            HStack {
                if state.step != .welcome {
                    Button("Back") { go(by: -1) }
                        .controlSize(.large)
                }
                Spacer()
                Button(nextTitle) {
                    if state.step == .ready { finish() } else { go(by: 1) }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                // tinyMuesli can't record without them, so they can't be skipped.
                .disabled(state.step == .permissions && !permissions.allGranted)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var nextTitle: String {
        switch state.step {
        case .welcome: "Get Started"
        case .permissions, .apps, .intelligence, .agents: "Continue"
        case .ready: "Done"
        }
    }

    private func go(by offset: Int) {
        guard let index = state.steps.firstIndex(of: state.step),
              state.steps.indices.contains(index + offset) else { return }
        state.go(to: state.steps[index + offset])
    }
}

// MARK: - Pages

/// Big symbol, title and subtitle at the top of each page.
private struct PageHeader: View {
    var symbol: String?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                icon(symbol)
            }
            Text(title)
                .font(.largeTitle.bold())
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 44)
        .padding(.bottom, symbol == nil ? 18 : 24)
        .padding(.horizontal, 40)
    }

    private func icon(_ symbol: String) -> some View {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.bottom, 4)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct WelcomePage: View {
    let meetingsFolder: String

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "waveform", title: "Welcome to tinyMuesli",
                       subtitle: "Notes from every meeting, so you remember what was said.")
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "bell.and.waveform", title: "Notices your meetings",
                        text: "When Zoom, Teams or another meeting app starts using your microphone, tinyMuesli asks whether to record.")
                Feature(symbol: "lock.fill", title: "Transcribes on your Mac",
                        text: "You and the other participants are recorded separately and transcribed on-device. Nothing leaves your Mac.")
                Feature(symbol: "doc.text", title: "Plain files you own",
                        text: "Each meeting becomes a Markdown transcript in \(meetingsFolder), ready for you or your AI agent.")
            }
            .padding(.horizontal, 56)
        }
    }

    private struct Feature: View {
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct PermissionsPage: View {
    let permissions: Permissions
    let allow: (Permissions.Kind) -> Void
    let bringToFront: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "hand.raised.fill", title: "A few permissions",
                       subtitle: "tinyMuesli needs all of these to record a meeting, and only uses them then.")
            VStack(spacing: 10) {
                ForEach(Permissions.Kind.allCases) { kind in
                    PermissionRow(kind: kind, permissions: permissions, allow: allow)
                }
            }
            .padding(.horizontal, 40)
        }
        // Pick up changes made in System Settings while this page is open.
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Once the system prompt is answered (or the switch flipped in System Settings), macOS hands
        // focus back to whichever app was in front before, leaving this window buried behind it.
        // With no Dock icon that looks as if tinyMuesli quit, so come back to the front.
        .onChange(of: Permissions.Kind.allCases.map(permissions.state)) {
            bringToFront()
        }
    }
}

private struct PermissionRow: View {
    let kind: Permissions.Kind
    let permissions: Permissions
    let allow: (Permissions.Kind) -> Void

    var body: some View {
        let state = permissions.state(kind)
        Card {
            HStack(spacing: 14) {
                Image(systemName: kind.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.headline)
                    Text(detail(state))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                switch state {
                case .granted:
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                case .notDetermined:
                    Button("Allow") { allow(kind) }
                        .buttonStyle(.borderedProminent)
                case .denied, .unknown:
                    Button("Open Settings…") { permissions.openSettings(kind) }
                }
            }
        }
    }

    private func detail(_ state: Permissions.State) -> String {
        switch state {
        case .denied:
            "\(kind.purpose) Turn on tinyMuesli in System Settings."
        case .granted where kind == .notifications && permissions.notificationsAreTemporary:
            "\(kind.purpose) Tip: choose Persistent in System Settings so prompts stay until you answer."
        default:
            kind.purpose
        }
    }
}

private struct AppsPage: View {
    let model: AppModel

    /// Meeting apps on this Mac, with their icons.
    private let installed: [(app: MeetingApp, icon: NSImage)] = MeetingApps.known.compactMap { app in
        let url = ([app.id] + app.bundleIDs).lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        return url.map { (app, NSWorkspace.shared.icon(forFile: $0.path)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "record.circle", title: "Always record",
                       subtitle: "Pick apps to record without asking. For the others, tinyMuesli sends a notification first.")
            if installed.isEmpty {
                Card {
                    Text("No meeting apps found. When one uses your microphone, the notification can set it to always record.")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Card {
                            HStack(spacing: 10) {
                                Image(systemName: "checklist")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 26)
                                Text("All apps").font(.headline)
                                Spacer()
                                Toggle("All apps", isOn: Binding(
                                    get: { installed.allSatisfy { model.alwaysRecord.contains($0.app.id) } },
                                    set: { on in installed.forEach { model.setAlwaysRecord($0.app.id, on) } }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            }
                        }
                        group("Meeting apps", apps: installed.filter { $0.app.kind == .native })
                        group("Browsers", note: "Records whenever a website uses the mic, not only meetings.",
                              apps: installed.filter { $0.app.kind == .browser })
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, note: String? = nil, apps: [(app: MeetingApp, icon: NSImage)]) -> some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                Card {
                    VStack(spacing: 10) {
                        ForEach(Array(apps.enumerated()), id: \.element.app.id) { index, entry in
                            if index > 0 { Divider() }
                            HStack(spacing: 10) {
                                Image(nsImage: entry.icon).resizable().frame(width: 26, height: 26)
                                Text(entry.app.name)
                                Spacer()
                                Toggle(entry.app.name, isOn: Binding(
                                    get: { model.alwaysRecord.contains(entry.app.id) },
                                    set: { model.setAlwaysRecord(entry.app.id, $0) }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ReadyPage: View {
    let model: AppModel
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "checkmark", title: "You're all set",
                       subtitle: "tinyMuesli lives in your menu bar and waits for your next meeting.")
            VStack(spacing: 10) {
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "menubar.rectangle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find it in the menu bar").font(.headline)
                            Text("Click \(Image(systemName: "waveform")) to start a recording, open recent meetings or change settings.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 14) {
                            Image(systemName: "power")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Open at Login").font(.headline)
                                Text("So tinyMuesli is always there to notice a meeting.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { enabled in
                                loginError = LoginItem.set(enabled)
                                openAtLogin = LoginItem.isEnabled
                            }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        if let loginError {
                            Text(loginError).font(.callout).foregroundStyle(.red)
                        }
                    }
                }
                if let raycast = Raycast.app {
                    RaycastCard(icon: NSWorkspace.shared.icon(forFile: raycast.path))
                }
            }
            .padding(.horizontal, 40)
        }
    }
}

/// Raycast, if it's on this Mac, and whether the tinyMuesli extension is in it.
private enum Raycast {
    static var app: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.raycast.macos")
    }

    /// The extension isn't in the Raycast Store, so it's installed from the repository.
    static let extensionPage = URL(string: "https://github.com/PotentialHedge/tinymuesli/tree/main/raycast")!

    /// Raycast keeps each extension in a folder of its own (named after it for one loaded from
    /// source, otherwise by an id), with the extension's `package.json` inside.
    static var hasExtension: Bool {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/raycast/extensions")
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.contains { entry in
            guard let data = try? Data(contentsOf: entry.appending(path: "package.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return manifest["name"] as? String == "tinymuesli"
        }
    }
}

private struct RaycastCard: View {
    let icon: NSImage
    @State private var installed = Raycast.hasExtension

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search from Raycast").font(.headline)
                    Text("Find a meeting or anything that was said, and name its speakers, without leaving the keyboard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if installed {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                } else {
                    Button("Get Extension…") { NSWorkspace.shared.open(Raycast.extensionPage) }
                }
            }
        }
        // Pick it up once it's installed while this page is open.
        .task {
            while !Task.isCancelled, !installed {
                try? await Task.sleep(for: .seconds(1))
                installed = Raycast.hasExtension
            }
        }
    }
}

/// Apple Intelligence's state, and what to change if it's off or stuck (most often: Siri's language
/// doesn't match the Mac's, so the model never downloads).
private struct IntelligencePage: View {
    @State private var status = AppleIntelligence.status
    @State private var mismatch = AppleIntelligence.languageMismatch
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "apple.intelligence", title: "Apple Intelligence",
                       subtitle: "Apple's on-device model lets tinyMuesli work with your meetings without anything leaving your Mac.")
            VStack(spacing: 10) {
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "cpu")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.headline)
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        switch status {
                        case .ready:
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .fontWeight(.medium)
                        case .notReady where mismatch == nil:
                            ProgressView().controlSize(.small)
                        default:
                            Button("Open Settings…") { AppleIntelligence.openSettings() }
                        }
                    }
                }
                if status != .ready, let mismatch {
                    Card {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "character.bubble")
                                .font(.title3)
                                .foregroundStyle(.orange)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Match Siri's language").font(.headline)
                                Text("Your Mac uses \(mismatch.mac), but Siri is set to \(mismatch.siri). Apple Intelligence only turns on when they're the same: change Siri's language in Apple Intelligence & Siri, or your Mac's in General › Language & Region.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if status != .ready {
                    Card {
                        HStack(spacing: 14) {
                            Text("Stuck? Your AI agent can check this Mac's settings and walk you through the fix.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(copied ? "Copied" : "Copy Prompt for Agent") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(AppleIntelligence.fixPrompt(), forType: .string)
                                copied = true
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
        }
        // Pick up changes made in System Settings, and the download finishing, while this page is open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                status = AppleIntelligence.status
                mismatch = AppleIntelligence.languageMismatch
            }
        }
    }

    private var title: String {
        switch status {
        case .ready: "Ready to use"
        case .turnedOff: "Turned off"
        case .notReady where mismatch != nil: "Waiting for a setting"
        case .notReady, .notEligible: "Downloading the model"
        }
    }

    private var detail: String {
        switch status {
        case .ready: "The model is on your Mac."
        case .turnedOff: "Turn on Apple Intelligence in System Settings. It's optional: recording and transcription work without it."
        case .notReady where mismatch != nil: "macOS won't download the model until the languages below match."
        case .notReady, .notEligible: "This can take a while. Keep your Mac on power and Wi-Fi; you can carry on in the meantime."
        }
    }
}

private struct AgentsPage: View {
    let model: AppModel

    private struct Agent: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
    }

    /// The AI apps on this Mac that tinyMuesli can add itself to.
    private let agents: [Agent] = [
        AppModel.claudeApp.map { Agent(id: "claude", name: "Claude", icon: NSWorkspace.shared.icon(forFile: $0.path)) },
        AppModel.chatGPTApp.map { Agent(id: "chatgpt", name: "ChatGPT", icon: NSWorkspace.shared.icon(forFile: $0.path)) },
    ].compactMap { $0 }

    @State private var added: Set<String> = []
    @State private var problem: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Ask about your meetings",
                       subtitle: "Your AI app can read your transcripts through tinyMuesli, right on your Mac.")
            VStack(spacing: 14) {
                ChatMock(question: "Give me a to-do list from my last meeting")
                if agents.isEmpty {
                    Card {
                        HStack(spacing: 14) {
                            Text("Works with AI apps that support MCP, like Claude or ChatGPT. The setup prompt tells your agent how to connect.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(copied ? "Copied" : "Copy Setup Prompt") {
                                model.copyAgentPrompt()
                                copied = true
                            }
                        }
                    }
                } else {
                    Card {
                        VStack(spacing: 10) {
                            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                                if index > 0 { Divider() }
                                row(agent)
                            }
                        }
                    }
                }
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 40)
        }
        // Claude is added through a few dialogs (it has to restart): keep checking the configs.
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ agent: Agent) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: agent.icon).resizable().frame(width: 28, height: 28)
            Text(agent.name).font(.headline)
            Spacer()
            if added.contains(agent.id) {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.medium)
            } else {
                Button("Add to \(agent.name)") { add(agent) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func add(_ agent: Agent) {
        switch agent.id {
        case "claude": model.addToClaudeDesktop()
        default: problem = model.addToChatGPT()
        }
        refresh()
    }

    private func refresh() {
        var now: Set<String> = []
        if ClaudeDesktopConfig.isInstalled() { now.insert("claude") }
        if CodexConfig.isInstalled() { now.insert("chatgpt") }
        if now != added { added = now }
    }
}

/// An abstract chat: the question, and an answer drawn as placeholder lines, with a note that it
/// came from tinyMuesli. Shows what's possible without pretending to be any particular app.
private struct ChatMock: View {
    let question: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.quaternary).frame(width: 9, height: 9)
                }
            }
            HStack {
                Spacer(minLength: 60)
                Text(question)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: 9) {
                    Label("Read your last meeting with tinyMuesli", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach([190.0, 150, 170], id: \.self) { width in
                        HStack(spacing: 8) {
                            Image(systemName: "square")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Capsule().fill(.quaternary).frame(width: width, height: 9)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}
