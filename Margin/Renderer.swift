import PencilKit
import UIKit
import Vision

enum Renderer {
    static func drawBackground(_ page: Page, pdf: CGPDFDocument?, image: UIImage? = nil, size: CGSize, dark: Bool = false, in ctx: CGContext) {
        let area = CGRect(origin: .zero, size: size)
        if let index = page.pdfPage {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(area)
            if let pdfPage = pdf?.page(at: index + 1) { drawPDF(pdfPage, size: size, in: ctx) }
            if dark { invert(area, in: ctx) }
            return
        }
        ctx.setFillColor(page.color.fill(dark: dark).cgColor)
        ctx.fill(area)
        if let image {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(area)
            image.draw(in: area)
            if dark { invert(area, in: ctx) }
            return
        }
        PaperArt(ctx: ctx, size: size, lineColor: page.color.line(dark: dark), labelColor: page.color.label(dark: dark)).draw(page.style)
    }

    private static func invert(_ area: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setBlendMode(.difference)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(area)
        ctx.restoreGState()
    }

    static func paperThumbnail(_ style: PaperStyle, color: PaperColor) -> UIImage {
        let scale: CGFloat = 0.2, size = CGSize(width: NoteLayout.width, height: NoteLayout.paperHeight)
        return UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale)).image { renderer in
            let ctx = renderer.cgContext
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(color.fill(dark: false).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            // Page lines are hairlines; at this size they need more weight to show the design.
            PaperArt(ctx: ctx, size: size, lineColor: color.line(dark: false).withAlphaComponent(0.75), labelColor: color.label(dark: false)).draw(style)
        }
    }

    /// CGPDFPage.getDrawingTransform never scales up, so scale from the page's native size by hand.
    private static func drawPDF(_ page: CGPDFPage, size: CGSize, in ctx: CGContext) {
        var native = page.getBoxRect(.cropBox).size
        if page.rotationAngle % 180 != 0 { native = CGSize(width: native.height, height: native.width) }
        guard native.width > 0 else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / native.width, y: -size.width / native.width)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: native), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    static func font(_ el: Element) -> UIFont {
        let design: UIFontDescriptor.SystemDesign? = switch el.fontName {
        case "sans": .default
        case "serif": .serif
        case "mono": .monospaced
        case "rounded": .rounded
        default: nil
        }
        if let design {
            let base = UIFont.systemFont(ofSize: el.fontSize, weight: el.bold ? .bold : .regular)
            return base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: el.fontSize) } ?? base
        }
        var descriptor = UIFontDescriptor(fontAttributes: [.family: el.fontName])
        if el.bold { descriptor = descriptor.withSymbolicTraits(.traitBold) ?? descriptor }
        return UIFont(descriptor: descriptor, size: el.fontSize)
    }

    static func textColor(_ el: Element, dark: Bool) -> UIColor {
        let color = UIColor(hex: el.colorHex)
        return dark && el.fillHex == nil ? color.forDarkPage : color
    }

    static func attributed(_ el: Element, dark: Bool = false) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(el), .foregroundColor: textColor(el, dark: dark)]
        if el.link != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: el.text, attributes: attributes)
    }

    /// The element's text without the words touched by `area` (note coordinates).
    static func textRemovingWords(of el: Element, crossing area: CGRect) -> String {
        let storage = NSTextStorage(attributedString: attributed(el))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: el.rect.width - el.inset * 2, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        let text = el.text
        var doomed: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { _, range, _, _ in
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(range, in: text), actualCharacterRange: nil)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: el.rect.minX + el.inset, dy: el.rect.minY + el.inset)
            if box.intersects(area) { doomed.append(range) }
        }
        var result = text
        for range in doomed.reversed() {
            var end = range.upperBound
            if end < result.endIndex, result[end] == " " { end = result.index(after: end) }
            result.removeSubrange(range.lowerBound..<end)
        }
        // Stickers aren't words, and leftover punctuation isn't worth keeping.
        if doomed.isEmpty, !text.contains(where: { $0.isLetter || $0.isNumber }) { return "" }
        guard result.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the box's text stops on the page, horizontally.
    static func textEnd(_ el: Element) -> CGFloat {
        let width = attributed(el).boundingRect(with: CGSize(width: el.rect.width - el.inset * 2, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width
        return el.rect.minX + el.inset + ceil(width)
    }

    static func textHeight(_ el: Element) -> CGFloat {
        let probe = el.text.isEmpty ? NSAttributedString(string: " ", attributes: [.font: font(el)]) : attributed(el)
        let width = el.rect.width - el.inset * 2
        let measured = ceil(probe.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height) + 2 + el.inset * 2
        return el.fillHex == nil ? measured : max(measured, el.rect.height) // a sticky note keeps its size until the text outgrows it
    }

    static func drawText(_ el: Element, in box: CGRect, dark: Bool = false, ctx: CGContext) {
        if let fill = el.fillHex {
            ctx.setFillColor(UIColor(hex: fill).cgColor)
            ctx.fill(box)
        }
        if el.stamp {
            ctx.setStrokeColor(textColor(el, dark: dark).cgColor)
            ctx.setLineWidth(2.5)
            ctx.stroke(box.insetBy(dx: 1.5, dy: 1.5))
        }
        attributed(el, dark: dark).draw(with: box.insetBy(dx: el.inset, dy: el.inset), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    /// PencilKit resolves ink for the current trait, so pin light to keep the colours the user picked.
    static func inkImage(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        return image
    }

    static func rects(for note: Note) -> [CGRect] {
        let heights = note.pages.map(\.height)
        return zip(NoteLayout.origins(heights), heights).map { CGRect(x: 0, y: $0, width: NoteLayout.width, height: $1) }
    }

    private static func draw(_ page: Page, rect: CGRect, note: Note, drawing: PKDrawing, pdf: CGPDFDocument?, dir: URL, inkScale: CGFloat, in ctx: CGContext) {
        let background = page.backgroundFile.flatMap { UIImage(contentsOfFile: dir.appendingPathComponent($0).path) }
        drawBackground(page, pdf: pdf, image: background, size: rect.size, in: ctx)
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: rect.size))
        ctx.translateBy(x: 0, y: -rect.minY)
        for el in note.elements where el.rect.intersects(rect) && !el.isTape && el.cover == nil {
            if let file = el.imageFile {
                UIImage(contentsOfFile: dir.appendingPathComponent(file).path)?.draw(in: el.rect)
            } else {
                drawText(el, in: el.rect, ctx: ctx)
            }
        }
        ctx.restoreGState()
        inkImage(drawing, rect: rect, scale: inkScale).draw(in: CGRect(origin: .zero, size: rect.size))
        for el in note.elements where el.rect.intersects(rect) {
            guard let cover = el.cover else { continue }
            ctx.setFillColor((cover == "redact" ? UIColor.black : UIColor.white).cgColor)
            ctx.fill(el.rect.offsetBy(dx: 0, dy: -rect.minY))
        }
    }

    static func exportPDF(note: Note, drawing: PKDrawing, dir: URL, onlyPage: Int? = nil) throws -> URL {
        let pdf = CGPDFDocument(dir.appendingPathComponent("source.pdf") as CFURL)
        var pairs = Array(zip(note.pages, rects(for: note)))
        if let onlyPage { pairs = [pairs[onlyPage]] }
        while pairs.count > 1, let (page, rect) = pairs.last, page.pdfPage == nil,
              !drawing.strokes.contains(where: { $0.renderBounds.intersects(rect) }),
              !note.elements.contains(where: { $0.rect.intersects(rect) && !$0.isTape }) {
            pairs.removeLast()
        }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: NoteLayout.width, height: NoteLayout.paperHeight)).pdfData { ctx in
            for (page, rect) in pairs {
                autoreleasepool {
                    ctx.beginPage(withBounds: CGRect(origin: .zero, size: rect.size), pageInfo: [:])
                    // A covered page goes out as a flat image, so the hidden text can't be selected or copied out of the PDF.
                    if note.elements.contains(where: { $0.cover != nil && $0.rect.intersects(rect) }) {
                        snapshot(note: note, drawing: drawing, rect: rect, dir: dir, scale: 3).draw(in: CGRect(origin: .zero, size: rect.size))
                    } else {
                        draw(page, rect: rect, note: note, drawing: drawing, pdf: pdf, dir: dir, inkScale: 3, in: ctx.cgContext)
                    }
                }
            }
        }
        let name = note.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.isEmpty ? "Note" : name).appendingPathExtension("pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func thumbnail(page: Page, index: Int, note: Note, drawing: PKDrawing, pdf: CGPDFDocument?, dir: URL, width: CGFloat) -> UIImage {
        let rect = rects(for: note)[index]
        let scale = width / NoteLayout.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: rect.height * scale), format: format).image { ctx in
            ctx.cgContext.scaleBy(x: scale, y: scale)
            draw(page, rect: rect, note: note, drawing: drawing, pdf: pdf, dir: dir, inkScale: max(scale * 2, 0.5), in: ctx.cgContext)
        }
    }

    static func snapshot(note: Note, drawing: PKDrawing, rect: CGRect, dir: URL, scale: CGFloat = 2, dark: Bool = false) -> UIImage {
        let pdf = CGPDFDocument(dir.appendingPathComponent("source.pdf") as CFURL)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            for (page, pageRect) in zip(note.pages, rects(for: note)) where pageRect.intersects(rect) {
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: pageRect.minX - rect.minX, y: pageRect.minY - rect.minY)
                if dark {
                    drawBackground(page, pdf: pdf, size: pageRect.size, dark: true, in: ctx.cgContext)
                } else {
                    draw(page, rect: pageRect, note: note, drawing: drawing, pdf: pdf, dir: dir, inkScale: scale, in: ctx.cgContext)
                }
                ctx.cgContext.restoreGState()
            }
        }
    }

    static func plot(_ expression: String, xRange: ClosedRange<Double> = -10...10) -> UIImage? {
        guard Calc.evaluate(expression, x: 1) != nil || Calc.evaluate(expression, x: 2) != nil else { return nil }
        let size = CGSize(width: 480, height: 360), n = 480
        let samples: [(Double, Double?)] = (0...n).map { i in
            let x = xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * Double(i) / Double(n)
            return (x, Calc.evaluate(expression, x: x))
        }
        // Clip wild values (tan, 1/x) so the curve's normal range stays readable.
        let ys = samples.compactMap(\.1).sorted()
        guard ys.count > 1 else { return nil }
        var low = ys[ys.count / 20], high = ys[ys.count - 1 - ys.count / 20]
        if high - low < 1e-6 { low -= 1; high += 1 }
        let pad = (high - low) * 0.1
        low -= pad
        high += pad
        func px(_ x: Double) -> CGFloat { CGFloat((x - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound)) * size.width }
        func py(_ y: Double) -> CGFloat { size.height - CGFloat((y - low) / (high - low)) * size.height }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let ctx = renderer.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
            for x in stride(from: xRange.lowerBound, through: xRange.upperBound, by: 2) {
                ctx.move(to: CGPoint(x: px(x), y: 0))
                ctx.addLine(to: CGPoint(x: px(x), y: size.height))
            }
            ctx.strokePath()
            ctx.setStrokeColor(UIColor(white: 0.35, alpha: 1).cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: px(0), y: 0))
            ctx.addLine(to: CGPoint(x: px(0), y: size.height))
            if low < 0, high > 0 {
                ctx.move(to: CGPoint(x: 0, y: py(0)))
                ctx.addLine(to: CGPoint(x: size.width, y: py(0)))
            }
            ctx.strokePath()

            ctx.setStrokeColor(UIColor.systemRed.cgColor)
            ctx.setLineWidth(2.5)
            var drawing = false
            var previous: Double?
            for (x, y) in samples {
                guard let y, y >= low - (high - low), y <= high + (high - low) else {
                    drawing = false
                    previous = nil
                    continue
                }
                if drawing, let previous, abs(y - previous) < high - low {
                    ctx.addLine(to: CGPoint(x: px(x), y: py(y)))
                } else {
                    ctx.move(to: CGPoint(x: px(x), y: py(y)))
                }
                drawing = true
                previous = y
            }
            ctx.strokePath()

            NSAttributedString(string: "y = " + Calc.body(expression), attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.black,
            ]).draw(at: CGPoint(x: 10, y: 8))
        }
    }

    /// Lays a mind map out left to right, each branch taking the height its leaves need.
    static func mindMap(_ root: MindNode) -> UIImage {
        let rowHeight: CGFloat = 44, columnWidth: CGFloat = 240, boxWidth: CGFloat = 200, boxHeight: CGFloat = 34
        func leaves(_ node: MindNode) -> Int { max((node.children ?? []).map(leaves).reduce(0, +), 1) }
        func depth(_ node: MindNode) -> Int { 1 + ((node.children ?? []).map(depth).max() ?? 0) }
        let size = CGSize(width: CGFloat(depth(root)) * columnWidth, height: CGFloat(leaves(root)) * rowHeight + 16)
        let colors: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal]

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let ctx = renderer.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            func draw(_ node: MindNode, column: Int, top: CGFloat, color: UIColor) -> CGPoint {
                let height = CGFloat(leaves(node)) * rowHeight
                let box = CGRect(x: CGFloat(column) * columnWidth + 8, y: top + height / 2 - boxHeight / 2, width: boxWidth, height: boxHeight)
                var childTop = top
                for (i, child) in (node.children ?? []).enumerated() {
                    let branch = column == 0 ? colors[i % colors.count] : color
                    let end = draw(child, column: column + 1, top: childTop, color: branch)
                    ctx.setStrokeColor(branch.cgColor)
                    ctx.setLineWidth(2)
                    ctx.move(to: CGPoint(x: box.maxX, y: box.midY))
                    ctx.addCurve(to: end, control1: CGPoint(x: box.maxX + 20, y: box.midY), control2: CGPoint(x: end.x - 20, y: end.y))
                    ctx.strokePath()
                    childTop += CGFloat(leaves(child)) * rowHeight
                }
                let shape = UIBezierPath(roundedRect: box, cornerRadius: 8)
                (column == 0 ? UIColor.black : color.withAlphaComponent(0.14)).setFill()
                shape.fill()
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.lineBreakMode = .byTruncatingTail
                NSAttributedString(string: node.title, attributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: column == 0 ? .bold : .medium),
                    .foregroundColor: column == 0 ? UIColor.white : UIColor.black,
                    .paragraphStyle: style,
                ]).draw(in: box.insetBy(dx: 6, dy: 8))
                return CGPoint(x: box.minX, y: box.midY)
            }
            _ = draw(root, column: 0, top: 8, color: .systemBlue)
        }
    }

    struct RecognizedLine: Sendable {
        let text: String
        let confidence: Float
        let box: CGRect // normalised, with the origin at the bottom left
    }

    static func recognizeLines(_ image: UIImage) -> [RecognizedLine] {
        guard let cg = image.cgImage else { return [] }
        // Accurate reads sentences best but returns nothing for very short words, which the fast level can read.
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = level == .accurate
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            let lines = (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, confidence: $0.confidence, box: observation.boundingBox) }
            }
            if !lines.isEmpty { return lines }
        }
        return []
    }

    static func recognize(_ image: UIImage) -> String {
        recognizeLines(image).map(\.text).joined(separator: "\n")
    }

    static func recognizeInk(_ drawing: PKDrawing, rect: CGRect) -> String {
        guard drawing.strokes.contains(where: { $0.renderBounds.intersects(rect) }) else { return "" }
        let ink = inkImage(drawing, rect: rect, scale: 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
        return recognize(image)
    }
}
