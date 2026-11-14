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
}
