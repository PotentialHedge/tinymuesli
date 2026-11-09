import AppKit
import CoreServices

/// Asks before quitting would cut off a recording, a final pass or a move of the meetings folder.
///
/// Logging out, restarting and shutting down aren't held up by a question: they stop the recording
/// and quit, as SIGTERM (`kill`, which the installer uses to update) does. Either way the audio is
/// complete, and the final pass runs at the next launch.
@MainActor
final class QuitGuard: NSObject, NSApplicationDelegate {
    /// Set by the app at launch, before anything can quit it.
    static var model: AppModel?

    private var signalSource: DispatchSourceSignal?
    /// "Quit When Done" was chosen: quits once nothing is in progress.
    private var waitTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Self.model?.prepareToQuit()
                exit(0)
            }
        }
        source.resume()
        signalSource = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, let blocker = model.quitBlocker else { return .terminateNow }
        if Self.sessionIsEnding {
            model.prepareToQuit()
            return .terminateNow
        }
        waitTask?.cancel()
        waitTask = nil

        switch ask(about: blocker) {
        case .stopAndQuit, .quitNow:
            model.prepareToQuit()
            return .terminateNow
        case .quitWhenDone:
            waitTask = Task {
                while !Task.isCancelled, model.isBusy {
                    try? await Task.sleep(for: .seconds(1))
                }
                if !Task.isCancelled { NSApp.terminate(nil) }
            }
            return .terminateCancel
        case .cancel:
            return .terminateCancel
        }
    }

    private enum Choice { case stopAndQuit, quitNow, quitWhenDone, cancel }

    private func ask(about blocker: AppModel.QuitBlocker) -> Choice {
        let alert = NSAlert()
        let choices: [Choice]
        switch blocker {
        case .recording(let paused):
            alert.messageText = paused
                ? "Stop the paused meeting and quit?"
                : "Stop recording and quit?"
            alert.informativeText = "Everything recorded so far is kept, and its transcript is finished the next time tinyMuesli opens."
            alert.addButton(withTitle: "Stop Recording and Quit")
            choices = [.stopAndQuit]
        case .moving:
            alert.messageText = "tinyMuesli is moving your meetings"
            alert.informativeText = "Quitting now would leave them split between the old and the new folder."
            alert.addButton(withTitle: "Quit When Done")
            choices = [.quitWhenDone]
        case .processing:
            alert.messageText = "tinyMuesli is still transcribing a meeting"
            alert.informativeText = "If you quit now, it starts over the next time tinyMuesli opens."
            alert.addButton(withTitle: "Quit When Done")
            alert.addButton(withTitle: "Quit Now")
            choices = [.quitWhenDone, .quitNow]
        }
        alert.addButton(withTitle: "Cancel")
        // A menu bar app isn't frontmost, so the alert would open behind other windows.
        NSApp.activate()
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return index < choices.count ? choices[index] : .cancel
    }

    /// The quit comes from logging out, restarting or shutting down.
    private static var sessionIsEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return false }
        let endings = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        return endings.map { OSType($0) }.contains(reason)
    }
}
