import UIKit

/// Hands Pencil writing to the system's Scribble recognizer, so it becomes text right where it was written.
/// Each existing text box is a target, and the rest of the page starts a new box at the pen.
@MainActor final class LiveScribble: NSObject, @preconcurrency UIIndirectScribbleInteractionDelegate {
    private static let newBox = "new"

    /// Handwriting wanders, so writing near a box counts as adding to it rather than starting another.
    private static func target(for el: Element) -> CGRect {
        el.rect.insetBy(dx: -max(el.fontSize * 3, 60), dy: -el.fontSize)
    }
    weak var model: EditorModel?

    func indirectScribbleInteraction(_ interaction: UIInteraction, requestElementsIn rect: CGRect, completion: @escaping ([String]) -> Void) {
        guard let model, model.scribbleActive || model.tool == .text else {
            completion([])
            return
        }
        let boxes = model.note.elements
            .filter { $0.imageFile == nil && !$0.isTape && $0.cover == nil && $0.comment == nil && !$0.stamp && $0.link == nil && Self.target(for: $0).intersects(rect) }
            .map(\.id.uuidString)
        completion(boxes + [Self.newBox])
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, willBeginWritingInElement elementIdentifier: String) {
        model?.checkpoint() // each burst of writing is its own undo step
        model?.scribbleConfirmed = true
        model?.lastPencilActivity = Date() // writing again, so any pending check is out of date
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, didFinishWritingInElement elementIdentifier: String) {
        model?.pencilStrokeEnded()
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, isElementFocused elementIdentifier: String) -> Bool {
        guard let model else { return false }
        // Scribble asks this repeatedly while writing. The new-box target counts as focused until its first text
        // lands; answering no would replace the box mid-word and lose everything written into it.
        if elementIdentifier == Self.newBox {
            return model.freshScribbleBoxID != nil && model.freshScribbleBoxID == model.editingElementID
        }
        return model.editingElementID?.uuidString == elementIdentifier
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, frameForElement elementIdentifier: String) -> CGRect {
        guard let model else { return .zero }
        if let el = model.note.elements.first(where: { $0.id.uuidString == elementIdentifier }) { return Self.target(for: el) }
        return CGRect(origin: .zero, size: model.overlay.bounds.size)
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, focusElementIfNeeded elementIdentifier: String, referencePoint focusReferencePoint: CGPoint, completion: @escaping ((any UIResponder & UITextInput)?) -> Void) {
        guard let model else {
            completion(nil)
            return
        }
        if let el = model.note.elements.first(where: { $0.id.uuidString == elementIdentifier }) {
            completion(model.overlay.focusForScribble(el))
        } else {
            if let id = model.freshScribbleBoxID, id == model.editingElementID, let el = model.note.elements.first(where: { $0.id == id }) {
                completion(model.overlay.focusForScribble(el))
                return
            }
            let el = model.liveTextBox(continuing: focusReferencePoint) ?? model.addLiveTextBox(at: focusReferencePoint)
            let editor = model.overlay.focusForScribble(el)
            model.freshScribbleBoxID = el.id
            completion(editor)
        }
    }
}
