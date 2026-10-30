import AVFoundation
import Observation
import PDFKit
import PencilKit
import UIKit

enum Tool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso, text, region, annotate, tape, laser
    var id: String { rawValue }
    var title: String {
        switch self {
        case .region: "Select Area"
        case .annotate: "Annotate"
        case .tape: "Study Tape"
        case .laser: "Laser Pointer"
        default: rawValue.capitalized
        }
    }
    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .text: "textformat"
        case .region: "viewfinder"
        case .annotate: "pencil.and.scribble"
        case .tape: "rectangle.fill"
        case .laser: "cursorarrow.rays"
        }
    }
}

enum HighlightMark: String, CaseIterable, Identifiable {
    case highlight = "Highlight", underline = "Underline", strikeout = "Strikeout", squiggle = "Squiggle"
    var id: String { rawValue }
}

enum AnnotateKind: String, CaseIterable, Identifiable {
    case arrow = "Arrow", line = "Line", box = "Box", oval = "Oval", area = "Area Highlight", comment = "Comment", whiteout = "Whiteout", redact = "Redact"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .box: "rectangle"
        case .oval: "oval"
        case .area: "rectangle.fill.on.rectangle.fill"
        case .comment: "text.bubble"
        case .whiteout: "rectangle.dashed"
        case .redact: "eye.slash"
        }
    }
}

enum PenStyle: String, CaseIterable, Identifiable {
    case ballpoint, fountain, pencil, monoline, crayon, watercolor
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var ink: PKInkingTool.InkType {
        switch self {
        case .ballpoint: .pen
        case .fountain: .fountainPen
        case .pencil: .pencil
        case .monoline: .monoline
        case .crayon: .crayon
        case .watercolor: .watercolor
        }
    }
}

/// CATiledLayer stays sharp at any zoom and only paints what is on screen. `painter` runs on background threads.
final class TiledView: UIView {
    final class FastLayer: CATiledLayer {
        override class func fadeDuration() -> CFTimeInterval { 0 }
    }
    override class var layerClass: AnyClass { FastLayer.self }
    var painter: ((CGContext) -> Void)?
    var contentKey: AnyHashable?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 4
        tiled.tileSize = CGSize(width: 512, height: 512)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        painter?(ctx)
    }
}

