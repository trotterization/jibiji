import PencilKit
import Testing
import UIKit
@testable import JIBIJI

/// The PencilKit canvas hosted in a real window, the way the app shows it.
@MainActor
@Suite("Canvas")
struct CanvasTests {
    @MainActor
    final class ChangeLog {
        var drawings: [PKDrawing] = []
    }

    /// Creates the canvas at zero size (as SwiftUI does), puts it in a window, then lays it out at `size`.
    private func hostedCanvas(size: CGSize, saved: PKDrawing, log: ChangeLog) throws
        -> (canvas: NoteCanvasView, coordinator: PencilCanvasView.Coordinator, window: UIWindow) {
        let coordinator = PencilCanvasView.Coordinator()
        coordinator.onDrawingChange = { log.drawings.append($0) }
        let canvas = NoteCanvasView()
        canvas.savedDrawing = saved
        canvas.delegate = coordinator

        // Unit tests run inside the app, so its window scene is available to host the canvas.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.isHidden = false
        window.addSubview(canvas)
        canvas.frame = window.bounds
        canvas.layoutIfNeeded()
        return (canvas, coordinator, window)
    }

    @Test func openingASavedPageShowsItWithoutCountingAsAnEdit() async throws {
        let log = ChangeLog()
        let saved = SyntheticInk.drawing(writing: "大人")
        let hosted = try hostedCanvas(size: CGSize(width: 820, height: 1100), saved: saved, log: log)

        #expect(hosted.canvas.drawing == saved)
        #expect(hosted.canvas.savedDrawing == nil)
        // Give any late delegate callback time to arrive.
        try await Task.sleep(for: .milliseconds(300))
        #expect(log.drawings.isEmpty)

        // A real change still reaches the page model.
        hosted.canvas.drawing = SyntheticInk.drawing(writing: "大人十")
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.drawings.count == 1)
        #expect(log.drawings.last?.strokes.count == 7)
        withExtendedLifetime(hosted) {}
    }

    @Test func eachCanvasHasItsOwnUndoHistory() throws {
        let one = try hostedCanvas(size: CGSize(width: 820, height: 1100), saved: PKDrawing(), log: ChangeLog())
        let two = try hostedCanvas(size: CGSize(width: 820, height: 1100), saved: PKDrawing(), log: ChangeLog())

        let oneUndo = try #require(one.canvas.undoManager)
        let twoUndo = try #require(two.canvas.undoManager)
        #expect(oneUndo !== twoUndo)
        #expect(oneUndo !== one.window.undoManager)

        oneUndo.registerUndo(withTarget: one.canvas) { _ in }
        #expect(oneUndo.canUndo)
        #expect(!twoUndo.canUndo)
        withExtendedLifetime((one, two)) {}
    }

    @Test func dismantlingACanvasStopsItsCallbacks() async throws {
        let log = ChangeLog()
        let hosted = try hostedCanvas(size: CGSize(width: 820, height: 1100), saved: PKDrawing(), log: log)

        PencilCanvasView.dismantleUIView(hosted.canvas, coordinator: hosted.coordinator)
        hosted.canvas.delegate = hosted.coordinator // even if a delegate call still arrived
        hosted.canvas.drawing = SyntheticInk.drawing(writing: "一")
        try await Task.sleep(for: .milliseconds(100))

        #expect(log.drawings.isEmpty)
        withExtendedLifetime(hosted) {}
    }

    @Test func inkThatFitsDoesNotScroll() throws {
        // Includes ink right up to the right edge, which must not make the page slide sideways.
        let ink = PKDrawing(strokes: SyntheticInk.drawing(writing: "大").strokes
            + SyntheticInk.drawing(writing: "一", origin: CGPoint(x: 700, y: 400), glyphSize: 112).strokes)
        let hosted = try hostedCanvas(size: CGSize(width: 820, height: 1100), saved: ink, log: ChangeLog())
        let visible = hosted.canvas.bounds.inset(by: hosted.canvas.adjustedContentInset).size

        #expect(ink.bounds.maxX > visible.width - NoteCanvasView.trailingInkMargin)
        #expect(hosted.canvas.contentSize == visible)
        withExtendedLifetime(hosted) {}
    }

    @Test func inkWrittenInALargerWindowStaysReachable() throws {
        // Written in portrait near the bottom right, reopened in a shorter, narrower window.
        let saved = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 1000, y: 1000))
        let hosted = try hostedCanvas(size: CGSize(width: 820, height: 700), saved: saved, log: ChangeLog())

        #expect(hosted.canvas.contentSize.width >= saved.bounds.maxX)
        #expect(hosted.canvas.contentSize.height >= saved.bounds.maxY)
        withExtendedLifetime(hosted) {}
    }

    @Test func lowestInkCanScrollClearOfTheToolPalette() throws {
        // A last line written just above the palette in portrait, reopened in landscape.
        let saved = SyntheticInk.drawing(writing: "十", origin: CGPoint(x: 100, y: 850))
        let hosted = try hostedCanvas(size: CGSize(width: 1180, height: 734), saved: saved, log: ChangeLog())

        // At maximum scroll, the ink's bottom must sit above the strip the palette covers.
        #expect(hosted.canvas.contentSize.height - saved.bounds.maxY >= NoteCanvasView.paletteClearance)
        withExtendedLifetime(hosted) {}
    }

    @Test func scrollableAreaGrowsWhenInkIsAddedPastTheEdge() async throws {
        let hosted = try hostedCanvas(size: CGSize(width: 820, height: 700), saved: PKDrawing(), log: ChangeLog())
        let farInk = SyntheticInk.drawing(writing: "十", origin: CGPoint(x: 100, y: 900))

        hosted.canvas.drawing = farInk
        try await Task.sleep(for: .milliseconds(100))

        #expect(hosted.canvas.contentSize.height >= farInk.bounds.maxY)
        withExtendedLifetime(hosted) {}
    }

    // MARK: - Whiteboard zoom and pan

    private func zoomable(_ log: ChangeLog = ChangeLog(), saved: PKDrawing = SyntheticInk.drawing(writing: "大人十", origin: CGPoint(x: 100, y: 200)))
        throws -> (canvas: NoteCanvasView, coordinator: PencilCanvasView.Coordinator, controller: CanvasController, window: UIWindow) {
        let hosted = try hostedCanvas(size: CGSize(width: 820, height: 1100), saved: saved, log: log)
        hosted.canvas.configureViewport()
        let controller = CanvasController()
        controller.canvasView = hosted.canvas
        hosted.coordinator.controller = controller
        return (hosted.canvas, hosted.coordinator, controller, hosted.window)
    }

    @Test func pinchRangeIsConfiguredAndClamped() throws {
        let z = try zoomable()
        #expect(z.canvas.minimumZoomScale == 0.5 && z.canvas.maximumZoomScale == 4)
        z.canvas.setZoomScale(10, animated: false)
        #expect(z.canvas.zoomScale <= 4)
        z.canvas.setZoomScale(0.1, animated: false)
        #expect(z.canvas.zoomScale >= 0.5)
        withExtendedLifetime(z) {}
    }

    @Test func fingerPansAndPinchesWhileInkIsPencilOnly() throws {
        let z = try zoomable()
        z.controller.inkIsPencilOnly = true
        z.controller.applyTools()
        #expect(z.canvas.drawingPolicy == .pencilOnly)
        #expect(z.canvas.panGestureRecognizer.minimumNumberOfTouches == 1)
        #expect(z.canvas.pinchGestureRecognizer?.isEnabled == true)
        // The opt-in "draw with finger" and disposable test notebooks keep finger ink.
        z.controller.tools.allowsFingerDrawing = true
        z.controller.applyTools()
        #expect(z.canvas.drawingPolicy == .anyInput)
        z.controller.tools.allowsFingerDrawing = false
        z.controller.inkIsPencilOnly = false
        z.controller.applyTools()
        #expect(z.canvas.drawingPolicy == .anyInput)
        withExtendedLifetime(z) {}
    }

    @Test func zoomingAndPanningNeverChangeInkOrCountAsEdits() async throws {
        let log = ChangeLog()
        let saved = SyntheticInk.drawing(writing: "大人十", origin: CGPoint(x: 100, y: 200))
        let z = try zoomable(log, saved: saved)
        try await Task.sleep(for: .milliseconds(100))
        log.drawings.removeAll()
        z.canvas.setZoomScale(2.5, animated: false)
        z.canvas.contentOffset = CGPoint(x: 120, y: 90)
        z.coordinator.scrollViewDidZoom(z.canvas)
        z.coordinator.scrollViewDidEndZooming(z.canvas, with: nil, atScale: 2.5)
        z.canvas.setZoomScale(1, animated: false)
        z.coordinator.scrollViewDidEndZooming(z.canvas, with: nil, atScale: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(z.canvas.drawing == saved)
        #expect(log.drawings.isEmpty)
        // Ink coordinates are page coordinates whatever the zoom: the saved data is identical.
        z.canvas.setZoomScale(3, animated: false)
        #expect(z.canvas.drawing.dataRepresentation() == saved.dataRepresentation())
        withExtendedLifetime(z) {}
    }

    @Test func overlaysFollowZoomAndPan() throws {
        let z = try zoomable()
        z.canvas.setZoomScale(2, animated: false)
        z.canvas.contentOffset = CGPoint(x: 30, y: 50)
        z.coordinator.scrollViewDidZoom(z.canvas)
        let page = CGRect(x: 100, y: 200, width: 60, height: 40)
        let visible = z.controller.visibleRect(forPageRect: page)
        #expect(visible == CGRect(x: 100 * 2 - z.canvas.contentOffset.x, y: 200 * 2 - z.canvas.contentOffset.y, width: 120, height: 80))
        #expect(z.controller.zoomScale == 2)
        withExtendedLifetime(z) {}
    }

    @Test func scrollableAreaScalesWithZoomSoAllInkStaysReachable() throws {
        let tall = SyntheticInk.drawing(writing: "大人十", origin: CGPoint(x: 100, y: 1500))
        let z = try zoomable(saved: tall)
        z.canvas.fitContentToInk()
        let natural = z.canvas.contentSize
        z.canvas.setZoomScale(2, animated: false)
        z.canvas.fitContentToInk()
        // The page doubles in size on screen. The tool-bar clearance is a fixed 128 screen points, so it
        // doesn't double: height = 2 x lowest ink + 128.
        #expect(abs(z.canvas.contentSize.height - (tall.bounds.maxY * 2 + NoteCanvasView.paletteClearance)) < 1)
        #expect(z.canvas.contentSize.height > natural.height)
        withExtendedLifetime(z) {}
    }

    @Test func undoAndEraseStillWorkWhileZoomedAndSaveRoundTrips() throws {
        let original = SyntheticInk.drawing(writing: "大人十", origin: CGPoint(x: 100, y: 200))
        let z = try zoomable(saved: original)
        z.canvas.setZoomScale(2, animated: false)
        z.canvas.contentOffset = CGPoint(x: 40, y: 40)
        // An erase (as one native undoable edit) while zoomed.
        let erased = PKDrawing(strokes: Array(original.strokes.dropLast()))
        z.controller.applyDrawing(erased, actionName: "Erase")
        #expect(z.canvas.drawing.strokes.count == original.strokes.count - 1)
        z.controller.undo()
        #expect(z.canvas.drawing == original)
        z.controller.redo()
        #expect(z.canvas.drawing.strokes.count == original.strokes.count - 1)
        #expect(z.canvas.zoomScale == 2)
        // The saved page is the same ink at any zoom.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zoom-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(directory: folder)
        try store.save(z.canvas.drawing, pageID: "page-1")
        #expect(try store.loadDrawing(pageID: "page-1") == z.canvas.drawing)
        withExtendedLifetime(z) {}
    }
}

