import Foundation
import Testing
@testable import TinyMuesliCore

private let zoom = MeetingApps.match(bundleID: "us.zoom.xos")!
private let chrome = MeetingApps.match(bundleID: "com.google.Chrome")!
private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite struct MeetingDetectorTests {
    @Test func startsWhenMeetingAppTakesMic() {
        var d = MeetingDetector(gracePeriod: 20)
        #expect(d.update(activeApps: [], now: t0) == [])
        #expect(d.update(activeApps: [zoom], now: t0 + 2) == [.started(zoom)])
        #expect(d.update(activeApps: [zoom], now: t0 + 4) == [])
    }

    @Test func briefMicDropDoesNotEndMeeting() {
        var d = MeetingDetector(gracePeriod: 20)
        _ = d.update(activeApps: [zoom], now: t0)
        #expect(d.update(activeApps: [], now: t0 + 10) == [])
        #expect(d.update(activeApps: [zoom], now: t0 + 15) == [])
        #expect(d.update(activeApps: [], now: t0 + 30) == [])  // only 15s since last seen
        #expect(d.current == zoom)
    }

    @Test func endsAfterGracePeriod() {
        var d = MeetingDetector(gracePeriod: 20)
        _ = d.update(activeApps: [zoom], now: t0)
        #expect(d.update(activeApps: [], now: t0 + 19) == [])
        #expect(d.update(activeApps: [], now: t0 + 20) == [.ended(zoom)])
        #expect(d.current == nil)
        #expect(d.update(activeApps: [], now: t0 + 40) == [])
    }

    @Test func switchingAppsEndsThenStarts() {
        var d = MeetingDetector(gracePeriod: 20)
        _ = d.update(activeApps: [zoom], now: t0)
        #expect(d.update(activeApps: [chrome], now: t0 + 5) == [])
        #expect(d.update(activeApps: [chrome], now: t0 + 25) == [.ended(zoom), .started(chrome)])
    }

    @Test func otherAppJoiningDoesNotInterrupt() {
        var d = MeetingDetector(gracePeriod: 20)
        _ = d.update(activeApps: [chrome], now: t0)
        #expect(d.update(activeApps: [zoom, chrome], now: t0 + 2) == [])
        #expect(d.current == chrome)
    }
}

@Suite struct MeetingAppsTests {
    @Test func helperProcessesMatchTheirApp() {
        #expect(MeetingApps.match(bundleID: "com.google.Chrome.helper")?.name == "Chrome")
        #expect(MeetingApps.match(bundleID: "com.microsoft.teams2.helper")?.name == "Teams")
        #expect(MeetingApps.match(bundleID: "us.zoom.CptHost")?.name == "Zoom")
        #expect(MeetingApps.match(bundleID: "com.apple.WebKit.GPU")?.name == "Safari")
    }

    @Test func prefixMustEndAtComponentBoundary() {
        #expect(MeetingApps.match(bundleID: "com.google.Chromeish") == nil)
        #expect(MeetingApps.match(bundleID: "com.apple.Music") == nil)
    }

    @Test func nativeAppsRankAboveBrowsersAndDeduplicate() {
        let processes = [
            AudioProcess(pid: 1, bundleID: "com.google.Chrome.helper", name: "", isRunningInput: true, isRunningOutput: false),
            AudioProcess(pid: 2, bundleID: "com.google.Chrome", name: "", isRunningInput: true, isRunningOutput: false),
            AudioProcess(pid: 3, bundleID: "us.zoom.xos", name: "", isRunningInput: true, isRunningOutput: false),
        ]
        #expect(MeetingApps.active(in: processes).map(\.name) == ["Zoom", "Chrome"])
    }
}

