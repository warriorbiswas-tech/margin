import PhotosUI
import SwiftUI

enum StudyError: LocalizedError {
    case emptyNote, emptySelection, noTranscript, emptyExplanation, emptyQuestion
    var errorDescription: String? {
        switch self {
        case .emptyNote: "There's nothing in this note to work from yet."
        case .emptySelection: "No text could be read in that area. Try selecting printed text or clearer handwriting."
        case .emptyExplanation: "Write your explanation first."
        case .emptyQuestion: "Type a question or choose a photo of one first."
        case .noTranscript: "This needs a recording with a transcript. Record the talk, or transcribe a recording from the playback bar."
        }
    }
}

/// Offers the one-time download where a feature needs it.
struct ModelPrompt: View {
    let file: ModelFile

    var body: some View {
        ContentUnavailableView {
            Label(file.title, systemImage: "arrow.down.circle")
        } description: {
            Text("This feature runs on your iPad using an open-source model. It downloads once (\(file.bytes.formatted(.byteCount(style: .file)))) and then works offline. Your notes never leave the device.")
        } actions: {
            ModelRow(file: file)
        }
    }
}

struct ModelRow: View {
    let file: ModelFile
    @State private var downloads = ModelDownloads.shared

    var body: some View {
        switch downloads.state(of: file) {
        case .absent:
            Button("Download \(file.bytes.formatted(.byteCount(style: .file)))") { downloads.download(file) }
                .disabled(!(file.name == ModelFile.writing.name ? margin_llm_supported() : margin_whisper_supported()))
        case let .downloading(done):
            ProgressView("Downloading…", value: done)
        case .verifying:
            ProgressView("Checking the download…")
        case .installed:
            Button("Remove from iPad", role: .destructive) { downloads.remove(file) }
        case let .failed(reason):
            VStack {
                Text(reason).foregroundStyle(.red)
                Button("Try Again") { downloads.download(file) }
            }
        }
    }
}

struct MindMapView: View {
    let model: EditorModel
    let generate: () async throws -> MindNode
    @State private var root: MindNode?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button(root == nil ? "Map This Note" : "Map It Again") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                if working { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
                if let root {
                    Image(uiImage: Renderer.mindMap(root))
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Mind map of \(root.title)")
                    Button("Insert into Note", systemImage: "text.badge.plus") { model.insertMindMap(root) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func run() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                root = try await generate()
            } catch is CancellationError {
                self.error = "Stopped because Margin left the screen. Try again."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct AssistantSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case chat = "Chat", summary = "Summary", points = "Key Points", cards = "Flashcards", quiz = "Quiz", map = "Mind Map", teach = "Teach Back", homework = "Homework", finish = "Finish Notes"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .chat: "bubble.left.and.text.bubble.right"
            case .summary: "text.alignleft"
            case .points: "list.bullet.clipboard"
            case .cards: "rectangle.on.rectangle"
            case .quiz: "checklist"
            case .map: "point.3.connected.trianglepath.dotted"
            case .teach: "person.wave.2"
            case .homework: "camera.viewfinder"
            case .finish: "text.badge.plus"
            }
        }
    }
    @State private var tab = Tab.chat
    @State private var wholeNote = true
    @State private var fromPage = 1
    @State private var toPage = 1

