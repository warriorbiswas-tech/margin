import Foundation

/// Two-way sync through a folder the user picks in iCloud Drive. A picked folder works under any signing,
/// where Apple's iCloud entitlement needs a paid developer account.
enum Sync {
    struct Outcome {
        var uploaded = 0, downloaded = 0, removed = 0, failed = 0
        var firstError: String?
    }

    private static let bookmarkKey = "backupBookmark"
    private static let stampsKey = "syncStamps"
    private static let folder = "Margin Notes"

    static var folderName: String? { resolve()?.lastPathComponent }
    static var isInICloud: Bool { resolve()?.path.contains("Mobile Documents") ?? false }

    static func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        UserDefaults.standard.set(try url.bookmarkData(), forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: stampsKey)
    }

    static func clearFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: stampsKey)
    }

    private static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? setFolder(url) }
        return url
    }

    static func run(notes: URL, subjects: URL, open: Set<String>, deleted: Set<String>) throws -> Outcome? {
        guard let picked = resolve() else { return nil }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let remote = picked.lastPathComponent == folder ? picked : picked.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        var stamps = UserDefaults.standard.dictionary(forKey: stampsKey) as? [String: Double] ?? [:]
        let outcome = try reconcile(notes: notes, remote: remote, stamps: &stamps, open: open, deleted: deleted)
        UserDefaults.standard.set(stamps, forKey: stampsKey)
        mergeSubjects(subjects, remote.appendingPathComponent("subjects.json"))
        return outcome
    }

    /// `stamps` holds each note's `updatedAt` as of the last sync, which tells an edit here from an edit elsewhere.
    /// `open` notes aren't overwritten, and `deleted` lists notes deleted forever here since the last sync.
    static func reconcile(notes local: URL, remote: URL, stamps: inout [String: Double], open: Set<String>, deleted: Set<String>) throws -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        let graves = remote.appendingPathComponent("Deleted", isDirectory: true)
        try fm.createDirectory(at: graves, withIntermediateDirectories: true)

        for id in deleted {
            try Data().write(to: graves.appendingPathComponent(id))
            try? fm.removeItem(at: remote.appendingPathComponent(id))
            stamps[id] = nil
        }
        // Deleting forever only follows a note already in the trash here. A live note was restored or
        // edited elsewhere, and absence of a file is never a reason to delete anything.
        for id in noteIDs(in: graves) where !open.contains(id) && !deleted.contains(id) {
            let mine = local.appendingPathComponent(id)
            guard let info = info(of: mine) else { continue }
            if info.deletedAt != nil {
                try? fm.removeItem(at: mine)
                stamps[id] = nil
                outcome.removed += 1
            } else {
                try? fm.removeItem(at: graves.appendingPathComponent(id))
            }
        }

        let ids = Set(noteIDs(in: local)).union(noteIDs(in: remote)).subtracting(noteIDs(in: graves))
        for id in ids {
            let mine = local.appendingPathComponent(id), theirs = remote.appendingPathComponent(id)
            guard ready(theirs) else { continue } // still downloading, so the next sync picks it up
            do {
                switch (info(of: mine)?.updatedAt, info(of: theirs)?.updatedAt) {
                case (nil, nil):
                    continue
                case let (a?, nil):
                    try mirror(mine, to: theirs)
                    stamps[id] = a
                    outcome.uploaded += 1
                case let (nil, b?):
                    guard !open.contains(id) else { continue }
                    try mirror(theirs, to: mine)
                    stamps[id] = b
                    outcome.downloaded += 1
                case let (a?, b?):
                    if a == b {
                        stamps[id] = a
                    } else if b == stamps[id] {
                        try mirror(mine, to: theirs)
                        stamps[id] = a
                        outcome.uploaded += 1
                    } else if !open.contains(id) {
                        if a == stamps[id] {
                            try mirror(theirs, to: mine)
                            stamps[id] = b
                        } else {
                            // Changed in both places, so neither version gets thrown away.
                            try keepCopy(of: theirs, in: local)
                            try mirror(mine, to: theirs)
                            stamps[id] = a
                            outcome.uploaded += 1
                        }
                        outcome.downloaded += 1
                    }
                }
            } catch {
                outcome.failed += 1
                if outcome.firstError == nil { outcome.firstError = error.localizedDescription }
            }
        }
        return outcome
    }

    private struct Info: Decodable {
        let updatedAt: Double
        let deletedAt: Double?
    }

    private static func info(of dir: URL) -> Info? {
        (try? read(dir.appendingPathComponent("note.json"))).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    }

    /// iCloud can stand a hidden `.name.icloud` file in for one it hasn't downloaded yet.
    private static func noteIDs(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            let id = name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(7)) : name
            return UUID(uuidString: id) == nil ? nil : id
        }
    }

    private static func ready(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let waiting = (fm.subpaths(atPath: dir.path) ?? []).filter { $0.hasSuffix(".icloud") }
        for path in waiting {
            let placeholder = dir.appendingPathComponent(path)
            let real = placeholder.deletingLastPathComponent().appendingPathComponent(String(placeholder.lastPathComponent.dropFirst().dropLast(7)))
            try? fm.startDownloadingUbiquitousItem(at: real)
        }
        return waiting.isEmpty
    }

    /// Copies only what changed, since a big PDF never does, and writes note.json last:
    /// an interrupted copy still looks out of date, so the next sync finishes it.
    private static func mirror(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let wanted = syncedFiles(in: source)
        for path in Set(syncedFiles(in: target)).subtracting(wanted) {
            try fm.removeItem(at: target.appendingPathComponent(path))
        }
        for path in wanted where path != "note.json" && changed(source.appendingPathComponent(path), target.appendingPathComponent(path)) {
            try copy(source.appendingPathComponent(path), to: target.appendingPathComponent(path))
        }
        if wanted.contains("note.json") {
            try copy(source.appendingPathComponent("note.json"), to: target.appendingPathComponent("note.json"))
        }
    }

    private static func syncedFiles(in dir: URL) -> [String] {
        let fm = FileManager.default
        return (fm.subpaths(atPath: dir.path) ?? []).filter { path in
            // Version history and the AI's cache are each device's own.
            let parts = path.split(separator: "/")
            guard parts.first != "versions", path != "digest-cache.json", !parts.contains(where: { $0.hasPrefix(".") }) else { return false }
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: dir.appendingPathComponent(path).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    private static func changed(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let first = try? fm.attributesOfItem(atPath: a.path), let second = try? fm.attributesOfItem(atPath: b.path) else { return true }
        return first[.size] as? Int != second[.size] as? Int || first[.modificationDate] as? Date != second[.modificationDate] as? Date
    }

    private static func keepCopy(of dir: URL, in local: URL) throws {
        let id = UUID().uuidString, copyDir = local.appendingPathComponent(id, isDirectory: true)
        try mirror(dir, to: copyDir)
        let file = copyDir.appendingPathComponent("note.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { return }
        json["id"] = id
        json["title"] = "\(json["title"] as? String ?? "Note") (from another device)"
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
    }

    // ponytail: folders merge by id, so a deleted or renamed folder can come back from another device. Give them stamps if that bites.
    private static func mergeSubjects(_ local: URL, _ remote: URL) {
        func entries(_ url: URL) -> [[String: Any]] {
            (try? read(url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        }
        let mine = entries(local), theirs = entries(remote)
        let known = Set(mine.compactMap { $0["id"] as? String })
        let merged = mine + theirs.filter { !known.contains($0["id"] as? String ?? "") }
        guard !merged.isEmpty, let data = try? JSONSerialization.data(withJSONObject: merged) else { return }
        if merged.count != mine.count { try? data.write(to: local, options: .atomic) }
        if merged.count != theirs.count || !Set(theirs.compactMap { $0["id"] as? String }).isSuperset(of: known) { try? data.write(to: remote, options: .atomic) }
    }

    // iCloud Drive's files have to be read and written through a coordinator.
    private static func read(_ url: URL) throws -> Data {
        var coordination: NSError?, result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordination { throw coordination }
        return try result?.get() ?? Data()
    }

    private static func copy(_ source: URL, to target: URL) throws {
        var coordination: NSError?, failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: target, options: .forReplacing, error: &coordination) { from, to in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temp = to.deletingLastPathComponent().appendingPathComponent(".\(to.lastPathComponent).syncing")
                try? fm.removeItem(at: temp)
                try fm.copyItem(at: from, to: temp)
                try? fm.removeItem(at: to)
                try fm.moveItem(at: temp, to: to)
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }
}
