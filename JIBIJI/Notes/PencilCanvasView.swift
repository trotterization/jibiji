import PencilKit
import SwiftUI
import UIKit

/// Lets SwiftUI reach the UIKit canvas.
@MainActor
@Observable
final class CanvasController {
    @ObservationIgnored weak var canvasView: PKCanvasView?

    /// The pen case the bar edits. Shared by every page's canvas.
    let tools = InkTools()
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// False while something covers the page (e.g. a sheet); the tool bar hides then.
    private(set) var isFocused = true
    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []

    init() {
        tools.onChange = { [weak self] in self?.applyTools() }
    }

    /// Makes `canvas` the one the bar drives: its tool, its policy, and its own undo history.
    func attach(_ canvas: NoteCanvasView, applyingTools: Bool = true) {
        canvasView = canvas
        // A new page's canvas starts at zoom 1 and offset 0, whatever the last page was left at.
        viewportDidChange(of: canvas)
        if applyingTools { applyTools() }
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers = [
            .NSUndoManagerCheckpoint, .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: canvas.undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndoState() }
            }
        }
        refreshUndoState()
    }

    /// Ink comes only from Apple Pencil, so a finger is free to pan and pinch like a whiteboard.
    /// "Draw with finger" (in the tool bar's settings) opts out. Disposable UI-test notebooks keep
    /// finger drawing, because XCUITest has no Pencil.
    var inkIsPencilOnly = true
    private(set) var isReading = false

    func setReading(_ reading: Bool) {
        guard isReading != reading else { return }
        isReading = reading
        tools.quickPalette = nil
        applyTools()
        if !reading { canvasView?.becomeFirstResponder() }
        refreshUndoState()
    }

    func applyTools() {
        guard let canvas = canvasView else { return }
        canvas.tool = tools.pkTool
        let pencilOnly = (inkIsPencilOnly || UIPencilInteraction.prefersPencilOnlyDrawing) && !tools.allowsFingerDrawing
        canvas.drawingPolicy = pencilOnly ? .pencilOnly : .anyInput
        (canvas as? NoteCanvasView)?.isReadOnly = isReading
        canvas.drawingGestureRecognizer.isEnabled = !isReading
        canvas.panGestureRecognizer.allowedTouchTypes = isReading
            ? [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            : [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    }

    func undo() {
        guard !isReading else { return }
        canvasView?.undoManager?.undo()
        refreshUndoState()
    }

    func redo() {
        guard !isReading else { return }
        canvasView?.undoManager?.redo()
        refreshUndoState()
    }

    func refreshUndoState() {
        let manager = canvasView?.undoManager
        let undo = manager?.canUndo ?? false
        let redo = manager?.canRedo ?? false
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }

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
        guard !isReading, let canvas = canvasView as? NoteCanvasView else { return }
        let old = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { controller in
            controller.applyDrawing(old, actionName: actionName, notify: true)
        }
        canvas.undoManager?.setActionName(actionName)
        canvas.setModelDrawing(drawing)
        if notify { canvas.delegate?.canvasViewDrawingDidChange?(canvas) }
        refreshUndoState()
    }

    /// Brings the tool bar back (e.g. after a sheet closes).
    func focus() {
        isFocused = true
        canvasView?.becomeFirstResponder()
    }

    /// Hides the tool bar while something covers the page (e.g. a sheet), so its undo or
    /// eraser can't change ink the student can't see.
    func resignFocus() {
        isFocused = false
        tools.quickPalette = nil
        canvasView?.resignFirstResponder()
    }
}

