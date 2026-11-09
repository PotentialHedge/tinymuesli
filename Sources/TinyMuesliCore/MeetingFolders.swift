import Foundation

/// The folders meetings are grouped into, as the Meetings window's "Group by Folder" sidebar
/// arranges them: create, rename, move and delete them, and move meetings between them. Paths are
/// below the root, "" being the root itself. Nothing here knows whether a meeting is being
/// recorded or processed; the app checks that first.
extension MeetingStore {
    public enum FolderError: LocalizedError, Equatable {
        case invalidName(String)
        case nameTaken(String)
        case noFolder(String)
        case intoItself(String)

        public var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                name.isEmpty ? "A folder needs a name." : "“\(name)” can't be used as a folder name."
            case .nameTaken(let name): "There's already something called “\(name)” there."
            case .noFolder(let path): "“\(path)” isn't there any more."
            case .intoItself(let name): "“\(name)” can't go into itself."
            }
        }
    }

    /// Every folder that isn't a meeting, at any depth, including empty ones: e.g. "2026",
    /// "2026/11", "Clients". Like `meetingFolders`, what's inside a meeting isn't searched.
    public func groupFolders() -> [String] {
        var result: [String] = []
        func walk(_ dir: URL, path: String, depth: Int) {
            guard depth < 8 else { return }
            for sub in Self.subdirectories(dir) where !Self.isMeeting(sub) {
                let subPath = path.isEmpty ? sub.lastPathComponent : "\(path)/\(sub.lastPathComponent)"
                result.append(subPath)
                walk(sub, path: subPath, depth: depth + 1)
            }
        }
        walk(root, path: "", depth: 0)
        return result
    }

    /// A folder below the root by its path; "" is the root.
    public func url(ofFolder path: String) -> URL {
        path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }

    /// A name as typed, trimmed, or nil if it can't be one folder's name.
    public static func folderName(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { return nil }
        return name
    }

    /// Makes a folder in `parent`, "untitled folder" (then "untitled folder 2"...) like Finder if
    /// no name is given. Returns its path.
    @discardableResult
    public func createFolder(named name: String? = nil, in parent: String = "") throws -> String {
        let fm = FileManager.default
        let dir = url(ofFolder: parent)
        guard parent.isEmpty || fm.fileExists(atPath: dir.path) else { throw FolderError.noFolder(parent) }
        var target: URL
        if let name {
            guard let clean = Self.folderName(name) else { throw FolderError.invalidName(name) }
            target = dir.appendingPathComponent(clean, isDirectory: true)
            guard !fm.fileExists(atPath: target.path) else { throw FolderError.nameTaken(clean) }
        } else {
            target = dir.appendingPathComponent("untitled folder", isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent("untitled folder \(n)", isDirectory: true)
                n += 1
            }
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        return relativePath(of: target)
    }

    /// Renames a folder (or a meeting's folder) in place. Returns its new path.
    @discardableResult
    public func renameFolder(_ path: String, to name: String) throws -> String {
        let fm = FileManager.default
        let source = url(ofFolder: path)
        guard !path.isEmpty, fm.fileExists(atPath: source.path) else { throw FolderError.noFolder(path) }
        guard let clean = Self.folderName(name) else { throw FolderError.invalidName(name) }
        let target = source.deletingLastPathComponent().appendingPathComponent(clean, isDirectory: true)
        guard clean != source.lastPathComponent else { return path }
        // A change of case only: the Mac's file system sees the same name.
        let sameItem = clean.lowercased() == source.lastPathComponent.lowercased()
        guard sameItem || !fm.fileExists(atPath: target.path) else { throw FolderError.nameTaken(clean) }
        try fm.moveItem(at: source, to: target)
        return relativePath(of: target)
    }

    /// Moves a folder or a meeting into the folder at `parent` ("" for the root), keeping its name;
    /// a name already taken there gets " (2)", " (3)"... Returns its new URL. Moving something to
    /// where it already is does nothing.
    @discardableResult
    public func moveItem(_ item: URL, into parent: String) throws -> URL {
        let fm = FileManager.default
        let itemPath = relativePath(of: item)
        guard isBelowRoot(item), fm.fileExists(atPath: item.path) else { throw FolderError.noFolder(itemPath) }
        let dir = url(ofFolder: parent)
        guard parent.isEmpty || fm.fileExists(atPath: dir.path) else { throw FolderError.noFolder(parent) }
        guard parent != itemPath, !parent.hasPrefix(itemPath + "/") else { throw FolderError.intoItself(item.lastPathComponent) }
        let currentParent = itemPath.split(separator: "/").dropLast().joined(separator: "/")
        guard currentParent != parent else { return item }
        let base = item.lastPathComponent
        var target = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: item, to: target)
        return target
    }

    /// Whether the folder is somewhere below the root (not the root itself).
    public func isBelowRoot(_ folder: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return parts.count > base.count && Array(parts.prefix(base.count)) == base
    }

    /// The meetings in a folder, at any depth.
    public func meetings(inFolder path: String) -> [URL] {
        let prefix = path + "/"
        return meetingFolders().filter { relativePath(of: $0).hasPrefix(prefix) }
    }
}
