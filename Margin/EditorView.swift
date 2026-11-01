import PhotosUI
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

private let swatches = ["1C1C1E", "8E8E93", "E5484D", "F76B15", "30A46C", "0091FF", "6E56CF", "D6409F"]
private let highlights = ["FFD60A", "FF9F0A", "FF6B6B", "5EE28A", "64D2FF", "BF9BFF"]
private let colorNames = [
    "1C1C1E": "Black", "8E8E93": "Gray", "E5484D": "Red", "F76B15": "Orange", "30A46C": "Green", "0091FF": "Blue", "6E56CF": "Purple", "D6409F": "Pink",
    "FFD60A": "Yellow", "FF9F0A": "Orange", "FF6B6B": "Red", "5EE28A": "Green", "64D2FF": "Blue", "BF9BFF": "Purple",
]

struct PenPreset: Codable, Hashable, Identifiable {
    var id: String { "\(style)-\(colorHex)-\(width)" }
    let style: String
    let colorHex: String
    let width: CGFloat
}

struct CanvasHost: UIViewRepresentable {
    let model: EditorModel

    final class Container: UIView {
        var model: EditorModel?
        override func layoutSubviews() {
            super.layoutSubviews()
            model?.canvas.frame = bounds
            model?.containerDidLayout(size: bounds.size)
        }
    }

    func makeUIView(context: Context) -> Container {
        let view = Container()
        view.backgroundColor = UIColor(white: 0.5, alpha: 0.18)
        view.clipsToBounds = true
        view.model = model
        view.addSubview(model.canvas)
        return view
    }

    func updateUIView(_ uiView: Container, context: Context) {}
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ScannerSheet: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void

