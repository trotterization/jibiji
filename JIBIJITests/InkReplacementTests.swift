import Foundation
import PencilKit
import Testing
import UIKit
@testable import JIBIJI

@Suite("Editable handwriting replacement", .serialized)
@MainActor
struct InkReplacementTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("InkReplacement-\(UUID().uuidString)") }

    @Test func cleanHandwritingIsThinNativeInkInTheStudentsPen() throws {
        #expect(CleanHandwriting.font(size: 30).fontName == "LXGWWenKaiTC-Regular")
        let target = CGRect(x: 40, y: 50, width: 180, height: 90)
        let pen = CleanHandwriting.Pen(inkType: .pen, color: .black, width: 2.5)
        let ink = try #require(CleanHandwriting.drawing(text: "牛我", in: target, pen: pen))
        // Several strokes per character, drawn along the middle of the glyph, not filled outlines.
        #expect(ink.strokes.count >= 6)
        // Roughly a stroke per pen stroke (牛 4, 我 7), not dozens of junction fragments.
        #expect(ink.strokes.count <= 22, "\(ink.strokes.count) strokes")
        #expect(ink.strokes.allSatisfy { $0.mask == nil && $0.ink.inkType == .pen })
        #expect(ink.strokes.allSatisfy { $0.path.allSatisfy { abs($0.size.width - 2.5) < 0.01 } })
        #expect(ink.bounds.insetBy(dx: -4, dy: -4).contains(target.insetBy(dx: 12, dy: 12)))
        #expect(target.insetBy(dx: -6, dy: -6).contains(ink.bounds))
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = ink.image(from: CGRect(x: 20, y: 30, width: 230, height: 130), scale: 1)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let composite = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
        let cg = try #require(composite.cgImage)
        let context = try #require(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                             bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        let dark = (0..<(cg.width * cg.height)).filter { bytes[$0 * 4] < 100 }.count
        #expect(dark > 100, "The strokes must actually render ink, not just store stroke metadata")
        #expect(dark < cg.width * cg.height / 8, "Thin pen lines, not filled glyphs")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jibiji-clean-ink-preview.png")
        try composite.pngData()?.write(to: file)
        print("LOCAL CLEAN INK PREVIEW: \(file.path)")
    }

    @Test func uncertainReadingNeverReplacesInkEvenFromTheEditPath() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(directory: folder)
        let ink = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 160))
        try store.save(ink, pageID: "page-1")
        let page = NotePageModel(pageID: "page-1", store: store,
                                 lineReader: ReplacementReader(lines: [RecognizedLine(text: "农夫市集 none fu shi ji", bounds: ink.bounds)]))
        page.suggestions.request(for: page.drawing)
        await page.suggestions.task?.value
        let item = try #require(page.suggestions.pending.first)
        #expect(!item.allowsInkReplacement)
        #expect(!page.replaceSuggestion(item.id, with: "农夫市集 nóngfū shìjí"))
        #expect(PageFlashcards.digest(of: page.drawing) == PageFlashcards.digest(of: ink))
        // It can still be kept as a note beside the ink.
        page.suggestions.accept(item.id)
        #expect(page.suggestions.annotations.count == 1)
        #expect(PageFlashcards.digest(of: page.drawing) == PageFlashcards.digest(of: ink))
    }

    @Test func replacementRestoresAfterRelaunchAndPreservesOtherWriting() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(directory: folder)
        let original = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 160))
        let neighbor = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 400, y: 160))
        let initial = PKDrawing(strokes: original.strokes + neighbor.strokes)
        try store.save(initial, pageID: "page-1")
        let page = NotePageModel(pageID: "page-1", store: store,
                                 lineReader: ReplacementReader(lines: [RecognizedLine(text: "大", bounds: original.bounds, readings: ["大", "牛"])]))
        page.suggestions.request(for: page.drawing)
        await page.suggestions.task?.value
        let item = try #require(page.suggestions.pending.first)
        #expect(page.replaceSuggestion(item.id, with: "牛"))
        let changed = PageFlashcards.digest(of: page.drawing)
        #expect(changed != PageFlashcards.digest(of: initial))
        #expect(page.drawing.strokes.suffix(neighbor.strokes.count).map(InkSelection.identity) == neighbor.strokes.map(InkSelection.identity))
        let reopened = NotePageModel(pageID: "page-1", store: store)
        let receipt = try #require(reopened.latestVisibleReplacement)
        #expect(PageFlashcards.digest(of: reopened.drawing) == changed)
        let later = SyntheticInk.drawing(writing: "十", origin: CGPoint(x: 80, y: 400))
        reopened.drawingDidChange(PKDrawing(strokes: reopened.drawing.strokes + later.strokes))
        #expect(reopened.restoreOriginal(receipt.id))
        #expect(reopened.drawing.strokes.map(InkSelection.identity) == (initial.strokes + later.strokes).map(InkSelection.identity))
        #expect(reopened.latestVisibleReplacement == nil)
    }

    @Test func penMatchesTheStrokesItReplaces() {
        let fine = SyntheticInk.stroke(through: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)], width: 1.8)
        let pen = CleanHandwriting.Pen.matching([fine, fine, SyntheticInk.stroke(through: [CGPoint(x: 0, y: 9), CGPoint(x: 9, y: 9)], width: 9)])
        #expect(abs(pen.width - 1.8) < 0.01)
        let marker = PKStroke(ink: PKInk(.marker, color: .red), path: fine.path)
        #expect(CleanHandwriting.Pen.matching([marker]).inkType == .pen)
    }

    @Test func movedAndResizedReplacementKeepsItsPenAndCanStillBeRestored() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(directory: folder)
        let original = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 80, y: 160))
        let neighbor = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 400, y: 160))
        let initial = PKDrawing(strokes: original.strokes + neighbor.strokes)
        let page = NotePageModel(pageID: "page-1", store: store,
                                 lineReader: ReplacementReader(lines: [RecognizedLine(text: "大", bounds: original.bounds, readings: ["牛"])]))
        page.drawingDidChange(initial)
        page.suggestions.request(for: page.drawing); await page.suggestions.task?.value
        let item = try #require(page.suggestions.pending.first)
        #expect(page.replaceSuggestion(item.id, with: "牛"))
        let note = try #require(page.latestVisibleReplacement)
        let before = try #require(page.replacementBounds(note))
        let widths = Set(page.drawing.strokes.prefix(while: { !neighbor.strokes.map(InkSelection.identity).contains(InkSelection.identity($0)) })
            .flatMap { $0.path.map { ($0.size.width * 100).rounded() } })

        #expect(page.adjustReplacement(note.id, by: CGAffineTransform(translationX: 30, y: -20)))
        let pivot = CGPoint(x: before.minX + 30, y: before.midY - 20)
        #expect(page.adjustReplacement(note.id, by: CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
            .concatenating(CGAffineTransform(scaleX: 0.5, y: 0.5)).concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))))
        let after = try #require(page.latestVisibleReplacement.flatMap(page.replacementBounds))
        #expect(abs(after.minX - (before.minX + 30)) < 4)
        #expect(after.height < before.height * 0.7)
        // Same pen width after resizing, and the neighbor is untouched.
        let movedWidths = Set(page.drawing.strokes.filter { !neighbor.strokes.map(InkSelection.identity).contains(InkSelection.identity($0)) }
            .flatMap { $0.path.map { ($0.size.width * 100).rounded() } })
        #expect(movedWidths == widths)
        #expect(page.drawing.strokes.suffix(neighbor.strokes.count).map(InkSelection.identity) == neighbor.strokes.map(InkSelection.identity))

        let reopened = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder))
        let receipt = try #require(reopened.latestVisibleReplacement)
        #expect(receipt.anchor.minX > before.minX + 20)
        #expect(reopened.restoreOriginal(receipt.id))
        #expect(reopened.drawing.strokes.map(InkSelection.identity) == initial.strokes.map(InkSelection.identity))
    }

    @Test func deletionRemovesOnlyTheReplacementAndPersists() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = SyntheticInk.drawing(writing: "大")
        let neighbor = SyntheticInk.drawing(writing: "人", origin: CGPoint(x: 400, y: 160))
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder),
                                 lineReader: ReplacementReader(lines: [RecognizedLine(text: "大", bounds: original.bounds, readings: ["大"])]))
        page.drawingDidChange(PKDrawing(strokes: original.strokes + neighbor.strokes))
        page.suggestions.request(for: page.drawing); await page.suggestions.task?.value
        let item = try #require(page.suggestions.pending.first)
        #expect(page.replaceSuggestion(item.id, with: "牛"))
        let receipt = try #require(page.latestVisibleReplacement)
        page.deleteReplacement(receipt.id)
        let reopened = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder))
        #expect(reopened.drawing.strokes.map(InkSelection.identity) == neighbor.strokes.map(InkSelection.identity))
        #expect(reopened.latestVisibleReplacement == nil)
    }

    @Test func confirmedReplacementFeedsCardsWithoutReinterpretingItsGlyphPaths() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = SyntheticInk.drawing(writing: "大")
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder),
                                 lineReader: ReplacementReader(lines: [RecognizedLine(text: "fuze responsible for", bounds: original.bounds)]))
        page.drawingDidChange(original)
        page.suggestions.request(for: original); await page.suggestions.task?.value
        let item = try #require(page.suggestions.pending.first)
        #expect(page.replaceSuggestion(item.id, with: "负责"))
        await page.flashcards.refresh(from: page.drawing, annotations: page.suggestions.annotations).value
        #expect(page.flashcards.currentDrafts.count == 1)
        #expect(page.flashcards.currentDrafts.first?.front == "负责")
        #expect(page.flashcards.currentDrafts.first?.back.contains("to be responsible for") == true)
    }

    @Test func crossingArrowIsNotMistakenForACharacterStroke() {
        let character = SyntheticInk.drawing(writing: "大")
        let arrow = SyntheticInk.stroke(through: [CGPoint(x: 0, y: 190), CGPoint(x: 600, y: 190)])
        let drawing = PKDrawing(strokes: character.strokes + [arrow])
        #expect(InkSelection.indices(in: drawing, bounds: character.bounds) == Array(character.strokes.indices))
    }

    @Test func failedRecoverySaveLeavesOriginalInkUntouched() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = SyntheticInk.drawing(writing: "大")
        let page = NotePageModel(pageID: "page-1", store: NoteStore(directory: folder),
                                 lineReader: ReplacementReader(lines: [RecognizedLine(text: "大", bounds: original.bounds, readings: ["大"])]))
        page.drawingDidChange(original)
        page.suggestions.request(for: original); await page.suggestions.task?.value
        let item = try #require(page.suggestions.pending.first)
        // Suggest already recorded this note, so the folder exists: swap it for a file to make every later save fail.
        try? FileManager.default.removeItem(at: folder)
        try Data("blocked".utf8).write(to: folder)
        #expect(!page.replaceSuggestion(item.id, with: "牛"))
        #expect(PageFlashcards.digest(of: page.drawing) == PageFlashcards.digest(of: original))
    }
}

private struct ReplacementReader: InkLineReader {
    var lines: [RecognizedLine]
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { lines }
}
