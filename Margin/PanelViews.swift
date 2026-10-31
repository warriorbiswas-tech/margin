import PDFKit
import PencilKit
import SwiftUI
import UserNotifications
import WebKit

/// A browser beside the page. Clip what you see, or save the whole page into the note.
struct WebPanel: View {
    let model: EditorModel
    @State private var address = ""
    @State private var web = WKWebView()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(go)
                Button("Close Browser", systemImage: "xmark") { model.showWeb = false }
                    .labelStyle(.iconOnly)
            }
            .padding(8)
            WebHost(web: web)
            HStack {
                Button("Back", systemImage: "chevron.left") { web.goBack() }.labelStyle(.iconOnly)
                Spacer()
                Button("Clip View") {
                    web.takeSnapshot(with: nil) { image, _ in
                        if let data = image?.pngData() { model.addImage(data) }
                    }
                }
                Button("Save as Pages") {
                    web.createPDF { result in
                        if case let .success(data) = result, let doc = PDFDocument(data: data) { model.insertPDF(doc) }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 400)
        .background(.bar)
    }

    private func go() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let url: URL?
        if text.contains("."), !text.contains(" ") {
            url = URL(string: text.lowercased().hasPrefix("http") ? text : "https://" + text)
        } else {
            var parts = URLComponents(string: "https://duckduckgo.com/")
            parts?.queryItems = [URLQueryItem(name: "q", value: text)]
            url = parts?.url
        }
        if let url { web.load(URLRequest(url: url)) }
    }
}

struct WebHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// The writing window: a magnified strip of the page along the bottom of the screen.
struct ZoomPanel: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                IconButton(icon: "arrow.left", label: "Move window left") { model.moveZoom(dx: -0.6, dy: 0) }
                IconButton(icon: "arrow.right", label: "Move window right") { model.moveZoom(dx: 0.6, dy: 0) }
                IconButton(icon: "arrow.up", label: "Move window up") { model.moveZoom(dx: 0, dy: -1) }
                IconButton(icon: "arrow.down", label: "Move window down") { model.moveZoom(dx: 0, dy: 1) }
                IconButton(icon: "return", label: "Next line") { model.zoomNextLine() }
                Spacer()
                Button("Close Zoom Window", systemImage: "xmark") { model.zoomOn = false }
                    .labelStyle(.iconOnly)
                    .padding(.trailing, 8)
            }
            .background(.bar)
            ZoomHost(model: model).frame(height: 200)
        }
    }
}

struct ZoomHost: UIViewRepresentable {
    let model: EditorModel

    final class Container: UIView {
        var model: EditorModel?
        override func layoutSubviews() {
            super.layoutSubviews()
            model?.zoomCanvas.frame = bounds
            model?.layoutZoom()
        }
    }

    func makeUIView(context: Context) -> Container {
        let view = Container()
        view.clipsToBounds = true
        view.backgroundColor = .white
        view.model = model
        view.addSubview(model.zoomCanvas)
        return view
    }

    func updateUIView(_ uiView: Container, context: Context) {}
}

