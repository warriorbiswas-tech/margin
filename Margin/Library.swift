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

    @ObservationIgnored private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    @ObservationIgnored private var notesDir: URL { root.appendingPathComponent("Notes", isDirectory: true) }
    @ObservationIgnored var subjectsFile: URL { root.appendingPathComponent("subjects.json") }
    @ObservationIgnored private var editing: Set<UUID> = []

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

    func dir(_ id: UUID) -> URL { notesDir.appendingPathComponent(id.uuidString, isDirectory: true) }
    func drawingURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("drawing.data") }
    func thumbURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("thumb.jpg") }
    func pdfURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("source.pdf") }

    func loadDrawing(_ id: UUID) -> PKDrawing {
        guard let data = try? Data(contentsOf: drawingURL(id)) else { return PKDrawing() }
        return (try? PKDrawing(data: data)) ?? PKDrawing()
    }

    // MARK: Notes

    func save(_ note: Note) {
        var note = note
        note.updatedAt = Date()
        // The search index is written behind the editor's back, so its copy may be out of date.
        if let current = notes.first(where: { $0.id == note.id }) { note.searchText = current.searchText }
        store(note)
    }

    private func store(_ note: Note) {
        do {
            try FileManager.default.createDirectory(at: dir(note.id), withIntermediateDirectories: true)
            try JSONEncoder().encode(note).write(to: dir(note.id).appendingPathComponent("note.json"), options: .atomic)
            if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note } else { notes.append(note) }
        } catch {
            lastError = "Couldn't save “\(note.title)”: \(error.localizedDescription)"
        }
    }

    func createNote(subject: UUID?, title: String? = nil) -> Note {
        var note = Note(title: title ?? "Note \(Date().formatted(date: .abbreviated, time: .omitted))", subjectID: subject)
        note.pages = [Prefs.newPage()]
        store(note)
        return note
    }

    func appendPDF(_ incoming: PDFDocument, to id: UUID) -> [Page] {
        let existing = PDFDocument(url: pdfURL(id))
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
        guard (existing ?? incoming).write(to: pdfURL(id)) else {
            lastError = "Couldn't save the imported PDF."
            return []
        }
        return pages
    }

    nonisolated func pdfText(_ doc: PDFDocument) -> String {
        (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
    }

    func setSearchText(_ text: String, for id: UUID) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        note.searchText = text
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
            note.pages = appendPDF(doc, to: note.id)
            guard !note.pages.isEmpty else { return nil }
            store(note)
            return note
        } catch {
            lastError = "“\(url.lastPathComponent)” couldn't be imported. It may be password-protected or damaged."
            return nil
        }
    }

    func deleteForever(_ id: UUID) {
        try? FileManager.default.removeItem(at: dir(id))
        notes.removeAll { $0.id == id }
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

    func context(for question: String) -> String {
        notes.filter { $0.deletedAt == nil }
            .map { note -> (Note, String, Int) in
                let spoken = note.recordings.flatMap { $0.transcript ?? [] }.map(\.text).joined(separator: " ")
                let body = ([note.searchText, spoken] + note.elements.map(\.text)).joined(separator: "\n")
                return (note, body, TextTools.score(query: question, in: note.title + " " + body))
            }
            .filter { $0.2 > 0 }
            .sorted { $0.2 > $1.2 }
            .prefix(8)
            .map { "# \($0.0.title)\n\($0.1)" }
            .joined(separator: "\n\n")
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

    // MARK: Backup

    private var backupItems: [(id: UUID, updatedAt: Date, dir: URL)] {
        notes.map { ($0.id, $0.updatedAt, dir($0.id)) }
    }

    @discardableResult
    func backUp() async -> Int {
        let items = backupItems, subjects = subjectsFile
        do {
            return try await Task.detached(priority: .utility) { try Backup.run(notes: items, subjectsFile: subjects) }.value
        } catch {
            lastError = "Backup failed: \(error.localizedDescription). Your notes on this iPad are safe."
            return 0
        }
    }

    func restoreBackup(from url: URL) -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let root = fm.fileExists(atPath: url.appendingPathComponent("Margin Backup").path) ? url.appendingPathComponent("Margin Backup") : url
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var restored = 0
        for source in dirs {
            guard let data = try? Data(contentsOf: source.appendingPathComponent("note.json")),
                  let incoming = try? JSONDecoder().decode(Note.self, from: data) else { continue }
            if let mine = notes.first(where: { $0.id == incoming.id }), mine.updatedAt >= incoming.updatedAt { continue }
            guard !editing.contains(incoming.id) else { continue }
            let incomingDir = notesDir.appendingPathComponent(".restore-\(incoming.id.uuidString)", isDirectory: true)
            try? fm.removeItem(at: incomingDir)
            guard (try? fm.copyItem(at: source, to: incomingDir)) != nil else { continue }
            try? fm.removeItem(at: dir(incoming.id))
            guard (try? fm.moveItem(at: incomingDir, to: dir(incoming.id))) != nil else { continue }
            restored += 1
        }
        if subjects.isEmpty, let data = try? Data(contentsOf: root.appendingPathComponent("subjects.json")) {
            try? data.write(to: subjectsFile, options: .atomic)
        }
        load()
        return restored
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