    @MainActor final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        init(onScan: @escaping ([UIImage]) -> Void) { self.onScan = onScan }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).map(scan.imageOfPage))
            controller.dismiss(animated: true)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { controller.dismiss(animated: true) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { controller.dismiss(animated: true) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
}

/// A labelled switch in the options bar. Off it reads as plain text, so colour only ever means something is on.
struct OptionToggle: View {
    let title: String
    var icon: String?
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Group {
                if let icon {
                    Label(title, systemImage: icon)
                } else {
                    Text(title)
                }
            }
            .font(.subheadline.weight(isOn ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
            .background(isOn ? Color.accentColor.opacity(0.14) : .clear, in: Capsule())
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct IconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let icon: String
    var active = false
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .opacity(isEnabled ? 1 : 0.3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Its own view, so pinching only redraws this label rather than the whole editor on every frame.
private struct ZoomMenu: View {
    let model: EditorModel

    var body: some View {
        Menu {
            Button("Fit Page to Width") { model.setZoom(percent: 100) }
            ForEach((model.note.boardWidth == nil ? [] : [20, 25]) + [40, 50, 75, 125, 150, 200, 300, 400], id: \.self) { percent in
                Button("\(percent)%") { model.setZoom(percent: CGFloat(percent)) }
            }
        } label: {
            Text("\(model.zoomPercent)%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 46, minHeight: 42)
        }
        .accessibilityLabel("Zoom, \(model.zoomPercent) percent")
    }
}

/// The notes you have open, one tap apart. They stay open until you close them, even after leaving for the library.
private struct TabStrip: View {
    let model: EditorModel
    let onOpen: (UUID) -> Void
    let onLeave: () -> Void

    private var tabs: [Note] { model.library.tabs.compactMap { id in model.library.notes.first { $0.id == id && $0.deletedAt == nil } } }

    var body: some View {
        if tabs.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { note in
                        let current = note.id == model.note.id
                        HStack(spacing: 2) {
                            Button {
                                if !current { onOpen(note.id) }
                            } label: {
                                Text(note.title).font(.footnote.weight(current ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 170)
                                    .foregroundStyle(current ? .primary : .secondary)
                                    .padding(.leading, 12)
                                    .frame(minHeight: 32)
                            }
                            .buttonStyle(.plain)
                            Button("Close \(note.title)", systemImage: "xmark") { close(note) }
                                .labelStyle(.iconOnly)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .buttonStyle(.plain)
                                .frame(width: 28, height: 32)
                                .contentShape(Rectangle())
                        }
                        .background {
                            if current {
                                RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)).shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                            }
                        }
                        .accessibilityAddTraits(current ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .background(.bar)
        }
    }

    private func close(_ note: Note) {
        let others = tabs.filter { $0.id != note.id }
        model.library.closeTab(note.id)
        guard note.id == model.note.id else { return }
        if let next = others.last { onOpen(next.id) } else { onLeave() }
    }
}

private struct PageThumbnail: View {
    let model: EditorModel
    let page: Page
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.secondary.opacity(0.08)
            }
        }
        .frame(width: 60, height: 80)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.separator))
        .accessibilityHidden(true)
        .task(id: page) {
            try? await Task.sleep(for: .milliseconds(120)) // a quick scroll passes by without drawing anything
            guard !Task.isCancelled else { return }
            image = await model.thumbnailInBackground(page, width: 180)
        }
    }
}

struct EditorView: View {
    @Bindable var model: EditorModel
    let onClose: () -> Void
    let onOpen: (UUID) -> Void

    enum Panel: String, Identifiable {
        case pages, transcript, assistant, find, versions, excerpts, stickers, scan, noteLink, signature, fontPicker
        var id: String { rawValue }
    }

    enum FontTarget { case live, text, region }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("theme") private var theme = "system"
    @AppStorage("invertPages") private var invertPages = true
    @AppStorage("eraserReturns") private var eraserReturns = true
    @AppStorage("snapHighlights") private var snapHighlights = false
    @State private var fontTarget = FontTarget.live
    @State private var commentText = ""
    @Environment(\.openWindow) private var openWindow
    @State private var panel: Panel?
    @State private var showPhotos = false
    @State private var showPDFImporter = false
    @State private var showAudioImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var exportURL: URL?
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var askingGraph = false
    @State private var graphText = ""
    @State private var askingWebLink = false
    @State private var askingPage = false
    @State private var pageEntry = ""
    @State private var webLink = ""
    @State private var presets: [PenPreset] = (UserDefaults.standard.data(forKey: "penPresets")).flatMap { try? JSONDecoder().decode([PenPreset].self, from: $0) } ?? []

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if !model.focusMode {
                    TabStrip(model: model, onOpen: onOpen, onLeave: onClose)
                    topBar
                    if model.playing == nil, !model.readOnly { optionsBar }
                    Divider()
                }
                HStack(spacing: 0) {
                    CanvasHost(model: model)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .overlay(alignment: .bottom) {
                            if model.playing == nil, !model.zoomOn {
                                Button {
                                    pageEntry = ""
                                    askingPage = true
                                } label: {
                                    Text("\(model.currentPage) / \(model.note.pages.count)")
                                        .font(.subheadline.monospacedDigit().weight(.medium))
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 36)
                                        .background(.regularMaterial, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, 16)
                                .accessibilityLabel("Page \(model.currentPage) of \(model.note.pages.count). Go to page")
                            }
                        }
                    if model.showLivePanel { Divider(); LivePanel(model: model) }
                    if model.showWeb, !model.webFloating {
                        Divider()
                        WebPanel(model: model).frame(width: 400)
                    }
                }
                if model.zoomOn { ZoomPanel(model: model) }
                if model.playing != nil { playbackBar }
            }
            if model.showWeb, model.webFloating { FloatingWeb(model: model) }
            if model.focusMode {
                Button("Exit Focus Mode", systemImage: "arrow.down.right.and.arrow.up.left") { model.focusMode = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .padding(10)
            }
            if let busy = model.busy {
                ProgressView(busy)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $panel) { panel in
            switch panel {
            case .pages: PagesSheet(model: model)
            case .transcript: TranscriptSheet(model: model)
            case .assistant: AssistantSheet(model: model)
            case .find: FindSheet(model: model)
            case .versions: VersionsSheet(model: model)
            case .excerpts: ExcerptsSheet(model: model)
            case .stickers: StickerSheet(model: model)
            case .noteLink: NoteLinkSheet(model: model)
            case .signature: SignatureSheet(model: model)
            case .fontPicker:
                FontPicker { family in
                    switch fontTarget {
                    case .live: model.liveFont = family
                    case .text:
                        model.textFont = family
                        model.applyTextStyle()
                    case .region: Task { await model.convertRegionToFont(family) }
                    }
                }
            case .scan:
                ScannerSheet { images in
                    let doc = PDFDocument()
                    for image in images {
                        if let page = PDFPage(image: image) { doc.insert(page, at: doc.pageCount) }
                    }
                    model.insertPDF(doc)
                }
                .ignoresSafeArea()
            }
        }
        .sheet(item: $exportURL) { url in ActivitySheet(url: url) }
        .sheet(item: $model.aiAnswer) { _ in AnswerSheet(model: model) }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .images)
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: DocumentConverter.importable) { result in
            if case let .success(url) = result { model.importFile(from: url) }
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio]) { result in
            if case let .success(url) = result { model.importAudio(from: url) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for (i, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) { model.addImage(data, offset: CGFloat(i) * 28) }
                }
                photoItems = []
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveNow() }
        }
        .onDisappear { model.close() }
        .onAppear { model.darkPages = invertPages && colorScheme == .dark }
        .onChange(of: colorScheme) { _, scheme in model.darkPages = invertPages && scheme == .dark }
        .onChange(of: invertPages) { _, invert in model.darkPages = invert && colorScheme == .dark }
        .onChange(of: model.commentEditingID) { _, id in
            commentText = model.note.elements.first { $0.id == id }?.comment ?? ""
        }
        .alert("Comment", isPresented: Binding(get: { model.commentEditingID != nil }, set: { _ in })) {
            let saved = model.note.elements.first { $0.id == model.commentEditingID }?.comment ?? ""
            TextField("Your comment", text: $commentText, axis: .vertical)
            Button("Save") { model.finishComment(commentText) }
            if !saved.isEmpty { Button("Delete", role: .destructive) { model.finishComment("") } }
            Button("Cancel", role: .cancel) { model.finishComment(saved) }
        }
        .alert("Rename Note", isPresented: $renaming) {
            TextField("Title", text: $draftTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(draftTitle) }
        }
        .alert("Go to Page", isPresented: $askingPage) {
            TextField("1 to \(model.note.pages.count)", text: $pageEntry)
                .keyboardType(.numbersAndPunctuation)
            Button("Cancel", role: .cancel) {}
            Button("Go") {
                guard let number = Int(pageEntry.trimmingCharacters(in: .whitespaces)) else { return }
                model.jump(toPage: min(max(number, 1), model.note.pages.count) - 1)
            }
        }
        .alert("Web Link", isPresented: $askingWebLink) {
            TextField("Address", text: $webLink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Add") { if !webLink.isEmpty { model.addLink(title: webLink, target: webLink) } }
        }
        .alert("Plot a Graph", isPresented: $askingGraph) {
            TextField("Function of x, like x^2 - 3", text: $graphText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Plot") {
                if !model.insertGraph(graphText) { model.message = "Couldn't read “\(graphText)” as a function of x." }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.bottom, 76)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .alert("Margin", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.message ?? "")
        }
    }

    // MARK: Top bar

    private var tools: some View {
        HStack(spacing: 1) {
            ForEach(Tool.allCases) { tool in
                // Writing, selecting and marking up are separate kinds of tool.
                if tool == .text || tool == .annotate {
                    Rectangle().fill(.separator).frame(width: 1, height: 22).padding(.horizontal, 4).accessibilityHidden(true)
                }
                IconButton(icon: tool.icon, active: model.tool == tool, label: tool.title) { model.tool = tool }
            }
            Rectangle().fill(.separator).frame(width: 1, height: 22).padding(.horizontal, 4).accessibilityHidden(true)
            insertMenu
        }
    }

    private var topBar: some View {
        Group {
            if model.playing != nil || model.readOnly {
                HStack(spacing: 2) {
                    titleControls
                    Spacer(minLength: 4)
                    Text(model.readOnly ? "Read Only" : "Tap your notes to jump to that moment").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    noteControls
                }
            } else {
                // Upright, every tool can't share a row with the note's controls, and none of them should be hidden.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) {
                        titleControls
                        Spacer(minLength: 4)
                        tools
                        Spacer(minLength: 4)
                        noteControls
                    }
                    VStack(spacing: 2) {
                        HStack(spacing: 2) {
                            titleControls
                            Spacer(minLength: 4)
                            noteControls
                        }
                        tools
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .tint(.primary)
        .background(.bar)
    }

    private var titleControls: some View {
        HStack(spacing: 2) {
            IconButton(icon: "chevron.left", label: "Back to library", action: onClose)
            Button {
                draftTitle = model.note.title
                renaming = true
            } label: {
                Text(model.note.title).font(.system(.headline, design: .serif)).lineLimit(1).frame(minWidth: 40, maxWidth: 170, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Rename")
        }
    }

    private var noteControls: some View {
        HStack(spacing: 2) {
            ZoomMenu(model: model)
            IconButton(icon: "arrow.uturn.backward", label: "Undo") { model.undo() }
                .disabled(!model.canUndo || model.playing != nil || model.readOnly)
                .keyboardShortcut("z", modifiers: .command)
            IconButton(icon: "arrow.uturn.forward", label: "Redo") { model.redo() }
                .disabled(!model.canRedo || model.playing != nil || model.readOnly)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            recordControl
            IconButton(icon: "graduationcap", label: "Study") { panel = .assistant }
            IconButton(icon: "square.grid.2x2", label: "Pages") { panel = .pages }
            moreMenu
        }
    }

    private var insertMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo") { showPhotos = true }
            Button("Scan Document", systemImage: "doc.viewfinder") { panel = .scan }
                .disabled(!VNDocumentCameraViewController.isSupported)
            Button("PDF or Document", systemImage: "doc.badge.plus") { showPDFImporter = true }
            Divider()
            Button("Sticker", systemImage: "face.smiling") { panel = .stickers }
            Button("Sticky Note", systemImage: "note") { model.addStickyNote() }
            Button("Signature", systemImage: "signature") { panel = .signature }
            stampMenu
            Button("Graph", systemImage: "function") {
                graphText = ""
                askingGraph = true
            }
            Divider()
            Button("Audio File", systemImage: "waveform.badge.plus") { showAudioImporter = true }
            Divider()
            Button("Link to a Note", systemImage: "link") { panel = .noteLink }
            Button("Web Link", systemImage: "globe") {
                webLink = ""
                askingWebLink = true
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 42)
        }
        .accessibilityLabel("Insert")
    }

    private var stampMenu: some View {
        Menu("Stamp", systemImage: "seal") {
            Button("Approved") { model.addStamp("APPROVED", colorHex: "1E8E4E") }
            Button("Reviewed") { model.addStamp("REVIEWED", colorHex: "0A66D8") }
            Button("Important") { model.addStamp("IMPORTANT", colorHex: "E5484D") }
            Button("Draft") { model.addStamp("DRAFT", colorHex: "8E8E93") }
            Button("Final") { model.addStamp("FINAL", colorHex: "1E8E4E") }
            Button("Confidential") { model.addStamp("CONFIDENTIAL", colorHex: "E5484D") }
            Button("Rejected") { model.addStamp("REJECTED", colorHex: "E5484D") }
            Button("Dated Today") { model.addStamp(Date().formatted(date: .abbreviated, time: .omitted).uppercased(), colorHex: "0A66D8") }
        }
    }

    private func fontMenu(_ title: String, target: FontTarget, pick: @escaping (String) -> Void) -> some View {
        Menu(title) {
            ForEach(TextFonts.quick, id: \.1) { name, key in
                Button(name) { pick(key) }
            }
            Divider()
            Button("All Fonts…") {
                fontTarget = target
                panel = .fontPicker
            }
        }
    }

    private var recordControl: some View {
        Group {
            if model.isRecording {
                HStack(spacing: 4) {
                    Button { model.toggleRecording() } label: {
                        Label(timeString(model.recordingElapsed), systemImage: "stop.fill")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(Color.red, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop recording")
                    IconButton(icon: "flag", label: "Flag this moment") { model.flagMoment() }
                    IconButton(icon: "text.bubble", active: model.showLivePanel, label: "Live transcript and Smart Notes") { model.showLivePanel.toggle() }
                }
            } else if model.note.recordings.isEmpty {
                IconButton(icon: "mic", label: "Record audio") { model.toggleRecording() }
            } else {
                Menu {
                    Button("New Recording", systemImage: "mic") { model.toggleRecording() }
                    Section("Recordings") {
                        ForEach(model.note.recordings) { rec in
                            Menu(rec.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + timeString(rec.duration)) {
                                Button("Play with Notes", systemImage: "play") { model.startPlayback(rec) }
                                ShareLink("Share Audio", item: model.audioURL(rec))
                                Button("Delete Recording", systemImage: "trash", role: .destructive) { model.deleteRecording(rec) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 40, height: 42)
                }
                .accessibilityLabel("Recordings")
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Export PDF", systemImage: "square.and.arrow.up") { Task { exportURL = await model.exportPDF() } }
            Button("Export Text", systemImage: "doc.plaintext") { Task { exportURL = await model.exportText() } }
            Button("Find in Note", systemImage: "magnifyingglass") { panel = .find }
            Button("Excerpts", systemImage: "scissors") { panel = .excerpts }
            Button("Version History", systemImage: "clock.arrow.circlepath") {
                model.saveNow()
                panel = .versions
            }
            if model.note.boardWidth == nil {
                Button("Add Page", systemImage: "plus.rectangle.portrait") { model.addPage() }
            }
            Divider()
            Toggle("Zoom Writing Window", systemImage: "rectangle.and.pencil.and.ellipsis", isOn: $model.zoomOn)
            Toggle("Web Browser", systemImage: "globe", isOn: $model.showWeb)
            Button("Read Aloud", systemImage: "speaker.wave.2") { model.toggleReadAloud() }
            Button("Focus Mode", systemImage: "arrow.up.left.and.arrow.down.right") { model.focusMode = true }
            Toggle("Read Only", systemImage: "book", isOn: $model.readOnly)
            Picker("Theme", systemImage: "circle.lefthalf.filled", selection: $theme) {
                Text("Match iPad").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.menu)
            Toggle("Invert Pages in Dark Theme", systemImage: "moon", isOn: $invertPages)
            Button("Open Another Note Beside This", systemImage: "rectangle.split.2x1") { openWindow(id: "library") }
            Toggle("Draw with Finger", systemImage: "hand.draw", isOn: $model.fingerDrawing)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 42)
        }
        .accessibilityLabel("More")
    }

    // MARK: Options bar

    @ViewBuilder private var optionsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                switch model.tool {
                case .pen: penOptions
                case .highlighter:
                    Picker("Mark", selection: $model.highlightMark) {
                        ForEach(HighlightMark.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    widthPicker([12, 20, 32], selection: $model.highlightWidth)
                    colorRow(highlights, selection: $model.highlightColor)
                    if model.highlightMark == .highlight {
                        OptionToggle(title: "Snap to Text", icon: "text.alignleft", isOn: $snapHighlights)
                    }
                case .eraser:
                    Picker("Eraser", selection: $model.eraseWholeStroke) {
                        Text("Partial").tag(false)
                        Text("Whole Stroke").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    Toggle("Switch Back After Erasing", isOn: $eraserReturns).fixedSize()
                case .lasso:
                    hint("Circle ink to move it. Tap the selection to copy or delete.")
                case .text:
                    Stepper("Size \(Int(model.textSize))", value: $model.textSize, in: 10...72, step: 2)
                        .fixedSize()
                        .onChange(of: model.textSize) { model.applyTextStyle() }
                    fontMenu(TextFonts.title(model.textFont), target: .text) { family in
                        model.textFont = family
                        model.applyTextStyle()
                    }
                    OptionToggle(title: "Bold", isOn: $model.textBold)
                        .onChange(of: model.textBold) { model.applyTextStyle() }
                    OptionToggle(title: "Italic", isOn: $model.textItalic)
                        .onChange(of: model.textItalic) { model.applyTextStyle() }
                    OptionToggle(title: "Underline", isOn: $model.textUnderline)
                        .onChange(of: model.textUnderline) { model.applyTextStyle() }
                    HStack(spacing: 0) {
                        IconButton(icon: "text.alignleft", active: model.textAlign == nil, label: "Align Left") { model.textAlign = nil }
                        IconButton(icon: "text.aligncenter", active: model.textAlign == "center", label: "Align Center") { model.textAlign = "center" }
                        IconButton(icon: "text.alignright", active: model.textAlign == "right", label: "Align Right") { model.textAlign = "right" }
                    }
                    .onChange(of: model.textAlign) { model.applyTextStyle() }
                    colorRow(swatches, selection: $model.textColor)
                        .onChange(of: model.textColor) { model.applyTextStyle() }
                    if let selected = model.selectedElement {
                        if selected.link != nil {
                            Button("Open Link", systemImage: "arrow.up.right") { model.openLink(selected) }
                        }
                        if selected.imageFile != nil {
                            Button("Cut Out Subject", systemImage: "person.crop.rectangle") { Task { await model.cutOutSubject(selected.id) } }
                            Button("Save as Sticker", systemImage: "seal") { model.saveAsSticker(selected.id) }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSelected() }
                    } else {
                        hint("Tap anywhere to type. Drag a box or image to move it.")
                    }
                case .region: regionOptions
                case .annotate: annotateOptions
                case .tape:
                    if model.hasTape {
                        Button("Reveal All") { model.setAllTape(revealed: true) }
                        Button("Cover All") { model.setAllTape(revealed: false) }
                        Button("Remove All", role: .destructive) { model.removeAllTape() }
                    }
                    hint("Drag over anything to cover it. Tap to reveal, hold to remove.")
                case .laser:
                    hint("Point at your page. The trail fades on its own and isn't saved.")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 36)
            .tint(.primary)
        }
        // Fading the edge shows there's more to scroll to.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.95), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .frame(height: 44)
        .background(.bar)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
    }

    @ViewBuilder private var penOptions: some View {
        Picker("Pen", selection: $model.penStyle) {
            ForEach(PenStyle.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        widthPicker([1.5, 3, 6], selection: $model.penWidth)
        colorRow(swatches, selection: $model.penColor)
        OptionToggle(title: "Live Text", icon: "character.cursor.ibeam", isOn: $model.liveText)
        if model.liveText {
            IconButton(icon: "keyboard", label: "Type with Keyboard") { model.typeWithKeyboard() }
            fontMenu(TextFonts.title(model.liveFont), target: .live) { model.liveFont = $0 }
            Menu(model.liveSize == 0 ? "Auto Size" : "\(Int(model.liveSize)) pt") {
                Button("Auto") { model.liveSize = 0 }
                ForEach([12, 14, 16, 18, 20, 24, 28, 32, 40, 48], id: \.self) { size in
                    Button("\(size) pt") { model.liveSize = Double(size) }
                }
            }
        }
        OptionToggle(title: "Shapes", icon: "scribble.variable", isOn: $model.snapShapes)
        OptionToggle(title: "Ruler", icon: "ruler", isOn: $model.rulerOn)
        Divider().frame(height: 24)
        ForEach(presets) { preset in
            Button {
                if let style = PenStyle(rawValue: preset.style) { model.penStyle = style }
                model.penColor = UIColor(hex: preset.colorHex)
                model.penWidth = preset.width
            } label: {
                Image(systemName: "pencil.tip")
                    .foregroundStyle(Color(uiColor: UIColor(hex: preset.colorHex)))
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Saved pen \(preset.style)")
            .contextMenu {
                Button("Remove Saved Pen", systemImage: "trash", role: .destructive) { savePresets(presets.filter { $0 != preset }) }
            }
        }
        Button("Save Pen", systemImage: "plus") {
            let preset = PenPreset(style: model.penStyle.rawValue, colorHex: model.penColor.hex, width: model.penWidth)
            if !presets.contains(preset) { savePresets(presets + [preset]) }
        }
        .labelStyle(.iconOnly)
    }

    private func savePresets(_ new: [PenPreset]) {
        presets = new
        UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: "penPresets")
    }

    @ViewBuilder private var annotateOptions: some View {
        ForEach(AnnotateKind.allCases) { kind in
            IconButton(icon: kind.icon, active: model.annotateKind == kind, label: kind.rawValue) { model.annotateKind = kind }
        }
        colorRow(swatches, selection: $model.annotateColor)
        stampMenu
        Button("Signature", systemImage: "signature") { panel = .signature }
        Text(model.annotateKind == .redact ? "Exports as a flat image, so hidden text can't be recovered." : model.annotateKind == .comment ? "Tap to pin a comment. Hold to remove it." : "Drag on the page.")
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
    }

    @ViewBuilder private var regionOptions: some View {
        if model.regionRect == nil {
            hint("Drag over handwriting, math or a PDF to select an area.")
        } else {
            fontMenu("To Font", target: .region) { font in Task { await model.convertRegionToFont(font) } }
            Button("To Math", systemImage: "x.squareroot") { Task { await model.convertRegionToMath() } }
            Button("Solve", systemImage: "equal") { Task { await model.solveRegion() } }
            Button("Graph", systemImage: "function") {
                Task {
                    graphText = await model.regionExpression()
                    askingGraph = true
                }
            }
            Button("Copy Text", systemImage: "doc.on.doc") { Task { await model.copyRegionText() } }
            if AI.isAvailable {
                Menu("Ask AI", systemImage: "sparkles") {
                    ForEach(AskMode.allCases) { mode in
                        Button(mode.rawValue, systemImage: mode.icon) { model.askAI(mode) }
                    }
                }
                Menu("Translate", systemImage: "character.bubble") {
                    ForEach(["English", "Hindi", "Spanish", "French", "German", "Chinese", "Japanese", "Arabic"], id: \.self) { language in
                        Button(language) { Task { await model.translateRegion(to: language) } }
                    }
                }
            }
            Button("Flashcard", systemImage: "rectangle.on.rectangle") { model.regionToFlashcard(back: "") }
            Button("Excerpt", systemImage: "scissors") { model.regionToExcerpt() }
            Button("Cancel", role: .cancel) { model.regionRect = nil }
        }
    }

    private func widthPicker(_ widths: [CGFloat], selection: Binding<CGFloat>) -> some View {
        HStack(spacing: 2) {
            ForEach(widths, id: \.self) { width in
                Button { selection.wrappedValue = width } label: {
                    Circle().fill(Color.primary)
                        .frame(width: 4 + CGFloat(widths.firstIndex(of: width) ?? 0) * 5, height: 4 + CGFloat(widths.firstIndex(of: width) ?? 0) * 5)
                        .frame(width: 34, height: 34)
                        .background(selection.wrappedValue == width ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(["Thin", "Medium", "Thick"][widths.firstIndex(of: width) ?? 0])
                .accessibilityAddTraits(selection.wrappedValue == width ? .isSelected : [])
            }
        }
    }

    private func colorRow(_ hexes: [String], selection: Binding<UIColor>) -> some View {
        HStack(spacing: 4) {
            ForEach(hexes, id: \.self) { hex in
                Button { selection.wrappedValue = UIColor(hex: hex) } label: {
                    Circle().fill(Color(uiColor: UIColor(hex: hex)))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
                        .overlay(Circle().stroke(Color.primary, lineWidth: selection.wrappedValue.hex == hex ? 2 : 0).padding(-3))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(colorNames[hex] ?? "Color")
                .accessibilityAddTraits(selection.wrappedValue.hex == hex ? .isSelected : [])
            }
            ColorPicker("Custom color", selection: Binding(
                get: { Color(uiColor: selection.wrappedValue) },
                set: { selection.wrappedValue = UIColor($0) }
            ))
            .labelsHidden()
        }
    }

    // MARK: Playback bar

    private var playbackBar: some View {
        HStack(spacing: 12) {
            IconButton(icon: model.isPaused ? "play.fill" : "pause.fill", label: model.isPaused ? "Play" : "Pause") { model.togglePause() }
            Text(timeString(model.playTime)).font(.subheadline.monospacedDigit())
            Slider(value: Binding(get: { model.playTime }, set: { model.seek(to: $0) }), in: 0...max(model.playing?.duration ?? 1, 0.1))
            Text(timeString(model.playing?.duration ?? 0)).font(.subheadline.monospacedDigit())
            Menu(model.playRate.formatted() + "×") {
                ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
                    Button(rate.formatted() + "×") { model.playRate = rate }
                }
            }
            .accessibilityLabel("Playback speed")
            IconButton(icon: "text.quote", label: "Transcript") { panel = .transcript }
            Button("Done") { model.stopPlayback() }.bold()
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(.bar)
    }
}

enum TextFonts {
    static let quick: [(String, String)] = [
        ("Sans", "sans"), ("Serif", "serif"), ("Mono", "mono"), ("Rounded", "rounded"),
        ("Noteworthy", "Noteworthy"), ("Bradley Hand", "Bradley Hand"), ("Marker Felt", "Marker Felt"),
        ("Chalkboard", "Chalkboard SE"), ("Snell Roundhand", "Snell Roundhand"),
        ("Georgia", "Georgia"), ("Times", "Times New Roman"), ("Avenir", "Avenir Next"), ("Futura", "Futura"), ("Courier", "Courier New"),
    ]
    static func title(_ key: String) -> String { quick.first { $0.1 == key }?.0 ?? key }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

struct TextResult: Identifiable {
    let text: String
    var id: String { text }
}

struct TextResultSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "No text found." : text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }.disabled(text.isEmpty)
                }
            }
        }
    }
}

struct LivePanel: View {
    @Bindable var model: EditorModel
    @AppStorage(SpeechLanguage.key) private var speechLanguage = "en"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Smart Notes", isOn: $model.smartNotesOn)
                .font(.headline)
                .disabled(!AI.isAvailable)
                .onChange(of: model.smartNotesOn) { _, on in
                    if on { Task { await model.refreshSmartNotes() } }
                }
                .padding(12)
            if !AI.isAvailable {
                Text("Download the writing model in Settings to turn this on.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            if model.smartNotesOn || !model.smartNotes.isEmpty {
                ScrollView {
                    Text(model.smartNotes.isEmpty ? "Your notes will build here as the talk goes on." : model.smartNotes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: .infinity)
                HStack {
                    if model.smartNotesBusy { ProgressView() }
                    Spacer()
                    Button("Insert into Note") {
                        model.insertText(model.smartNotes)
                    }
                    .disabled(model.smartNotes.isEmpty)
                }
                .padding(.horizontal, 12)
                Divider().padding(.top, 8)
            }
            HStack {
                Text("Live Transcript").font(.headline)
                Spacer()
                Picker("Language", selection: $speechLanguage) {
                    ForEach(SpeechLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.menu)
            }
            .padding(12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !LocalWhisper.isAvailable {
                            Text("Download the transcription model in Settings to see words appear as they're spoken.").foregroundStyle(.secondary)
                        } else if model.liveLines.isEmpty {
                            Text("Listening…").foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.liveLines.enumerated()), id: \.offset) { i, line in
                            Text(line.text).font(.callout).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                }
                .onChange(of: model.liveLines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 320)
        .background(.bar)
    }
}

struct TranscriptSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var result: TextResult?
    @State private var resultTitle = ""
    @State private var working: String?
    @State private var problem: String?

    /// A long talk is more than the model can take at once, so it goes through a piece at a time.
    private func rewrite(_ text: String, title: String, doing: String, _ piece: @escaping (String) async throws -> String) {
        working = doing
        resultTitle = title
        Task {
            defer { working = nil }
            do {
                var parts: [String] = []
                for chunk in TextTools.chunks(text, size: 6000) { parts.append(try await piece(chunk)) }
                result = TextResult(text: parts.joined(separator: "\n\n"))
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let rec = model.playing, let lines = rec.transcript, !lines.isEmpty {
                    List {
                        if let flags = rec.flags, !flags.isEmpty {
                            Section("Flagged Moments") {
                                ForEach(flags, id: \.self) { flag in
                                    Button("Jump to \(timeString(flag))", systemImage: "flag.fill") { model.seek(to: flag) }
                                }
                            }
                        }
                        Section("Transcript") {
                            ForEach(lines, id: \.self) { line in
                                Button {
                                    model.seek(to: line.time)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(timeString(line.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Text(line.text).foregroundStyle(.primary)
                                    }
                                }
                            }
                        }
                    }
                } else if model.transcribing != nil {
                    ProgressView("Transcribing…", value: model.transcribeProgress)
                        .padding(40)
                } else if let rec = model.playing {
                    ContentUnavailableView {
                        Label("No Transcript Yet", systemImage: "text.quote")
                    } actions: {
                        Button("Transcribe Recording") { model.transcribe(rec) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if AI.isAvailable, let lines = model.playing?.transcript, !lines.isEmpty {
                        let spoken = lines.map(\.text).joined(separator: " ")
                        Menu("Improve", systemImage: "sparkles") {
                            Button("Clean Up", systemImage: "wand.and.stars") {
                                rewrite(spoken, title: "Cleaned Up", doing: "Cleaning up…") { try await AI.cleanTranscript($0) }
                            }
                            Menu("Translate", systemImage: "character.bubble") {
                                ForEach(["English", "Hindi", "Spanish", "French", "German", "Chinese", "Japanese", "Arabic"], id: \.self) { language in
                                    Button(language) {
                                        rewrite(spoken, title: "Translation", doing: "Translating…") { try await AI.translate($0, to: language) }
                                    }
                                }
                            }
                        }
                        .disabled(working != nil)
                    }
                }
            }
            .overlay {
                if let working {
                    ProgressView(working).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(item: $result) { TextResultSheet(title: resultTitle, text: $0.text) }
            .alert("Margin", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
        }
    }
}

struct PagesSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var recognized: String?
    @State private var working = false
    @State private var bookmarksOnly = false
    @State private var photoTarget: Page?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var outline: [EditorModel.OutlineItem] = []
    @State private var shareURL: URL?
    @State private var designTarget: Page?

    var body: some View {
        NavigationStack {
            List {
                if !outline.isEmpty {
                    Section("Contents") {
                        ForEach(outline) { item in
                            Button {
                                model.jump(toPage: item.pageIndex)
                                dismiss()
                            } label: {
                                Text(item.title).padding(.leading, CGFloat(item.depth) * 16)
                            }
                        }
                    }
                }
                Section {
                    Toggle("Bookmarked Pages Only", isOn: $bookmarksOnly)
                }
                Section("Pages") {
                    // Filtered first: an `if` inside the ForEach makes List build every row at once, thumbnails included.
                    ForEach(Array(model.note.pages.enumerated()).filter { !bookmarksOnly || $0.element.bookmarked }, id: \.element.id) { i, page in
                        row(page, index: i)
                    }
                    .onMove { from, to in
                        var pages = model.note.pages
                        pages.move(fromOffsets: from, toOffset: to)
                        model.setPages(pages)
                    }
                    .onDelete { offsets in
                        var pages = model.note.pages
                        pages.remove(atOffsets: offsets)
                        model.setPages(pages)
                    }
                    .moveDisabled(bookmarksOnly)
                    .deleteDisabled(model.note.pages.count == 1 || bookmarksOnly)
                }
                Section {
                    Button("Add Page", systemImage: "plus") { model.addPage() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { recognized.map(TextResult.init) }, set: { recognized = $0?.text })) { result in
                TextResultSheet(title: "Recognized Text", text: result.text)
            }
            .sheet(item: $shareURL) { url in ActivitySheet(url: url) }
            .sheet(item: $designTarget) { target in
                TemplateGallery(color: target.color) { style in
                    guard let i = model.note.pages.firstIndex(of: target) else { return }
                    change(i) {
                        $0.style = style
                        $0.backgroundFile = nil
                    }
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item, let target = photoTarget else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { model.setBackgroundImage(data, for: target) }
                    photoItem = nil
                }
            }
            .overlay { if working { ProgressView().controlSize(.large) } }
            .task { outline = await model.pdfOutline() }
        }
    }

    private func row(_ page: Page, index i: Int) -> some View {
        HStack(spacing: 14) {
            PageThumbnail(model: model, page: page)
            VStack(alignment: .leading) {
                Text("Page \(i + 1)").font(.headline)
                Text(page.pdfPage == nil ? (page.backgroundFile == nil ? "\(page.style.title), \(page.color.title)" : "Custom paper") : "PDF")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                change(i) { $0.bookmarked.toggle() }
            } label: {
                Image(systemName: page.bookmarked ? "bookmark.fill" : "bookmark").frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(page.bookmarked ? "Remove bookmark" : "Bookmark page \(i + 1)")
            pageMenu(page, index: i)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.jump(toPage: i)
            dismiss()
        }
    }

    private func pageMenu(_ page: Page, index: Int) -> some View {
        Menu {
            Button("Share Page as PDF", systemImage: "doc") { shareURL = model.exportPage(index) }
            Button("Share Page as Image", systemImage: "photo") { shareURL = model.exportPageImage(page) }
            if page.pdfPage == nil {
                Button("Choose Page Design", systemImage: "square.grid.2x2") { designTarget = page }
                Picker("Color", selection: Binding(get: { page.color }, set: { color in change(index) { $0.color = color } })) {
                    ForEach(PaperColor.allCases) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: Binding(
                    get: { PageSize.allCases.first { $0.height == page.height } ?? .letter },
                    set: { size in change(index) { $0.height = size.height } }
                )) {
                    ForEach(PageSize.allCases) { Text($0.title).tag($0) }
                }
                Button("Use a Photo as Paper", systemImage: "photo") {
                    photoTarget = page
                    showPhotos = true
                }
                Button("Apply Paper to All Pages", systemImage: "square.on.square") {
                    model.setPages(model.note.pages.map { p in
                        var p = p
                        if p.pdfPage == nil {
                            p.style = page.style
                            p.color = page.color
                            p.backgroundFile = page.backgroundFile
                        }
                        return p
                    })
                }
            }
            Button("Duplicate Page", systemImage: "plus.square.on.square") { model.duplicatePage(index) }
            Button("Insert Blank Page After", systemImage: "plus.rectangle.portrait") { model.insertBlankPage(after: index) }
            Button("Convert Handwriting to Type", systemImage: "character.cursor.ibeam") {
                Task {
                    dismiss()
                    await model.convertPageToFont(index, font: model.liveFont)
                }
            }
            Button("Recognize Handwriting", systemImage: "text.viewfinder") {
                working = true
                Task {
                    recognized = await model.recognizePage(page)
                    working = false
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 40, height: 40)
        }
        .accessibilityLabel("Options for page \(index + 1)")
    }

    private func change(_ index: Int, _ edit: (inout Page) -> Void) {
        var pages = model.note.pages
        edit(&pages[index])
        model.setPages(pages)
    }
}
