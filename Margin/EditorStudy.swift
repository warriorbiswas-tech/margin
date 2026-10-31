import AVFoundation
import PDFKit
import PencilKit
import UIKit

extension EditorModel {
    // MARK: Ink helpers

    private func textEdits(crossing area: CGRect) -> [(id: UUID, text: String)] {
        note.elements.compactMap { el in
            guard el.imageFile == nil, !el.isTape, el.cover == nil, el.comment == nil, el.rect.intersects(area) else { return nil }
            let text = Renderer.textRemovingWords(of: el, crossing: area)
            return text == el.text ? nil : (el.id, text)
        }
    }

    private func apply(_ edits: [(id: UUID, text: String)]) {
        for edit in edits {
            guard let i = note.elements.firstIndex(where: { $0.id == edit.id }) else { continue }
            if edit.text.isEmpty {
                if selectedElementID == edit.id { selectedElementID = nil }
                if liveTailID == edit.id { liveTailID = nil }
                note.elements.remove(at: i)
            } else {
                note.elements[i].text = edit.text
                note.elements[i].rect.size.height = Renderer.textHeight(note.elements[i])
            }
        }
    }

    /// PencilKit's eraser only knows about ink, so typed words under its path are removed here.
    func eraserTouch(_ touch: UITouch, began: Bool) {
        guard tool == .eraser, playing == nil, touch.type == .pencil || fingerDrawing else {
            eraserTrailPoint = nil
            return
        }
        let z = max(canvas.zoomScale, 0.01), location = touch.location(in: canvas)
        let point = CGPoint(x: location.x / z, y: location.y / z)
        if began { eraserUndoRegistered = false }
        let previous = (began ? nil : eraserTrailPoint) ?? point
        eraserTrailPoint = point
        let area = CGRect(x: min(previous.x, point.x), y: min(previous.y, point.y), width: abs(previous.x - point.x), height: abs(previous.y - point.y)).insetBy(dx: -6, dy: -6)
        let edits = textEdits(crossing: area)
        guard !edits.isEmpty else { return }
        if !eraserUndoRegistered {
            checkpoint()
            eraserUndoRegistered = true
        }
        apply(edits)
        syncElements()
        scheduleSave()
    }

    func scribbleErase(_ stroke: PKStroke) -> Bool {
        let strokes = canvas.drawing.strokes
        guard strokes.last?.path.creationDate == stroke.path.creationDate,
              Scribble.isScribble(stroke.path.map(\.location)) else { return false }
        let area = stroke.renderBounds
        let kept = strokes.dropLast().filter { !$0.renderBounds.intersects(area) }
        let edits = textEdits(crossing: area)
        guard kept.count < strokes.count - 1 || !edits.isEmpty else { return false } // covered nothing, so it's just a mark

        setInk(PKDrawing(strokes: Array(kept)))
        apply(edits)
        liveSince = max(liveSince, stroke.path.creationDate)
        syncElements()
        scheduleSave()
        return true
    }