@Suite struct MeetingStoreTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return c
    }()

    @Test func folderNameIsSortableTimestampPlusApp() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 5))!
        #expect(MeetingStore.folderName(start: date, appName: "Zoom", calendar: calendar) == "2026-11-04 0905 Zoom")
        #expect(MeetingStore.folderName(start: date, appName: nil, calendar: calendar) == "2026-11-04 0905 Meeting")
        #expect(MeetingStore.folderName(start: date, appName: "A/B: C", calendar: calendar) == "2026-11-04 0905 A-B- C")
    }

    @Test func displayNameDropsOnlyOurTimestamp() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 5))!
        let folder = { (name: String) in URL(fileURLWithPath: "/m/2026/11/\(name)") }
        #expect(MeetingStore.displayName(of: folder("2026-11-04 0905 Zoom (2)"), start: date, calendar: calendar) == "Zoom (2)")
        #expect(MeetingStore.displayName(of: folder("Design review"), start: date, calendar: calendar) == "Design review")
        #expect(MeetingStore.displayName(of: folder("2026-11-03 0905 Zoom"), start: date, calendar: calendar) == "2026-11-03 0905 Zoom")
    }

    @Test func renamedMeetingsKeepTheirPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        func meeting(hour: Int) throws -> URL {
            let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: hour))!
            let folder = try store.makeMeetingFolder(start: start, appName: "Zoom", calendar: calendar)
            try MeetingMetadata(start: start, app: "Zoom", status: .done).frontmatter()
                .write(to: folder.appendingPathComponent(MeetingFiles.transcript), atomically: true, encoding: .utf8)
            return folder
        }
        let early = try meeting(hour: 9)
        _ = try meeting(hour: 11)
        try FileManager.default.moveItem(at: early, to: early.deletingLastPathComponent().appendingPathComponent("Standup"))

        #expect(store.recentMeetings().map(\.lastPathComponent) == ["2026-11-04 1100 Zoom", "Standup"])
    }

    @Test func findsMeetingsMovedIntoFoldersOfAnyDepth() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = MeetingStore(root: root)
        func meeting(_ path: String, hour: Int) throws -> URL {
            let folder = root.appendingPathComponent(path, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: hour))!
            try MeetingMetadata(start: start, app: "Zoom", status: .done).frontmatter()
                .write(to: folder.appendingPathComponent(MeetingFiles.transcript), atomically: true, encoding: .utf8)
            return folder
        }
        _ = try meeting("2026/11/2026-11-04 0900 Zoom", hour: 9)
        _ = try meeting("Clients/Acme/Q4/Kickoff", hour: 11)
        _ = try meeting("Standup", hour: 10)
        // A folder inside a meeting isn't another meeting.
        try fm.createDirectory(at: root.appendingPathComponent("Standup/notes/old"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("Standup/notes/old/transcript.md"), atomically: true, encoding: .utf8)
        // Nor is anything hidden.
        _ = try meeting(".Trash/Gone", hour: 12)

        let found = store.recentMeetings(limit: .max)
        #expect(found.map(store.relativePath(of:)) == ["Clients/Acme/Q4/Kickoff", "Standup", "2026/11/2026-11-04 0900 Zoom"])
        let library = MeetingLibrary(store: store)
        #expect(library.meetings().map(\.id) == ["Clients/Acme/Q4/Kickoff", "Standup", "2026/11/2026-11-04 0900 Zoom"])
        #expect(library.folder(id: "Clients/Acme/Q4/Kickoff") != nil)
        #expect(library.folder(id: "Standup/notes/old") == nil)
    }

    @Test func movesMeetingsKeepingFoldersOfTheirOwn() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let old = MeetingStore(root: base.appendingPathComponent("old"))
        let new = MeetingStore(root: base.appendingPathComponent("new"))
        let folder = old.root.appendingPathComponent("Clients/Acme/Kickoff")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hi".write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: old.root.appendingPathComponent("Clients/Other"), withIntermediateDirectories: true)

        let result = old.move(old.allMeetings(), to: new)

        #expect(result.moved == 1 && result.failed.isEmpty)
        #expect(fm.fileExists(atPath: new.root.appendingPathComponent("Clients/Acme/Kickoff/transcript.md").path))
        // Emptied folders go, others stay.
        #expect(!fm.fileExists(atPath: old.root.appendingPathComponent("Clients/Acme").path))
        #expect(fm.fileExists(atPath: old.root.appendingPathComponent("Clients/Other").path))
    }

    @Test func createsFoldersInRootAndAvoidsCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10, minute: 30))!

        let first = try store.makeMeetingFolder(start: date, appName: "Zoom", calendar: calendar)
        let second = try store.makeMeetingFolder(start: date, appName: "Zoom", calendar: calendar)

        #expect(first.deletingLastPathComponent().lastPathComponent == root.lastPathComponent)
        #expect(first.lastPathComponent == "2026-11-04 1030 Zoom")
        #expect(second.lastPathComponent == "2026-11-04 1030 Zoom (2)")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("audio"), withIntermediateDirectories: true)
        }
        #expect(store.recentMeetings().map(\.lastPathComponent) == ["2026-11-04 1030 Zoom (2)", "2026-11-04 1030 Zoom"])
    }

    @Test func movesMeetingsKeepingSubfoldersAndAvoidingCollisions() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let old = MeetingStore(root: base.appendingPathComponent("old"))
        let new = MeetingStore(root: base.appendingPathComponent("new"))
        let nov = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10, minute: 30))!

        let a = try old.makeMeetingFolder(start: nov, appName: "Zoom", calendar: calendar)
        try "hi".write(to: a.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        // Grouped into a folder of its own (or `year/month/` from older versions).
        let b = old.root.appendingPathComponent("2026/10/2026-10-01 0900 Meet", isDirectory: true)
        // Recording, nothing said yet: only audio.
        try fm.createDirectory(at: b.appendingPathComponent("audio"), withIntermediateDirectories: true)
        let taken = try new.makeMeetingFolder(start: nov, appName: "Zoom", calendar: calendar)
        try "taken".write(to: taken.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        // No transcript or audio: left alone, and not taken for a meeting.
        try fm.createDirectory(at: old.root.appendingPathComponent("Archive/11/x"), withIntermediateDirectories: true)

        /// The temp dir is reached through a symlink, so compare paths below the root.
        func relative(_ store: MeetingStore) -> [String] { store.allMeetings().map(store.relativePath(of:)) }
        #expect(old.allMeetings().map(\.lastPathComponent) == [a, b].map(\.lastPathComponent))
        let result = old.move(old.allMeetings(), to: new)

        #expect(result.moved == 2 && result.failed.isEmpty)
        #expect(old.allMeetings().isEmpty)
        #expect(!fm.fileExists(atPath: old.root.appendingPathComponent("2026").path))
        #expect(fm.fileExists(atPath: old.root.appendingPathComponent("Archive").path))
        #expect(relative(new) == [
            "2026-11-04 1030 Zoom (2)", "2026-11-04 1030 Zoom", "2026/10/2026-10-01 0900 Meet",
        ])
        let moved = new.root.appendingPathComponent("2026-11-04 1030 Zoom (2)/transcript.md")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "hi")
    }

    @Test func frontmatterIncludesDurationOnceEnded() {
        let meta = MeetingMetadata(start: t0, end: t0 + 3725, app: "Zoom", status: .recorded)
        let text = meta.frontmatter()
        #expect(text.hasPrefix("---\ndate: "))
        #expect(text.contains("duration: 01:02:05"))
        #expect(text.contains("app: Zoom"))
        #expect(text.hasSuffix("status: recorded\n---\n"))
    }
}

