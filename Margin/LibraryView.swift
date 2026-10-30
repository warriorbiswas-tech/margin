import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

enum Shelf: Hashable {
    case all, favorites, unfiled, study, templates, trash
    case subject(UUID)
    case tag(String)
}

enum SortOrder: String, CaseIterable, Identifiable {
    case edited = "Date Edited", created = "Date Created", title = "Title"
    var id: String { rawValue }
}

struct LibraryView: View {
    @Bindable var library: Library
    @State private var shelf: Shelf? = .all
    @State private var search = ""
    @AppStorage("sort") private var sort = SortOrder.edited
    @State private var editor: EditorModel?
    @State private var importing = false
    @State private var prompt: TextPrompt?
    @State private var promptText = ""
    @State private var showSettings = false
    @State private var reminderNote: Note?
    @State private var pendingSetup: NoteSetup?
    @State private var creating = false

    struct TextPrompt {
        let title: String
        let action: (String) -> Void
    }

    private var currentSubject: UUID? {
        if case let .subject(id) = shelf { id } else { nil }
    }

    private var visibleNotes: [Note] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = library.notes.filter { note in
            let inShelf = switch shelf ?? .all {
            case .all, .study: note.deletedAt == nil && !note.isTemplate
            case .favorites: note.deletedAt == nil && note.favorite
            case .unfiled: note.deletedAt == nil && note.subjectID == nil && !note.isTemplate
            case .templates: note.deletedAt == nil && note.isTemplate
            case .trash: note.deletedAt != nil
            case let .subject(id): note.deletedAt == nil && note.subjectID == id
            case let .tag(tag): note.deletedAt == nil && note.tags.contains(tag)
            }
            guard inShelf else { return false }
            guard !query.isEmpty else { return true }
            // A locked note's contents stay out of search results.
            if note.locked { return note.title.localizedCaseInsensitiveContains(query) }
            return note.title.localizedCaseInsensitiveContains(query)
                || note.searchText.localizedCaseInsensitiveContains(query)
                || note.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || note.elements.contains { $0.text.localizedCaseInsensitiveContains(query) }
                || note.recordings.contains { ($0.transcript ?? []).contains { $0.text.localizedCaseInsensitiveContains(query) } }
        }
        return filtered.sorted {
            switch sort {
            case .edited: $0.updatedAt > $1.updatedAt
            case .created: $0.createdAt > $1.createdAt
            case .title: $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if shelf == .study {
                StudyHome(library: library).navigationTitle("Study")
            } else {
                grid
            }
        }
        .fullScreenCover(item: $editor) { model in
            EditorView(model: model) {
                model.close()
                editor = nil
            }
            .onChange(of: model.openNoteRequest) { _, id in
                guard let id, let target = library.notes.first(where: { $0.id == id }) else { return }
                model.close()
                editor = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { open(target) }
            }
        }
        .sheet(item: $reminderNote) { note in ReminderSheet(note: note) }
        .sheet(isPresented: $showSettings) { SettingsView(library: library) }
        .sheet(isPresented: $creating) {
            NewNoteSheet(library: library, startingFolder: currentSubject) { note, setup in
                pendingSetup = setup
                open(note)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: DocumentConverter.importable) { result in
            if case let .success(url) = result { importDocument(url) }
        }
        .onOpenURL { url in importDocument(url) }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                let name = promptText.trimmingCharacters(in: .whitespaces)
                prompt?.action(name)
            }
        }
        .alert("Margin", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(library.lastError ?? "")
        }
    }

    private func importDocument(_ url: URL) {
        Task {
            if let note = await library.importDocument(from: url, subject: currentSubject) { open(note) }
        }
    }

    /// Face ID is a privacy lock for the screen; files aren't separately encrypted beyond iOS's own data protection.
    private func open(_ note: Note) {
        guard library.beginEditing(note.id) else { return }
        guard note.locked else {
            let model = EditorModel(note: note, library: library)
            model.apply(pendingSetup)
            pendingSetup = nil
            editor = model
            return
        }
        let context = LAContext()
        var problem: NSError?
        // With no passcode on the device there's nothing to check against; don't lock the owner out of their notes.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            editor = EditorModel(note: note, library: library)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open “\(note.title)”") { success, _ in
            DispatchQueue.main.async {
                if success {
                    editor = EditorModel(note: note, library: library)
                } else {
                    library.endEditing(note.id)
                }
            }
        }
    }

    private func ask(_ title: String, initial: String = "", action: @escaping (String) -> Void) {
        promptText = initial
        prompt = TextPrompt(title: title, action: action)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $shelf) {
            Label("All Notes", systemImage: "note.text").tag(Shelf.all)
            Label("Favorites", systemImage: "star").tag(Shelf.favorites)
            Label("Unfiled", systemImage: "tray").tag(Shelf.unfiled)
            Label {
                HStack {
                    Text("Study")
                    Spacer()
                    if !library.dueCards.isEmpty { Text("\(library.dueCards.count)").foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: "graduationcap")
            }
            .tag(Shelf.study)
            Section("Folders") {
                ForEach(library.subjects) { subject in
                    Label {
                        Text(subject.name)
                    } icon: {
                        Circle().fill(Color(uiColor: UIColor(hex: subject.colorHex))).frame(width: 12, height: 12)
                    }
                    .tag(Shelf.subject(subject.id))
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            ask("Rename Folder", initial: subject.name) { if !$0.isEmpty { library.renameSubject(subject.id, to: $0) } }
                        }
                        Button("Delete Folder", systemImage: "trash", role: .destructive) {
                            if shelf == .subject(subject.id) { shelf = .all }
                            library.deleteSubject(subject.id)
                        }
                    }
                }
                Button("New Folder", systemImage: "plus") {
                    ask("New Folder") { if !$0.isEmpty { library.addSubject(name: $0) } }
                }
            }
            if !library.allTags.isEmpty {
                Section("Tags") {
                    ForEach(library.allTags, id: \.self) { tag in
                        Label(tag, systemImage: "number").tag(Shelf.tag(tag))
                    }
                }
            }
            Section {
                Label("My Templates", systemImage: "doc.on.doc").tag(Shelf.templates)
                Label("Recently Deleted", systemImage: "trash").tag(Shelf.trash)
            }
        }
        .navigationTitle("Margin")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        Group {
            if visibleNotes.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView {
                        Label(shelf == .trash ? "Nothing Deleted" : "No Notes", systemImage: shelf == .trash ? "trash" : "note.text")
                    } actions: {
                        if shelf != .trash { Button("New Note") { creating = true }.buttonStyle(.borderedProminent) }
                    }
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 22)], spacing: 26) {
                        ForEach(visibleNotes) { note in
                            NoteCard(note: note, library: library)
                                .onTapGesture {
                                    if note.deletedAt == nil { open(note) }
                                }
                                .contextMenu { menu(for: note) }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $search, prompt: "Search notes and handwriting")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Button("Import PDF or Document", systemImage: "doc.badge.plus") { importing = true }
                Button("New Note", systemImage: "square.and.pencil") { creating = true }
            }
        }
    }

    private var title: String {
        switch shelf ?? .all {
        case .all: "All Notes"
        case .favorites: "Favorites"
        case .unfiled: "Unfiled"
        case .study: "Study"
        case .templates: "My Templates"
        case .trash: "Recently Deleted"
        case let .subject(id): library.subjects.first { $0.id == id }?.name ?? "Notes"
        case let .tag(tag): "#\(tag)"
        }
    }

    @ViewBuilder private func menu(for note: Note) -> some View {
        if note.deletedAt != nil {
            Button("Restore", systemImage: "arrow.uturn.backward") { library.restore(note.id) }
            Button("Delete Forever", systemImage: "trash", role: .destructive) { library.deleteForever(note.id) }
        } else {
            Button("Rename", systemImage: "pencil") {
                ask("Rename Note", initial: note.title) { if !$0.isEmpty { library.rename(note.id, to: $0) } }
            }
            Button(note.favorite ? "Unfavorite" : "Favorite", systemImage: note.favorite ? "star.slash" : "star") {
                library.toggleFavorite(note.id)
            }
            Button("Tags", systemImage: "number") {
                ask("Tags, separated by commas", initial: note.tags.joined(separator: ", ")) { text in
                    let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    library.setTags(tags, for: note.id)
                }
            }
            Menu("Move to", systemImage: "folder") {
                Button("Unfiled") { library.move(note.id, to: nil) }
                ForEach(library.subjects) { subject in
                    Button(subject.name) { library.move(note.id, to: subject.id) }
                }
            }
            Button(note.locked ? "Remove Lock" : "Lock with Face ID", systemImage: note.locked ? "lock.open" : "lock") {
                setLock(note)
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(note.id) }
            Button("Remind Me", systemImage: "bell") { reminderNote = note }
            Button(note.isTemplate ? "Stop Using as Template" : "Save as Template", systemImage: "doc.on.doc") {
                library.setTemplate(!note.isTemplate, for: note.id)
            }
            Button("Delete", systemImage: "trash", role: .destructive) { library.trash(note.id) }
        }
    }

    private func setLock(_ note: Note) {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            library.lastError = "Set a passcode on this iPad before locking notes."
            return
        }
        guard note.locked else {
            library.setLocked(true, for: note.id)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Remove the lock from “\(note.title)”") { success, _ in
            DispatchQueue.main.async { if success { library.setLocked(false, for: note.id) } }
        }
    }
}

