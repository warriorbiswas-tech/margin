import Foundation

enum Backup {
    private static let bookmarkKey = "backupBookmark"
    private static let stampsKey = "backupStamps"

    static var folderName: String? {
        resolve()?.lastPathComponent
    }

    static func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: stampsKey)
    }

    static func clearFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? setFolder(url) }
        return url
    }

    static func run(notes: [(id: UUID, updatedAt: Date, dir: URL)], subjectsFile: URL) throws -> Int {
        guard let folder = resolve() else { return 0 }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let root = folder.appendingPathComponent("Margin Backup", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var stamps = UserDefaults.standard.dictionary(forKey: stampsKey) as? [String: Double] ?? [:]
        var copied = 0
        for note in notes where stamps[note.id.uuidString] != note.updatedAt.timeIntervalSince1970 {
            guard fm.fileExists(atPath: note.dir.path) else { continue }
            let target = root.appendingPathComponent(note.id.uuidString, isDirectory: true)
            // Copy beside the old backup and swap, so a failure never leaves it half-written.
            let incoming = root.appendingPathComponent(".incoming-\(note.id.uuidString)", isDirectory: true)
            try? fm.removeItem(at: incoming)
            try fm.copyItem(at: note.dir, to: incoming)
            try? fm.removeItem(at: target)
            try fm.moveItem(at: incoming, to: target)
            stamps[note.id.uuidString] = note.updatedAt.timeIntervalSince1970
            copied += 1
        }
        if fm.fileExists(atPath: subjectsFile.path) {
            let target = root.appendingPathComponent("subjects.json")
            try? fm.removeItem(at: target)
            try fm.copyItem(at: subjectsFile, to: target)
        }
        UserDefaults.standard.set(stamps, forKey: stampsKey)
        return copied
    }
}
