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
    @State private var deleting: Note?
    @State private var busy: String?
    @AppStorage("iCloudBannerDismissed") private var bannerDismissed = false

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
        .overlay {
            if let busy {
                ProgressView(busy)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear { resumeLastNote() }
        .fullScreenCover(isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })) {
            if let model = editor {
                EditorView(model: model, onClose: {
                    model.close()
                    editor = nil
                    UserDefaults.standard.removeObject(forKey: Self.lastNoteKey)
                }, onOpen: { switchTo($0, from: model) })
                .id(model.id)
                .onChange(of: model.openNoteRequest) { _, id in
                    if let id { switchTo(id, from: model) }
                }
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
        busy = "Importing…"
        Task {
            let note = await library.importDocument(from: url, subject: currentSubject)
            busy = nil
            if let note { open(note) }
        }
    }

    /// Swaps the note on screen in place, so moving between tabs doesn't animate the editor away and back.
    private func switchTo(_ id: UUID, from current: EditorModel) {
        guard id != current.note.id, let target = library.notes.first(where: { $0.id == id }) else { return }
        current.close()
        if target.locked {
            editor = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { open(target) }
        } else {
            open(target)
        }
    }

    private func file(_ note: Note) async throws -> Subject? {
        let body = note.searchText + "\n" + note.elements.map(\.text).joined(separator: "\n")
        let name = try await AI.folder(for: "\(note.title)\n\(body)", among: library.subjects.map(\.name))
        guard let folder = library.subjects.first(where: { $0.name == name }) else { return nil }
        library.move(note.id, to: folder.id)
        return folder
    }

    private func fileAutomatically(_ note: Note) {
        busy = "Choosing a folder…"
        Task {
            defer { busy = nil }
            do {
                if let folder = try await file(note) {
                    busy = "Moved to \(library.path(of: folder))"
                    try? await Task.sleep(for: .seconds(1.5))
                }
            } catch {
                library.lastError = error.localizedDescription
            }
        }
    }

    private func sortUnfiled() {
        let waiting = library.notes.filter { $0.subjectID == nil && $0.deletedAt == nil && !$0.isTemplate && !$0.locked }
        Task {
            defer { busy = nil }
            do {
                for (i, note) in waiting.enumerated() {
                    busy = "Sorting \(i + 1) of \(waiting.count)…"
                    _ = try await file(note)
                }
            } catch {
                library.lastError = error.localizedDescription
            }
        }
    }

    private static let lastNoteKey = "lastOpenNote"
    private static var resumed = false

    /// If Margin was left inside a note, it comes back there. Going back to the library first means starting from the library.
    private func resumeLastNote() {
        guard !Self.resumed else { return }
        Self.resumed = true
        guard let id = UserDefaults.standard.string(forKey: Self.lastNoteKey),
              let note = library.notes.first(where: { $0.id.uuidString == id && $0.deletedAt == nil && !$0.locked }) else { return }
        open(note)
    }

    /// Face ID is a privacy lock for the screen; files aren't separately encrypted beyond iOS's own data protection.
    private func open(_ note: Note) {
        guard library.beginEditing(note.id) else { return }
        library.addTab(note.id)
        UserDefaults.standard.set(note.id.uuidString, forKey: Self.lastNoteKey)
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
            let due = library.dueCards.count, tags = library.allTags
            Label("All Notes", systemImage: "note.text").tag(Shelf.all)
            Label("Favorites", systemImage: "star").tag(Shelf.favorites)
            Label("Unfiled", systemImage: "tray").tag(Shelf.unfiled)
            Label {
                HStack {
                    Text("Study")
                    Spacer()
                    if due > 0 { Text("\(due)").foregroundStyle(.secondary) }
                }
            } icon: {
                Image(systemName: "graduationcap")
            }
            .tag(Shelf.study)
            Section("Folders") {
                folderRows(in: nil)
                Button("New Folder", systemImage: "plus") {
                    ask("New Folder") { if !$0.isEmpty { library.addSubject(name: $0) } }
                }
            }
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.self) { tag in
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

    private func folderRows(in parent: UUID?) -> AnyView {
        AnyView(ForEach(library.subfolders(of: parent)) { subject in
            if library.subfolders(of: subject.id).isEmpty {
                folderRow(subject)
            } else {
                DisclosureGroup {
                    folderRows(in: subject.id)
                } label: {
                    folderRow(subject)
                }
            }
        })
    }

    private func folderRow(_ subject: Subject) -> some View {
        Label {
            Text(subject.name)
        } icon: {
            Circle().fill(Color(uiColor: UIColor(hex: subject.colorHex))).frame(width: 12, height: 12)
        }
        .tag(Shelf.subject(subject.id))
        .contextMenu {
            Button("New Subfolder", systemImage: "folder.badge.plus") {
                ask("New Subfolder") { if !$0.isEmpty { library.addSubject(name: $0, parent: subject.id) } }
            }
            Button("Rename", systemImage: "pencil") {
                ask("Rename Folder", initial: subject.name) { if !$0.isEmpty { library.renameSubject(subject.id, to: $0) } }
            }
            Button("Delete Folder", systemImage: "trash", role: .destructive) {
                if shelf == .subject(subject.id) { shelf = .all }
                library.deleteSubject(subject.id)
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 0) {
            let notes = visibleNotes
            if !Sync.hasFolder, !bannerDismissed {
                ICloudBanner(library: library) { bannerDismissed = true }
                    .padding([.horizontal, .top], 24)
            }
            if notes.isEmpty {
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 22, alignment: .top)], spacing: 26) {
                        ForEach(notes) { note in
                            Button {
                                if note.deletedAt == nil { open(note) }
                            } label: {
                                NoteCard(note: note, library: library)
                            }
                            .buttonStyle(CardPress())
                            .contextMenu { menu(for: note) }
                        }
                    }
                    .padding(24)
                    if let status = library.syncStatus {
                        Label(status, systemImage: "icloud")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
        .alert("Delete “\(deleting?.title ?? "")” Forever?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { library.deleteForever(deleting.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone, and it's removed from your other devices too.")
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
                if shelf == .unfiled, AI.isAvailable, !library.subjects.isEmpty, !visibleNotes.isEmpty {
                    Button("Sort into Folders", systemImage: "sparkles") { sortUnfiled() }
                }
                Button("Import PDF or Document", systemImage: "doc.badge.plus") { importing = true }
                // A tap asks how the note should be set up. Holding it skips that, for writing something down right away.
                Menu {
                    Button("Quick Note", systemImage: "bolt") { open(library.createNote(subject: currentSubject)) }
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                } primaryAction: {
                    creating = true
                }
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
            Button("Delete Forever", systemImage: "trash", role: .destructive) { deleting = note }
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
                    Button(library.path(of: subject)) { library.move(note.id, to: subject.id) }
                }
            }
            if AI.isAvailable, !library.subjects.isEmpty, !note.locked {
                Button("File Automatically", systemImage: "sparkles") { fileAutomatically(note) }
            }
            Menu("Cover", systemImage: "book.closed") {
                Button("First Page") { library.setCover(nil, for: note.id) }
                ForEach(NoteCard.covers, id: \.hex) { cover in
                    Button(cover.name) { library.setCover(cover.hex, for: note.id) }
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

/// Asks in place rather than on launch, since Apple's privacy rules leave choosing the folder to the person.
struct ICloudBanner: View {
    let library: Library
    let dismiss: () -> Void
    @State private var picking = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "icloud").font(.title2).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Every Note in iCloud").font(.subheadline.weight(.semibold))
                    Text("Choose a folder in iCloud Drive and Margin saves all your notes and annotations there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Choose Folder") { picking = true }.buttonStyle(.borderedProminent)
                    Button("Not Now", action: dismiss)
                }
                .font(.subheadline)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result, (try? Sync.setFolder(url)) != nil else { return }
            Task { await library.sync() }
        }
    }
}

