import AppKit
import CoreGraphics
import SwiftUI

/// macOS asking for a permission, and where its prompt is relative to the onboarding window.
struct PromptGuide: Equatable {
    enum Placement: Equatable {
        /// Waiting for the prompt to appear (or it couldn't be found).
        case waiting
        /// The prompt is this rect, in the window's coordinates (origin top left): draw around it.
        case around(CGRect)
        /// The prompt is a notification banner above the window, at this x: point up at it.
        case belowBanner(arrowX: CGFloat)
    }

    let id = UUID()
    let kind: Permissions.Kind
    var placement = Placement.waiting
}

/// Finds the window of the permission prompt macOS shows. Microphone and system audio prompts come
/// from the UserNotificationCenter process (a small dialog above all windows); the notifications
/// prompt is a banner, which isn't looked for. Only needs window bounds, not screen recording.
@MainActor
struct PromptLocator {
    private let owner: String?
    private let existing: Set<Int>

    /// Create before asking, so windows that were already there don't count.
    init(kind: Permissions.Kind) {
        owner = kind == .notifications ? nil : "UserNotificationCenter"
        existing = Set(Self.windows(of: owner).map(\.number))
    }

    /// The prompt's window number and frame, in Core Graphics screen coordinates (origin top left of
    /// the main screen). macOS animates the prompt in, so this waits for its frame to settle.
    func find(timeout: Duration = .seconds(3)) async -> (number: Int, bounds: CGRect)? {
        guard owner != nil else { return nil }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let prompt = Self.windows(of: owner).first(where: { !existing.contains($0.number) }) {
                return (prompt.number, await settledBounds(of: prompt.number) ?? prompt.bounds)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The frame once it's the same twice in a row (or after a second). Nil if the window went away.
    private func settledBounds(of number: Int) async -> CGRect? {
        var last = bounds(of: number)
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(100))
            let current = bounds(of: number)
            if current == last { return current }
            last = current
        }
        return last
    }

    /// Where that window is now; nil once it has closed.
    func bounds(of number: Int) -> CGRect? {
        Self.windows(of: owner).first { $0.number == number }?.bounds
    }

    private static func windows(of owner: String?) -> [(number: Int, bounds: CGRect)] {
        guard let owner,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard info[kCGWindowOwnerName as String] as? String == owner,
                  (info[kCGWindowLayer as String] as? Int ?? 0) > 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width > 100, bounds.height > 60
            else { return nil }
            return (number, dialog(in: bounds))
        }
    }

    /// The prompt is a dialog 260 wide, but its window can be bigger, with a clear border of the same
    /// width on every side (75 on a 1x display, where the window is 410 × 400). Only the dialog counts.
    private static func dialog(in window: CGRect) -> CGRect {
        let border = max((window.width - 260) / 2, 0)
        guard window.height - 2 * border > 60 else { return window }
        return window.insetBy(dx: border, dy: border)
    }
}

extension NSScreen {
    static var withMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// Core Graphics measures from the top left of the main screen, AppKit from its bottom left.
    static func appKitRect(fromCG rect: CGRect) -> NSRect {
        let height = screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}

private extension Permissions.Kind {
    var promptTitle: String {
        switch self {
        case .microphone: "Click “Allow” to let tinyMuesli use the microphone"
        case .systemAudio: "Click “Allow” to let tinyMuesli record system audio"
        case .notifications: "Click “Allow” on the notification"
        case .accessibility: "Click “Open System Settings”, then turn on tinyMuesli"
        }
    }

    var promptReason: String {
        switch self {
        case .microphone: "That's how your side of the meeting gets into the transcript."
        case .systemAudio: "That's how the other participants get into the transcript. It's only the sound, never your screen."
        case .notifications: "Then tinyMuesli can ask whether to record when a meeting starts."
        case .accessibility: "Then tinyMuesli sees when you mute yourself in the call, and doesn't record you then."
        }
    }
}

/// Fills the onboarding window while macOS's prompt is up: what to click above the prompt, a ring
/// and arrows around it, and why below it.
struct PromptGuideView: View {
    let guide: PromptGuide
    let backToSetup: () -> Void

    @State private var pulse = false
    /// With Reduce Motion the ring and arrows hold still.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            switch guide.placement {
            case .around(let prompt):
                around(prompt, in: size)
            case .belowBanner(let arrowX):
                belowBanner(arrowX: arrowX, in: size)
            case .waiting:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Waiting for macOS to ask…").foregroundStyle(.secondary)
                    backButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .onAppear { pulse = !reduceMotion }
    }

    private func around(_ prompt: CGRect, in size: CGSize) -> some View {
        let ring = prompt.insetBy(dx: -14, dy: -14)
        let titleBar: CGFloat = 28
        let aboveHeight = max(ring.minY - titleBar, 0)
        let belowHeight = max(size.height - ring.maxY, 0)
        return ZStack(alignment: .topLeading) {
            Color.clear

            // Above: what to do.
            VStack(spacing: 6) {
                Image(systemName: guide.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(guide.kind.promptTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .frame(width: size.width, height: aboveHeight)
            .offset(y: titleBar)

            // Around the prompt: a pulsing ring and arrows pointing in from both sides.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                .frame(width: ring.width, height: ring.height)
                .scaleEffect(pulse ? 1.03 : 1)
                .opacity(pulse || reduceMotion ? 1 : 0.6)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .offset(x: ring.minX, y: ring.minY)
            arrow("arrow.right", at: CGPoint(x: ring.minX - 34, y: ring.midY), nudge: pulse ? 6 : 0)
            arrow("arrow.left", at: CGPoint(x: ring.maxX + 34, y: ring.midY), nudge: pulse ? -6 : 0)

            // Below: why, and a way out.
            VStack(spacing: 12) {
                Text(guide.kind.promptReason)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Audio never leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                backButton
            }
            .padding(.horizontal, 40)
            .frame(width: size.width, height: belowHeight)
            .offset(y: ring.maxY)
        }
    }

    private func belowBanner(arrowX: CGFloat, in size: CGSize) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "arrow.up")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .offset(y: pulse ? -8 : 0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: min(max(arrowX, 30), size.width - 30) - 17)
                .padding(.top, 40)
            VStack(spacing: 10) {
                Image(systemName: guide.kind.symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text(guide.kind.promptTitle)
                    .font(.title2.bold())
                Text("It's in the top right corner of your screen. \(guide.kind.promptReason)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Don't see it? A Focus may be holding it back. Click the date in the menu bar to find it in Notification Center.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                backButton
                    .padding(.top, 6)
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)
            Spacer()
        }
    }

    private func arrow(_ symbol: String, at point: CGPoint, nudge: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 40, height: 40)
            .offset(x: point.x - 20 + nudge, y: point.y - 20)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
    }

    private var backButton: some View {
        Button("Back to Setup", action: backToSetup)
            .buttonStyle(.link)
    }
}