    private var isLong: Bool { model.note.pages.count > 30 }
    private var range: ClosedRange<Int>? { wholeNote ? nil : min(fromPage, toPage)...max(fromPage, toPage) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Tab.allCases) { option in
                            OptionToggle(title: option.rawValue, icon: option.icon, isOn: Binding(get: { tab == option }, set: { if $0 { tab = option } }))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                if tab != .chat, tab != .finish, tab != .teach, tab != .homework, model.note.pages.count > 1 { scopeBar }
                if let progress = model.aiProgress {
                    Text(progress).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 6)
                }
                if !AI.isAvailable, tab != .cards {
                    ModelPrompt(file: .writing)
                } else {
                    switch tab {
                    case .summary:
                        GeneratedText(button: "Summarize", insertInto: model) { partial in
                            try await AI.summary(of: try await nonEmptyText(), using: model.digester(), onPartial: partial)
                        }
                    case .points:
                        GeneratedText(button: "Find Key Points", insertInto: model) { partial in
                            try await AI.keyPoints(of: try await nonEmptyText(), using: model.digester(), onPartial: partial)
                        }
                    case .chat:
                        ChatView { question in await model.chatContext(for: question) }
                    case .cards:
                        CardsView(model: model, text: { try await nonEmptyText() })
                    case .quiz:
                        QuizView { try await AI.quiz(from: try await nonEmptyText(), using: model.digester()) }
                    case .map:
                        MindMapView(model: model) { try await AI.mindMap(from: try await nonEmptyText(), using: model.digester()) }
                    case .teach:
                        TeachBackView(model: model)
                    case .homework:
                        HomeworkView(model: model)
                    case .finish:
                        GeneratedText(button: "Fill In What I Missed", insertInto: model) { partial in
                            guard !model.transcriptText.isEmpty else { throw StudyError.noTranscript }
                            let notes = await model.studyText(pages: nil)
                            return try await AI.finishNotes(notes: notes, transcript: model.transcriptText, using: model.digester(), onPartial: partial)
                        }
                    }
                }
            }
            .navigationTitle("Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                LocalLLM.shared.warmUp()
                // A whole book takes many minutes, so a long note starts on the pages in front of you.
                wholeNote = !isLong
                fromPage = model.currentPage
                toPage = min(model.currentPage + 9, model.note.pages.count)
            }
            .onChange(of: tab) {
                model.aiProgress = nil
            }
            .onDisappear { model.aiProgress = nil }
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 12) {
            Picker("Use", selection: $wholeNote) {
                Text("Pages").tag(false)
                Text("Whole Note").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            if wholeNote {
                if isLong {
                    Text("\(model.note.pages.count) pages can take a long time.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Stepper("From \(fromPage)", value: $fromPage, in: 1...model.note.pages.count).fixedSize()
                Stepper("To \(toPage)", value: $toPage, in: 1...model.note.pages.count).fixedSize()
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func nonEmptyText() async throws -> String {
        let text = await model.studyText(pages: range)
        guard !text.isEmpty else { throw StudyError.emptyNote }
        return text
    }
}

struct TeachBackView: View {
    let model: EditorModel
    @State private var explanation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Explain a topic from this note in your own words. Margin compares it with your notes and shows you what's missing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            TextEditor(text: $explanation)
                .frame(height: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .accessibilityLabel("Your explanation")
            GeneratedText(button: "Check My Understanding", insertInto: model) { partial in
                let said = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !said.isEmpty else { throw StudyError.emptyExplanation }
                return try await AI.reviewExplanation(said, against: await model.chatContext(for: said), onPartial: partial)
            }
        }
    }
}

struct HomeworkView: View {
    let model: EditorModel
    @State private var question = ""
    @State private var photo: PhotosPickerItem?
    @State private var reading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PhotosPicker("Choose a Photo", selection: $photo, matching: .images)
                if reading { ProgressView() }
                Spacer()
            }
            .padding(.horizontal)
            TextEditor(text: $question)
                .frame(height: 130)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .accessibilityLabel("Your question")
            GeneratedText(button: "Solve Step by Step", insertInto: model) { partial in
                let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !asked.isEmpty else { throw StudyError.emptyQuestion }
                return try await AI.ask(.steps, about: asked, onPartial: partial)
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            reading = true
            Task {
                defer {
                    reading = false
                    photo = nil
                }
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                question = await Task.detached(priority: .userInitiated) { Renderer.recognize(image) }.value
            }
        }
    }
}

struct AnswerSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let answer = model.aiAnswer {
                        if answer.working, answer.text.isEmpty {
                            Label { Text("Thinking…") } icon: { ProgressView() }.foregroundStyle(.secondary)
                        }
                        if let failure = answer.failure { Text(failure).foregroundStyle(.red) }
                        Text(TextTools.styled(answer.text)).lineSpacing(3).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(model.aiAnswer?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let answer = model.aiAnswer, !answer.working, !answer.text.isEmpty {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = TextTools.plain(answer.text) }
                        Button("Insert into Note", systemImage: "text.badge.plus") {
                            model.insertText(TextTools.plain(answer.text))
                            dismiss()
                        }
                    }
                }
            }
        }
        .onDisappear { model.askTask?.cancel() }
    }
}

