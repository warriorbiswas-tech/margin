import Foundation
import Observation
import PDFKit
import PencilKit
import UIKit

@MainActor @Observable
final class Library {
    private(set) var notes: [Note] = []
    private(set) var subjects: [Subject] = []
    var lastError: String?
    var syncStatus: String?

    private nonisolated let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private nonisolated var notesDir: URL { root.appendingPathComponent("Notes", isDirectory: true) }
    @ObservationIgnored var subjectsFile: URL { root.appendingPathComponent("subjects.json") }
    @ObservationIgnored private var editing: Set<UUID> = []
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var indexing: Set<UUID> = []
    @ObservationIgnored private let thumbnails = NSCache<NSString, UIImage>()
    /// Files are written one at a time off the main thread, because encoding a long note takes long enough to interrupt the pen.
    private nonisolated let writer = DispatchQueue(label: "margin.save", qos: .userInitiated)

    init() {
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: subjectsFile) {
            subjects = (try? JSONDecoder().decode([Subject].self, from: data)) ?? []
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)) ?? []
        notes = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("note.json")) else { return nil }
            return try? JSONDecoder().decode(Note.self, from: data)
        }
    }

    func beginEditing(_ id: UUID) -> Bool {
        guard !editing.contains(id) else {
            lastError = "That note is already open in another window."
            return false
        }
        editing.insert(id)
        return true
    }

    func endEditing(_ id: UUID) { editing.remove(id) }

    static func positionKey(_ id: UUID) -> String { "position-\(id.uuidString)" }

    nonisolated func dir(_ id: UUID) -> URL { notesDir.appendingPathComponent(id.uuidString, isDirectory: true) }
    func drawingURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("drawing.data") }
    func thumbURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("thumb.jpg") }
    func pdfURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("source.pdf") }

    func loadDrawing(_ id: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingURL(id)) else { return PKDrawing() }
        var drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
        // Highlights from before they were translucent would hide the text under them.
        if drawing.strokes.contains(where: { $0.ink.inkType == .marker && $0.ink.color.cgColor.alpha > 0.99 }) {
            drawing.strokes = drawing.strokes.map { stroke in
                guard stroke.ink.inkType == .marker, stroke.ink.color.cgColor.alpha > 0.99 else { return stroke }
                var clear = stroke
                clear.ink = PKInk(.marker, color: stroke.ink.color.withAlphaComponent(0.4))
                return clear
            }
        }
        return drawing
    }

    // MARK: Notes

    func save(_ note: Note, ink: PKDrawing? = nil, failed: (@MainActor (String) -> Void)? = nil) {
        var note = note
        note.updatedAt = Date()
        // The search index is written behind the editor's back, so its copy may be out of date.
        if let current = notes.first(where: { $0.id == note.id }) { note.searchText = current.searchText }
        store(note, ink: ink, failed: failed)
    }

    private func store(_ note: Note, ink: PKDrawing? = nil, failed: (@MainActor (String) -> Void)? = nil) {
        let folder = dir(note.id), inkFile = drawingURL(note.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn't save “\(note.title)”: \(error.localizedDescription)"
            return
        }
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.append(note) }
        writer.async { [weak self] in
            do {
                // The ink goes first: note.json is what tells a sync that a note changed.
                try ink?.dataRepresentation().write(to: inkFile, options: .atomic)
                try JSONEncoder().encode(note).write(to: folder.appendingPathComponent("note.json"), options: .atomic)
            } catch {
                let reason = "Couldn't save “\(note.title)”: \(error.localizedDescription)"
                Task { @MainActor [weak self] in
                    if let failed { failed(reason) } else { self?.lastError = reason }
                }
            }
        }
        syncSoon()
    }

    /// Returns once everything saved so far is on disk.
    func flush() { writer.sync {} }

    /// The note's library picture. A long list of cards would otherwise read every file again on each redraw.
    func thumbnail(for id: UUID) -> UIImage? {
        let path = thumbURL(id).path
        guard let changed = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        let key = "\(id)-\(changed.timeIntervalSinceReferenceDate)" as NSString
        if let known = thumbnails.object(forKey: key) { return known }
        let image = UIImage(contentsOfFile: path)
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    func createNote(subject: UUID?, title: String? = nil) -> Note {
        var note = Note(title: title ?? "Note \(Date().formatted(date: .abbreviated, time: .omitted))", subjectID: subject)
        note.pages = [Prefs.newPage()]
        store(note)
        return note
    }

    /// A long PDF takes seconds to rewrite, so this happens off the main thread.
    func appendPDF(_ incoming: PDFDocument, to id: UUID) async -> [Page] {
        struct Unchecked: @unchecked Sendable { let doc: PDFDocument }
        let target = pdfURL(id), source = Unchecked(doc: incoming)
        let pages: [Page]? = await Task.detached(priority: .userInitiated) {
            let incoming = source.doc
            let existing = PDFDocument(url: target)
            let start = existing?.pageCount ?? 0
            var pages: [Page] = []
            for i in 0..<incoming.pageCount {
                guard let page = incoming.page(at: i) else { continue }
                existing?.insert(page, at: existing?.pageCount ?? 0)
                var box = page.bounds(for: .cropBox).size
                if page.rotation % 180 != 0 { box = CGSize(width: box.height, height: box.width) }
                pages.append(Page(height: NoteLayout.width * box.height / max(box.width, 1), pdfPage: start + pages.count))
            }
            // A first import is written as-is, which keeps its table of contents; rebuilding it would drop that.
            let temp = target.deletingLastPathComponent().appendingPathComponent("incoming.tmp")
            guard (existing ?? incoming).write(to: temp) else { return nil }
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
                return pages
            } catch {
                do {
                    try FileManager.default.moveItem(at: temp, to: target)
                    return pages
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    return nil
                }
            }
        }.value
        guard let pages else {
            lastError = "Couldn't save the imported PDF."
            return []
        }
        return pages
    }

    /// One reader per note at a time; reading a scanned book takes minutes.
    func beginIndexing(_ id: UUID) -> Bool { indexing.insert(id).inserted }

    /// What's printed on a note's scanned pages, by PDF page. Reading one takes about a second, so results are kept with the note.
    nonisolated func scannedText(of note: Note, in doc: PDFDocument?, pdfPages wanted: Set<Int>? = nil) -> [Int: String] {
        guard let doc else { return [:] }
        let folder = dir(note.id), file = folder.appendingPathComponent("scan-text.json")
        var known = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Int: String].self, from: $0) } ?? [:]
        let rects = Renderer.rects(for: note)
        var unsaved = 0
        for (i, page) in note.pages.enumerated() {
            guard let index = page.pdfPage, wanted?.contains(index) ?? true, known[index] == nil else { continue }
            autoreleasepool {
                guard (doc.page(at: index)?.string ?? "").isEmpty else { return }
                known[index] = Renderer.recognize(Renderer.snapshot(note: note, drawing: PKDrawing(), rect: rects[i], dir: folder))
                unsaved += 1
            }
            if unsaved >= 10 {
                try? JSONEncoder().encode(known).write(to: file, options: .atomic)
                unsaved = 0
            }
        }
        if unsaved > 0 { try? JSONEncoder().encode(known).write(to: file, options: .atomic) }
        return known
    }

    nonisolated func pdfText(_ doc: PDFDocument) -> String {
        (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    func setSearchText(_ text: String, for id: UUID) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        note.searchText = text
        indexing.remove(id)
        store(note)
    }

    func rename(_ id: UUID, to title: String) { edit(id) { $0.title = title } }
    func setTags(_ tags: [String], for id: UUID) { edit(id) { $0.tags = tags } }
    func setLocked(_ locked: Bool, for id: UUID) { edit(id) { $0.locked = locked } }
    var allTags: [String] { Array(Set(notes.filter { $0.deletedAt == nil }.flatMap(\.tags))).sorted() }
    func toggleFavorite(_ id: UUID) { edit(id) { $0.favorite.toggle() } }
    func move(_ id: UUID, to subject: UUID?) { edit(id) { $0.subjectID = subject } }
    func trash(_ id: UUID) { edit(id) { $0.deletedAt = Date() } }
    func restore(_ id: UUID) { edit(id) { $0.deletedAt = nil } }

    private func edit(_ id: UUID, _ change: (inout Note) -> Void) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        change(&note)
        save(note)
    }

    @discardableResult
    func duplicate(_ id: UUID, title: String? = nil) -> Note? {
        guard var copy = notes.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID()
        copy.title = title ?? copy.title + " copy"
        copy.createdAt = Date()
        copy.isTemplate = false
        flush()
        do {
            try FileManager.default.copyItem(at: dir(id), to: dir(copy.id))
            try? FileManager.default.removeItem(at: versionsDir(copy.id))
            store(copy)
            return copy
        } catch {
            lastError = "Couldn't duplicate: \(error.localizedDescription)"
            return nil
        }
    }

    func setTemplate(_ on: Bool, for id: UUID) { edit(id) { $0.isTemplate = on } }
    var templates: [Note] { notes.filter { $0.isTemplate && $0.deletedAt == nil }.sorted { $0.title < $1.title } }

    func createNote(subject: UUID?, title: String?, page: Page) -> Note {
        var note = Note(title: title ?? "Note \(Date().formatted(date: .abbreviated, time: .omitted))", subjectID: subject)
        note.pages = [page]
        store(note)
        return note
    }

    var signatureURL: URL { root.appendingPathComponent("signature.png") }

    /// A document of any supported type becomes a new note made of its pages.
    func importDocument(from url: URL, subject: UUID?) async -> Note? {
        do {
            let doc = try await DocumentConverter.pdf(from: url)
            var note = Note(title: url.deletingPathExtension().lastPathComponent, subjectID: subject)
            try FileManager.default.createDirectory(at: dir(note.id), withIntermediateDirectories: true)
            note.pages = await appendPDF(doc, to: note.id)
            guard !note.pages.isEmpty else { return nil }
            store(note)
            return note
        } catch {
            lastError = "“\(url.lastPathComponent)” couldn't be imported. It may be password-protected or damaged."
            return nil
        }
    }

    func deleteForever(_ id: UUID) {
        flush()
        try? FileManager.default.removeItem(at: dir(id))
        notes.removeAll { $0.id == id }
        UserDefaults.standard.removeObject(forKey: Self.positionKey(id))
        if Sync.hasFolder { pendingDeletes.insert(id.uuidString) }
        syncSoon()
    }

    // MARK: Study

    struct DueCard: Identifiable, Hashable {
        var id: UUID { card.id }
        let noteID: UUID
        let card: Flashcard
    }

    var dueCards: [DueCard] {
        notes.filter { $0.deletedAt == nil && !$0.isTemplate && !editing.contains($0.id) }
            .flatMap { note in note.flashcards.filter { $0.due <= Date() }.map { DueCard(noteID: note.id, card: $0) } }
            .sorted { $0.card.due < $1.card.due }
    }

    func grade(_ due: DueCard, _ grade: SM2.Grade) {
        edit(due.noteID) { note in
            guard let i = note.flashcards.firstIndex(where: { $0.id == due.card.id }) else { return }
            note.flashcards[i].apply(grade)
        }
    }

    func cardImage(_ due: DueCard) -> UIImage? {
        due.card.frontImage.flatMap { UIImage(contentsOfFile: dir(due.noteID).appendingPathComponent($0).path) }
    }

    func context(for question: String) async -> String {
        let notes = notes
        return await Task.detached(priority: .userInitiated) {
            var passages: [String] = []
            for note in notes where note.deletedAt == nil && !note.locked {
                let spoken = note.recordings.flatMap { $0.transcript ?? [] }.map(\.text).joined(separator: " ")
                let body = ([note.searchText, spoken] + note.elements.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n")
                for chunk in TextTools.chunks(body, size: 3000) { passages.append("From \"\(note.title)\":\n\(chunk)") }
            }
            return TextTools.bestPassages(query: question, passages: passages, limit: 12000).map { passages[$0] }.joined(separator: "\n\n")
        }.value
    }

    // MARK: Versions

    private func versionsDir(_ id: UUID) -> URL { dir(id).appendingPathComponent("versions", isDirectory: true) }

    func snapshot(_ id: UUID) {
        let fm = FileManager.default
        let target = versionsDir(id).appendingPathComponent(String(Int(Date().timeIntervalSince1970)), isDirectory: true)
        guard (try? fm.createDirectory(at: target, withIntermediateDirectories: true)) != nil else { return }
        for file in ["note.json", "drawing.data"] {
            try? fm.copyItem(at: dir(id).appendingPathComponent(file), to: target.appendingPathComponent(file))
        }
        for old in versions(id).dropFirst(30) { try? fm.removeItem(at: old.url) }
    }

    struct Version: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let date: Date
    }

    func versions(_ id: UUID) -> [Version] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: versionsDir(id), includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { url in
            Double(url.lastPathComponent).map { Version(url: url, date: Date(timeIntervalSince1970: $0)) }
        }
        .sorted { $0.date > $1.date }
    }

    func readVersion(_ version: Version) -> (note: Note, drawing: PKDrawing)? {
        guard let data = try? Data(contentsOf: version.url.appendingPathComponent("note.json")),
              let note = try? JSONDecoder().decode(Note.self, from: data) else { return nil }
        let drawing = (try? Data(contentsOf: version.url.appendingPathComponent("drawing.data"))).flatMap { try? PKDrawing(data: $0) }
        return (note, drawing ?? PKDrawing())
    }

    // MARK: Sync

    /// Every save lands here, so each stroke and annotation reaches the folder a moment after it's made.
    private func syncSoon() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { await self?.sync() }
        }
    }

    @discardableResult
    func sync() async -> Sync.Outcome? {
        guard !syncing else {
            syncAgain = true
            return nil
        }
        syncing = true
        defer { syncing = false }
        var outcome: Sync.Outcome?
        repeat {
            syncAgain = false
            let notes = notesDir, subjects = subjectsFile, open = Set(editing.map(\.uuidString)), deleted = pendingDeletes, writer = writer
            do {
                outcome = try await Task.detached(priority: .utility) {
                    writer.sync {} // what was just saved goes along
                    return try Sync.run(notes: notes, subjects: subjects, open: open, deleted: deleted)
                }.value
                guard let outcome else { return nil }
                pendingDeletes.subtract(deleted)
                refresh(after: outcome)
            } catch {
                // Worth showing, but never worth interrupting the writing for: the notes on this iPad are safe.
                syncStatus = "Couldn't reach your sync folder: \(error.localizedDescription)"
                return nil
            }
        } while syncAgain
        return outcome
    }

    private func refresh(after outcome: Sync.Outcome) {
        if outcome.downloaded + outcome.removed > 0 {
            load()
        } else if let data = try? Data(contentsOf: subjectsFile), let saved = try? JSONDecoder().decode([Subject].self, from: data), saved != subjects {
            subjects = saved
        }
        if let error = outcome.firstError {
            syncStatus = "\(outcome.failed) notes didn't sync: \(error)"
        } else {
            syncStatus = "\(Sync.isInICloud ? "Saved to iCloud" : "Synced") at \(Date().formatted(date: .omitted, time: .shortened))"
        }
    }

    private var pendingDeletes: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "syncDeleted") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "syncDeleted") }
    }

    // MARK: Subjects

    func addSubject(name: String) {
        let palette = ["E5484D", "F76B15", "FFB224", "30A46C", "0091FF", "6E56CF", "D6409F"]
        subjects.append(Subject(name: name, colorHex: palette[subjects.count % palette.count]))
        saveSubjects()
    }

    func renameSubject(_ id: UUID, to name: String) {
        guard let i = subjects.firstIndex(where: { $0.id == id }) else { return }
        subjects[i].name = name
        saveSubjects()
    }

    func deleteSubject(_ id: UUID) {
        subjects.removeAll { $0.id == id }
        saveSubjects()
        for note in notes where note.subjectID == id { move(note.id, to: nil) }
    }

    private func saveSubjects() {
        try? JSONEncoder().encode(subjects).write(to: subjectsFile, options: .atomic)
    }
}