@Suite("Native replacement undo", .serialized)
@MainActor
struct ReplacementCanvasTests {
    @Test func replacementIsOneNativeUndoStepAndRedoNotifiesThePage() async throws {
        let original = SyntheticInk.drawing(writing: "大")
        let replacement = try #require(CleanHandwriting.drawing(text: "牛", in: original.bounds))
        let coordinator = PencilCanvasView.Coordinator()
        var changes: [PKDrawing] = []
        coordinator.onDrawingChange = { changes.append($0) }
        let canvas = NoteCanvasView()
        canvas.savedDrawing = original
        canvas.delegate = coordinator
        let controller = CanvasController()
        controller.canvasView = canvas
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1100)
        window.addSubview(canvas); canvas.frame = window.bounds; window.isHidden = false
        canvas.layoutIfNeeded()
        let undo = try #require(canvas.undoManager)
        undo.beginUndoGrouping()
        controller.applyDrawing(replacement)
        undo.endUndoGrouping()
        #expect(PageFlashcards.digest(of: canvas.drawing) == PageFlashcards.digest(of: replacement))
        #expect(undo.canUndo)
        undo.undo()
        #expect(PageFlashcards.digest(of: canvas.drawing) == PageFlashcards.digest(of: original))
        #expect(undo.canRedo)
        undo.redo()
        #expect(PageFlashcards.digest(of: canvas.drawing) == PageFlashcards.digest(of: replacement))
        #expect(changes.count == 2)
        withExtendedLifetime((window, coordinator, controller)) {}
    }
}
