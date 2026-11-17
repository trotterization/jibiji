import PencilKit
import SwiftUI
import UIKit

/// Lets SwiftUI reach the UIKit canvas.
@MainActor
@Observable
final class CanvasController {
    @ObservationIgnored weak var canvasView: PKCanvasView?

    /// The canvas's scroll offset and zoom, so SwiftUI overlays can follow the ink.
    private(set) var contentOffset = CGPoint.zero
    private(set) var zoomScale: CGFloat = 1

    fileprivate func viewportDidChange(of canvas: UIScrollView) {
        if contentOffset != canvas.contentOffset { contentOffset = canvas.contentOffset }
        if zoomScale != canvas.zoomScale { zoomScale = canvas.zoomScale }
    }

    /// Converts a rectangle in page (ink) coordinates to the canvas's visible coordinates.
    func visibleRect(forPageRect rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * zoomScale - contentOffset.x,
            y: rect.minY * zoomScale - contentOffset.y,
            width: rect.width * zoomScale,
            height: rect.height * zoomScale
        )
    }

    /// Install a model edit as one native undo operation. Native undo/redo notifies
    /// the model, while the initial model-authored change is already accounted for.
    func applyDrawing(_ drawing: PKDrawing, actionName: String = "Replace handwriting", notify: Bool = false) {
        guard let canvas = canvasView as? NoteCanvasView else { return }
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { controller in
            controller.applyDrawing(old, actionName: actionName, notify: true)
        }
        canvas.undoManager?.setActionName(actionName)
        canvas.setModelDrawing(drawing)
        if notify { canvas.delegate?.canvasViewDrawingDidChange?(canvas) }
    }

    /// Gives the canvas first responder again (e.g. after a sheet closes) so the tool picker returns.
    func focus() {
        canvasView?.becomeFirstResponder()
    }

    /// Hides the tool picker while something covers the page (e.g. a sheet), so its undo or
    /// eraser can't change ink the student can't see.
    func resignFocus() {
        canvasView?.resignFirstResponder()
    }
}

/// A PencilKit page with the system tool picker (pens, eraser, lasso, ruler, undo, redo).
struct PencilCanvasView: UIViewRepresentable {
    /// Used only when the canvas is created; later edits flow out through `onDrawingChange`.
    let initialDrawing: PKDrawing
    let controller: CanvasController
    /// For test notebooks: start with the pen and don't save tool changes, so UI tests are
    /// repeatable and never change the palette a student has set up.
    var startsWithPenWithoutSavingTools = false
    /// Lowest page y of suggestion chips, so they can be scrolled into view.
    var noteBottom: CGFloat = 0
    let onDrawingChange: @MainActor (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NoteCanvasView {
        let canvas = NoteCanvasView()
        canvas.savedDrawing = initialDrawing
        // `.default` follows the system "Only Draw with Apple Pencil" setting:
        // Pencil-only on an iPad paired with a Pencil, finger drawing in the Simulator.
        canvas.drawingPolicy = .default
        canvas.backgroundColor = .systemBackground
        canvas.isOpaque = true
        canvas.alwaysBounceVertical = false
        canvas.accessibilityIdentifier = "noteCanvas"

        let coordinator = context.coordinator
        coordinator.onDrawingChange = onDrawingChange
        if startsWithPenWithoutSavingTools {
            coordinator.toolPicker.stateAutosaveName = nil
            if let pen = coordinator.toolPicker.toolItems.first(where: {
                ($0 as? PKToolPickerInkingItem)?.inkingTool.inkType == .pen
            }) {
                coordinator.toolPicker.selectedToolItem = pen
            }
        }
        canvas.delegate = coordinator
        canvas.toolPicker = coordinator.toolPicker
        coordinator.toolPicker.addObserver(canvas)

        coordinator.controller = controller
        controller.canvasView = canvas
        return canvas
    }

    func updateUIView(_ canvas: NoteCanvasView, context: Context) {
        context.coordinator.onDrawingChange = onDrawingChange
        canvas.noteBottom = noteBottom
    }

    static func dismantleUIView(_ canvas: NoteCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker.removeObserver(canvas)
        canvas.delegate = nil
        // A page switch replaces the canvas; nothing from the old one may reach a page model afterwards.
        coordinator.onDrawingChange = nil
        coordinator.controller = nil
        canvas.resignFirstResponder()
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        var onDrawingChange: (@MainActor (PKDrawing) -> Void)?
        weak var controller: CanvasController?

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            controller?.viewportDidChange(of: scrollView)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let noteCanvas = canvasView as? NoteCanvasView
            noteCanvas?.fitContentToInk()
            // Opening the saved page isn't an edit.
            if noteCanvas?.isApplyingSavedDrawing == true { return }
            onDrawingChange?(canvasView.drawing)
        }
    }
}