    /// Reading a page's words takes long enough to catch the next stroke, so it happens off the main thread.
    func snapHighlight(_ stroke: PKStroke) {
        let heights = note.pages.map(\.height)
        let index = NoteLayout.pageIndex(y: stroke.renderBounds.midY, heights: heights)
        guard note.pages.indices.contains(index), let pdfIndex = note.pages[index].pdfPage,
              let first = stroke.path.first?.location.applying(stroke.transform),
              let last = stroke.path.last?.location.applying(stroke.transform) else { return }
        let origin = NoteLayout.origins(heights)[index], url = library.pdfURL(note.id), pageID = note.pages[index].id
        let mark = highlightMark, date = stroke.path.creationDate

        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                Self.selectedWords(in: url, page: pdfIndex, from: first, to: last, pageTop: origin)
            }.value
            guard let self, let found else { return }
            let strokes = self.canvas.drawing.strokes
            guard strokes.contains(where: { $0.path.creationDate == date }) else { return } // undone in the meantime
            self.keepExcerpt(Excerpt(text: found.text, pageID: pageID, rect: stroke.renderBounds))
            // A highlight stays exactly as drawn, while underlines and the like only make sense along the words.
            if mark != .highlight || Prefs.snapHighlights {
                self.placeMark(mark, along: found.lines, replacing: stroke, in: strokes)
            }
            self.scheduleSave()
        }
    }

    /// Going over the same words again refines the excerpt rather than adding another.
    private func keepExcerpt(_ excerpt: Excerpt) {
        if let i = note.excerpts.indices.last, note.excerpts[i].pageID == excerpt.pageID, let previous = note.excerpts[i].text, let text = excerpt.text {
            if previous.contains(text) { return }
            if text.contains(previous) {
                note.excerpts[i] = excerpt
                return
            }
        }
        note.excerpts.append(excerpt)
    }

    private nonisolated static func selectedWords(in url: URL, page pdfIndex: Int, from first: CGPoint, to last: CGPoint, pageTop origin: CGFloat) -> (text: String, lines: [CGRect])? {
        guard let page = PDFDocument(url: url)?.page(at: pdfIndex) else { return nil }
        let toBox = page.transform(for: .cropBox), fromBox = toBox.inverted()
        var box = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { box = CGSize(width: box.height, height: box.width) }
        let scale = NoteLayout.width / max(box.width, 1)
        func toPDF(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x / scale, y: box.height - (p.y - origin) / scale).applying(fromBox)
        }
        guard let touched = page.selection(from: toPDF(first), to: toPDF(last)), let selection = wholeWords(of: touched, on: page) else { return nil }
        let byLine = selection.selectionsByLine()
        let text = byLine.compactMap(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.filter(\.isLetter).count >= 3 else { return nil } // a stray dot or a stroke across an equation's symbols
        let lines: [CGRect] = byLine.compactMap { line in
            let r = line.bounds(for: page).applying(toBox)
            guard r.width > 1 else { return nil }
            return CGRect(x: r.minX * scale, y: origin + (box.height - r.maxY) * scale, width: r.width * scale, height: r.height * scale)
        }
        return (text, lines)
    }

    /// A pen rarely starts and stops on a word's edge, and half a word is no use as an excerpt.
    private nonisolated static func wholeWords(of selection: PDFSelection, on page: PDFPage) -> PDFSelection? {
        guard let text = page.string as NSString?, selection.numberOfTextRanges(on: page) > 0 else { return nil }
        var range = selection.range(at: 0, on: page)
        for i in 1..<max(selection.numberOfTextRanges(on: page), 1) {
            range = NSUnionRange(range, selection.range(at: i, on: page))
        }
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length, range.length > 0 else { return nil }
        let letters = CharacterSet.alphanumerics
        func isLetter(_ i: Int) -> Bool { UnicodeScalar(text.character(at: i)).map(letters.contains) ?? false }
        while range.location > 0, isLetter(range.location - 1), isLetter(range.location) {
            range.location -= 1
            range.length += 1
        }
        while NSMaxRange(range) < text.length, isLetter(NSMaxRange(range)), isLetter(NSMaxRange(range) - 1) {
            range.length += 1
        }
        return page.selection(for: range)
    }

    private func placeMark(_ mark: HighlightMark, along rects: [CGRect], replacing stroke: PKStroke, in current: [PKStroke]) {
        var strokes = current
        guard strokes.last?.path.creationDate == stroke.path.creationDate else { return }
        let lines: [PKStroke] = rects.map { r in
            let top = r.minY, height = r.height, left = r.minX, right = r.maxX
            let date = stroke.path.creationDate
            func make(_ ink: PKInk, _ path: [CGPoint], size: CGFloat) -> PKStroke {
                let points = path.enumerated().map { i, p in
                    PKStrokePoint(location: p, timeOffset: Double(i) * 0.02, size: CGSize(width: size, height: size), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: date))
            }
            // Highlighter colors are too pale to read as a thin line, so these marks use a deeper shade.
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            stroke.ink.color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            let thin = PKInk(.pen, color: UIColor(hue: hue, saturation: saturation, brightness: brightness * 0.75, alpha: 1))
            switch mark {
            case .highlight:
                return make(stroke.ink, [CGPoint(x: left, y: top + height / 2), CGPoint(x: right, y: top + height / 2)], size: height * 1.6) // a marker lays down about 60% of its size
            case .underline:
                return make(thin, [CGPoint(x: left, y: top + height), CGPoint(x: right, y: top + height)], size: 3)
            case .strikeout:
                return make(thin, [CGPoint(x: left, y: top + height / 2), CGPoint(x: right, y: top + height / 2)], size: 3)
            case .squiggle:
                return make(thin, ShapeSnap.squiggle(fromX: left, toX: right, y: top + height), size: 2.5)
            }
        }
        guard !lines.isEmpty else { return }
        strokes.removeLast()
        strokes += lines
        setInk(PKDrawing(strokes: strokes))
    }

    /// PencilKit has no dashed ink, so a finished stroke is cut into dashes along its path.
    func cutIntoDashes(_ stroke: PKStroke) {
        var strokes = canvas.drawing.strokes
        guard strokes.last?.path.creationDate == stroke.path.creationDate else { return }
        let points = Array(stroke.path.interpolatedPoints(by: .distance(2)))
        let dash = max(Int(penWidth * 2.5), 5), gap = max(Int(penWidth * 1.5), 4)
        guard points.count > dash + gap else { return }
        var dashes: [PKStroke] = []
        for start in stride(from: 0, to: points.count, by: dash + gap) {
            let piece = Array(points[start..<min(start + dash, points.count)])
            guard piece.count > 1 else { continue }
            dashes.append(PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: piece, creationDate: stroke.path.creationDate), transform: stroke.transform))
        }
        strokes.removeLast()
        setInk(PKDrawing(strokes: strokes + dashes))
    }

    // MARK: Ask AI

    func askAI(_ mode: AskMode) {
        guard let rect = regionRect else { return }
        askTask?.cancel()
        aiAnswer = AIAnswer(title: mode.rawValue)
        askTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = await self.regionText(rect)
                guard !text.isEmpty else { throw StudyError.emptySelection }
                let answer = try await AI.ask(mode, about: text) { [weak self] partial in
                    Task { @MainActor [weak self] in
                        if self?.aiAnswer?.working == true { self?.aiAnswer?.text = partial }
                    }
                }
                self.aiAnswer?.text = answer
            } catch is CancellationError {
                return
            } catch {
                self.aiAnswer?.failure = error.localizedDescription
            }
            self.aiAnswer?.working = false
        }
    }

    // MARK: Area actions

    private func regionImage(_ rect: CGRect, scale: CGFloat = 3) -> UIImage {
        Renderer.snapshot(note: note, drawing: currentDrawing, rect: rect, dir: library.dir(note.id), scale: scale)
    }

    /// The exact words when the area is on a PDF with real text; otherwise whatever recognition can read.
    private func regionText(_ rect: CGRect) async -> String {
        if let text = pdfText(in: rect), !text.isEmpty, canvas.drawing.strokes.allSatisfy({ !$0.renderBounds.intersects(rect) }) {
            return text
        }
        let image = regionImage(rect)
        return await Task.detached { Renderer.recognize(image) }.value
    }

    private func pdfText(in rect: CGRect) -> String? {
        let heights = note.pages.map(\.height)
        let index = NoteLayout.pageIndex(y: rect.midY, heights: heights)
        guard let pdfIndex = note.pages[index].pdfPage, let page = PDFDocument(url: library.pdfURL(note.id))?.page(at: pdfIndex) else { return nil }
        let box = pageBox(page), scale = NoteLayout.width / max(box.width, 1), origin = NoteLayout.origins(heights)[index]
        let area = CGRect(x: rect.minX / scale, y: box.height - (rect.maxY - origin) / scale, width: rect.width / scale, height: rect.height / scale)
        guard let selection = page.selection(for: area.applying(page.transform(for: .cropBox).inverted())) else { return nil }
        return selection.selectionsByLine().compactMap(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pageBox(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return page.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box
    }

    /// Follows a link in a PDF: web links open in the browser, internal ones jump to their page.
    func followPDFLink(at point: CGPoint) -> Bool {
        let heights = note.pages.map(\.height)
        let index = NoteLayout.pageIndex(y: point.y, heights: heights)
        guard note.pages.indices.contains(index), let pdfIndex = note.pages[index].pdfPage,
              let doc = PDFDocument(url: library.pdfURL(note.id)), let page = doc.page(at: pdfIndex) else { return false }
        let box = pageBox(page), scale = NoteLayout.width / max(box.width, 1), origin = NoteLayout.origins(heights)[index]
        let inPage = CGPoint(x: point.x / scale, y: box.height - (point.y - origin) / scale).applying(page.transform(for: .cropBox).inverted())
        guard let link = page.annotation(at: inPage), link.type == "Link" else { return false }
        if let url = (link.action as? PDFActionURL)?.url ?? link.url {
            UIApplication.shared.open(url)
            return true
        }
        let target = (link.action as? PDFActionGoTo)?.destination.page ?? link.destination?.page
        if let target, let i = note.pages.firstIndex(where: { $0.pdfPage == doc.index(for: target) }) {
            jump(toPage: i)
            return true
        }
        return false
    }

    func addLink(title: String, target: String) {
        checkpoint()
        tool = .text
        let c = visibleCenter()
        var el = Element(rect: CGRect(x: max(c.x - 150, 8), y: c.y, width: 300, height: 30), text: title, fontSize: 18, colorHex: "0A66D8")
        el.link = target
        el.rect.size.height = Renderer.textHeight(el)
        note.elements.append(el)
        syncElements()
        selectedElementID = el.id
        scheduleSave()
    }

    func openLink(_ el: Element) {
        guard let link = el.link else { return }
        if link.hasPrefix("note:") {
            guard let id = UUID(uuidString: String(link.dropFirst(5))), library.notes.contains(where: { $0.id == id && $0.deletedAt == nil }) else {
                message = "The note this links to no longer exists."
                return
            }
            openNoteRequest = id
        } else if let url = URL(string: link.contains("://") ? link : "https://" + link) {
            UIApplication.shared.open(url)
        }
    }

    var selectedElement: Element? { note.elements.first { $0.id == selectedElementID } }

    // MARK: Writing window

    func configureZoomCanvas() {
        zoomCanvas.delegate = self
        zoomCanvas.isOpaque = false
        zoomCanvas.backgroundColor = .clear
        zoomCanvas.overrideUserInterfaceStyle = .light
        zoomCanvas.isScrollEnabled = false
        zoomCanvas.showsVerticalScrollIndicator = false
        zoomCanvas.showsHorizontalScrollIndicator = false
        zoomCanvas.insertSubview(zoomBackground, at: 0)
    }

    func zoomDidToggle() {
        overlay.refreshZoomBox()
        guard zoomOn else { return }
        zoomCanvas.drawing = canvas.drawing
        zoomCanvas.tool = canvas.tool
        let c = visibleCenter()
        zoomRect.origin = CGPoint(x: 40, y: max(c.y - 200, 0))
    }

    func layoutZoom() {
        guard zoomOn, zoomCanvas.bounds.width > 0 else { return }
        zoomRect.size.height = zoomRect.width * zoomCanvas.bounds.height / zoomCanvas.bounds.width
        let z = zoomCanvas.bounds.width / zoomRect.width
        let total = NoteLayout.totalHeight(note.pages.map(\.height))
        zoomCanvas.minimumZoomScale = z
        zoomCanvas.maximumZoomScale = z
        zoomCanvas.zoomScale = z
        zoomCanvas.contentSize = CGSize(width: NoteLayout.width * z, height: total * z)
        zoomCanvas.contentOffset = CGPoint(x: zoomRect.minX * z, y: zoomRect.minY * z)
        zoomBackground.frame = CGRect(x: zoomRect.minX * z, y: zoomRect.minY * z, width: zoomRect.width * z, height: zoomRect.height * z)
        zoomBackground.image = Renderer.snapshot(note: note, drawing: PKDrawing(), rect: zoomRect, dir: library.dir(note.id), scale: z * 2, dark: darkPages)
        overlay.refreshZoomBox()
    }

    func moveZoom(dx: CGFloat, dy: CGFloat) {
        let total = NoteLayout.totalHeight(note.pages.map(\.height))
        zoomRect.origin.x = min(max(zoomRect.minX + dx * zoomRect.width, 0), NoteLayout.width - zoomRect.width)
        zoomRect.origin.y = min(max(zoomRect.minY + dy * zoomRect.height, 0), max(total - zoomRect.height, 0))
        layoutZoom()
        let z = canvas.zoomScale
        canvas.scrollRectToVisible(CGRect(x: zoomRect.minX * z, y: zoomRect.minY * z, width: zoomRect.width * z, height: zoomRect.height * z), animated: true)
    }

    func zoomNextLine() {
        zoomRect.origin.x = 40
        moveZoom(dx: 0, dy: 1)
    }

    /// Keeps the two canvases on one drawing. Returns true when the change came only from this sync.
    func syncZoom(from source: PKCanvasView) -> Bool {
        guard zoomOn else { return false }
        if source === zoomCanvas {
            let wasNew = zoomCanvas.drawing.strokes.count > canvas.drawing.strokes.count
            if canvas.drawing != zoomCanvas.drawing { canvas.drawing = zoomCanvas.drawing }
            if wasNew { scheduleLiveText() }
            if wasNew, let last = zoomCanvas.drawing.strokes.last, last.renderBounds.maxX > zoomRect.maxX - zoomRect.width * 0.15 {
                if zoomRect.maxX >= NoteLayout.width - 1 { zoomNextLine() } else { moveZoom(dx: 0.6, dy: 0) }
            }
            return true
        }
        if zoomCanvas.drawing != canvas.drawing { zoomCanvas.drawing = canvas.drawing }
        return false
    }

    // MARK: Listening

    func toggleReadAloud() {
        if reader.isSpeaking {
            reader.stopSpeaking(at: .immediate)
            return
        }
        Task {
            let text = await studyText(pages: nil)
            guard !text.isEmpty else {
                message = "There's nothing in this note to read yet."
                return
            }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            reader.speak(AVSpeechUtterance(string: text))
        }
    }

    /// Lecture opens recording; Math opens with shape snapping on.
    func apply(_ setup: NoteSetup?) {
        switch setup {
        case .lecture: toggleRecording()
        case .math: snapShapes = true
        case .meeting, nil: break
        }
    }

    func exportPage(_ index: Int) -> URL? {
        saveNow()
        return try? Renderer.exportPDF(note: note, drawing: currentDrawing, dir: library.dir(note.id), onlyPage: index)
    }

    func exportPageImage(_ page: Page) -> URL? {
        guard let image = thumbnail(page, width: 1536), let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(note.title.replacingOccurrences(of: "/", with: "-")) page.png")
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    func importFile(from url: URL) {
        Task {
            await working("Importing…") {
                insertPDF(try await DocumentConverter.pdf(from: url))
            }
        }
    }

    func pdfOutline() async -> [OutlineItem] {
        let url = library.pdfURL(note.id), pages = note.pages
        return await Task.detached(priority: .userInitiated) {
            guard let doc = PDFDocument(url: url), let root = doc.outlineRoot else { return [] }
            let pageForPDF = Dictionary(pages.enumerated().compactMap { i, page in page.pdfPage.map { ($0, i) } }, uniquingKeysWith: { first, _ in first })
            var items: [OutlineItem] = []
            func walk(_ node: PDFOutline, depth: Int) {
                for i in 0..<node.numberOfChildren {
                    guard let child = node.child(at: i) else { continue }
                    if let page = child.destination?.page, let index = pageForPDF[doc.index(for: page)] {
                        items.append(OutlineItem(title: child.label ?? "Untitled", depth: depth, pageIndex: index))
                    }
                    walk(child, depth: depth + 1)
                }
            }
            walk(root, depth: 0)
            return items
        }.value
    }

    private func removeInk(in rect: CGRect) {
        let strokes = canvas.drawing.strokes.filter {
            !rect.contains(CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY))
        }
        setInk(PKDrawing(strokes: strokes))
    }

    private func addText(_ text: String, at rect: CGRect) {
        var el = Element(rect: CGRect(x: rect.minX, y: rect.minY, width: max(rect.width, 200), height: 30), text: text, fontSize: textSize, colorHex: textColor.hex)
        el.rect.size.height = Renderer.textHeight(el)
        note.elements.append(el)
        syncElements()
        scheduleSave()
    }

    private func working(_ label: String, _ work: () async throws -> Void) async {
        busy = label
        defer { busy = nil }
        do {
            try await work()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Handwriting to type

    /// Replaces the given ink with typed text in the same place, at about the same size and in the same color.
    /// Returns false, leaving the ink alone, if nothing could be read with enough confidence.
    @discardableResult
    private func typeset(_ strokes: [PKStroke], font: String, minimumConfidence: Float, live: Bool) async -> Bool {
        guard !strokes.isEmpty else { return false }
        let bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !bounds.isNull, bounds.width > 2 || bounds.height > 2 else { return false }
        // Recognition needs clear space around the writing, and reads a tight crop as nothing.
        let pad = max(bounds.height, 48)
        let area = bounds.insetBy(dx: -pad, dy: -pad)
        let ink = Renderer.inkImage(PKDrawing(strokes: strokes), rect: area, scale: 3)
        let found: [Renderer.RecognizedLine] = await Task.detached(priority: .userInitiated) {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: area.size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: area.size))
                ink.draw(in: CGRect(origin: .zero, size: area.size))
            }
            return Renderer.recognizeLines(image)
        }.value
        let lines = found.filter { $0.confidence >= minimumConfidence && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return false }
        // The pen may have come down, or the ink been undone, while this was being read. Replacing the drawing now would lose a stroke.
        if live, penDown { return false }
        let color = strokes.first?.ink.color.withAlphaComponent(1).hex ?? textColor.hex
        let dates = Set(strokes.map(\.path.creationDate))
        guard canvas.drawing.strokes.contains(where: { dates.contains($0.path.creationDate) }) else { return false }
        checkpoint()
        let kept = canvas.drawing.strokes.filter { !dates.contains($0.path.creationDate) }
        setInk(PKDrawing(strokes: kept))
        for line in lines {
            let rect = CGRect(x: area.minX + line.box.minX * area.width,
                              y: area.minY + (1 - line.box.maxY) * area.height,
                              width: line.box.width * area.width, height: line.box.height * area.height)
            place(line.text, in: rect, font: font, colorHex: color, live: live)
        }
        syncElements()
        scheduleSave()
        return true
    }

    /// Live text picks up where the last word ended, so a sentence written in bursts stays one line of type.
    private func place(_ text: String, in rect: CGRect, font: String, colorHex: String, live: Bool) {
        let size = liveSize > 0 && live ? CGFloat(liveSize) : min(max((rect.height * 0.8).rounded(), 11), 64)
        if live, let id = liveTailID, let i = note.elements.firstIndex(where: { $0.id == id }) {
            let tail = note.elements[i]
            let sameLine = abs(rect.midY - tail.rect.midY) < max(tail.rect.height, rect.height) * 0.7
            let textEnd = tail.rect.minX + (Renderer.attributed(tail).size().width)
            if sameLine, rect.minX >= tail.rect.minX, rect.minX - textEnd < tail.fontSize * 4 {
                // A pause mid-word arrives as a piece right beside the last one, so only a real gap gets a space.
                note.elements[i].text += (rect.minX - textEnd < tail.fontSize * 0.3 ? "" : " ") + text
                let width = Renderer.attributed(note.elements[i]).size().width + tail.fontSize
                note.elements[i].rect.size.width = min(max(width, tail.rect.width), NoteLayout.width - tail.rect.minX)
                note.elements[i].rect.size.height = Renderer.textHeight(note.elements[i])
                return
            }
        }
        var el = Element(rect: CGRect(x: rect.minX, y: rect.minY, width: 100, height: 30), text: text, fontSize: size, colorHex: colorHex, fontName: font)
        let width = Renderer.attributed(el).size().width + size
        el.rect.size.width = min(max(width, 60), NoteLayout.width - rect.minX)
        el.rect.size.height = Renderer.textHeight(el)
        note.elements.append(el)
        if live { liveTailID = el.id }
    }

    /// The box whose line this writing carries on, so words written side by side stay one line of text.
    func liveTextBox(continuing point: CGPoint) -> Element? {
        note.elements.last { el in
            guard el.imageFile == nil, !el.isTape, el.cover == nil, el.comment == nil, !el.stamp, el.link == nil,
                  !el.text.isEmpty, abs(point.y - el.rect.midY) <= max(el.rect.height, el.fontSize * 2) / 2 + el.fontSize * 0.5 else { return false }
            return point.x >= el.rect.minX - el.fontSize && point.x <= Renderer.textEnd(el) + el.fontSize * 6
        }
    }

    /// A new text box for Scribble, starting where the Pencil came down and running to the page edge.
    func addLiveTextBox(at point: CGPoint) -> Element {
        checkpoint()
        let size = liveSize > 0 ? CGFloat(liveSize) : 22
        let x = max(min(point.x, NoteLayout.width - 120), 0)
        var el = Element(rect: CGRect(x: x, y: point.y - size * 0.7, width: NoteLayout.width - x - 12, height: 30),
                         fontSize: size, colorHex: penColor.hex, fontName: liveFont)
        el.rect.size.height = Renderer.textHeight(el)
        note.elements.append(el)
        syncElements()
        return el
    }

    func scheduleLiveText() {
        guard liveText, tool == .pen, !snapShapes, playing == nil else { return }
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled else { return }
            await self?.convertLiveInk()
        }
    }

    private func convertLiveInk() async {
        guard !penDown, liveText else { return }
        // A word written slowly fails in pieces, so unread strokes stay in play and get another try with what follows.
        let since = max(liveSince, Date().addingTimeInterval(-20))
        let pending = canvas.drawing.strokes.filter { $0.path.creationDate > since }
        guard let newest = pending.map(\.path.creationDate).max() else { return }
        if await typeset(pending, font: liveFont, minimumConfidence: 0.3, live: true) { liveSince = newest }
    }

    func convertRegionToFont(_ font: String) async {
        guard let rect = regionRect else { return }
        let strokes = canvas.drawing.strokes.filter { rect.contains(CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY)) }
        guard !strokes.isEmpty else {
            message = "There's no handwriting in that area."
            return
        }
        await working("Converting…") {
            if await typeset(strokes, font: font, minimumConfidence: 0, live: false) {
                regionRect = nil
            } else {
                message = "No handwriting could be read in that area."
            }
        }
    }

    func convertPageToFont(_ index: Int, font: String) async {
        let rect = Renderer.rects(for: note)[index]
        let strokes = canvas.drawing.strokes.filter { rect.contains(CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY)) }
        guard !strokes.isEmpty else {
            message = "There's no handwriting on that page."
            return
        }
        await working("Converting…") {
            if !(await typeset(strokes, font: font, minimumConfidence: 0, live: false)) {
                message = "No handwriting could be read on that page."
            }
        }
    }

    // MARK: PDF annotation

    func finishAnnotation(from a: CGPoint, to b: CGPoint) {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard hypot(rect.width, rect.height) > 8 else { return }
        switch annotateKind {
        case .arrow: addInk(.arrow(a, b))
        case .line: addInk(.line(a, b))
        case .box: addInk(.rectangle(rect))
        case .oval: addInk(.ellipse(rect))
        case .area:
            checkpoint()
            let size = CGSize(width: rect.height, height: rect.height)
            let points = [rect.minX, rect.maxX].enumerated().map { i, x in
                PKStrokePoint(location: CGPoint(x: x, y: rect.midY), timeOffset: Double(i) * 0.05, size: size, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            appendStroke(PKStroke(ink: PKInk(.marker, color: highlightInk), path: PKStrokePath(controlPoints: points, creationDate: Date())))
        case .whiteout, .redact:
            checkpoint()
            note.elements.append(Element(rect: rect, cover: annotateKind == .redact ? "redact" : "whiteout"))
            syncElements()
            scheduleSave()
        case .comment:
            break
        }
    }

    private func addInk(_ shape: SnappedShape) {
        checkpoint()
        let points = ShapeSnap.outline(shape).enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        appendStroke(PKStroke(ink: PKInk(.pen, color: annotateColor), path: PKStrokePath(controlPoints: points, creationDate: Date())))
    }

    private func appendStroke(_ stroke: PKStroke) {
        let strokes = canvas.drawing.strokes + [stroke]
        setInk(PKDrawing(strokes: strokes))
        scheduleSave()
    }

    func addComment(at point: CGPoint) {
        checkpoint()
        let el = Element(rect: CGRect(x: point.x - 16, y: point.y - 16, width: 34, height: 34), text: "💬", fontSize: 24, comment: "")
        note.elements.append(el)
        syncElements()
        commentEditingID = el.id
    }

    func finishComment(_ text: String) {
        guard let id = commentEditingID else { return }
        commentEditingID = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            removeElement(id)
        } else {
            updateElement(id) { $0.comment = trimmed }
        }
    }

    func addStamp(_ text: String, colorHex: String) {
        checkpoint()
        tool = .text
        let c = visibleCenter()
        var el = Element(rect: CGRect(x: 0, y: c.y, width: 100, height: 40), text: text, fontSize: 22, colorHex: colorHex, bold: true, stamp: true)
        el.rect.size.width = Renderer.attributed(el).size().width + 28
        el.rect.origin.x = max(c.x - el.rect.width / 2, 0)
        el.rect.size.height = Renderer.textHeight(el)
        note.elements.append(el)
        syncElements()
        selectedElementID = el.id
        scheduleSave()
    }

    func saveSignature(_ drawing: PKDrawing) {
        guard !drawing.strokes.isEmpty else {
            message = "Sign in the box first."
            return
        }
        let image = Renderer.inkImage(drawing, rect: drawing.bounds.insetBy(dx: -6, dy: -6), scale: 3)
        do {
            try image.pngData()?.write(to: library.signatureURL, options: .atomic)
            insertSignature()
        } catch {
            message = "Couldn't save your signature: \(error.localizedDescription)"
        }
    }

    func insertSignature() {
        guard let data = try? Data(contentsOf: library.signatureURL) else { return }
        addImage(data, transparent: true)
    }

    func duplicatePage(_ index: Int) {
        guard note.pages.indices.contains(index) else { return }
        let source = Renderer.rects(for: note)[index], distance = source.height + NoteLayout.gap
        var copy = note.pages[index]
        copy.id = UUID()
        copy.bookmarked = false
        var pages = note.pages
        pages.insert(copy, at: index + 1)
        setPages(pages)
        let onPage = canvas.drawing.strokes.filter { source.contains(CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY)) }
        let moved = onPage.map { stroke -> PKStroke in
            var stroke = stroke
            stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: 0, y: distance))
            return stroke
        }
        setInk(PKDrawing(strokes: canvas.drawing.strokes + moved))
        note.elements += note.elements.filter { source.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }.map { el in
            var el = el
            el.id = UUID()
            el.rect.origin.y += distance
            return el
        }
        syncElements()
        scheduleSave()
    }

    func insertBlankPage(after index: Int) {
        var pages = note.pages
        let paper = pages[...index].last { $0.pdfPage == nil }
        pages.insert(paper.map { Page(height: $0.height, style: $0.style, color: $0.color) } ?? Prefs.newPage(), at: index + 1)
        setPages(pages)
    }

    /// Without the writing model, this still gives the recognised text, just without the cleanup and LaTeX.
    func convertRegionToMath() async {
        guard let rect = regionRect else { return }
        await working("Reading math…") {
            let text = await regionText(rect)
            guard !text.isEmpty else {
                message = "No math was found in that area."
                return
            }
            var clean = text
            if AI.isAvailable {
                let math = try await AI.math(fromRecognized: text)
                clean = math.unicode
                UIPasteboard.general.string = math.latex
                notify("Converted. The LaTeX is on your clipboard.")
            }
            checkpoint()
            removeInk(in: rect)
            addText(clean, at: rect)
            regionRect = nil
        }
    }

    func solveRegion() async {
        guard let rect = regionRect else { return }
        await working("Solving…") {
            let text = await regionText(rect)
            var answer = Calc.evaluate(text).map { $0.formatted(.number.precision(.significantDigits(1...10))) }
            if answer == nil, AI.isAvailable, !text.isEmpty {
                answer = try await AI.solve(text)
            }
            guard let answer else {
                message = "Couldn't read that as a calculation. It read as: \(text.isEmpty ? "(nothing)" : text)"
                return
            }
            checkpoint()
            addText("= \(answer)", at: CGRect(x: min(rect.maxX + 8, NoteLayout.width - 208), y: rect.midY - 14, width: 200, height: 30))
            regionRect = nil
        }
    }

    func translateRegion(to language: String) async {
        guard let rect = regionRect else { return }
        await working("Translating…") {
            let text = await regionText(rect)
            guard !text.isEmpty else {
                message = "No text was found in that area."
                return
            }
            let translation = try await AI.translate(text, to: language)
            checkpoint()
            addText(translation, at: CGRect(x: rect.minX, y: rect.maxY + 8, width: max(rect.width, 200), height: 30))
            regionRect = nil
        }
    }

    func insertMindMap(_ root: MindNode) {
        guard let data = Renderer.mindMap(root).pngData() else { return }
        addImage(data)
    }

    func regionExpression() async -> String {
        guard let rect = regionRect else { return "" }
        return await regionText(rect)
    }

    func insertGraph(_ expression: String) -> Bool {
        guard let image = Renderer.plot(expression), let data = image.pngData() else { return false }
        let at = regionRect
        addImage(data)
        if let at, let id = selectedElementID {
            updateElement(id) { $0.rect.origin = CGPoint(x: at.minX, y: at.maxY + 8) }
            overlay.refreshSelection()
        }
        regionRect = nil
        return true
    }

    func copyRegionText() async {
        guard let rect = regionRect else { return }
        await working("Reading…") {
            let text = await regionText(rect)
            UIPasteboard.general.string = text
            if text.isEmpty { message = "No text was found in that area." } else { notify("Copied") }
        }
    }

    private func saveRegionImage(_ rect: CGRect) -> String? {
        let file = "clip-\(UUID().uuidString).png"
        guard let data = regionImage(rect).pngData(),
              (try? data.write(to: library.dir(note.id).appendingPathComponent(file), options: .atomic)) != nil else {
            message = "Couldn't save that area."
            return nil
        }
        return file
    }

    func regionToFlashcard(back: String) {
        guard let rect = regionRect, let file = saveRegionImage(rect) else { return }
        note.flashcards.append(Flashcard(front: "", back: back, frontImage: file))
        notify("Card added. Write its answer under Study › Flashcards.")
        regionRect = nil
        scheduleSave()
    }

    func regionToExcerpt() {
        guard let rect = regionRect, let file = saveRegionImage(rect) else { return }
        checkpoint()
        let index = NoteLayout.pageIndex(y: rect.midY, heights: note.pages.map(\.height))
        note.excerpts.append(Excerpt(imageFile: file, pageID: note.pages[index].id, rect: rect))
        regionRect = nil
        scheduleSave()
        notify("Saved to Excerpts")
    }

    func image(named file: String) -> UIImage? {
        UIImage(contentsOfFile: library.dir(note.id).appendingPathComponent(file).path)
    }

    func jump(to rect: CGRect) {
        let z = canvas.zoomScale
        let y = max(0, min(rect.minY * z - 80, canvas.contentSize.height - canvas.bounds.height))
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: true)
    }

    func jump(toPage index: Int) {
        let rects = Renderer.rects(for: note)
        if rects.indices.contains(index) { jump(to: rects[index]) }
    }

    /// The picture of an excerpt stays in the note's folder, since undo can bring the excerpt back.
    func deleteExcerpt(_ excerpt: Excerpt) {
        checkpoint()
        note.excerpts.removeAll { $0.id == excerpt.id }
        scheduleSave()
    }

    func deleteAllExcerpts() {
        checkpoint()
        note.excerpts.removeAll()
        scheduleSave()
    }

    // MARK: Images

    func cutOutSubject(_ id: UUID) async {
        guard let file = note.elements.first(where: { $0.id == id })?.imageFile else { return }
        let source = library.dir(note.id).appendingPathComponent(file)
        await working("Cutting out…") {
            let png = try await Task.detached(priority: .userInitiated) { try Renderer.subjectCutout(of: source) }.value
            let name = "img-\(UUID().uuidString).png"
            try png.write(to: library.dir(note.id).appendingPathComponent(name), options: .atomic)
            checkpoint()
            updateElement(id) { $0.imageFile = name }
            overlay.refreshSelection()
        }
    }

    func saveAsSticker(_ id: UUID) {
        guard let file = note.elements.first(where: { $0.id == id })?.imageFile, let image = image(named: file), let png = image.pngData() else { return }
        do {
            try library.saveSticker(png)
            notify("Saved to My Stickers")
        } catch {
            message = "Couldn't save the sticker: \(error.localizedDescription)"
        }
    }

    // MARK: Text, stickers, sticky notes

    func insertText(_ text: String) {
        checkpoint()
        let c = visibleCenter()
        let rect = CGRect(x: 48, y: max(c.y - 200, 8), width: NoteLayout.width - 96, height: 30)
        // Over a PDF's own text, only a filled note stays readable.
        if note.pages[NoteLayout.pageIndex(y: c.y, heights: note.pages.map(\.height))].pdfPage != nil {
            tool = .text
            addTextElement(Element(rect: rect, text: text, fontSize: 18, colorHex: "1C1C1E", fillHex: "FFE98A"))
        } else {
            addText(text, at: rect)
        }
    }

    func addSticker(_ emoji: String) {
        checkpoint()
        let c = visibleCenter()
        addTextElement(Element(rect: CGRect(x: c.x - 48, y: c.y - 48, width: 96, height: 96), text: emoji, fontSize: 72))
    }

    func addStickyNote() {
        checkpoint()
        let c = visibleCenter()
        tool = .text
        addTextElement(Element(rect: CGRect(x: c.x - 120, y: c.y - 70, width: 240, height: 140), text: "Note", fontSize: 18, colorHex: "1C1C1E", fillHex: "FFE98A"))
    }

    private func addTextElement(_ el: Element) {
        var el = el
        el.rect.size.height = max(el.rect.height, Renderer.textHeight(el))
        note.elements.append(el)
        syncElements()
        scheduleSave()
    }

    // MARK: Study tape

    func addTape(_ rect: CGRect) {
        checkpoint()
        note.elements.append(Element(rect: rect, colorHex: UserDefaults.standard.string(forKey: "tapeColor") ?? "5B8DEF", isTape: true))
        syncElements()
        scheduleSave()
    }

    func setAllTape(revealed: Bool) {
        for i in note.elements.indices where note.elements[i].isTape { note.elements[i].revealed = revealed }
        syncElements()
        scheduleSave()
    }

    func removeAllTape() {
        checkpoint()
        note.elements.removeAll(where: \.isTape)
        syncElements()
        scheduleSave()
    }

    var hasTape: Bool { note.elements.contains(where: \.isTape) }

    // MARK: Flashcards

    var dueCards: [Library.DueCard] {
        note.flashcards.filter { $0.due <= Date() }.map { Library.DueCard(noteID: note.id, card: $0) }
    }

    func grade(_ due: Library.DueCard, _ grade: SM2.Grade) {
        guard let i = note.flashcards.firstIndex(where: { $0.id == due.card.id }) else { return }
        note.flashcards[i].apply(grade)
        scheduleSave()
    }

    // MARK: Paper

    func setBackgroundImage(_ data: Data, for page: Page) {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9),
              let i = note.pages.firstIndex(of: page) else {
            message = "That image couldn't be read."
            return
        }
        let file = "paper-\(UUID().uuidString).jpg"
        guard (try? jpeg.write(to: library.dir(note.id).appendingPathComponent(file), options: .atomic)) != nil else {
            message = "Couldn't save that template."
            return
        }
        var pages = note.pages
        pages[i].backgroundFile = file
        pages[i].height = NoteLayout.width * image.size.height / max(image.size.width, 1)
        setPages(pages)
    }

    // MARK: PDF contents

    struct OutlineItem: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let depth: Int
        let pageIndex: Int
    }

    // MARK: Find

    func pageTexts() async -> [String] {
        let note = note, drawing = currentDrawing, library = library
        return await Task.detached {
            let printed = library.pdfPageText(of: note)
            let rects = Renderer.rects(for: note)
            return note.pages.indices.map { i in
                autoreleasepool {
                    let text = note.pages[i].pdfPage.flatMap { printed[$0] } ?? ""
                    let ink = Renderer.recognizeInk(drawing, rect: rects[i])
                    let typed = note.elements.filter { $0.rect.intersects(rects[i]) }.map(\.text).joined(separator: "\n")
                    return [text, ink, typed].joined(separator: "\n")
                }
            }
        }.value
    }

    // MARK: Versions

    func restore(_ version: Library.Version) {
        guard let saved = library.readVersion(version) else {
            message = "That version couldn't be read."
            return
        }
        saveNow()
        library.snapshot(note.id) // the state you're leaving is itself a version
        var restored = saved.note
        restored.id = note.id
        note = restored
        setInk(saved.drawing)
        clearHistory()
        selectedElementID = nil
        rebuildPages()
        syncElements()
        inkChanged = true
        saveNow()
    }

    // MARK: Audio files

    func importAudio(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = "rec-\(UUID().uuidString).\(url.pathExtension)"
        let target = library.dir(note.id).appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: library.dir(note.id), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            let player = try AVAudioPlayer(contentsOf: target)
            let rec = Recording(file: file, startedAt: Date(), duration: player.duration)
            note.recordings.append(rec)
            saveNow()
            transcribe(rec)
        } catch {
            try? FileManager.default.removeItem(at: target)
            message = "Couldn't import that audio: \(error.localizedDescription)"
        }
    }

    func audioURL(_ rec: Recording) -> URL { library.dir(note.id).appendingPathComponent(rec.file) }
}