/// A PencilKit page. Its tools come from ``InkTools`` and the jibiji tool bar, not the system picker.
struct PencilCanvasView: UIViewRepresentable {
    /// Used only when the canvas is created; later edits flow out through `onDrawingChange`.
    let initialDrawing: PKDrawing
    let controller: CanvasController
    /// For test notebooks: start with the pen and don't save tool changes, so UI tests are
    /// repeatable and never change the palette a student has set up.
    var startsWithPenWithoutSavingTools = false
    /// Lowest page y of suggestion chips, so they can be scrolled into view.
    var noteBottom: CGFloat = 0
    /// How far the floating bar reaches down over the canvas. The page starts below it, and
    /// scrolls up under it.
    var topInset: CGFloat = 0
    let onDrawingChange: @MainActor (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NoteCanvasView {
        let canvas = NoteCanvasView()
        canvas.savedDrawing = initialDrawing
        canvas.backgroundColor = .jibijiPaper
        canvas.isOpaque = true
        canvas.alwaysBounceVertical = false
        canvas.accessibilityIdentifier = "noteCanvas"
        canvas.configureViewport()

        let coordinator = context.coordinator
        coordinator.onDrawingChange = onDrawingChange
        canvas.delegate = coordinator
        // Double-tap and squeeze, as set in Settings › Apple Pencil.
        canvas.addInteraction(UIPencilInteraction(delegate: coordinator))

        coordinator.controller = controller
        controller.inkIsPencilOnly = !startsWithPenWithoutSavingTools
        #if targetEnvironment(simulator)
        // The Simulator has no Apple Pencil: keep finger drawing there so the page can be written on.
        controller.inkIsPencilOnly = false
        #endif
        controller.tools.load(persisting: !startsWithPenWithoutSavingTools)
        controller.attach(canvas)
        return canvas
    }

    func updateUIView(_ canvas: NoteCanvasView, context: Context) {
        context.coordinator.onDrawingChange = onDrawingChange
        canvas.noteBottom = noteBottom
        canvas.topInset = topInset
    }

    static func dismantleUIView(_ canvas: NoteCanvasView, coordinator: Coordinator) {
        canvas.delegate = nil
        // A page switch replaces the canvas; nothing from the old one may reach a page model afterwards.
        coordinator.onDrawingChange = nil
        coordinator.controller = nil
        canvas.resignFirstResponder()
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        var onDrawingChange: (@MainActor (PKDrawing) -> Void)?
        weak var controller: CanvasController?

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            controller?.viewportDidChange(of: scrollView)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            controller?.viewportDidChange(of: scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            controller?.viewportDidChange(of: scrollView)
            (scrollView as? NoteCanvasView)?.fitContentToInk(ignoringZoomState: true)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let noteCanvas = canvasView as? NoteCanvasView
            noteCanvas?.fitContentToInk()
            // Opening the saved page isn't an edit.
            if noteCanvas?.isApplyingSavedDrawing == true { return }
            controller?.tools.quickPalette = nil
            onDrawingChange?(canvasView.drawing)
            controller?.refreshUndoState()
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            guard controller?.isReading == false else { return }
            controller?.tools.pencilTap(at: tap.hoverPose?.location)
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended, controller?.isReading == false else { return }
            controller?.tools.pencilSqueeze(at: squeeze.hoverPose?.location)
        }
    }
}

/// Opens the saved page once the canvas has a size, and shows the tool picker in a window.
final class NoteCanvasView: PKCanvasView {
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
    var isReadOnly = false {
        didSet {
            guard isReadOnly != oldValue else { return }
            if isReadOnly { resignFirstResponder() }
        }
    }
    override var canBecomeFirstResponder: Bool { !isReadOnly }
    override var undoManager: UndoManager? { isReadOnly ? nil : pageUndoManager }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        !isReadOnly && super.canPerformAction(action, withSender: sender)
    }

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

    /// The total top inset wanted, counted from the canvas's top edge (see ``PencilCanvasView/topInset``).
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { applyTopInset() } }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        applyTopInset()
    }

    /// UIKit already adds the safe area (the status bar) on top of `contentInset`, so only the
    /// rest is set here. A page that was scrolled to the top stays at the top.
    private func applyTopInset() {
        let wasAtTop = contentOffset.y <= -adjustedContentInset.top + 0.5
        let inset = max(0, topInset - safeAreaInsets.top)
        guard contentInset.top != inset else { return }
        contentInset.top = inset
        verticalScrollIndicatorInsets.top = inset
        if wasAtTop {
            contentOffset.y = -adjustedContentInset.top
        }
        fitContentToInk()
    }

    /// Lowest page y used by suggestion/accepted-note chips (0 when none).
    var noteBottom: CGFloat = 0 {
        didSet { if noteBottom != oldValue { fitContentToInk() } }
    }

    /// Space kept to the right of ink that runs past the right edge.
    static let trailingInkMargin: CGFloat = 32
    /// The tool bar floats over about the last 90 pt of the page, so the lowest ink
    /// must be able to scroll at least this far above the bottom edge to be seen.
    static let paletteClearance: CGFloat = 128

    /// Makes the scrollable area cover all of the ink, so strokes written in a larger window
    /// (e.g. portrait before rotating to landscape) stay reachable, including ink that would
    /// otherwise sit under the tool palette. A page whose ink is already in view doesn't scroll.
    func fitContentToInk(ignoringZoomState: Bool = false) {
        guard !bounds.isEmpty else { return }
        // The page at zoom 1 is as big as the visible area. Ink and notes are in page units; the scroll
        // view's contentSize is in screen units (page units times the zoom). The tool-bar clearance is a
        // fixed distance on screen, so it is added after scaling.
        let zoom = max(zoomScale, 0.01)
        let page = bounds.inset(by: adjustedContentInset).size
        var pageWidth = page.width
        var height = page.height * zoom
        if !drawing.strokes.isEmpty {
            let ink = drawing.bounds
            if ink.maxX > page.width {
                pageWidth = ink.maxX + Self.trailingInkMargin
            }
            // Notes sit below their ink, so they must be scrollable above the palette too.
            height = max(height, max(ink.maxY, noteBottom) * zoom + Self.paletteClearance)
        }
        let size = CGSize(width: pageWidth * zoom, height: height)
        if contentSize != size, ignoringZoomState || (!isZooming && !isZoomBouncing) {
            contentSize = size
        }
    }

    /// Pinch to zoom and a finger to pan are PencilKit's own scroll-view gestures; with Pencil-only
    /// ink they never compete with drawing.
    func configureViewport() {
        minimumZoomScale = Self.zoomRange.lowerBound
        maximumZoomScale = Self.zoomRange.upperBound
        bouncesZoom = true
        panGestureRecognizer.minimumNumberOfTouches = 1
        pinchGestureRecognizer?.isEnabled = true
    }

    /// How far the page can be zoomed. 1 is the page at its natural size.
    static let zoomRange: ClosedRange<CGFloat> = 0.5...4

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // First responder, so hardware-keyboard Undo/Redo reach this page's history. At launch
        // (and right after a menu closes) the window may not be key yet, and
        // becomeFirstResponder() then silently fails; retry once the transition has finished.
        if !becomeFirstResponder() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                self.becomeFirstResponder()
            }
        }
    }
}