/// Opens the saved page once the canvas has a size, and shows the tool picker in a window.
final class NoteCanvasView: PKCanvasView {
    weak var toolPicker: PKToolPicker?

    /// The page to show when the canvas is first laid out. PencilKit doesn't render a drawing
    /// assigned while the canvas is still zero-sized (as it is in `makeUIView`), so it waits until then.
    var savedDrawing: PKDrawing?
    private(set) var isApplyingSavedDrawing = false

    func setModelDrawing(_ next: PKDrawing) {
        isApplyingSavedDrawing = true
        drawing = next
        isApplyingSavedDrawing = false
        fitContentToInk()
    }

    /// Each page's canvas has its own undo history. Without this, every canvas shares the window's
    /// UndoManager, so Undo on one page could be offered for, or act on, another page's strokes.
    /// History lasts while the canvas does: switching pages starts the page's canvas fresh.
    private let pageUndoManager = UndoManager()
    override var undoManager: UndoManager? { pageUndoManager }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let savedDrawing, !bounds.isEmpty {
            self.savedDrawing = nil
            isApplyingSavedDrawing = true
            drawing = savedDrawing
            isApplyingSavedDrawing = false
        }
        fitContentToInk()
    }

    /// Lowest page y used by suggestion/accepted-note chips (0 when none).
    var noteBottom: CGFloat = 0 {
        didSet { if noteBottom != oldValue { fitContentToInk() } }
    }

    /// Space kept to the right of ink that runs past the right edge.
    static let trailingInkMargin: CGFloat = 32
    /// The default tool palette floats over about the last 120 pt of the page, so the lowest ink
    /// must be able to scroll at least this far above the bottom edge to be seen.
    static let paletteClearance: CGFloat = 128

    /// Makes the scrollable area cover all of the ink, so strokes written in a larger window
    /// (e.g. portrait before rotating to landscape) stay reachable, including ink that would
    /// otherwise sit under the tool palette. A page whose ink is already in view doesn't scroll.
    func fitContentToInk() {
        guard !bounds.isEmpty else { return }
        let visible = bounds.inset(by: adjustedContentInset).size
        var size = visible
        if !drawing.strokes.isEmpty {
            let ink = drawing.bounds
            if ink.maxX > visible.width {
                size.width = ink.maxX + Self.trailingInkMargin
            }
            // Notes sit below their ink, so they must be scrollable above the palette too.
            size.height = max(visible.height, max(ink.maxY, noteBottom) + Self.paletteClearance)
        }
        if contentSize != size {
            contentSize = size
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        toolPicker?.setVisible(true, forFirstResponder: self)
        // At launch (and right after a menu closes) the window may not be key yet, and
        // becomeFirstResponder() then silently fails, leaving the palette without a responder.
        // Retry once the current layout/menu transition has finished.
        if !becomeFirstResponder() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                self.toolPicker?.setVisible(true, forFirstResponder: self)
                self.becomeFirstResponder()
            }
        }
    }
}
