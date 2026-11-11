import AppKit
import OSLog
import SwiftUI
import TinyMuesliCore

private let log = Logger(subsystem: "com.tinymuesli", category: "share")

/// Sharing a finished meeting: the system share menu with the meeting's web page, except that Mail
/// writes the transcript into the email itself (`MailComposer`). Mail keeps attachments in its own
/// container, where Safari isn't allowed to open them, so an attached page would open only after
/// being saved somewhere else first.
@MainActor
final class MeetingSharer: NSObject, @preconcurrency NSSharingServicePickerDelegate {
    static let shared = MeetingSharer()
    private var meeting: SharedMeeting?

    /// Shows the share menu next to `rect` in `view`.
    func share(folder: URL, relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge) {
        do {
            let meeting = try SharedMeeting(folder: folder)
            let page = try meeting.writeTemporaryPage()
            self.meeting = meeting
            let picker = NSSharingServicePicker(items: [page])
            picker.delegate = self
            picker.show(relativeTo: rect, of: view, preferredEdge: edge)
        } catch {
            Self.alert("Couldn't Share the Meeting", error)
        }
    }

    /// The share menu where the pointer is, for a menu item.
    func shareAtPointer(folder: URL) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        share(folder: folder, relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .maxY)
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        guard MailComposer.isDefaultMailApp, let meeting,
              let mailTitle = NSSharingService(named: .composeEmail)?.title,
              let index = proposed.firstIndex(where: { $0.title == mailTitle })
        else { return proposed }
        var services = proposed
        let mail = proposed[index]
        services[index] = NSSharingService(title: mail.title, image: mail.image, alternateImage: mail.alternateImage) {
            MainActor.assumeIsolated { MailComposer.compose(meeting) }
        }
        return services
    }

    static func alert(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// Writes a shared meeting into a new email in Mail, as the email's own text: the chat with its
/// bubbles, and the Add to tinyMuesli link. Only Mail's scripting can set an email's HTML (the
/// share menu hands Mail rich text, which loses the bubbles), and it can't keep that HTML intact
/// alongside an attachment, so the page isn't attached: the email holds everything it does.
@MainActor
enum MailComposer {
    static let mailBundleID = "com.apple.mail"

    /// Whether email goes through Apple Mail. Other mail apps get the page attached, as usual.
    static var isDefaultMailApp: Bool {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:x@example.com")!) else { return false }
        return Bundle(url: url)?.bundleIdentifier == mailBundleID
    }

    static func compose(_ meeting: SharedMeeting) {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tinyMuesli Shared", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let body = dir.appendingPathComponent("email.html")
            try meeting.emailHTML().write(to: body, atomically: true, encoding: .utf8)
            let source = """
            tell application "Mail"
              set m to make new outgoing message with properties {subject:\(appleScriptString(meeting.emailSubject)), visible:true}
              set html content of m to (read (POSIX file \(appleScriptString(body.path))) as «class utf8»)
              activate
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return }
            log.error("Mail script failed: \(error, privacy: .public)")
            // Not allowed to control Mail (-1743), or Mail refused: attach the page instead.
            let page = try meeting.writeTemporaryPage()
            let service = NSSharingService(named: .composeEmail)
            service?.subject = meeting.emailSubject
            service?.perform(withItems: [page])
        } catch {
            MeetingSharer.alert("Couldn't Write the Email", error)
        }
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// A toolbar button that opens the share menu below itself.
struct ShareButton: View {
    let folder: URL
    @State private var anchor = Anchor()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            MeetingSharer.shared.share(folder: folder, relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .background(AnchorView(anchor: anchor))
    }

    final class Anchor {
        weak var view: NSView?
    }

    private struct AnchorView: NSViewRepresentable {
        let anchor: Anchor
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            anchor.view = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
    }
}

/// Saves a finished meeting's web page where the user chooses.
enum WebPageExport {
    @MainActor static func save(folder: URL) {
        do {
            let shared = try SharedMeeting(folder: folder)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = shared.fileName
            panel.message = "Anyone can open the page in a browser. With tinyMuesli, they can add the meeting to theirs."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try shared.html().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            MeetingSharer.alert("Couldn't Save the Web Page", error)
        }
    }
}