struct ReminderSheet: View {
    let note: Note
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(3600)
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Remind me", selection: $date, in: Date()...)
                    .datePickerStyle(.graphical)
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle(note.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Set") { schedule() } }
            }
        }
    }

    private func schedule() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                problem = "Allow notifications for Margin in Settings to use reminders."
                return
            }
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = "Your reminder for this note."
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: note.id.uuidString, content: content, trigger: trigger))
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct NoteLinkSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.library.notes.filter { $0.deletedAt == nil && $0.id != model.note.id }.sorted { $0.title < $1.title }) { note in
                Button(note.title) {
                    model.addLink(title: note.title, target: "note:\(note.id.uuidString)")
                    dismiss()
                }
            }
            .navigationTitle("Link to a Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Every paper design, grouped, drawn live so the preview is exactly the page you'll get.
struct TemplateGallery: View {
    let color: PaperColor
    let onPick: (PaperStyle) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(PaperCategory.allCases) { category in
                        Text(category.rawValue).font(.title3.weight(.semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 18) {
                            ForEach(PaperStyle.allCases.filter { $0.category == category }) { style in
                                Button {
                                    onPick(style)
                                    dismiss()
                                } label: {
                                    PaperPreview(style: style, color: color, title: style.title)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Page Designs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct PaperPreview: View {
    let style: PaperStyle
    let color: PaperColor
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Image(uiImage: Renderer.paperThumbnail(style, color: color))
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .accessibilityHidden(true)
            Text(title).font(.caption).multilineTextAlignment(.center).lineLimit(2)
        }
    }
}

/// Asked every time a note is made: what it's called, where it lives and what it looks like.
struct NewNoteSheet: View {
    let library: Library
    let startingFolder: UUID?
    let onCreate: (Note, NoteSetup?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: UUID?
    @State private var style = Prefs.paperStyle
    @State private var color = Prefs.paperColor
    @State private var size = Prefs.pageSize
    @State private var setup: NoteSetup?
    @State private var choosingDesign = false
    @State private var addingFolder = false
    @State private var folderName = ""
    @State private var endless = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Note \(Date().formatted(date: .abbreviated, time: .omitted))", text: $name)
                }
                Section("Folder") {
                    Picker("Folder", selection: $folder) {
                        Text("Unfiled").tag(UUID?.none)
                        ForEach(library.subjects) { Text(library.path(of: $0)).tag(UUID?.some($0.id)) }
                    }
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        folderName = ""
                        addingFolder = true
                    }
                }
                Section("Start From") {
                    ForEach(NoteSetup.allCases) { option in
                        Button {
                            setup = setup == option ? nil : option
                            if setup != nil { style = option.paper }
                        } label: {
                            HStack {
                                Label(option.rawValue, systemImage: option.icon).foregroundStyle(.primary)
                                Spacer()
                                if setup == option { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        choosingDesign = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(uiImage: Renderer.paperThumbnail(style, color: color))
                                .resizable().scaledToFit().frame(height: 96)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(style.title).foregroundStyle(.primary)
                                Text("Browse \(PaperStyle.allCases.count) designs").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                    }
                    Picker("Paper Color", selection: $color) {
                        ForEach(PaperColor.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Page Size", selection: $size) {
                        ForEach(PageSize.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Endless Page", isOn: $endless)
                } header: {
                    Text("Notebook Design")
                } footer: {
                    if endless { Text("One long page that grows as you write, for brainstorms and sketches.") }
                }
                if !library.templates.isEmpty {
                    Section("My Templates") {
                        ForEach(library.templates) { template in
                            Button(template.title) {
                                if let note = library.duplicate(template.id, title: name.isEmpty ? template.title : name) {
                                    if folder != nil { library.move(note.id, to: folder) }
                                    dismiss()
                                    onCreate(library.notes.first { $0.id == note.id } ?? note, nil)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create() }.bold() }
            }
            .sheet(isPresented: $choosingDesign) {
                TemplateGallery(color: color) { style = $0 }
            }
            .alert("New Folder", isPresented: $addingFolder) {
                TextField("Name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    let trimmed = folderName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    library.addSubject(name: trimmed)
                    folder = library.subjects.last?.id
                }
            }
            .onAppear { folder = startingFolder }
        }
    }

    private func create() {
        let page = Page(height: size.height, style: style, color: color, endless: endless ? true : nil)
        let title = name.trimmingCharacters(in: .whitespaces)
        let note = library.createNote(subject: folder, title: title.isEmpty ? nil : title, page: page)
        dismiss()
        onCreate(note, setup)
    }
}

/// The system's font list, including any fonts the user has installed.
struct FontPicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let parent: FontPicker
        init(_ parent: FontPicker) { self.parent = parent }
        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            if let family = viewController.selectedFontDescriptor?.object(forKey: .family) as? String { parent.onPick(family) }
            parent.dismiss()
        }
        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) { parent.dismiss() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let controller = UIFontPickerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIFontPickerViewController, context: Context) {}
}

struct SignatureSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var saved: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let saved {
                    Image(uiImage: saved).resizable().scaledToFit().frame(maxHeight: 110).background(.white)
                        .accessibilityLabel("Your saved signature")
                    Button("Insert Saved Signature") {
                        model.insertSignature()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Or sign again below").font(.subheadline).foregroundStyle(.secondary)
                }
                SignatureCanvas(canvas: canvas)
                    .frame(height: 220)
                    .background(.white)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                HStack {
                    Button("Clear") { canvas.drawing = PKDrawing() }
                    Spacer()
                    Button("Save and Insert") {
                        model.saveSignature(canvas.drawing)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { saved = UIImage(contentsOfFile: model.library.signatureURL.path) }
        }
    }
}

struct SignatureCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.overrideUserInterfaceStyle = .light
        return canvas
    }
    func updateUIView(_ view: PKCanvasView, context: Context) {}
}
