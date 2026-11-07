import Foundation
import TinyMuesliCore
import UserNotifications

/// The "Zoom is using your microphone. Record?" prompt. Shortly after another meeting ended, it
/// also offers to continue that one instead. And the "meeting ended" notice, from which a meeting can
/// be continued (while that's still possible), opened or deleted. And, while recording, the offer to
/// switch the transcript to the language people seem to be speaking.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    enum Action {
        case record(appID: String)
        case alwaysRecord(appID: String)
        case continueMeeting(appID: String)
        /// From the "meeting ended" notice: carry on recording that meeting.
        case resumeMeeting(folder: URL)
        case openMeeting(folder: URL)
        case deleteMeeting(folder: URL)
        /// From the language suggestion: switch, or keep the current language.
        case switchLanguage
        case keepLanguage
    }

    var onAction: ((Action) -> Void)?

    nonisolated private static let category = "meeting-detected"
    nonisolated private static let continuableCategory = "meeting-detected-continuable"
    nonisolated private static let continueAction = "continue"
    nonisolated private static let recordAction = "record"
    nonisolated private static let alwaysRecordAction = "always-record"
    nonisolated private static let promptID = "meeting-prompt"
    nonisolated private static let appIDKey = "appID"
    nonisolated private static let endedCategory = "meeting-ended"
    nonisolated private static let endedContinuableCategory = "meeting-ended-continuable"
    nonisolated private static let resumeAction = "resume"
    nonisolated private static let openAction = "open"
    nonisolated private static let deleteAction = "delete"
    nonisolated private static let folderKey = "folder"
    nonisolated private static let languageCategory = "language-suggestion"
    nonisolated private static let switchLanguageAction = "switch-language"
    nonisolated private static let keepLanguageAction = "keep-language"
    nonisolated private static let languageID = "language-suggestion"

    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let alwaysRecord = UNNotificationAction(identifier: Self.alwaysRecordAction, title: "Always Record This App")
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open Transcript Folder")
        // Not destroyed from here: the app asks for confirmation first.
        let delete = UNNotificationAction(identifier: Self.deleteAction, title: "Delete Meeting…", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [UNNotificationAction(identifier: Self.recordAction, title: "Record"), alwaysRecord],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.continuableCategory,
                actions: [
                    UNNotificationAction(identifier: Self.continueAction, title: "Continue Previous Meeting"),
                    UNNotificationAction(identifier: Self.recordAction, title: "Record New Meeting"),
                    alwaysRecord,
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.endedContinuableCategory,
                actions: [UNNotificationAction(identifier: Self.resumeAction, title: "Continue Recording"), open, delete],
                intentIdentifiers: []
            ),
            UNNotificationCategory(identifier: Self.endedCategory, actions: [open, delete], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Self.languageCategory,
                actions: [
                    UNNotificationAction(identifier: Self.switchLanguageAction, title: "Switch Language"),
                    UNNotificationAction(identifier: Self.keepLanguageAction, title: "Keep Current Language"),
                ],
                intentIdentifiers: []
            ),
        ])
        // Permission is asked for in onboarding (or from the menu), not at launch.
    }

    /// - Parameter previous: a recently ended meeting that this one could continue, if any.
    func promptToRecord(_ app: MeetingApp, previous: String? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(app.name) is using your microphone"
        if let previous {
            content.body = "Record this meeting, or continue “\(previous)”?"
            content.categoryIdentifier = Self.continuableCategory
        } else {
            content.body = "Record this meeting?"
            content.categoryIdentifier = Self.category
        }
        content.userInfo = [Self.appIDKey: app.id]
        // Asking is only useful while the meeting is on, so try to get past a Focus. Without the
        // time-sensitive entitlement this needs tinyMuesli allowed in the Focus's settings.
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: Self.promptID, content: content, trigger: nil))
    }

    func removePrompt() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.promptID])
    }

    /// "Zoom meeting ended". - Parameter continuableUntil: offer to continue recording until then.
    /// - Parameter quietly: updates an earlier notice (e.g. the chance to continue has passed)
    ///   without showing it again.
    func meetingEnded(_ title: String, folder: URL, length: String, continuableUntil: Date?, quietly: Bool = false) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(title) ended"
        if let continuableUntil {
            let until = continuableUntil.formatted(date: .omitted, time: .shortened)
            content.body = "Recorded \(length). You can continue recording until \(until)."
            content.categoryIdentifier = Self.endedContinuableCategory
        } else {
            content.body = "Recorded \(length). The transcript is being finished."
            content.categoryIdentifier = Self.endedCategory
        }
        content.userInfo = [Self.folderKey: folder.path]
        if quietly {
            content.interruptionLevel = .passive
        } else {
            content.sound = .default
            // Continuing is only possible for a few minutes, so like the record prompt, try to get past a Focus.
            if continuableUntil != nil { content.interruptionLevel = .timeSensitive }
        }
        center.add(UNNotificationRequest(identifier: Self.endedID(folder), content: content, trigger: nil))
    }

    /// "The others seem to be speaking German". Replaces an earlier suggestion.
    func suggestLanguage(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.languageCategory
        content.interruptionLevel = .timeSensitive  // only useful during the meeting
        center.add(UNNotificationRequest(identifier: Self.languageID, content: content, trigger: nil))
    }

    func removeLanguageSuggestion() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.languageID])
    }

    func removeMeetingEnded(folder: URL) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.endedID(folder)])
    }

    private static func endedID(_ folder: URL) -> String {
        "meeting-ended:\(folder.standardizedFileURL.path)"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        if response.notification.request.content.categoryIdentifier == Self.languageCategory {
            await MainActor.run {
                switch actionID {
                case Self.switchLanguageAction: onAction?(.switchLanguage)
                case Self.keepLanguageAction: onAction?(.keepLanguage)
                default: break  // clicking the banner leaves the question open in the menu
                }
            }
            return
        }
        if let path = userInfo[Self.folderKey] as? String {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            await MainActor.run {
                switch actionID {
                case Self.resumeAction: onAction?(.resumeMeeting(folder: folder))
                case Self.deleteAction: onAction?(.deleteMeeting(folder: folder))
                // Clicking the notice itself opens the meeting too.
                case Self.openAction, UNNotificationDefaultActionIdentifier: onAction?(.openMeeting(folder: folder))
                default: break
                }
            }
            return
        }
        guard let appID = userInfo[Self.appIDKey] as? String else { return }
        await MainActor.run {
            switch actionID {
            case Self.recordAction: onAction?(.record(appID: appID))
            case Self.alwaysRecordAction: onAction?(.alwaysRecord(appID: appID))
            case Self.continueAction: onAction?(.continueMeeting(appID: appID))
            default: break  // clicking the banner itself just dismisses it
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