struct NoteCard: View {
    let note: Note
    let library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if note.locked {
                    ZStack {
                        Color.secondary.opacity(0.14)
                        Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                } else if let image = UIImage(contentsOfFile: library.thumbURL(note.id).path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .accessibilityHidden(true)

            Text(note.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                if note.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favorite") }
                if !note.recordings.isEmpty { Image(systemName: "waveform").accessibilityLabel("Has audio") }
                if note.locked { Image(systemName: "lock.fill").accessibilityLabel("Locked") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct LicensesView: View {
    private let text = Bundle.main.url(forResource: "Licenses", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        ScrollView {
            Text(text).font(.footnote).textSelection(.enabled).padding()
        }
        .navigationTitle("Open-Source Licenses")
    }
}

struct SettingsView: View {
    let library: Library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultPaper") private var paper = PaperStyle.ruled
    @AppStorage("defaultColor") private var color = PaperColor.white
    @AppStorage("defaultSize") private var size = PageSize.letter
    @AppStorage("snapToText") private var snapToText = true
    @AppStorage("scribbleErase") private var scribbleErase = true
    @AppStorage("holdForShapes") private var holdForShapes = true
    @AppStorage("liveTranscribe") private var liveTranscribe = true
    @AppStorage("eraserReturns") private var eraserReturns = true
    @AppStorage("theme") private var theme = "system"
    @AppStorage("invertPages") private var invertPages = true
    @State private var folder = Backup.folderName
    @State private var pickingFolder = false
    @State private var pickingRestore = false
    @State private var status: String?
    @State private var backingUp = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $theme) {
                        Text("Match iPad").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Toggle("Invert Pages in Dark Theme", isOn: $invertPages)
                }
                Section("New Notes") {
                    Picker("Paper", selection: $paper) { ForEach(PaperStyle.allCases) { Text($0.title).tag($0) } }
                    Picker("Color", selection: $color) { ForEach(PaperColor.allCases) { Text($0.title).tag($0) } }
                    Picker("Size", selection: $size) { ForEach(PageSize.allCases) { Text($0.title).tag($0) } }
                }
                Section("Writing") {
                    Toggle("Snap PDF Highlights to Text", isOn: $snapToText)
                    Toggle("Scratch Out to Delete", isOn: $scribbleErase)
                    Toggle("Hold to Draw Shapes", isOn: $holdForShapes)
                    Toggle("Return to Pen After Erasing", isOn: $eraserReturns)
                }
                Section("Recording") {
                    Toggle("Live Transcription", isOn: $liveTranscribe)
                }
                Section {
                    LabeledContent(ModelFile.writing.title) { ModelRow(file: .writing) }
                    LabeledContent(ModelFile.speech.title) { ModelRow(file: .speech) }
                    NavigationLink("Open-Source Licenses") { LicensesView() }
                } header: {
                    Text("On-Device AI")
                } footer: {
                    Text("Summaries, chat, flashcards, quizzes and transcripts run entirely on this iPad with open-source models. They download once from Hugging Face, then work offline. Your notes never leave the device.")
                }
                Section {
                    LabeledContent("Folder", value: folder ?? "Not set")
                    Button(folder == nil ? "Choose Backup Folder" : "Change Folder") { pickingFolder = true }
                    if folder != nil {
                        Button(backingUp ? "Backing Up…" : "Back Up Now") {
                            backingUp = true
                            Task {
                                let count = await library.backUp()
                                status = "Backed up \(count) changed notes."
                                backingUp = false
                            }
                        }
                        .disabled(backingUp)
                        Button("Stop Backing Up", role: .destructive) {
                            Backup.clearFolder()
                            folder = nil
                        }
                    }
                    Button("Restore from a Backup") { pickingRestore = true }
                    if let status { Text(status).foregroundStyle(.secondary) }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Pick a folder in iCloud Drive, Dropbox or anywhere in Files. Notes copy there when you close them. Restore on another iPad to move your notes across.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                guard case let .success(url) = result else { return }
                do {
                    try Backup.setFolder(url)
                    folder = Backup.folderName
                    Task {
                        let count = await library.backUp()
                        status = "Backed up \(count) notes."
                    }
                } catch {
                    status = "Couldn't use that folder: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $pickingRestore, allowedContentTypes: [.folder]) { result in
                guard case let .success(url) = result else { return }
                status = "Restored \(library.restoreBackup(from: url)) notes."
            }
        }
    }
}
