import Foundation
import Testing
@testable import TinyMuesliCore

struct MeetingFoldersTests {
    let fm = FileManager.default

    private func makeStore() -> MeetingStore {
        MeetingStore(root: fm.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @discardableResult
    private func meeting(_ path: String, in store: MeetingStore) throws -> URL {
        let folder = store.url(ofFolder: path)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try MeetingMetadata(start: .now, app: "Zoom", status: .done).frontmatter()
            .write(to: folder.appendingPathComponent(MeetingFiles.transcript), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func listsFoldersIncludingEmptyOnesButNotMeetings() throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.root) }
        try meeting("2026/11/Standup", in: store)
        try fm.createDirectory(at: store.url(ofFolder: "2026/11/Standup/notes"), withIntermediateDirectories: true)
        try store.createFolder(named: "Clients")

        #expect(Set(store.groupFolders()) == ["2026", "2026/11", "Clients"])
    }

    @Test func createsUntitledFoldersLikeFinder() throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.root) }
        #expect(try store.createFolder() == "untitled folder")
        #expect(try store.createFolder() == "untitled folder 2")
        #expect(try store.createFolder(named: " Acme ", in: "untitled folder") == "untitled folder/Acme")
        #expect(throws: MeetingStore.FolderError.nameTaken("Acme")) { try store.createFolder(named: "Acme", in: "untitled folder") }
        #expect(throws: MeetingStore.FolderError.invalidName("a/b")) { try store.createFolder(named: "a/b") }
        #expect(throws: MeetingStore.FolderError.invalidName(".hidden")) { try store.createFolder(named: ".hidden") }
    }

    @Test func renamesFolders() throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.root) }
        try meeting("Clients/Kickoff", in: store)
        try store.createFolder(named: "Other")

        #expect(try store.renameFolder("Clients", to: "Customers") == "Customers")
        #expect(store.meetingFolders().map(store.relativePath(of:)) == ["Customers/Kickoff"])
        #expect(throws: MeetingStore.FolderError.nameTaken("Other")) { try store.renameFolder("Customers", to: "Other") }
        #expect(try store.renameFolder("Customers", to: "customers") == "customers")
    }

    @Test func movesMeetingsAndFolders() throws {
        let store = makeStore()
        defer { try? fm.removeItem(at: store.root) }
        let standup = try meeting("2026/11/Standup", in: store)
        try meeting("Clients/Standup", in: store)
        try store.createFolder(named: "Acme", in: "Clients")

        // A name already taken gets a number.
        let moved = try store.moveItem(standup, into: "Clients")
        #expect(store.relativePath(of: moved) == "Clients/Standup (2)")
        // The folder it came from stays, even when empty.
        #expect(store.groupFolders().contains("2026/11"))

        let acme = try store.moveItem(store.url(ofFolder: "Clients/Acme"), into: "")
        #expect(store.relativePath(of: acme) == "Acme")
        let clients = try store.moveItem(store.url(ofFolder: "Clients"), into: "Acme")
        #expect(store.meetings(inFolder: "Acme/Clients").count == 2)
        #expect(throws: MeetingStore.FolderError.intoItself("Acme")) { try store.moveItem(store.url(ofFolder: "Acme"), into: "Acme/Clients") }
        // Already there.
        #expect(try store.moveItem(clients, into: "Acme") == clients)
        // Nothing outside the root.
        #expect(throws: MeetingStore.FolderError.self) { try store.moveItem(fm.temporaryDirectory, into: "") }
    }
}
