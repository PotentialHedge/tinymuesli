import Testing
@testable import TinyMuesliCore

struct CallMuteTests {
    @Test(arguments: [
        (["Unmute Audio", "Start Video"], true),                         // Zoom menu bar, muted
        (["Mute Audio", "Start Video"], false),                          // Zoom, unmuted
        (["Unmute (⌘+Shift+M)", "Leave"], true),                         // Teams
        (["Turn on microphone (⌘ + d)", "Leave call"], true),           // Meet
        (["Turn off microphone (⌘ + d)"], false),
        (["Mute All", "Ask All to Unmute", "Mute Audio"], false),        // host controls don't count
        (["Unmute Audio", "Mute Audio"], nil),                           // ambiguous: assume not muted
        (["Share Screen"], nil),
        ([String](), nil),
    ] as [([String], Bool?)])
    func readsTheMuteButton(labels: [String], muted: Bool?) {
        #expect(CallMute.classify(labels) == muted)
    }

    /// Another tab's video player offers "Unmute" too; in a browser only mic buttons count.
    @Test func browsersOnlyTrustMicButtons() {
        #expect(CallMute.classify(["Unmute (m)"], micOnly: true) == nil)
        #expect(CallMute.classify(["Unmute (m)", "Turn off microphone (⌘ + d)"], micOnly: true) == false)
        #expect(CallMute.classify(["Turn on microphone (⌘ + d)"], micOnly: true) == true)
    }
}