import AVFAudio

@Suite struct MixdownTests {
    func mixed(_ buffer: AVAudioPCMBuffer) -> [Float] {
        var out = [Float](repeating: 0, count: Int(buffer.frameLength))
        out.withUnsafeMutableBufferPointer {
            TrackWriter.mix(buffer.audioBufferList, channels: Int(buffer.format.channelCount),
                            interleaved: buffer.format.isInterleaved, offset: 0, frames: $0.count, into: $0.baseAddress!)
        }
        return out
    }

    @Test func averagesDeinterleavedChannels() {
        // Like the voice-processing mic input: 3 channels, deinterleaved.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        for ch in 0..<3 { buffer.floatChannelData![ch][0] = 0.3; buffer.floatChannelData![ch][1] = Float(ch) }

        let out = mixed(buffer)
        #expect(abs(out[0] - 0.3) < 1e-6)
        #expect(abs(out[1] - 1.0) < 1e-6)
    }

    @Test func averagesInterleavedStereo() {
        // Like the system audio tap: stereo, interleaved.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        samples[0] = 0.2; samples[1] = 0.4; samples[2] = -1; samples[3] = 1

        let out = mixed(buffer)
        #expect(abs(out[0] - 0.3) < 1e-6)
        #expect(out[1] == 0)
    }
}