/// The card gives way slightly under a finger, like pressing on paper.
private struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct NoteCard: View {
    let note: Note
    let library: Library

    static let covers = [
        (name: "Navy", hex: "1F3A5F"), (name: "Forest", hex: "2F4F3E"), (name: "Oxblood", hex: "7A2E2E"),
        (name: "Graphite", hex: "3B3B3F"), (name: "Ochre", hex: "8A6D3B"), (name: "Plum", hex: "5B4A7A"),
    ]

    private func cover(_ hex: String) -> some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: UIColor(hex: hex))
            // A notebook's stitched spine.
            Rectangle().fill(.black.opacity(0.18)).frame(width: 12)
            Text(note.title)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(4)
                .padding(.leading, 26)
                .padding([.top, .trailing], 16)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Every card is the same shape, whatever the page's, so a row of notes lines up.
            Color.white
                .aspectRatio(8.5 / 11, contentMode: .fit)
                .overlay(alignment: .top) {
                    if note.locked {
                        ZStack {
                            Color(.secondarySystemBackground)
                            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                        }
                    } else if let hex = note.coverHex {
                        cover(hex)
                    } else if let image = library.thumbnail(for: note.id) {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .accessibilityHidden(true)

            // The rule down a ruled page's left side, which is what the app is named for.
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.accentColor).frame(width: 1.5).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted) + (note.pages.count > 1 ? " · \(note.pages.count) pages" : ""))
                        if note.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favorite") }
                        if !note.recordings.isEmpty { Image(systemName: "waveform").accessibilityLabel("Has audio") }
                        if note.locked { Image(systemName: "lock.fill").accessibilityLabel("Locked") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
    @AppStorage("scribbleErase") private var scribbleErase = true
    @AppStorage("holdForShapes") private var holdForShapes = true
    @AppStorage("liveTranscribe") private var liveTranscribe = true
    @AppStorage(SpeechLanguage.key) private var speechLanguage = "en"
    @AppStorage("eraserReturns") private var eraserReturns = true
    @AppStorage("tiltPressure") private var tiltPressure = false
    @AppStorage("tiltStrength") private var tiltStrength = 0.6
    @AppStorage("theme") private var theme = "system"
    @AppStorage("invertPages") private var invertPages = true
    @State private var folder = Sync.folderName
    @State private var pickingFolder = false
    @State private var status: String?

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
                Section {
                    Toggle("Scratch Out to Delete", isOn: $scribbleErase)
                    Toggle("Hold to Draw Shapes", isOn: $holdForShapes)
                    Toggle("Switch Back After Erasing", isOn: $eraserReturns)
                    Toggle("Tilt for Pressure", isOn: $tiltPressure)
                    if tiltPressure {
                        LabeledContent("Strength") {
                            Slider(value: $tiltStrength, in: 0.2...1)
                        }
                    }
                } header: {
                    Text("Writing")
                } footer: {
                    if tiltPressure { Text("Lean the Pencil over for a thicker line, or hold it upright for a thinner one. The line changes when you lift the Pencil.") }
                }
                Section {
                    Toggle("Live Transcription", isOn: $liveTranscribe)
                    Picker("Language", selection: $speechLanguage) {
                        ForEach(SpeechLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    if speechLanguage != "en" { Text("Languages other than English use the Other Languages model, downloaded below.") }
                }
                Section {
                    LabeledContent(ModelFile.writing.title) { ModelRow(file: .writing) }
                    LabeledContent(ModelFile.speech.title) { ModelRow(file: .speech) }
                    LabeledContent(ModelFile.speechWorld.title) { ModelRow(file: .speechWorld) }
                    NavigationLink("Open-Source Licenses") { LicensesView() }
                } header: {
                    Text("On-Device AI")
                } footer: {
                    Text("Summaries, chat, flashcards, quizzes and transcripts run entirely on this iPad with open-source models. They download once from Hugging Face, then work offline. The AI never sends your notes anywhere.")
                }
                Section {
                    LabeledContent("Folder", value: folder ?? "Not set")
                    Button(folder == nil ? "Choose iCloud Drive Folder" : "Change Folder") { pickingFolder = true }
                    if folder != nil {
                        Button("Sync Now") { syncNow() }
                        Button("Stop Syncing", role: .destructive) {
                            Sync.clearFolder()
                            folder = nil
                            status = nil
                        }
                    }
                    if folder != nil, !Sync.isInICloud {
                        Text("This folder isn't in iCloud Drive, so your notes won't reach iCloud.").foregroundStyle(.red)
                    }
                    if let line = status ?? library.syncStatus { Text(line).foregroundStyle(.secondary) }
                } header: {
                    Text("iCloud Sync")
                } footer: {
                    Text("In the picker, open iCloud Drive and choose or create a folder. Margin keeps your notes in it and syncs when you open the app, close a note or leave the app. Choose the same folder on another device to get them there.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                guard case let .success(url) = result else { return }
                do {
                    try Sync.setFolder(url)
                    folder = Sync.folderName
                    syncNow()
                } catch {
                    status = "Couldn't use that folder: \(error.localizedDescription)"
                }
            }
        }
    }

    private func syncNow() {
        status = "Syncing…"
        Task {
            await library.sync()
            status = nil
        }
    }
}
