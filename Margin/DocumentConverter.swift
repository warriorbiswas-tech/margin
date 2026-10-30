import PDFKit
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Turns anything iPadOS can display (Word, PowerPoint, Excel, web pages, text, images) into PDF pages, on the device.
@MainActor
final class DocumentConverter: NSObject, WKNavigationDelegate {
    static let importable: [UTType] = [
        .pdf, .image, .rtf, .plainText, .html,
        UTType("org.openxmlformats.wordprocessingml.document"), UTType("com.microsoft.word.doc"),
        UTType("org.openxmlformats.presentationml.presentation"), UTType("com.microsoft.powerpoint.ppt"),
        UTType("org.openxmlformats.spreadsheetml.sheet"),
    ].compactMap { $0 }

    private var finished: CheckedContinuation<Void, Error>?

    static func pdf(from url: URL) async throws -> PDFDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url), !doc.isLocked else { throw CocoaError(.fileReadCorruptFile) }
            return doc
        }
        if let image = UIImage(contentsOfFile: url.path), let page = PDFPage(image: image) {
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            return doc
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        return try await DocumentConverter().convert(copy)
    }

    private func convert(_ url: URL) async throws -> PDFDocument {
        let frame = CGRect(x: 0, y: 0, width: 612, height: 792)
        let web = WKWebView(frame: frame)
        web.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            web.loadFileURL(url, allowingReadAccessTo: url)
        }
        try await Task.sleep(for: .milliseconds(600)) // Office previews finish laying out just after the load event
        return try Self.paginate(web, pageSize: frame.size)
    }

    private static func paginate(_ web: WKWebView, pageSize: CGSize) throws -> PDFDocument {
        let paper = CGRect(origin: .zero, size: pageSize)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.setValue(paper, forKey: "paperRect")
        renderer.setValue(paper.insetBy(dx: 36, dy: 36), forKey: "printableRect")
        let data = UIGraphicsPDFRenderer(bounds: paper).pdfData { ctx in
            for page in 0..<max(renderer.numberOfPages, 1) {
                ctx.beginPage()
                renderer.drawPage(at: page, in: ctx.pdfContextBounds)
            }
        }
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        return doc
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finished?.resume(throwing: error)
        finished = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finished?.resume(throwing: error)
        finished = nil
    }
}
