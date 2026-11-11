import Foundation
import Testing
@testable import TinyMuesliCore

@Suite struct SharedMeetingTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeMeeting(status: MeetingMetadata.Status = .done) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let segments = [
            Segment(start: 0, end: 2, speaker: "Me", track: .mic, text: "Hi <everyone> & welcome."),
            Segment(start: 3, end: 5, speaker: "Ann", track: .system, text: "Hello."),
            Segment(start: 400, end: 402, speaker: "Speaker 2", track: .system, text: "Back again."),
        ]
        let document = TranscriptDocument(start: start, end: start + 600, app: "Zoom", language: "en-US", segments: segments)
        try document.encoded().write(to: folder.appendingPathComponent(MeetingFiles.json))
        let metadata = MeetingMetadata(start: start, end: start + 600, title: "Roadmap \"Q4\"", app: "Zoom", status: status,
                                       speakers: document.speakers, tags: ["planning"])
        try (metadata.frontmatter() + "\n" + TranscriptRenderer.markdown(segments) + "\n")
            .write(to: folder.appendingPathComponent(MeetingFiles.transcript), atomically: true, encoding: .utf8)
        try Data("{}".utf8).write(to: folder.appendingPathComponent(MeetingFiles.speakers))
        return folder
    }

    private func makeStore() throws -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MeetingStore(root: root)
    }

    @Test func meIsRenamedToTheSharer() throws {
        let shared = try SharedMeeting(folder: makeMeeting(), sharedBy: "Ben")
        #expect(shared.speakers == ["Ben", "Ann", "Speaker 2"])
        #expect(shared.title == "Roadmap \"Q4\"")
        #expect(shared.tags == ["planning"])
        #expect(shared.transcript.segments[0].track == .mic)
    }

    @Test func onlyFinishedMeetingsAreShared() throws {
        let folder = try makeMeeting(status: .recording)
        #expect(throws: SharedMeeting.ShareError.notFinished) { try SharedMeeting(folder: folder, sharedBy: "Ben") }
    }

    @Test func roundTripsThroughLinkAndPage() throws {
        let shared = try SharedMeeting(folder: makeMeeting(), sharedBy: "Ben")
        #expect(try SharedMeeting(importURL: shared.importURL()) == shared)
        let html = try shared.html()
        #expect(try SharedMeeting(html: html) == shared)
        // Text is escaped, and nothing but the transcript is carried.
        #expect(html.contains("Hi &lt;everyone&gt; &amp; welcome."))
        #expect(html.contains("<title>Roadmap &quot;Q4&quot;</title>"))
        #expect(!html.contains("<everyone>"))
    }

    @Test func sharedByRoundTripsThroughFrontmatter() {
        var metadata = MeetingMetadata(start: start, app: "Zoom", status: .done)
        metadata.sharedBy = "O'Brien, \"Ann\""
        #expect(MeetingMetadata(parsing: metadata.frontmatter())?.sharedBy == "O'Brien, \"Ann\"")
        #expect(MeetingMetadata(parsing: MeetingMetadata(start: start, app: nil, status: .done).frontmatter())?.sharedBy == nil)
    }

    @Test func emailCarriesTheMeetingWithoutScripts() throws {
        let shared = try SharedMeeting(folder: makeMeeting(), sharedBy: "Ben")
        let email = try shared.emailHTML()
        #expect(try SharedMeeting(html: email) == shared)
        #expect(email.contains("Hi &lt;everyone&gt; &amp; welcome."))
        #expect(!email.contains("<script") && !email.contains("<style"))
        // The sharer is on the right in blue, everyone else on the left.
        #expect(email.contains("text-align:right;margin:10px 0 0\"><span style=\"display:inline-block;max-width:75%;text-align:left;background:#0a84ff"))
        #expect(shared.emailSubject.hasPrefix("Roadmap \"Q4\" – "))
    }

    @Test func rejectsDamagedPayloads() {
        #expect(throws: SharedMeeting.ShareError.unreadable) { try SharedMeeting(payload: "not-a-meeting") }
        #expect(throws: SharedMeeting.ShareError.unreadable) { try SharedMeeting(html: "<html></html>") }
        #expect(throws: SharedMeeting.ShareError.unreadable) {
            try SharedMeeting(importURL: URL(string: "tinymuesli://meeting?id=x")!)
        }
    }

    @Test func addsAFinishedMeetingOnce() throws {
        let store = try makeStore()
        let shared = try SharedMeeting(folder: makeMeeting(), sharedBy: "Ben")
        let first = try shared.add(to: store)
        #expect(first.added)
        let summary = try #require(MeetingLibrary(store: store).summary(of: first.folder))
        #expect(summary.status == "done")
        #expect(summary.title == "Roadmap \"Q4\"")
        #expect(summary.speakers == ["Ben", "Ann", "Speaker 2"])
        #expect(summary.sharedBy == "Ben")
        #expect(!FileManager.default.fileExists(atPath: first.folder.appendingPathComponent(MeetingFiles.speakers).path))
        let chat = ChatTranscript.load(folder: first.folder)
        #expect(chat.messages.map(\.text) == shared.transcript.segments.map(\.text))
        #expect(chat.messages.allSatisfy { !$0.isMe })

        // Renaming a speaker afterwards doesn't make it a different meeting.
        try MeetingEditor(folder: first.folder).rename(speaker: "Speaker 2", to: "Cleo")
        // Edits keep who shared it.
        #expect(MeetingLibrary(store: store).summary(of: first.folder)?.sharedBy == "Ben")
        let second = try shared.add(to: store)
        #expect(!second.added)
        #expect(second.folder.resolvingSymlinksInPath() == first.folder.resolvingSymlinksInPath())
        #expect(store.meetingFolders().count == 1)
    }
}
