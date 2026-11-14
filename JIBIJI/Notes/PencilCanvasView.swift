import PencilKit
import SwiftUI
import UIKit

/// Lets SwiftUI reach the UIKit canvas.
@MainActor
final class CanvasController {
    fileprivate weak var canvasView: PKCanvasView?

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

        controller.canvasView = canvas
        return canvas
    }

    func updateUIView(_ canvas: NoteCanvasView, context: Context) {
        context.coordinator.onDrawingChange = onDrawingChange
    }

    static func dismantleUIView(_ canvas: NoteCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker.removeObserver(canvas)
        canvas.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        var onDrawingChange: (@MainActor (PKDrawing) -> Void)?

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
            size.height = max(visible.height, ink.maxY + Self.paletteClearance)
        }
        if contentSize != size {
            contentSize = size
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        toolPicker?.setVisible(true, forFirstResponder: self)
        becomeFirstResponder()
    }
}