struct GeneratedText: View {
    let button: String
    let insertInto: EditorModel
    let generate: (@escaping @Sendable (String) -> Void) async throws -> String
    @State private var text = ""
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if working {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(text.isEmpty ? "Reading your notes…" : "Writing…").foregroundStyle(.secondary)
                        Button("Stop", role: .destructive) { task?.cancel() }
                    }
                } else {
                    Button(button) { run() }.buttonStyle(.borderedProminent)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if !text.isEmpty {
                    Text(TextTools.styled(text)).lineSpacing(3).textSelection(.enabled)
                    if !working {
                        HStack {
                            Button("Insert into Note", systemImage: "text.badge.plus") { insertInto.insertText(TextTools.plain(text)) }
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = TextTools.plain(text) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .onDisappear { task?.cancel() }
    }

    private func run() {
        working = true
        error = nil
        task = Task {
            defer { working = false }
            do {
                let result = try await generate { partial in
                    DispatchQueue.main.async { text = partial }
                }
                text = result
            } catch is CancellationError {
                self.error = "Stopped."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ChatView: View {
    let context: (String) async -> String
    @State private var messages: [(role: String, text: String)] = []
    @State private var draft = ""
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            Text("Ask anything. Margin finds the right pages first, so this works on long books too, and nothing leaves your iPad.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(messages.enumerated()), id: \.offset) { i, message in
                            Text(message.role == "user" ? AttributedString(message.text) : TextTools.styled(message.text))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(.horizontal, message.role == "user" ? 14 : 0)
                                .padding(.vertical, message.role == "user" ? 9 : 2)
                                .background(message.role == "user" ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 18))
                                .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                                .id(i)
                        }
                        if working, messages.last?.text.isEmpty != false {
                            Label { Text("Finding the right pages…") } icon: { ProgressView() }.foregroundStyle(.secondary)
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .onChange(of: messages.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: messages.last?.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onDisappear { task?.cancel() }
            Divider()
            HStack {
                TextField("Ask a question", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                    .onSubmit(send)
                if working {
                    Button("Stop", systemImage: "stop.circle.fill") { task?.cancel() }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !working else { return }
        draft = ""
        messages.append(("user", question))
        working = true
        error = nil
        task = Task {
            defer { working = false }
            do {
                // A follow-up like "why does it happen?" says nothing of its subject, so the question before it searches too.
                let recent = messages.filter { $0.role == "user" }.suffix(2).map(\.text).joined(separator: " ")
                let system = AI.chatSystem(context: await context(recent))
                let asked = Array(messages.suffix(5)) // recent turns are enough, and leave room for the notes
                messages.append(("assistant", ""))
                let last = messages.count - 1
                let answer = try await AI.complete(system: system, messages: asked) { partial in
                    DispatchQueue.main.async { if messages.indices.contains(last) { messages[last].text = partial } }
                }
                messages[last].text = answer
            } catch {
                // What was already written of the answer stays, as when stopping any other reply.
                if messages.last?.text.isEmpty == true { messages.removeLast() }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
}

struct CardsView: View {
    @Bindable var model: EditorModel
    let text: () async throws -> String
    @State private var working = false
    @State private var error: String?
    @State private var front = ""
    @State private var back = ""
    @State private var reviewing = false

    var body: some View {
        List {
            Section {
                Button("Review \(model.dueCards.count) Due", systemImage: "play.fill") { reviewing = true }
                    .disabled(model.dueCards.isEmpty)
                Button(working ? "Writing Cards…" : "Write Cards from This Note") { generate() }
                    .disabled(working || !AI.isAvailable)
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section("New Card") {
                TextField("Front", text: $front, axis: .vertical)
                TextField("Back", text: $back, axis: .vertical)
                Button("Add Card", systemImage: "plus") {
                    model.note.flashcards.append(Flashcard(front: front, back: back))
                    model.scheduleSave()
                    front = ""
                    back = ""
                }
                .disabled(front.isEmpty || back.isEmpty)
            }
            Section("\(model.note.flashcards.count) Cards") {
                ForEach($model.note.flashcards) { $card in
                    HStack {
                        if let file = card.frontImage, let image = model.image(named: file) {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 80, height: 48).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading) {
                            TextField("Front", text: $card.front, axis: .vertical).font(.subheadline.weight(.semibold))
                            TextField("Answer", text: $card.back, axis: .vertical).font(.subheadline)
                            Text(card.due <= Date() ? "Due now" : "Due \(card.due.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    model.note.flashcards.remove(atOffsets: offsets)
                    model.scheduleSave()
                }
            }
        }
        .onChange(of: model.note.flashcards) { model.scheduleSave() }
        .sheet(isPresented: $reviewing) {
            ReviewView(queue: model.dueCards, image: { due in due.card.frontImage.flatMap(model.image(named:)) }) { due, grade in
                model.grade(due, grade)
            }
        }
    }

    private func generate() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let cards = try await AI.flashcards(from: try await text(), using: model.digester())
                model.note.flashcards += cards.map { Flashcard(front: $0.front, back: $0.back) }
                model.scheduleSave()
            } catch is CancellationError {
                self.error = "Stopped because Margin left the screen. Try again."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ReviewView: View {
    @State var queue: [Library.DueCard]
    let image: (Library.DueCard) -> UIImage?
    let onGrade: (Library.DueCard, SM2.Grade) -> Void
    @State private var revealed = false
    @State private var done = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let due = queue.first {
                    VStack(spacing: 20) {
                        ScrollView {
                            VStack(spacing: 18) {
                                if let picture = image(due) {
                                    Image(uiImage: picture).resizable().scaledToFit().frame(maxHeight: 280).accessibilityLabel("Card image")
                                }
                                if !due.card.front.isEmpty { Text(due.card.front).font(.title2.weight(.semibold)).multilineTextAlignment(.center) }
                                if revealed {
                                    Divider()
                                    Text(due.card.back.isEmpty ? "(No answer written)" : due.card.back).font(.title3).multilineTextAlignment(.center)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        if revealed {
                            HStack {
                                ForEach(SM2.Grade.allCases) { grade in
                                    Button(grade.title) { answer(due, grade) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        } else {
                            Button("Show Answer") { revealed = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView("All Done", systemImage: "checkmark.circle", description: Text("You reviewed \(done) cards."))
                }
            }
            .navigationTitle(queue.isEmpty ? "Review" : "\(queue.count) Left")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func answer(_ due: Library.DueCard, _ grade: SM2.Grade) {
        guard queue.first?.id == due.id else { return } // a second tap before the next card appears
        onGrade(due, grade)
        queue.removeFirst()
        if grade == .again { queue.append(due) } else { done += 1 }
        revealed = false
    }
}

struct QuizView: View {
    let generate: () async throws -> [QuizQuestion]
    @State private var questions: [QuizQuestion] = []
    @State private var answers: [String: Int] = [:]
    @State private var working = false
    @State private var error: String?

    private var score: Int { questions.filter { answers[$0.id] == $0.answer }.count }

    var body: some View {
        List {
            Section {
                Button(working ? "Writing Questions…" : (questions.isEmpty ? "Start a Quiz" : "New Quiz")) { run() }
                    .disabled(working)
                if let error { Text(error).foregroundStyle(.red) }
                if !questions.isEmpty, answers.count == questions.count {
                    Text("You got \(score) of \(questions.count).").font(.headline)
                }
            }
            ForEach(questions) { question in
                Section(question.question) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                        Button {
                            if answers[question.id] == nil { answers[question.id] = i }
                        } label: {
                            HStack {
                                Text(option).foregroundStyle(.primary)
                                Spacer()
                                if let chosen = answers[question.id] {
                                    if i == question.answer {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Correct answer")
                                    } else if i == chosen {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Your answer, incorrect")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func run() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                questions = try await generate()
                answers = [:]
            } catch is CancellationError {
                self.error = "Stopped because Margin left the screen. Try again."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct StudyHome: View {
    let library: Library
    @State private var reviewing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(library.dueCards.count) cards due").font(.title2.weight(.semibold))
                    Text("From all your notes").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review", systemImage: "play.fill") { reviewing = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.dueCards.isEmpty)
            }
            .padding()
            Divider()
            if AI.isAvailable {
                ChatView { question in await library.context(for: question) }
            } else {
                ModelPrompt(file: .writing)
            }
        }
        .sheet(isPresented: $reviewing) {
            ReviewView(queue: library.dueCards, image: library.cardImage) { due, grade in
                library.grade(due, grade)
            }
        }
    }
}

struct FindSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var texts: [String]?

    private var hits: [(page: Int, snippet: String)] {
        guard let texts, !query.isEmpty else { return [] }
        return texts.enumerated().compactMap { i, text in
            guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            return (i, text[start..<end].replacingOccurrences(of: "\n", with: " "))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if texts == nil {
                    ProgressView("Reading your pages…")
                } else if query.isEmpty {
                    ContentUnavailableView("Find in Note", systemImage: "magnifyingglass", description: Text("Searches handwriting, typed text and PDFs."))
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(hits, id: \.page) { hit in
                        Button {
                            model.jump(toPage: hit.page)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text("Page \(hit.page + 1)").font(.headline).foregroundStyle(.primary)
                                Text(hit.snippet).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this note")
            .navigationTitle("Find")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { texts = await model.pageTexts() }
        }
    }
}

struct VersionsSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: Library.Version?

    var body: some View {
        NavigationStack {
            let versions = model.library.versions(model.note.id)
            Group {
                if versions.isEmpty {
                    ContentUnavailableView("No Versions Yet", systemImage: "clock.arrow.circlepath", description: Text("A version is saved each time you close this note after changing it."))
                } else {
                    List(versions) { version in
                        Button(version.date.formatted(date: .abbreviated, time: .shortened)) { confirm = version }
                    }
                }
            }
            .navigationTitle("Version History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Restore this version? What you have now is kept as a version too.", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                Button("Restore") {
                    if let confirm { model.restore(confirm) }
                    dismiss()
                }
            }
        }
    }
}

struct ExcerptsSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.note.excerpts.isEmpty && !model.note.elements.contains(where: { $0.comment != nil }) {
                    ContentUnavailableView("No Excerpts", systemImage: "scissors", description: Text("Highlight text in a PDF, or use Select Area and choose Excerpt. Each one links back to where it came from."))
                } else {
                    List {
                        let comments = model.note.elements.filter { $0.comment != nil }
                        if !comments.isEmpty {
                            Section("Comments") {
                                ForEach(comments) { el in
                                    Button(el.comment ?? "") {
                                        model.jump(to: el.rect)
                                        dismiss()
                                    }
                                }
                            }
                        }
                        ForEach(model.note.excerpts) { excerpt in
                            Button {
                                model.jump(to: excerpt.rect)
                                dismiss()
                            } label: {
                                if let text = excerpt.text {
                                    Text(text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                } else if let file = excerpt.imageFile, let image = model.image(named: file) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                        .accessibilityLabel("Excerpt from \(excerpt.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { model.note.excerpts[$0] }.forEach(model.deleteExcerpt)
                        }
                    }
                }
            }
            .navigationTitle("Excerpts and Highlights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Copy All Highlights", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = model.note.excerpts.compactMap(\.text).joined(separator: "\n\n")
                        }
                        .disabled(!model.note.excerpts.contains { $0.text != nil })
                        Button("Delete All Excerpts", systemImage: "trash", role: .destructive) { model.deleteAllExcerpts() }
                            .disabled(model.note.excerpts.isEmpty)
                    }
                }
            }
        }
    }
}

struct StickerSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var mine: [URL] = []
    private let groups: [(String, String)] = [
        ("Study", "📌 📎 ✏️ 📝 📚 📖 🎓 🧠 💡 🔬 🧪 🧮 📐 📏 🗂️ 📅 ⏰ ✅ ❌ ❓ ❗ ⭐ 🔥 🎯"),
        ("Reactions", "😀 😂 🥳 😎 🤔 😴 😭 🤯 👍 👎 👏 🙌 💪 ❤️ 💯 🎉"),
        ("Nature", "🌱 🌿 🌸 🌻 🌙 ☀️ ⛅ 🌈 🐱 🐶 🦊 🐼 🦉 🐝 🦋 🐢"),
        ("Arrows", "➡️ ⬅️ ⬆️ ⬇️ ↗️ ↘️ ↩️ 🔁 ➕ ➖ ✖️ ➗"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !mine.isEmpty {
                        Text("My Stickers").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 10) {
                            ForEach(mine, id: \.self) { url in
                                Button {
                                    if let data = try? Data(contentsOf: url) { model.addImage(data, transparent: true) }
                                    dismiss()
                                } label: {
                                    if let image = UIImage(contentsOfFile: url.path) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(width: 88, height: 88)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Sticker")
                                .contextMenu {
                                    Button("Remove Sticker", systemImage: "trash", role: .destructive) {
                                        try? FileManager.default.removeItem(at: url)
                                        mine = model.library.stickers
                                    }
                                }
                            }
                        }
                    }
                    ForEach(groups, id: \.0) { group in
                        Text(group.0).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 10) {
                            ForEach(group.1.split(separator: " ").map(String.init), id: \.self) { emoji in
                                Button {
                                    model.addSticker(emoji)
                                    dismiss()
                                } label: {
                                    Text(emoji).font(.system(size: 38)).frame(width: 56, height: 56)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { mine = model.library.stickers }
        }
    }
}
