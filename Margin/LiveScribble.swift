import UIKit

/// Hands Pencil writing to the system's Scribble recognizer, so it becomes text right where it was written.
/// Each existing text box is a target, and the rest of the page starts a new box at the pen.
@MainActor final class LiveScribble: NSObject, @preconcurrency UIIndirectScribbleInteractionDelegate {
    private static let newBox = "new"
    weak var model: EditorModel?

    func indirectScribbleInteraction(_ interaction: UIInteraction, requestElementsIn rect: CGRect, completion: @escaping ([String]) -> Void) {
        guard let model, model.scribbleActive || model.tool == .text else {
            completion([])
            return
        }
        let boxes = model.note.elements
            .filter { $0.imageFile == nil && !$0.isTape && $0.cover == nil && $0.comment == nil && !$0.stamp && $0.link == nil && $0.rect.intersects(rect) }
            .map(\.id.uuidString)
        completion(boxes + [Self.newBox])
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, isElementFocused elementIdentifier: String) -> Bool {
        model?.editingElementID?.uuidString == elementIdentifier
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, frameForElement elementIdentifier: String) -> CGRect {
        guard let model else { return .zero }
        if let el = model.note.elements.first(where: { $0.id.uuidString == elementIdentifier }) { return el.rect }
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
            completion(model.overlay.focusForScribble(model.addLiveTextBox(at: focusReferencePoint)))
        }
    }
}
