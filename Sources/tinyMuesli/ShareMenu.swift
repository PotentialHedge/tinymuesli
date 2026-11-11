import AppKit
import CoreTransferable
import TinyMuesliCore
import UniformTypeIdentifiers

/// A finished meeting as the web page `SharedMeeting` makes, for the share menu. The page is
/// only built when a service asks for it.
struct SharedMeetingPage: Transferable {
    let folder: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .html) { page in
            SentTransferredFile(try SharedMeeting(folder: page.folder).writeTemporaryPage())
        }
    }

    /// The meeting's title, else its app, for the share sheet's preview.
    static func title(of folder: URL) -> String {
        let text = try? String(contentsOf: folder.appendingPathComponent(MeetingFiles.transcript), encoding: .utf8)
        let metadata = text.flatMap(MeetingMetadata.init(parsing:))
        return metadata?.title ?? metadata?.app ?? folder.lastPathComponent
    }

    /// Asks where to save the page.
    @MainActor func save() {
        do {
            let shared = try SharedMeeting(folder: folder)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = shared.fileName
            panel.message = "Anyone can open the page in a browser. With tinyMuesli, they can add the meeting to theirs."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try shared.html().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't Save the Web Page"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
