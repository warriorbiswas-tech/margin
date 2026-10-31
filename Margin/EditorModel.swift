import AVFoundation
import Observation
import PDFKit
import PencilKit
import UIKit
import WebKit

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
    case ballpoint, fountain, pencil, monoline, dashed, crayon, watercolor
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var ink: PKInkingTool.InkType {
        switch self {
        case .ballpoint: .pen
        case .fountain: .fountainPen
        case .pencil: .pencil
        case .monoline, .dashed: .monoline
        case .crayon: .crayon
        case .watercolor: .watercolor
        }
    }
}

/// PencilKit's own undo list knows nothing of pages or text boxes and loses track whenever the drawing is replaced.
/// All undo goes through EditorModel's history, so this list stays empty.
final class InkCanvas: PKCanvasView {
    private let unused: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()
    override var undoManager: UndoManager? { unused }
}

/// Everything one undo step puts back.
struct NoteState: Equatable {
    var boardWidth: CGFloat?
    var pages: [Page]
    var elements: [Element]
    var excerpts: [Excerpt]
    var drawing: PKDrawing
}

/// CATiledLayer stays sharp at any zoom and only paints what is on screen. `painter` runs on background threads.
final class TiledView: UIView {
    final class FastLayer: CATiledLayer {
        override class func fadeDuration() -> CFTimeInterval { 0 }
    }
    override class var layerClass: AnyClass { FastLayer.self }
    private let painterLock = NSLock()
    private var currentPainter: ((CGContext) -> Void)?
    /// Replaced on the main thread while tiles draw on others, when a page changes or an endless page grows.
    var painter: ((CGContext) -> Void)? {
        get { painterLock.withLock { currentPainter } }
        set { painterLock.withLock { currentPainter = newValue } }
    }
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
final class EditorModel: NSObject, UIGestureRecognizerDelegate, Identifiable, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    private static let fingerDrawingKey = "fingerDrawing"
    @ObservationIgnored let library: Library
    @ObservationIgnored let canvas = InkCanvas()
    @ObservationIgnored let overlay = OverlayView()
    @ObservationIgnored private let underlay = UIView()
    @ObservationIgnored var pageViews: [UUID: TiledView] = [:]
    @ObservationIgnored private var pageHeights: [CGFloat] = []
    @ObservationIgnored private var pageOrigins: [CGFloat] = []
    @ObservationIgnored private var shownPages: ClosedRange<Int>?
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
    @ObservationIgnored private var thumbnailStale = false
    @ObservationIgnored private var startingRecording = false
    @ObservationIgnored private var studyCache: (drawing: PKDrawing, pages: [Page], elements: [Element], text: [String])?
    @ObservationIgnored private var history = History<NoteState>(limit: 200)
    @ObservationIgnored private var inkOnRecord: PKDrawing
    @ObservationIgnored private var touchRecorded = false
    @ObservationIgnored private var lastTouchType = UITouch.TouchType.direct
    private(set) var canUndo = false
    private(set) var canRedo = false

    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    var note: Note
    var message: String?
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// Good news that needs no answer, so it passes by rather than interrupting.
    func notify(_ text: String) {
        notice = text
        UIAccessibility.post(notification: .announcement, argument: text)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

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
            scribbleUnavailable = false
            applyTool()
            applyDrawingPolicy()
            if liveText {
                liveSince = max(Date(), canvas.drawing.strokes.map(\.path.creationDate).max() ?? .distantPast)
                scheduleLiveText()
            } else {
                liveTask?.cancel()
            }
        }
    }
    var liveFont = UserDefaults.standard.string(forKey: "liveFont") ?? "sans" {
        didSet { UserDefaults.standard.set(liveFont, forKey: "liveFont") }
    }
    var liveSize = UserDefaults.standard.double(forKey: "liveSize") { // 0 matches the handwriting
        didSet { UserDefaults.standard.set(liveSize, forKey: "liveSize") }
    }
    @ObservationIgnored let liveScribble = LiveScribble()
    @ObservationIgnored var scribbleConfirmed = false
    @ObservationIgnored var eraserTrailPoint: CGPoint?
    @ObservationIgnored var eraserUndoRegistered = false
    @ObservationIgnored var freshScribbleBoxID: UUID?
    @ObservationIgnored var lastPencilActivity = Date.distantPast
    var scribbleUnavailable = false

    /// Scribble reads the pen's motion, which is far more accurate than reading a picture of the ink, but it only works with a Pencil.
    var scribbleActive: Bool { liveText && tool == .pen && !fingerDrawing && !scribbleUnavailable && playing == nil && !readOnly }
    var aiProgress: String?
    var aiAnswer: AIAnswer?
    @ObservationIgnored var askTask: Task<Void, Never>?
    @ObservationIgnored var liveSince = Date()
    @ObservationIgnored var liveTask: Task<Void, Never>?
    @ObservationIgnored var liveInk: CGRect?
    /// The last stroke as the pen actually moved. PencilKit smooths fast back-and-forth strokes almost flat.
    @ObservationIgnored var rawStroke: [CGPoint] = []
    @ObservationIgnored var lastLiveScratch = Date.distantPast
    @ObservationIgnored var lastLiveTouch = Date.distantPast
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
    /// Ink sits above the page on its own layer, so only transparency lets the text show through a highlight.
    var highlightInk: UIColor { highlightColor.withAlphaComponent(0.4) }
    var highlightWidth = UserDefaults.standard.object(forKey: "highlightWidth") as? CGFloat ?? 20 { didSet { applyTool() } }
    var eraseWholeStroke = false { didSet { applyTool() } }
    var snapShapes = false
    var rulerOn = false { didSet { canvas.isRulerActive = rulerOn } }
    var focusMode = false
    var regionRect: CGRect? { didSet { overlay.refreshRegion() } }
    var busy: String?
    var fingerDrawing = UserDefaults.standard.object(forKey: EditorModel.fingerDrawingKey) as? Bool ?? !UIPencilInteraction.prefersPencilOnlyDrawing {
        didSet {
            UserDefaults.standard.set(fingerDrawing, forKey: Self.fingerDrawingKey)
            applyDrawingPolicy()
            applyTool()
        }
    }

    var textColor = UIColor(hex: "1C1C1E")
    var textSize: CGFloat = 20
    var textFont = "sans"
    var textBold = false
    var textItalic = false
    var textUnderline = false
    var textAlign: String?
    var readOnly = false {
        didSet {
            overlay.commitEditing()
            selectedElementID = nil
            regionRect = nil
            applyTool()
            applyDrawingPolicy()
        }
    }
    var showWeb = false
    var webFloating = false
    /// One web view for the note, so a video keeps playing when its window moves between docked and floating.
    @ObservationIgnored lazy var web: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    var openNoteRequest: UUID?
    var zoomOn = false { didSet { zoomDidToggle() } }
    @ObservationIgnored let zoomCanvas = InkCanvas()
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
        var note = note
        note.elements.removeAll(where: \.isBlank) // a box left behind when the app closed mid-word would catch later writing
        self.note = note
        self.library = library
        let drawing = library.loadDrawing(note.id)
        savedNote = note
        openedNote = note
        savedDrawing = drawing
        openedDrawing = drawing
        inkOnRecord = drawing
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
        let trail = TouchTrail(target: nil, action: nil)
        trail.onTouch = { [weak self] touch, began in
            if began { self?.lastTouchType = touch.type }
            self?.eraserTouch(touch, began: began)
            self?.liveTouch(touch, began: began)
        }
        trail.onPoints = { [weak self] points, began in
            guard let self else { return }
            if began { self.rawStroke = [] }
            let z = max(self.canvas.zoomScale, 0.01)
            self.rawStroke += points.map { CGPoint(x: $0.x / z, y: $0.y / z) }
        }
        trail.onEnd = { [weak self] touch in
            guard let self, touch.type == .pencil else { return }
            self.liveStrokeEnded(self.rawStroke)
        }
        canvas.addGestureRecognizer(trail)
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
        twoFinger.require(toFail: threeFinger) // three fingers rarely land together
        twoFinger.delegate = self
        threeFinger.delegate = self
        canvas.addGestureRecognizer(twoFinger)
        canvas.addGestureRecognizer(threeFinger)

        rebuildPages()
        syncElements()
        applyTool()
        applyDrawingPolicy()
    }

    // MARK: Canvas layout

    func containerDidLayout(size: CGSize) {
        defer { showNearbyPages() }
        guard size.width > 0, size.width != lastWidth else { return }
        var left: CGFloat?, top = canvas.contentOffset.y / max(canvas.zoomScale, 0.01)
        var factor = lastWidth > 0 ? canvas.zoomScale / (lastWidth / NoteLayout.width) : 1
        if lastWidth == 0, let saved = UserDefaults.standard.array(forKey: positionKey) as? [Double], saved.count == 3 {
            (left, top, factor) = (saved[0], saved[1], saved[2])
        } else if lastWidth == 0, let board = note.boardWidth {
            // A whiteboard opens in its middle, with room to write in every direction.
            left = (board - NoteLayout.width) / 2
            top = (NoteLayout.totalHeight(note.pages.map(\.height)) - NoteLayout.paperHeight) / 2
        }
        lastWidth = size.width
        let fit = size.width / NoteLayout.width
        canvas.minimumZoomScale = fit * (note.boardWidth == nil ? 0.4 : 0.17)
        canvas.maximumZoomScale = fit * 6
        canvas.zoomScale = fit * factor
        updateForZoom()
        let z = canvas.zoomScale
        let x = left.map { min($0 * z, max(canvas.contentSize.width - size.width, 0)) } ?? -canvas.contentInset.left
        canvas.contentOffset = CGPoint(x: max(x, -canvas.contentInset.left), y: max(0, min(top * z, canvas.contentSize.height - size.height)))
    }

    private var positionKey: String { Library.positionKey(note.id) }

    /// Where this note was left, in page coordinates, so it reopens there at the same zoom.
    private func rememberPosition() {
        guard lastWidth > 0 else { return }
        let z = max(canvas.zoomScale, 0.01)
        UserDefaults.standard.set([canvas.contentOffset.x / z, canvas.contentOffset.y / z, z / (lastWidth / NoteLayout.width)].map(Double.init), forKey: positionKey)
    }

    func setZoom(percent: CGFloat) {
        guard lastWidth > 0 else { return }
        canvas.setZoomScale(lastWidth / NoteLayout.width * percent / 100, animated: true)
    }

    private func updateForZoom() {
        let z = canvas.zoomScale
        let total = NoteLayout.totalHeight(note.pages.map(\.height))
        canvas.contentSize = CGSize(width: note.width * z, height: total * z)
        // Zoomed out, the page is narrower than the screen, so keep it centered.
        let side = max((canvas.bounds.width - note.width * z) / 2, 0)
        canvas.contentInset = UIEdgeInsets(top: 0, left: side, bottom: 0, right: side)
        if lastWidth > 0 { zoomPercent = Int((z / (lastWidth / NoteLayout.width) * 100).rounded()) }
        for view in [underlay, overlay] as [UIView] {
            view.bounds = CGRect(x: 0, y: 0, width: note.width, height: total)
            view.transform = CGAffineTransform(scaleX: z, y: z)
        }
        overlay.refreshSelection()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateForZoom()
        showNearbyPages()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === canvas else { return }
        let z = max(canvas.zoomScale, 0.01)
        let middle = (canvas.contentOffset.y + canvas.bounds.height / 2) / z
        let page = NoteLayout.pageIndex(y: middle, heights: pageHeights) + 1
        if page != currentPage { currentPage = page }
        showNearbyPages()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { rememberPosition() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { rememberPosition() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { rememberPosition() }
    }

    func visibleCenter() -> CGPoint {
        let z = canvas.zoomScale
        return CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / z, y: (canvas.contentOffset.y + canvas.bounds.height / 2) / z)
    }

    func rebuildPages() {
        pageHeights = note.pages.map(\.height)
        pageOrigins = NoteLayout.origins(pageHeights)
        shownPages = nil
        showNearbyPages()
        updateForZoom()
    }

    /// Only pages within a screen of the view exist; a long book would otherwise hold hundreds of tiled layers in memory.
    private func showNearbyPages() {
        guard !note.pages.isEmpty, pageHeights.count == note.pages.count else { return }
        let z = max(canvas.zoomScale, 0.01), top = canvas.contentOffset.y / z, height = canvas.bounds.height / z
        let nearby = NoteLayout.pageIndex(y: top - height, heights: pageHeights)...NoteLayout.pageIndex(y: top + height * 2, heights: pageHeights)
        guard nearby != shownPages else { return }
        shownPages = nearby
        let wanted = Set(note.pages[nearby].map(\.id))
        for (id, view) in pageViews where !wanted.contains(id) {
            view.removeFromSuperview()
            pageViews[id] = nil
        }
        for i in nearby {
            let page = note.pages[i], y = pageOrigins[i]
            let view = pageViews[page.id] ?? {
                let v = TiledView(frame: .zero)
                underlay.insertSubview(v, at: 0)
                pageViews[page.id] = v
                return v
            }()
            view.frame = CGRect(x: 0, y: y, width: note.width, height: page.height)
            let key = AnyHashable([AnyHashable(page), AnyHashable(darkPages), AnyHashable(note.width)])
            if view.contentKey != key {
                let size = view.bounds.size, doc = pdf, dark = darkPages
                let background = page.backgroundFile.flatMap { UIImage(contentsOfFile: library.dir(note.id).appendingPathComponent($0).path) }
                view.painter = { ctx in Renderer.drawBackground(page, pdf: doc, image: background, size: size, dark: dark, in: ctx) }
                view.contentKey = key
                view.setNeedsDisplay()
            }
        }
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
                // Undo or a cut-out can change which file an image shows.
                let view = (elementViews[el.id] as? UIImageView).flatMap { $0.accessibilityIdentifier == file ? $0 : nil } ?? {
                    elementViews[el.id]?.removeFromSuperview()
                    let v = UIImageView(image: UIImage(contentsOfFile: library.dir(note.id).appendingPathComponent(file).path))
                    v.accessibilityIdentifier = file
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
        let inking = [.pen, .highlighter, .eraser, .lasso].contains(tool) && playing == nil && !scribbleActive && !readOnly
        canvas.drawingGestureRecognizer.isEnabled = inking
        zoomCanvas.drawingGestureRecognizer.isEnabled = inking
        overlay.isUserInteractionEnabled = !inking && !readOnly
        // A Pencil only scrolls with a tool that doesn't write. Otherwise a quick stroke could move the page instead.
        canvas.panGestureRecognizer.allowedTouchTypes = inking || scribbleActive
            ? [UITouch.TouchType.direct.rawValue as NSNumber, UITouch.TouchType.indirectPointer.rawValue as NSNumber]
            : [UITouch.TouchType.direct.rawValue as NSNumber, UITouch.TouchType.pencil.rawValue as NSNumber, UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        if tool != .text, !scribbleActive {
            overlay.commitEditing()
            selectedElementID = nil
        }
        if tool != .region { regionRect = nil }
        switch tool {
        case .pen: canvas.tool = PKInkingTool(penStyle.ink, color: penColor, width: penWidth)
        case .highlighter: canvas.tool = PKInkingTool(.marker, color: highlightInk, width: highlightWidth * 1.25) // a marker lays down less than its width, and medium should cover a line
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
        canvas.drawingPolicy = fingerDrawing && !readOnly ? .anyInput : .pencilOnly
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
        guard !fingerDrawing || readOnly, playing == nil else { return }
        let p = g.location(in: canvas)
        let z = canvas.zoomScale
        let point = CGPoint(x: p.x / z, y: p.y / z)
        if let el = note.elements.last(where: { $0.link != nil && $0.rect.contains(point) }) {
            openLink(el)
        } else {
            _ = followPDFLink(at: point)
        }
    }

    func undo() {
        guard playing == nil, !readOnly else { return }
        overlay.commitEditing()
        guard let state = history.undo(from: currentState) else { return }
        restore(state)
    }

    func redo() {
        guard playing == nil, !readOnly else { return }
        overlay.commitEditing()
        guard let state = history.redo(from: currentState) else { return }
        restore(state)
    }

    var currentState: NoteState {
        // A box with nothing written in it yet doesn't show, so undoing to it would look like nothing happened.
        NoteState(boardWidth: note.boardWidth, pages: note.pages, elements: note.elements.filter { !$0.isBlank }, excerpts: note.excerpts, drawing: currentDrawing)
    }

    private func restore(_ state: NoteState) {
        let pagesChanged = state.pages != note.pages || state.boardWidth != note.boardWidth
        note.boardWidth = state.boardWidth
        note.pages = state.pages
        note.elements = state.elements
        note.excerpts = state.excerpts
        selectedElementID = nil
        setInk(state.drawing)
        if pagesChanged { rebuildPages() }
        syncElements()
        scheduleSave()
        updateUndoButtons()
    }

    func recordBefore(_ state: NoteState) {
        history.record(state)
        updateUndoButtons()
    }

    /// Call before changing the note. Strokes record themselves, in `canvasViewDrawingDidChange`.
    func checkpoint() {
        history.record(currentState)
        updateUndoButtons()
    }

    func clearHistory() {
        history.clear()
        updateUndoButtons()
    }

    private func updateUndoButtons() {
        if canUndo != history.canUndo { canUndo = history.canUndo }
        if canRedo != history.canRedo { canRedo = history.canRedo }
    }

    /// Replaces the ink without it counting as something the pen just did. A PKDrawing remembers its past and merges
    /// with the canvas on the next stroke, so handing back an older one would bring undone ink back. A new one has no past.
    func setInk(_ drawing: PKDrawing) {
        let fresh = PKDrawing(strokes: drawing.strokes)
        inkOnRecord = fresh
        lastStrokeCount = fresh.strokes.count
        canvas.drawing = fresh
    }

    // Scrolling, drawing or a text box must never swallow the undo gestures.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// The way to a real keyboard, for when handwriting won't do. Carries on in the box being written, if there is one.
    func typeWithKeyboard() {
        let current = editingElementID
        overlay.commitEditing()
        tool = .text
        let el = note.elements.first { $0.id == current } ?? addTextBox(at: visibleCenter())
        selectedElementID = el.id
        overlay.beginEditing(el)
    }
    @objc private func tapUndo() {
        guard playing == nil, !readOnly else { return }
        notify(canUndo ? "Undo" : "Nothing to Undo")
        undo()
    }

    @objc private func tapRedo() {
        guard playing == nil, !readOnly else { return }
        notify(canRedo ? "Redo" : "Nothing to Redo")
        redo()
    }

    // MARK: Ink changes

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        penDown = true
        touchRecorded = false
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
        let drawing = canvas.drawing
        if drawing != inkOnRecord {
            if !touchRecorded {
                var before = currentState
                before.drawing = inkOnRecord
                history.record(before)
            }
            touchRecorded = penDown
            inkOnRecord = drawing
            updateUndoButtons()
        }
        let strokes = drawing.strokes
        let added = strokes.count == lastStrokeCount + 1
        lastStrokeCount = strokes.count
        if added, let last = strokes.last {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.noticePencil()
                if self.tool == .pen, self.penStyle == .dashed {
                    self.cutIntoDashes(last)
                    return
                }
                if self.tool == .pen, Prefs.scribbleErase, self.scribbleErase(last) { return }
                if self.tool == .pen, Prefs.holdForShapes, !self.snapShapes, self.snapIfHeld(last) { return }
                if self.tool == .pen, self.snapShapes { self.snap(last) }
                if self.tool == .highlighter { self.snapHighlight(last) }
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

    /// Whoever writes with a Pencil rests a hand on the page and scrolls with a finger, so the first Pencil stroke stops
    /// fingers drawing, unless they were turned on by choice. It also lets Live Text move to Scribble.
    private func noticePencil() {
        guard fingerDrawing, lastTouchType == .pencil else { return }
        if liveText || UserDefaults.standard.object(forKey: Self.fingerDrawingKey) == nil { fingerDrawing = false }
    }

    /// Scribble can be off in Settings, or unavailable for the keyboard language. A Pencil stroke
    /// it never picked up would otherwise vanish, so that one stroke switches Live Text back to ink.
    func pencilStrokeEnded() {
        // Once Scribble has picked up any writing it's working. An illegible word isn't a reason to give up on it.
        guard scribbleActive, !scribbleConfirmed else { return }
        let finished = Date()
        lastPencilActivity = finished
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
            guard scribbleActive, !scribbleConfirmed, lastPencilActivity == finished else { return }
            scribbleUnavailable = true
            overlay.commitEditing()
            liveSince = Date()
            applyTool()
            notify("Scribble isn't responding, so Live Text is reading your ink.")
        }
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
        setInk(PKDrawing(strokes: strokes))
    }

    private func appendPageIfNeeded(after bounds: CGRect) {
        if let board = note.boardWidth, bounds.maxX > board - NoteLayout.width {
            note.boardWidth = board + NoteLayout.width
            rebuildPages()
        }
        guard let last = note.pages.last, last.pdfPage == nil, let origin = NoteLayout.origins(note.pages.map(\.height)).last else { return }
        if last.endless == true {
            guard bounds.maxY > origin + last.height - NoteLayout.paperHeight / 2 else { return }
            note.pages[note.pages.count - 1].height += NoteLayout.paperHeight
            rebuildPages()
            return
        }
        guard bounds.maxY > origin else { return }
        note.pages.append(Page(height: last.backgroundFile == nil ? last.height : NoteLayout.paperHeight, style: last.style, color: last.color))
        rebuildPages()
    }

    // MARK: Pages

    func setPages(_ new: [Page]) {
        guard !new.isEmpty else { return }
        checkpoint()
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
        setInk(PKDrawing(strokes: strokes))
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
        busy = "Adding pages…"
        Task {
            let pages = await library.appendPDF(doc, to: note.id)
            busy = nil
            pdf = CGPDFDocument(library.pdfURL(note.id) as CFURL)
            // Repaint existing PDF pages against the reloaded document.
            pageViews.values.forEach { $0.contentKey = nil }
            inkChanged = true
            setPages(note.pages + pages)
        }
    }

    /// Rendered off the main thread, so a page list on a long book scrolls instead of stalling.
    func thumbnailInBackground(_ page: Page, width: CGFloat) async -> UIImage? {
        guard let i = note.pages.firstIndex(of: page) else { return nil }
        let note = note, drawing = currentDrawing, doc = pdf, dir = library.dir(note.id)
        struct Unchecked: @unchecked Sendable { let doc: CGPDFDocument? }
        let source = Unchecked(doc: doc)
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool { Renderer.thumbnail(page: page, index: i, note: note, drawing: drawing, pdf: source.doc, dir: dir, width: width) }
        }.value
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
        checkpoint()
        let width = min(380, note.width - point.x - 12)
        var el = Element(rect: CGRect(x: max(min(point.x, note.width - 120), 0), y: point.y, width: max(width, 108), height: 30), fontSize: textSize, colorHex: textColor.hex, fontName: textFont, bold: textBold)
        el.italic = textItalic
        el.underline = textUnderline
        el.align = textAlign
        el.rect.size.height = Renderer.textHeight(el)
        note.elements.append(el)
        syncElements()
        return el
    }

    func addImage(_ data: Data, transparent: Bool = false, offset: CGFloat = 0) {
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
        checkpoint()
        let width = min(420, size.width), height = width * size.height / size.width
        let c = visibleCenter()
        let el = Element(rect: CGRect(x: max(0, c.x - width / 2 + offset), y: c.y - height / 2 + offset, width: width, height: height), imageFile: file)
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
        checkpoint()
        removeElement(id)
    }

    func applyTextStyle() {
        guard let id = selectedElementID, let current = note.elements.first(where: { $0.id == id }), current.imageFile == nil,
              current.fontSize != textSize || current.colorHex != textColor.hex || current.fontName != textFont || current.bold != textBold
                || current.italic != textItalic || current.underline != textUnderline || current.align != textAlign else { return }
        checkpoint()
        updateElement(id) { el in
            el.fontSize = textSize
            el.colorHex = textColor.hex
            el.fontName = textFont
            el.bold = textBold
            el.italic = textItalic
            el.underline = textUnderline
            el.align = textAlign
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
            guard !Task.isCancelled, let self else { return }
            self.rememberPosition()
            self.storeChanges()
        }
    }

    /// Hands anything new to the library's writer, so the pen never waits on the disk.
    private func storeChanges() {
        let drawing = currentDrawing, inkDiffers = drawing != savedDrawing
        guard inkDiffers || note != savedNote else { return }
        library.save(note, ink: inkDiffers ? drawing : nil) { [weak self] reason in self?.message = reason }
        savedNote = note
        savedDrawing = drawing
        thumbnailStale = true
    }

    /// For when the app is about to leave, or something needs the files right now.
    func saveNow() {
        saveTask?.cancel()
        rememberPosition()
        storeChanges()
        if thumbnailStale { writeThumbnail() }
        library.flush()
    }

    private func writeThumbnail() {
        thumbnailStale = false
        guard let first = note.pages.first, let image = coverPicture(first) else { return }
        try? image.jpegData(compressionQuality: 0.7)?.write(to: library.thumbURL(note.id), options: .atomic)
    }

    /// A whiteboard or endless page is mostly empty, so its picture shows the part that has something on it.
    private func coverPicture(_ first: Page) -> UIImage? {
        guard first.endless == true, let page = Renderer.rects(for: note).first else { return thumbnail(first, width: 360) }
        let ink = currentDrawing.strokes.map(\.renderBounds).filter { $0.intersects(page) }
        let boxes = note.elements.map(\.rect).filter { $0.intersects(page) }
        let content = (ink + boxes).reduce(CGRect.null) { $0.union($1) }
        guard !content.isNull else { return thumbnail(first, width: 360) }
        let width = min(max(content.width + 80, NoteLayout.width), page.width), height = min(width * 11 / 8.5, page.height)
        let area = CGRect(x: min(max(content.minX - 40, 0), page.maxX - width), y: min(max(content.minY - 40, 0), page.maxY - height), width: width, height: height)
        return Renderer.snapshot(note: note, drawing: currentDrawing, rect: area, dir: library.dir(note.id), scale: 360 / width)
    }

    func rename(_ title: String) {
        note.title = title
        scheduleSave()
    }

    func exportText() async -> URL? {
        let pages = await studyPages()
        let body = pages.enumerated().filter { !$0.element.isEmpty }.map { "## Page \($0.offset + 1)\n\n\($0.element)" }.joined(separator: "\n\n")
        let name = note.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.isEmpty ? "Note" : name).appendingPathExtension("md")
        do {
            try "# \(note.title)\n\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            message = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func exportPDF() async -> URL? {
        saveNow()
        busy = "Exporting…"
        defer { busy = nil }
        let note = note, drawing = currentDrawing, dir = library.dir(note.id)
        do {
            return try await Task.detached(priority: .userInitiated) {
                try Renderer.exportPDF(note: note, drawing: drawing, dir: dir)
            }.value
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
        clearHistory()
        if !finishingRecorder { library.endEditing(note.id) }
        indexInBackground()
        let library = library
        Task { await library.sync() }
    }

    private func indexInBackground() {
        guard inkChanged || note.searchText.isEmpty, library.beginIndexing(note.id) else { return }
        let drawing = canvas.drawing, note = note, id = note.id, library = library
        Task.detached(priority: .utility) {
            // Reading a long PDF's text takes seconds, so none of it happens on the main thread.
            let printed = library.pdfPageText(of: note).sorted { $0.key < $1.key }.map(\.value)
            let ink = Renderer.rects(for: note).map { rect in autoreleasepool { Renderer.recognizeInk(drawing, rect: rect) } }
            await library.setSearchText((printed + ink).joined(separator: "\n"), for: id)
        }
    }

    /// One string per page, for the assistant. A PDF's printed text is read once and kept, since a long book takes seconds to read.
    func studyPages() async -> [String] {
        let note = note, drawing = currentDrawing
        if let known = studyCache, known.drawing == drawing, known.pages == note.pages, known.elements == note.elements { return known.text }
        let library = library
        let text: [String] = await Task.detached(priority: .userInitiated) {
            let printed = library.pdfPageText(of: note)
            let rects = Renderer.rects(for: note)
            return note.pages.indices.map { i in
                autoreleasepool {
                    let ink = Renderer.recognizeInk(drawing, rect: rects[i])
                    let typed = note.elements.filter { !$0.isTape && $0.rect.intersects(rects[i]) }.map { $0.comment ?? $0.text }.filter { $0 != "" }
                    let page = note.pages[i].pdfPage.flatMap { printed[$0] } ?? ""
                    return ([page, ink] + typed).filter { !$0.isEmpty }.joined(separator: "\n")
                }
            }
        }.value
        studyCache = (drawing, note.pages, note.elements, text)
        return text
    }

    /// The text of a page range, 1-based and inclusive. With no range, the whole note and any transcripts.
    func studyText(pages range: ClosedRange<Int>?) async -> String {
        let pages = await studyPages()
        guard let range else {
            return (pages + [transcriptText]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let low = max(range.lowerBound, 1) - 1, high = min(range.upperBound, pages.count) - 1
        guard low <= high else { return "" }
        return pages[low...high].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The pages most relevant to a question, so a long book can be asked about in seconds.
    func chatContext(for question: String) async -> String {
        let pages = await studyPages(), spoken = transcriptText
        return await Task.detached(priority: .userInitiated) {
            var passages: [String] = []
            for (i, text) in pages.enumerated() {
                for chunk in TextTools.chunks(text, size: TextTools.passageSize) { passages.append("Page \(i + 1):\n\(chunk)") }
            }
            for chunk in TextTools.chunks(spoken, size: TextTools.passageSize) { passages.append("Recording transcript:\n\(chunk)") }
            let chosen = TextTools.bestPassages(query: question, passages: passages, limit: TextTools.contextSize)
            return chosen.sorted().map { passages[$0] }.joined(separator: "\n\n")
        }.value
    }

    func digester() -> Digester {
        Digester(cacheURL: library.dir(note.id).appendingPathComponent("digest-cache.json")) { [weak self] done, total in
            Task { @MainActor [weak self] in
                self?.aiProgress = "Reading part \(done + 1) of \(total). You can stop anytime; this work is kept."
            }
        }
    }

    var transcriptText: String {
        note.recordings.flatMap { $0.transcript ?? [] }.map(\.text).joined(separator: " ")
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else if !startingRecording {
            startingRecording = true
            Task {
                await startRecording()
                startingRecording = false
            }
        }
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
        let restored = realDrawing
        playing = nil
        setInk(restored)
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
