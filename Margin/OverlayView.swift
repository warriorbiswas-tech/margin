import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reports where a touch goes without ever claiming it, so the canvas underneath keeps working as normal.
final class TouchTrail: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: ((UITouch, _ began: Bool) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { onTouch?(touch, true) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { onTouch?(touch, false) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// A text box's own edits stay out of the note's undo history, where they'd be steps that undo nothing once it closes.
/// It also leaves the three-finger tap to the note, rather than the system's editing menu.
private final class BoxEditor: UITextView {
    private let ownUndo = UndoManager()
    override var undoManager: UndoManager? { ownUndo }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
}

/// Sits above the ink and takes touches for every tool that isn't writing, and during playback.
/// Element views stay below the ink so you can write on top of them; this layer only handles the gestures.
final class OverlayView: UIView, UIGestureRecognizerDelegate, UITextViewDelegate {
    weak var model: EditorModel?
    private(set) lazy var pan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(onPan))
        g.delegate = self
        g.maximumNumberOfTouches = 1 // two fingers always scroll
        return g
    }()
    private lazy var pencilWatch: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(onPencilWatch))
        g.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        g.cancelsTouchesInView = false
        g.delegate = self
        return g
    }()
    private let outline = UIView()
    private let handle = UIView()
    private let regionLayer = CAShapeLayer()
    private let zoomLayer = CAShapeLayer()
    private var editor: BoxEditor?
    private var dragStart = CGRect.zero
    private var dragOrigin = CGPoint.zero
    private var dragging: UUID?
    private var resizing = false
    private var laserPath: UIBezierPath?
    private var laserLayer: CAShapeLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onTap)))
        addGestureRecognizer(pan)
        addGestureRecognizer(pencilWatch)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(onLongPress)))
        outline.isUserInteractionEnabled = false
        outline.layer.borderColor = UIColor.systemBlue.cgColor
        outline.isHidden = true
        handle.isUserInteractionEnabled = false
        handle.backgroundColor = .systemBlue
        handle.layer.borderColor = UIColor.white.cgColor
        handle.isHidden = true
        addSubview(outline)
        addSubview(handle)
        regionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.1).cgColor
        regionLayer.strokeColor = UIColor.systemBlue.cgColor
        regionLayer.lineDashPattern = [6, 4]
        layer.addSublayer(regionLayer)
        layer.addSublayer(zoomLayer)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow), name: UIResponder.keyboardDidShowNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func element(at p: CGPoint) -> Element? {
        let tool = model?.tool
        return model?.note.elements.last { el in
            guard el.rect.contains(p) else { return false }
            switch tool {
            case .tape: return el.isTape
            case .annotate: return el.cover != nil || el.comment != nil
            default: return !el.isTape && el.cover == nil
            }
        }
    }

    private func onHandle(_ p: CGPoint) -> Bool {
        guard !handle.isHidden, let z = model?.canvas.zoomScale else { return false }
        return handle.frame.insetBy(dx: -14 / z, dy: -14 / z).contains(p)
    }

    func refreshSelection() {
        guard let model, let id = model.selectedElementID, let el = model.note.elements.first(where: { $0.id == id }) else {
            outline.isHidden = true
            handle.isHidden = true
            return
        }
        let z = max(model.canvas.zoomScale, 0.01), size = 14 / z
        outline.isHidden = false
        outline.frame = el.rect.insetBy(dx: -3 / z, dy: -3 / z)
        outline.layer.borderWidth = 1.5 / z
        handle.isHidden = false
        handle.frame = CGRect(x: outline.frame.maxX - size / 2, y: outline.frame.maxY - size / 2, width: size, height: size)
        handle.layer.cornerRadius = size / 2
        handle.layer.borderWidth = 1.5 / z
    }

    func refreshZoomBox() {
        guard let model else { return }
        zoomLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        zoomLayer.strokeColor = UIColor.systemBlue.cgColor
        zoomLayer.lineWidth = 1.5 / max(model.canvas.zoomScale, 0.01)
        zoomLayer.path = model.zoomOn ? UIBezierPath(rect: model.zoomRect).cgPath : nil
    }

    func refreshRegion() {
        let rect = model?.regionRect
        regionLayer.lineWidth = 1.5 / max(model?.canvas.zoomScale ?? 1, 0.01)
        regionLayer.path = rect.map { UIBezierPath(rect: $0).cgPath }
    }

    // MARK: Gestures

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let model else { return }
        let p = g.location(in: self)
        if model.playing != nil {
            model.seekToStroke(near: p)
            return
        }
        switch model.tool {
        case .region:
            if model.regionRect == nil { _ = model.followPDFLink(at: p) }
            model.regionRect = nil
        case .tape:
            if let id = element(at: p)?.id { model.updateElement(id) { $0.revealed.toggle() } }
        case .annotate:
            if let el = element(at: p), el.comment != nil {
                model.commentEditingID = el.id
            } else if model.annotateKind == .comment {
                model.addComment(at: p)
            }
        case .text:
            if let editor {
                if !editor.frame.contains(p) { commitEditing(); model.selectedElementID = nil }
                return
            }
            if let el = element(at: p) {
                model.selectedElementID = el.id
                if el.imageFile == nil, el.link == nil, !el.stamp, el.comment == nil { beginEditing(el) }
            } else if model.followPDFLink(at: p) {
                return
            } else if model.selectedElementID != nil {
                model.selectedElementID = nil
            } else {
                let el = model.addTextBox(at: p)
                model.selectedElementID = el.id
                beginEditing(el)
            }
        default:
            if let editor, !editor.frame.contains(p) { commitEditing() }
        }
    }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let model, model.tool == .tape || model.tool == .annotate, let el = element(at: g.location(in: self)) else { return }
        model.registerStateUndo()
        model.removeElement(el.id)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === pencilWatch || other === pencilWatch
    }

    @objc private func onPencilWatch(_ g: UIPanGestureRecognizer) {
        if g.state == .ended { model?.pencilStrokeEnded() }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UILongPressGestureRecognizer {
            return (model?.tool == .tape || model?.tool == .annotate) && element(at: g.location(in: self)) != nil
        }
        guard g === pan else { return true }
        guard let model, model.playing == nil, editor == nil else { return false }
        switch model.tool {
        case .region, .tape, .laser:
            return true
        case .annotate:
            return model.annotateKind != .comment
        case .text:
            let p = g.location(in: self)
            return onHandle(p) || element(at: p) != nil
        default:
            return false
        }
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        guard let model else { return }
        let p = g.location(in: self)
        switch model.tool {
        case .laser: laser(g, at: p)
        case .region, .tape, .annotate: rubberBand(g, at: p, model: model)
        default: moveElement(g, at: p, model: model)
        }
    }

    private func moveElement(_ g: UIPanGestureRecognizer, at p: CGPoint, model: EditorModel) {
        switch g.state {
        case .began:
            resizing = onHandle(p)
            if !resizing { model.selectedElementID = element(at: p)?.id }
            guard let id = model.selectedElementID, let el = model.note.elements.first(where: { $0.id == id }) else { return }
            model.registerStateUndo()
            dragging = id
            dragStart = el.rect
        case .changed:
            guard let id = dragging else { return }
            let t = g.translation(in: self), start = dragStart, resize = resizing
            model.updateElement(id) { el in
                guard resize else {
                    el.rect.origin = CGPoint(x: start.minX + t.x, y: start.minY + t.y)
                    return
                }
                el.rect.size.width = max(60, start.width + t.x)
                if el.imageFile != nil {
                    el.rect.size.height = el.rect.width * start.height / max(start.width, 1)
                } else {
                    if el.fillHex != nil { el.rect.size.height = max(60, start.height + t.y) }
                    el.rect.size.height = Renderer.textHeight(el)
                }
            }
            refreshSelection()
        default:
            dragging = nil
        }
    }

    private func rubberBand(_ g: UIPanGestureRecognizer, at p: CGPoint, model: EditorModel) {
        switch g.state {
        case .began:
            dragOrigin = CGPoint(x: p.x - g.translation(in: self).x, y: p.y - g.translation(in: self).y)
        case .changed:
            regionLayer.lineWidth = 1.5 / max(model.canvas.zoomScale, 0.01)
            if model.tool == .annotate, model.annotateKind == .arrow || model.annotateKind == .line {
                let path = UIBezierPath()
                path.move(to: dragOrigin)
                path.addLine(to: p)
                regionLayer.path = path.cgPath
            } else {
                regionLayer.path = UIBezierPath(rect: band(to: p)).cgPath
            }
        case .ended:
            if model.tool == .annotate {
                regionLayer.path = nil
                model.finishAnnotation(from: dragOrigin, to: p)
                return
            }
            let rect = band(to: p)
            guard rect.width > 12, rect.height > 8 else {
                regionLayer.path = nil
                return
            }
            if model.tool == .region {
                model.regionRect = rect
            } else {
                regionLayer.path = nil
                model.addTape(rect)
            }
        default:
            regionLayer.path = nil
        }
    }

    private func band(to p: CGPoint) -> CGRect {
        CGRect(x: min(dragOrigin.x, p.x), y: min(dragOrigin.y, p.y), width: abs(p.x - dragOrigin.x), height: abs(p.y - dragOrigin.y))
    }

    private func laser(_ g: UIPanGestureRecognizer, at p: CGPoint) {
        let z = max(model?.canvas.zoomScale ?? 1, 0.01)
        switch g.state {
        case .began:
            let path = UIBezierPath()
            path.move(to: p)
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.strokeColor = UIColor.systemRed.cgColor
            shape.lineWidth = 4 / z
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.shadowColor = UIColor.systemRed.cgColor
            shape.shadowOpacity = 0.9
            shape.shadowRadius = 6 / z
            shape.shadowOffset = .zero
            layer.addSublayer(shape)
            laserPath = path
            laserLayer = shape
        case .changed:
            laserPath?.addLine(to: p)
            laserLayer?.path = laserPath?.cgPath
        default:
            guard let shape = laserLayer else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { shape.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.9
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            shape.add(fade, forKey: "fade")
            CATransaction.commit()
            laserLayer = nil
            laserPath = nil
        }
    }

    // MARK: Text editing

    func beginEditing(_ el: Element) {
        guard let model else { return }
        model.textSize = el.fontSize
        model.textColor = UIColor(hex: el.colorHex)
        model.textFont = el.fontName
        model.textBold = el.bold
        model.editingElementID = el.id
        model.syncElements()

        let view = BoxEditor(frame: el.rect)
        view.backgroundColor = el.fillHex.map { UIColor(hex: $0) } ?? .clear
        view.tintColor = .systemBlue
        view.overrideUserInterfaceStyle = .light
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: el.inset, left: el.inset, bottom: el.inset, right: el.inset)
        view.textContainer.lineFragmentPadding = 0
        view.font = Renderer.font(el)
        view.textColor = Renderer.textColor(el, dark: model.darkPages)
        view.text = el.text
        view.delegate = self
        view.contentScaleFactor = window?.screen.scale ?? 2
        if model.scribbleActive {
            // Handwriting needs no keyboard or cursor. An empty input view keeps the keyboard and its bar away.
            view.inputView = UIView()
            view.tintColor = .clear
            view.inputAssistantItem.leadingBarButtonGroups = []
            view.inputAssistantItem.trailingBarButtonGroups = []
            view.autocorrectionType = .no
            view.spellCheckingType = .no
        }
        addSubview(view)
        editor = view
        view.becomeFirstResponder()
    }

    /// Scribble is about to write into this box. An empty box left behind is dropped first.
    func focusForScribble(_ el: Element) -> UITextView? {
        if model?.editingElementID != el.id {
            commitEditing()
            beginEditing(el)
        }
        return editor
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let model, let id = model.editingElementID else { return }
        model.freshScribbleBoxID = nil
        model.updateElement(id) { el in
            el.text = textView.text
            el.rect.size.height = Renderer.textHeight(el)
            textView.frame = el.rect
        }
        refreshSelection()
    }

    func styleDidChange() {
        guard let model, let editor, let id = model.editingElementID,
              let el = model.note.elements.first(where: { $0.id == id }) else { return }
        editor.font = Renderer.font(el)
        editor.textColor = Renderer.textColor(el, dark: model.darkPages)
        editor.frame = el.rect
        refreshSelection()
    }

    @objc private func keyboardDidShow() {
        guard let model, let editor else { return }
        let z = model.canvas.zoomScale, r = editor.frame
        model.canvas.scrollRectToVisible(CGRect(x: r.minX * z, y: r.minY * z, width: r.width * z, height: r.height * z).insetBy(dx: 0, dy: -40), animated: true)
    }

    func commitEditing() {
        guard let model, let view = editor, let id = model.editingElementID else { return }
        editor = nil
        model.editingElementID = nil
        view.resignFirstResponder()
        view.removeFromSuperview()
        if view.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.removeElement(id)
        } else {
            model.syncElements()
        }
    }

    func cancelEditing() {
        guard let model, let view = editor else { return }
        editor = nil
        model.editingElementID = nil
        view.resignFirstResponder()
        view.removeFromSuperview()
    }
}