@MainActor @Observable
final class EditorModel: NSObject, Identifiable, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    @ObservationIgnored let library: Library
    @ObservationIgnored let canvas = PKCanvasView()
    @ObservationIgnored let overlay = OverlayView()
    @ObservationIgnored private let underlay = UIView()
    @ObservationIgnored var pageViews: [UUID: TiledView] = [:]
    @ObservationIgnored private var elementViews: [UUID: UIView] = [:]
    @ObservationIgnored var pdf: CGPDFDocument?
    @ObservationIgnored private var lastWidth: CGFloat = 0
    @ObservationIgnored var lastStrokeCount = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savedNote: Note
    @ObservationIgnored private var savedDrawing: PKDrawing
    @ObservationIgnored private let openedNote: Note
    @ObservationIgnored private let openedDrawing: PKDrawing
    @ObservationIgnored var inkChanged = false

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    var note: Note
    var message: String?

    var tool: Tool = .pen {
        didSet {
            guard tool != oldValue else { return }
            if tool == .eraser, oldValue == .pen || oldValue == .highlighter { toolBeforeEraser = oldValue }
            applyTool()
        }
    }
    @ObservationIgnored var toolBeforeEraser = Tool.pen
    var highlightMark = HighlightMark.highlight
    var annotateKind = AnnotateKind.arrow
    var annotateColor = UIColor(hex: "E5484D")
    var commentEditingID: UUID?
    var liveText = UserDefaults.standard.bool(forKey: "liveText") {
        didSet {
            UserDefaults.standard.set(liveText, forKey: "liveText")
            liveSince = Date()
            liveTailID = nil
            applyTool()
        }
    }
    var liveFont = UserDefaults.standard.string(forKey: "liveFont") ?? "sans" {
        didSet { UserDefaults.standard.set(liveFont, forKey: "liveFont") }
    }
    var liveSize = UserDefaults.standard.double(forKey: "liveSize") { // 0 matches the handwriting
        didSet { UserDefaults.standard.set(liveSize, forKey: "liveSize") }
    }
    @ObservationIgnored let liveScribble = LiveScribble()

    /// Pencil writing goes to Scribble. Finger writing can't, so it stays ink and is read from the page.
    var scribbleActive: Bool { liveText && tool == .pen && !fingerDrawing && playing == nil }
    @ObservationIgnored var liveSince = Date()
    @ObservationIgnored var liveTask: Task<Void, Never>?
    @ObservationIgnored var liveTailID: UUID?
    @ObservationIgnored var penDown = false
    var zoomPercent = 100
    var currentPage = 1
    var darkPages = false {
        didSet {
            guard darkPages != oldValue else { return }
            let style: UIUserInterfaceStyle = darkPages ? .dark : .light
            canvas.overrideUserInterfaceStyle = style
            zoomCanvas.overrideUserInterfaceStyle = style
            rebuildPages()
            syncElements()
            layoutZoom()
        }
    }
    var penStyle = PenStyle(rawValue: UserDefaults.standard.string(forKey: "penStyle") ?? "") ?? .ballpoint { didSet { applyTool() } }
    var penColor = UIColor(hex: UserDefaults.standard.string(forKey: "penColor") ?? "1C1C1E") { didSet { applyTool() } }
    var penWidth = UserDefaults.standard.object(forKey: "penWidth") as? CGFloat ?? 3 { didSet { applyTool() } }
    var highlightColor = UIColor(hex: UserDefaults.standard.string(forKey: "highlightColor") ?? "FFD60A") { didSet { applyTool() } }
    var highlightWidth = UserDefaults.standard.object(forKey: "highlightWidth") as? CGFloat ?? 20 { didSet { applyTool() } }
    var eraseWholeStroke = false { didSet { applyTool() } }
    var snapShapes = false
    var rulerOn = false { didSet { canvas.isRulerActive = rulerOn } }
    var focusMode = false
    var regionRect: CGRect? { didSet { overlay.refreshRegion() } }
    var busy: String?
    var fingerDrawing = !UIPencilInteraction.prefersPencilOnlyDrawing {
        didSet {
            applyDrawingPolicy()
            applyTool()
        }
    }

    var textColor = UIColor(hex: "1C1C1E")
    var textSize: CGFloat = 20
    var textFont = "sans"
    var textBold = false
    var showWeb = false
    var openNoteRequest: UUID?
    var zoomOn = false { didSet { zoomDidToggle() } }
    @ObservationIgnored let zoomCanvas = PKCanvasView()
    @ObservationIgnored var zoomRect = CGRect(x: 40, y: 72, width: 300, height: 90)
    @ObservationIgnored let zoomBackground = UIImageView()
    @ObservationIgnored let reader = AVSpeechSynthesizer()
    var selectedElementID: UUID? { didSet { overlay.refreshSelection() } }
    @ObservationIgnored var editingElementID: UUID?

    var isRecording = false
    var recordingElapsed: TimeInterval = 0
    var liveLines: [TranscriptLine] = []
    var smartNotes = ""
    var smartNotesOn = false
    var smartNotesBusy = false
    var showLivePanel = false
    @ObservationIgnored private var recorder: LiveRecorder?
    @ObservationIgnored private var recordingFile = ""
    @ObservationIgnored private var recordingStart = Date()
    @ObservationIgnored private var recordingTimer: Timer?
    @ObservationIgnored private var smartTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    var pendingFlags: [TimeInterval] = []

    var playing: Recording?
    var isPaused = false
    var playTime: TimeInterval = 0
    var playRate: Float = 1 { didSet { player?.rate = playRate } }
    var transcribing: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playTimer: Timer?
    @ObservationIgnored private var realDrawing = PKDrawing()
    @ObservationIgnored private var strokeDates: [Date] = []
    @ObservationIgnored private var revealedCount = -1
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var finishingRecorder = false
    var transcribeProgress = 0.0

    init(note: Note, library: Library) {
        self.note = note
        self.library = library
        let drawing = library.loadDrawing(note.id)
        savedNote = note
        openedNote = note
        savedDrawing = drawing
        openedDrawing = drawing
        super.init()
        pdf = CGPDFDocument(library.pdfURL(note.id) as CFURL)

        canvas.drawing = drawing
        lastStrokeCount = canvas.drawing.strokes.count
        canvas.delegate = self
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.overrideUserInterfaceStyle = .light // keep ink the colour the user picked
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsHorizontalScrollIndicator = false
        canvas.bouncesZoom = false
        canvas.addInteraction({ let i = UIPencilInteraction(); i.delegate = self; return i }())

        for layerView in [underlay, overlay] as [UIView] {
            layerView.layer.anchorPoint = .zero
            layerView.layer.position = .zero
        }
        canvas.insertSubview(underlay, at: 0)
        canvas.addSubview(overlay)
        overlay.model = self
        canvas.panGestureRecognizer.require(toFail: overlay.pan)
        liveScribble.model = self
        overlay.addInteraction(UIIndirectScribbleInteraction(delegate: liveScribble))
        configureZoomCanvas()
        let fingerTap = UITapGestureRecognizer(target: self, action: #selector(fingerTapped))
        fingerTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        canvas.addGestureRecognizer(fingerTap)
        // Two-finger tap undoes, three-finger tap redoes.
        let twoFinger = UITapGestureRecognizer(target: self, action: #selector(tapUndo))
        twoFinger.numberOfTouchesRequired = 2
        let threeFinger = UITapGestureRecognizer(target: self, action: #selector(tapRedo))
        threeFinger.numberOfTouchesRequired = 3
        canvas.addGestureRecognizer(twoFinger)
        canvas.addGestureRecognizer(threeFinger)

        rebuildPages()
        syncElements()
        applyTool()
        applyDrawingPolicy()
    }

    // MARK: Canvas layout

    func containerDidLayout(size: CGSize) {
        guard size.width > 0, size.width != lastWidth else { return }
        let top = canvas.contentOffset.y / max(canvas.zoomScale, 0.01)
        let factor = lastWidth > 0 ? canvas.zoomScale / (lastWidth / NoteLayout.width) : 1
        lastWidth = size.width
        let fit = size.width / NoteLayout.width
        canvas.minimumZoomScale = fit * 0.4
        canvas.maximumZoomScale = fit * 6
        canvas.zoomScale = fit * factor
        updateForZoom()
        canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: top * canvas.zoomScale)
    }

    func setZoom(percent: CGFloat) {
        guard lastWidth > 0 else { return }
        canvas.setZoomScale(lastWidth / NoteLayout.width * percent / 100, animated: true)
    }

    private func updateForZoom() {
        let z = canvas.zoomScale
        let total = NoteLayout.totalHeight(note.pages.map(\.height))
        canvas.contentSize = CGSize(width: NoteLayout.width * z, height: total * z)
        // Zoomed out, the page is narrower than the screen, so keep it centered.
        let side = max((canvas.bounds.width - NoteLayout.width * z) / 2, 0)
        canvas.contentInset = UIEdgeInsets(top: 0, left: side, bottom: 0, right: side)
        if lastWidth > 0 { zoomPercent = Int((z / (lastWidth / NoteLayout.width) * 100).rounded()) }
        for view in [underlay, overlay] as [UIView] {
            view.bounds = CGRect(x: 0, y: 0, width: NoteLayout.width, height: total)
            view.transform = CGAffineTransform(scaleX: z, y: z)
        }
        overlay.refreshSelection()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateForZoom() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === canvas else { return }
        let z = max(canvas.zoomScale, 0.01)
        let middle = (canvas.contentOffset.y + canvas.bounds.height / 2) / z
        let page = NoteLayout.pageIndex(y: middle, heights: note.pages.map(\.height)) + 1
        if page != currentPage { currentPage = page }
    }

    func visibleCenter() -> CGPoint {
        let z = canvas.zoomScale
        return CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / z, y: (canvas.contentOffset.y + canvas.bounds.height / 2) / z)
    }

    func rebuildPages() {
        let ids = Set(note.pages.map(\.id))
        for (id, view) in pageViews where !ids.contains(id) {
            view.removeFromSuperview()
            pageViews[id] = nil
        }
        let origins = NoteLayout.origins(note.pages.map(\.height))
        for (page, y) in zip(note.pages, origins) {
            let view = pageViews[page.id] ?? {
                let v = TiledView(frame: .zero)
                underlay.insertSubview(v, at: 0)
                pageViews[page.id] = v
                return v
            }()
            view.frame = CGRect(x: 0, y: y, width: NoteLayout.width, height: page.height)
            let key = AnyHashable([AnyHashable(page), AnyHashable(darkPages)])
            if view.contentKey != key {
                let size = view.bounds.size, doc = pdf, dark = darkPages
                let background = page.backgroundFile.flatMap { UIImage(contentsOfFile: library.dir(note.id).appendingPathComponent($0).path) }
                view.painter = { ctx in Renderer.drawBackground(page, pdf: doc, image: background, size: size, dark: dark, in: ctx) }
                view.contentKey = key
                view.setNeedsDisplay()
            }
        }
        updateForZoom()
    }

    func syncElements() {
        let ids = Set(note.elements.map(\.id))
        for (id, view) in elementViews where !ids.contains(id) {
            view.removeFromSuperview()
            elementViews[id] = nil
        }
        for el in note.elements {
            if el.isTape || el.cover != nil {
                let view = elementViews[el.id] ?? {
                    let v = UIView(frame: el.rect)
                    v.isUserInteractionEnabled = false
                    v.layer.cornerRadius = 3
                    overlay.insertSubview(v, at: 0)
                    elementViews[el.id] = v
                    return v
                }()
                view.frame = el.rect
                if let cover = el.cover {
                    view.backgroundColor = (cover == "redact") != darkPages ? .black : .white
                } else {
                    view.backgroundColor = UIColor(hex: el.colorHex).withAlphaComponent(el.revealed ? 0.18 : 1)
                }
            } else if let file = el.imageFile {
                let view = elementViews[el.id] ?? {
                    let v = UIImageView(image: UIImage(contentsOfFile: library.dir(note.id).appendingPathComponent(file).path))
                    v.contentMode = .scaleToFill
                    underlay.addSubview(v)
                    elementViews[el.id] = v
                    return v
                }()
                view.frame = el.rect
            } else {
                let view = elementViews[el.id] as? TiledView ?? {
                    let v = TiledView(frame: el.rect)
                    underlay.addSubview(v)
                    elementViews[el.id] = v
                    return v
                }()
                view.frame = el.rect
                view.isHidden = el.id == editingElementID
                var content = el
                content.rect.origin = .zero
                let key = AnyHashable([AnyHashable(content), AnyHashable(darkPages)])
                if view.contentKey != key {
                    let dark = darkPages
                    view.painter = { ctx in Renderer.drawText(content, in: content.rect, dark: dark, ctx: ctx) }
                    view.contentKey = key
                    view.setNeedsDisplay()
                }
            }
        }
    }

    // MARK: Tools

    private func applyTool() {
        let inking = [.pen, .highlighter, .eraser, .lasso].contains(tool) && playing == nil && !scribbleActive
        canvas.drawingGestureRecognizer.isEnabled = inking
        zoomCanvas.drawingGestureRecognizer.isEnabled = inking
        overlay.isUserInteractionEnabled = !inking
        if tool != .text, !scribbleActive {
            overlay.commitEditing()
            selectedElementID = nil
        }
        if tool != .region { regionRect = nil }
        switch tool {
        case .pen: canvas.tool = PKInkingTool(penStyle.ink, color: penColor, width: penWidth)
        case .highlighter: canvas.tool = PKInkingTool(.marker, color: highlightColor, width: highlightWidth)
        case .eraser: canvas.tool = PKEraserTool(eraseWholeStroke ? .vector : .bitmap)
        case .lasso: canvas.tool = PKLassoTool()
        case .text, .region, .annotate, .tape, .laser: break
        }
        zoomCanvas.tool = canvas.tool
        let defaults = UserDefaults.standard
        defaults.set(penStyle.rawValue, forKey: "penStyle")
        defaults.set(penColor.hex, forKey: "penColor")
        defaults.set(penWidth, forKey: "penWidth")
        defaults.set(highlightColor.hex, forKey: "highlightColor")
        defaults.set(highlightWidth, forKey: "highlightWidth")
    }

    private func applyDrawingPolicy() {
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        zoomCanvas.drawingPolicy = canvas.drawingPolicy
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        tool = tool == .eraser ? .pen : .eraser
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        tool = tool == .highlighter ? .pen : .highlighter
    }

    @objc private func fingerTapped(_ g: UITapGestureRecognizer) {
        // With finger drawing on, a tap is ink, not a click.
        guard !fingerDrawing, playing == nil else { return }
        let p = g.location(in: canvas)
        let z = canvas.zoomScale
        let point = CGPoint(x: p.x / z, y: p.y / z)
        if let el = note.elements.last(where: { $0.link != nil && $0.rect.contains(point) }) {
            openLink(el)
        } else {
            _ = followPDFLink(at: point)
        }
    }

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }
    @objc private func tapUndo() { if playing == nil { undo() } }
    @objc private func tapRedo() { if playing == nil { redo() } }

    // MARK: Ink changes

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        penDown = true
        liveTask?.cancel()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        penDown = false
        if tool == .eraser, Prefs.eraserReturns {
            tool = toolBeforeEraser
        } else {
            scheduleLiveText()
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard playing == nil else { return }
        if syncZoom(from: canvasView) { return }
        let strokes = canvas.drawing.strokes
        let added = strokes.count == lastStrokeCount + 1
        lastStrokeCount = strokes.count
        if added, let last = strokes.last, -last.path.creationDate.timeIntervalSinceNow < 3 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.noticePencil(last)
                if self.tool == .pen, Prefs.scribbleErase, self.scribbleErase(last) { return }
                if self.tool == .pen || self.tool == .highlighter, Prefs.holdForShapes, !self.snapShapes, self.snapIfHeld(last) { return }
                if self.tool == .pen, self.snapShapes { self.snap(last) }
                if self.tool == .highlighter, Prefs.snapToText { self.snapHighlight(last) }
                self.scheduleLiveText()
            }
        }
        if added, let last = strokes.last { appendPageIfNeeded(after: last.renderBounds) }
        scheduleSave()
    }

    /// Finishing a stroke and holding still turns it into a clean shape. Returns true if it did.
    private func snapIfHeld(_ stroke: PKStroke) -> Bool {
        let points = stroke.path.map { (location: $0.location, time: $0.timeOffset) }
        guard ShapeSnap.heldAtEnd(points), ShapeSnap.recognize(stroke.path.map(\.location)) != nil else { return false }
        snap(stroke)
        liveSince = max(liveSince, stroke.path.creationDate)
        return true
    }

    /// A finger always reports a flat altitude, so a tilted point means a Pencil. Live Text then moves to Scribble, which only a Pencil can use.
    private func noticePencil(_ stroke: PKStroke) {
        guard liveText, fingerDrawing, let point = stroke.path.first, point.altitude < .pi / 2 - 0.05 else { return }
        fingerDrawing = false
    }

    private func snap(_ stroke: PKStroke) {
        var strokes = canvas.drawing.strokes
        guard strokes.last?.path.creationDate == stroke.path.creationDate,
              let shape = ShapeSnap.recognize(stroke.path.map(\.location)) else { return }
        let width = stroke.path.first?.size ?? CGSize(width: penWidth, height: penWidth)
        let points = ShapeSnap.outline(shape).enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: width, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        strokes[strokes.count - 1] = PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate), transform: stroke.transform)
        registerStateUndo()
        canvas.drawing = PKDrawing(strokes: strokes)
    }

    private func appendPageIfNeeded(after bounds: CGRect) {
        guard let last = note.pages.last, last.pdfPage == nil,
              let origin = NoteLayout.origins(note.pages.map(\.height)).last, bounds.maxY > origin else { return }
        note.pages.append(Page(height: last.backgroundFile == nil ? last.height : NoteLayout.paperHeight, style: last.style, color: last.color))
        rebuildPages()
    }

    func registerStateUndo() {
        let pages = note.pages, elements = note.elements, drawing = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { model in
            model.registerStateUndo()
            model.note.pages = pages
            model.note.elements = elements
            model.lastStrokeCount = drawing.strokes.count
            model.canvas.drawing = drawing
            model.selectedElementID = nil
            model.rebuildPages()
            model.syncElements()
            model.scheduleSave()
        }
    }

    // MARK: Pages

    func setPages(_ new: [Page]) {
        guard !new.isEmpty else { return }
        registerStateUndo()
        let heights = note.pages.map(\.height)
        let shifts = NoteLayout.shifts(old: note.pages.map { ($0.id, $0.height) }, new: new.map { ($0.id, $0.height) })
        let strokes: [PKStroke] = canvas.drawing.strokes.compactMap { stroke in
            guard let dy = shifts[NoteLayout.pageIndex(y: stroke.renderBounds.midY, heights: heights)] else { return nil }
            var moved = stroke
            moved.transform = stroke.transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
            return moved
        }
        note.elements = note.elements.compactMap { el in
            guard let dy = shifts[NoteLayout.pageIndex(y: el.rect.midY, heights: heights)] else { return nil }
            var moved = el
            moved.rect.origin.y += dy
            return moved
        }
        note.pages = new
        lastStrokeCount = strokes.count
        canvas.drawing = PKDrawing(strokes: strokes)
        rebuildPages()
        syncElements()
        scheduleSave()
    }

    func addPage() {
        let last = note.pages.last { $0.pdfPage == nil }
        setPages(note.pages + [last.map { Page(height: $0.height, style: $0.style, color: $0.color) } ?? Prefs.newPage()])
        DispatchQueue.main.async { [self] in
            let y = (NoteLayout.origins(note.pages.map(\.height)).last ?? 0) * canvas.zoomScale
            canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: max(0, min(y, canvas.contentSize.height - canvas.bounds.height))), animated: true)
        }
    }

    func insertPDF(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), !doc.isLocked else {
            message = "“\(url.lastPathComponent)” can't be opened. It may be password-protected."
            return
        }
        insertPDF(doc)
    }

    func insertPDF(_ doc: PDFDocument) {
        let pages = library.appendPDF(doc, to: note.id)
        pdf = CGPDFDocument(library.pdfURL(note.id) as CFURL)
        // Repaint existing PDF pages against the reloaded document.
        pageViews.values.forEach { $0.contentKey = nil }
        inkChanged = true
        setPages(note.pages + pages)
    }

    func thumbnail(_ page: Page, width: CGFloat) -> UIImage? {
        guard let i = note.pages.firstIndex(of: page) else { return nil }
        return Renderer.thumbnail(page: page, index: i, note: note, drawing: currentDrawing, pdf: pdf, dir: library.dir(note.id), width: width)
    }

    func recognizePage(_ page: Page) async -> String {
        guard let i = note.pages.firstIndex(of: page) else { return "" }
        let drawing = currentDrawing, rect = Renderer.rects(for: note)[i]
        return await Task.detached { Renderer.recognizeInk(drawing, rect: rect) }.value
    }

    // MARK: Elements

    func addTextBox(at point: CGPoint) -> Element {
        registerStateUndo()
        let width = min(380, NoteLayout.width - point.x - 12)
        var el = Element(rect: CGRect(x: max(min(point.x, NoteLayout.width - 120), 0), y: point.y, width: max(width, 108), height: 30), fontSize: textSize, colorHex: textColor.hex, fontName: textFont, bold: textBold)
        el.rect.size.height = Renderer.textHeight(el)
        note.elements.append(el)
        syncElements()
        return el
    }

    func addImage(_ data: Data, transparent: Bool = false) {
        guard let image = UIImage(data: data), image.size.width > 0 else {
            message = "That image couldn't be read."
            return
        }
        let side = max(image.size.width, image.size.height)
        let scale = min(1, 2048 / side)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !transparent
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let file = "img-\(UUID().uuidString).\(transparent ? "png" : "jpg")"
        do {
            try (transparent ? scaled.pngData() : scaled.jpegData(compressionQuality: 0.85))?.write(to: library.dir(note.id).appendingPathComponent(file), options: .atomic)
        } catch {
            message = "Couldn't save the image: \(error.localizedDescription)"
            return
        }
        registerStateUndo()
        let width = min(420, size.width), height = width * size.height / size.width
        let c = visibleCenter()
        let el = Element(rect: CGRect(x: max(0, c.x - width / 2), y: c.y - height / 2, width: width, height: height), imageFile: file)
        note.elements.append(el)
        syncElements()
        tool = .text
        selectedElementID = el.id
        scheduleSave()
    }

    func updateElement(_ id: UUID, _ change: (inout Element) -> Void) {
        guard let i = note.elements.firstIndex(where: { $0.id == id }) else { return }
        change(&note.elements[i])
        syncElements()
        scheduleSave()
    }

    func removeElement(_ id: UUID) {
        note.elements.removeAll { $0.id == id }
        if selectedElementID == id { selectedElementID = nil }
        syncElements()
        scheduleSave()
    }

    func deleteSelected() {
        guard let id = selectedElementID else { return }
        overlay.cancelEditing()
        registerStateUndo()
        removeElement(id)
    }

    func applyTextStyle() {
        guard let id = selectedElementID else { return }
        updateElement(id) { el in
            guard el.imageFile == nil else { return }
            el.fontSize = textSize
            el.colorHex = textColor.hex
            el.fontName = textFont
            el.bold = textBold
            el.rect.size.height = Renderer.textHeight(el)
        }
        overlay.styleDidChange()
    }

    // MARK: Saving

    /// The canvas shows dimmed strokes during playback, so this is the only drawing safe to persist or export.
    var currentDrawing: PKDrawing { playing == nil ? canvas.drawing : realDrawing }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let drawing = currentDrawing
        guard note != savedNote || drawing != savedDrawing else { return }
        do {
            try FileManager.default.createDirectory(at: library.dir(note.id), withIntermediateDirectories: true)
            try drawing.dataRepresentation().write(to: library.drawingURL(note.id), options: .atomic)
            savedDrawing = drawing
        } catch {
            message = "Couldn't save your ink: \(error.localizedDescription)"
        }
        library.save(note)
        savedNote = note
        writeThumbnail()
    }

    private func writeThumbnail() {
        guard let first = note.pages.first, let image = thumbnail(first, width: 360) else { return }
        try? image.jpegData(compressionQuality: 0.7)?.write(to: library.thumbURL(note.id), options: .atomic)
    }

    func rename(_ title: String) {
        note.title = title
        scheduleSave()
    }

    func exportPDF() -> URL? {
        saveNow()
        do {
            return try Renderer.exportPDF(note: note, drawing: currentDrawing, dir: library.dir(note.id))
        } catch {
            message = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        overlay.commitEditing()
        if isRecording { stopRecording() }
        if playing != nil { stopPlayback() }
        transcribeTask?.cancel()
        reader.stopSpeaking(at: .immediate)
        liveTask?.cancel()
        zoomOn = false
        saveNow()
        let inkEdited = canvas.drawing != openedDrawing
        if inkEdited || note != openedNote { library.snapshot(note.id) }
        if inkEdited { inkChanged = true }
        if !FileManager.default.fileExists(atPath: library.thumbURL(note.id).path) { writeThumbnail() }
        canvas.undoManager?.removeAllActions()
        if !finishingRecorder { library.endEditing(note.id) }
        indexInBackground()
        let library = library
        Task { await library.backUp() }
    }

    private func indexInBackground() {
        guard inkChanged || note.searchText.isEmpty else { return }
        let drawing = canvas.drawing, note = note, id = note.id, library = library, dir = library.dir(note.id)
        let pdfURL = library.pdfURL(id)
        Task.detached(priority: .utility) {
            // Reading a long PDF's text takes seconds, so none of it happens on the main thread.
            let doc = PDFDocument(url: pdfURL)
            let pdfText = doc.map(library.pdfText) ?? ""
            let scanned = note.pages.indices.filter { i in
                note.pages[i].pdfPage.map { (doc?.page(at: $0)?.string ?? "").isEmpty } ?? false
            }
            let rects = Renderer.rects(for: note)
            let ink = rects.map { Renderer.recognizeInk(drawing, rect: $0) }
            let scans = scanned.map { i in
                Renderer.recognize(Renderer.snapshot(note: note, drawing: PKDrawing(), rect: rects[i], dir: dir))
            }
            await library.setSearchText(([pdfText] + scans + ink).joined(separator: "\n"), for: id)
        }
    }

    func fullText() async -> String {
        let drawing = currentDrawing, rects = Renderer.rects(for: note)
        let ink = await Task.detached { rects.map { Renderer.recognizeInk(drawing, rect: $0) }.joined(separator: "\n") }.value
        let typed = note.elements.filter { !$0.isTape && $0.comment == nil }.map(\.text).joined(separator: "\n")
        let comments = note.elements.compactMap(\.comment).joined(separator: "\n")
        let spoken = transcriptText
        let pdfURL = library.pdfURL(note.id), library = library
        let pdfText = await Task.detached { PDFDocument(url: pdfURL).map(library.pdfText) ?? "" }.value
        return [typed, comments, ink, spoken, pdfText].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var transcriptText: String {
        note.recordings.flatMap { $0.transcript ?? [] }.map(\.text).joined(separator: " ")
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { Task { await startRecording() } }
    }

    private func startRecording() async {
        if playing != nil { stopPlayback() }
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "Margin needs microphone access. Turn it on in Settings › Privacy & Security › Microphone."
            return
        }
        let transcribe = Prefs.liveTranscribe && LocalWhisper.isAvailable
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            recordingFile = "rec-\(UUID().uuidString).m4a"
            try FileManager.default.createDirectory(at: library.dir(note.id), withIntermediateDirectories: true)
            let recorder = LiveRecorder()
            recorder.onTranscript = { [weak self] lines in self?.liveLines = lines }
            // A crash mid-recording loses the take: the m4a is only finalised on stop.
            try recorder.start(url: library.dir(note.id).appendingPathComponent(recordingFile), transcribe: transcribe)
            self.recorder = recorder
            recordingStart = Date()
            recordingElapsed = 0
            liveLines = []
            pendingFlags = []
            smartNotes = ""
            isRecording = true
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordingElapsed = self?.recorder?.elapsed ?? 0 }
            }
            startSmartNotesLoop()
            NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted), name: AVAudioSession.interruptionNotification, object: session)
            NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged), name: .AVAudioEngineConfigurationChange, object: nil)
        } catch {
            message = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        let duration = recorder.stop()
        self.recorder = nil
        recordingTimer?.invalidate()
        smartTask?.cancel()
        isRecording = false
        showLivePanel = false
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let rec = Recording(file: recordingFile, startedAt: recordingStart, duration: duration, flags: pendingFlags.isEmpty ? nil : pendingFlags)
        note.recordings.append(rec)
        saveNow()
        finishingRecorder = true
        // The last few seconds are still being transcribed. Hold the recorder and this note until that's done.
        recorder.onFinished = { [self] lines in
            finishingRecorder = false
            if !lines.isEmpty {
                finishTranscript(rec.id, lines: lines)
            } else if LocalWhisper.isAvailable, !Prefs.liveTranscribe, !closed {
                transcribe(rec)
            }
            if closed { library.endEditing(note.id) }
            _ = recorder
        }
    }

    private func startSmartNotesLoop() {
        smartTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self else { return }
                if self.smartNotesOn { await self.refreshSmartNotes() }
            }
        }
    }

    func refreshSmartNotes() async {
        let transcript = liveLines.map(\.text).joined(separator: " ")
        guard !transcript.isEmpty, !smartNotesBusy, UIApplication.shared.applicationState == .active else { return }
        smartNotesBusy = true
        defer { smartNotesBusy = false }
        do {
            smartNotes = try await AI.smartNotes(previous: smartNotes, transcript: transcript)
        } catch is CancellationError {
            return
        } catch {
            smartNotesOn = false
            message = error.localizedDescription
        }
    }

    /// A phone call pauses the recorder, which would drift the stroke timing, so end the take and keep it.
    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        stopRecording()
        message = "Recording stopped by an interruption. What was captured is saved."
    }

    /// Plugging in headphones stops the audio engine, so keep what was captured rather than record silence.
    @objc private func audioRouteChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.stopRecording()
            self.message = "Recording stopped because the audio device changed. What was captured is saved."
        }
    }

    func flagMoment() {
        pendingFlags.append(recordingElapsed)
    }

    func deleteRecording(_ rec: Recording) {
        if playing?.id == rec.id { stopPlayback() }
        try? FileManager.default.removeItem(at: library.dir(note.id).appendingPathComponent(rec.file))
        note.recordings.removeAll { $0.id == rec.id }
        saveNow()
    }

    // MARK: Playback (notes replay in step with the audio)

    func startPlayback(_ rec: Recording) {
        overlay.commitEditing()
        if playing != nil { stopPlayback() }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: library.dir(note.id).appendingPathComponent(rec.file))
            player.enableRate = true
            player.rate = playRate
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            self.player = player
        } catch {
            message = "Couldn't play that recording: \(error.localizedDescription)"
            return
        }
        realDrawing = canvas.drawing
        strokeDates = realDrawing.strokes.map(\.path.creationDate).filter(rec.covers).sorted()
        revealedCount = -1
        playing = rec
        isPaused = false
        playTime = 0
        selectedElementID = nil
        applyTool()
        updateReveal()
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackTick() }
        }
    }

    private func playbackTick() {
        guard let player else { return }
        if !player.isPlaying, !isPaused {
            isPaused = true // reached the end
        }
        playTime = player.currentTime
        updateReveal()
    }

    private func updateReveal() {
        guard let rec = playing else { return }
        let now = rec.startedAt.addingTimeInterval(playTime)
        let count = strokeDates.prefix { $0 <= now }.count
        guard count != revealedCount else { return }
        let growing = count > revealedCount && revealedCount >= 0
        revealedCount = count
        let strokes = realDrawing.strokes.map { stroke -> PKStroke in
            let date = stroke.path.creationDate
            guard rec.covers(date), date > now else { return stroke }
            var dimmed = stroke
            dimmed.ink = PKInk(stroke.ink.inkType, color: stroke.ink.color.withAlphaComponent(0.18))
            return dimmed
        }
        canvas.drawing = PKDrawing(strokes: strokes)
        if growing, count > 0, let newest = realDrawing.strokes.first(where: { $0.path.creationDate == strokeDates[count - 1] }) {
            let z = canvas.zoomScale, b = newest.renderBounds
            let target = CGRect(x: b.minX * z, y: b.minY * z, width: b.width * z, height: b.height * z)
            let visible = CGRect(origin: canvas.contentOffset, size: canvas.bounds.size)
            if !visible.contains(target) { canvas.scrollRectToVisible(target.insetBy(dx: 0, dy: -80), animated: true) }
        }
    }

    func togglePause() {
        guard let player else { return }
        if isPaused {
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
        } else {
            player.pause()
        }
        isPaused.toggle()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        playTime = player.currentTime
        updateReveal()
    }

    func seekToStroke(near point: CGPoint) {
        guard let rec = playing else { return }
        let hit = realDrawing.strokes
            .filter { rec.covers($0.path.creationDate) && $0.renderBounds.insetBy(dx: -14, dy: -14).contains(point) }
            .min { hypot($0.renderBounds.midX - point.x, $0.renderBounds.midY - point.y) < hypot($1.renderBounds.midX - point.x, $1.renderBounds.midY - point.y) }
        guard let hit else { return }
        seek(to: hit.path.creationDate.timeIntervalSince(rec.startedAt))
    }

    func stopPlayback() {
        playTimer?.invalidate()
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lastStrokeCount = realDrawing.strokes.count
        let restored = realDrawing
        playing = nil
        canvas.drawing = restored
        applyTool()
    }

    // MARK: Transcripts

    func transcribe(_ rec: Recording) {
        guard LocalWhisper.isAvailable else {
            message = "Download the transcription model in Settings to use this. It runs entirely on your iPad."
            return
        }
        transcribing = rec.id
        transcribeProgress = 0
        let url = library.dir(note.id).appendingPathComponent(rec.file)
        transcribeTask = Task {
            do {
                let lines = try await Transcriber.transcribe(file: url) { done in self.transcribeProgress = done }
                finishTranscript(rec.id, lines: lines)
            } catch is CancellationError {
                transcribing = nil
            } catch {
                transcribing = nil
                message = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }

    private func finishTranscript(_ id: UUID, lines: [TranscriptLine]) {
        if let i = note.recordings.firstIndex(where: { $0.id == id }) {
            note.recordings[i].transcript = lines
            if playing?.id == id { playing = note.recordings[i] }
        }
        transcribing = nil
        if lines.isEmpty { message = "No speech was found in that recording." }
        saveNow()
    }
}
