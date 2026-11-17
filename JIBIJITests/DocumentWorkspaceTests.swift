import PDFKit
import PencilKit
import Testing
import UIKit
@testable import JIBIJI

@MainActor @Suite("PDF workspace and search")
struct DocumentWorkspaceTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }
    private func pdf() throws -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500))
        let bytes = renderer.pdfData { context in
            for number in 1...2 {
                context.beginPage()
                "Mandarin lesson \(number)".draw(at: CGPoint(x: 24, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        let document = try #require(PDFDocument(data: bytes))
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 400, width: 100, height: 30), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: URL(string: "https://example.com/lesson")!)
        document.page(at: 0)?.addAnnotation(link)
        document.page(at: 1)?.rotation = 90
        return try #require(document.dataRepresentation())
    }

    @Test func importAnnotateReopenExportPreservesSourceTextLinksAndRotation() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PDFLibrary(directory: root)
        let source = try pdf()
        let item = try library.importPDF(data: source, title: "Textbook")
        let notebook = try PDFNotebook(item: item, source: library.source(item.id))
        let original = SyntheticInk.drawing(writing: "大", origin: CGPoint(x: 70, y: 100), glyphSize: 50)
        let blue = PKDrawing(strokes: original.strokes.map { PKStroke(ink: PKInk(.pen, color: .blue), path: $0.path, transform: $0.transform, mask: $0.mask) })
        notebook.changed(blue, page: 0, size: CGSize(width: 300, height: 500))
        #expect(notebook.pending)
        notebook.save()
        #expect(!notebook.pending)
        let reopened = try PDFNotebook(item: item, source: library.source(item.id))
        let saved = try #require(try reopened.pageInk(0))
        #expect(PageFlashcards.digest(of: try PKDrawing(data: saved.drawing)) == PageFlashcards.digest(of: blue))
        #expect(try Data(contentsOf: library.source(item.id)) == source)
        let bytes = try reopened.export()
        let exported = try #require(PDFDocument(data: bytes))
        #expect(exported.pageCount == 2)
        #expect(exported.string?.contains("Mandarin") == true)
        #expect(exported.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 500, height: 300))
        let links = try #require(exported.page(at: 0)).annotations.filter { $0.url != nil }
        #expect(links.count == 1)
        #expect(links.first?.url?.host == "example.com")
        let image = try #require(exported.page(at: 0)?.thumbnail(of: CGSize(width: 300, height: 500), for: .mediaBox).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        #expect(stride(from: 0, to: pixels.count, by: 4).filter { Int(pixels[$0 + 2]) > Int(pixels[$0]) + 40 }.count > 10)
    }

    @Test func failedPDFSaveKeepsItsBufferAcrossCloseAndRetriesWithoutChangingSource() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let notebook = NotebookModel(store: NoteStore(directory: root))
        let original = try pdf()
        let beforeImport = notebook.localRevision
        let item = try notebook.documents.importPDF(data: original, title: "Retry")
        #expect(notebook.localRevision > beforeImport)
        let opened = try notebook.documents.open(item)
        let beforeInk = notebook.localRevision
        let drawing = SyntheticInk.drawing(writing: "大")
        let blocked = notebook.documents.folder(item.id).appending(path: "ink-0.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        opened.changed(drawing, page: 0, size: CGSize(width: 300, height: 500))
        #expect(notebook.localRevision > beforeInk)
        notebook.documents.close(item.id)
        #expect(notebook.hasPendingInk)
        #expect(try notebook.documents.open(item) === opened)
        #expect(opened.problem != nil)
        let buffered = try #require(try opened.pageInk(0))
        #expect(PageFlashcards.digest(of: try PKDrawing(data: buffered.drawing)) == PageFlashcards.digest(of: drawing))
        try FileManager.default.removeItem(at: blocked)
        notebook.saveAll()
        #expect(!notebook.hasPendingInk)
        #expect(opened.problem == nil)
        notebook.documents.close(item.id)
        let reopened = try notebook.documents.open(item)
        #expect(reopened !== opened)
        let saved = try #require(try reopened.pageInk(0))
        #expect(PageFlashcards.digest(of: try PKDrawing(data: saved.drawing)) == PageFlashcards.digest(of: drawing))
        #expect(try Data(contentsOf: notebook.documents.source(item.id)) == original)
    }

    @Test func malformedImportAndAnnotationFilesNeverOverwriteSource() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PDFLibrary(directory: root)
        #expect(throws: (any Error).self) { try library.importPDF(data: Data("not pdf".utf8), title: "Invalid") }
        #expect(library.items.isEmpty)
        let source = try pdf()
        let item = try library.importPDF(data: source, title: "Original")
        let url = library.folder(item.id).appending(path: "ink-0.json")
        let bad = Data("damaged".utf8); try bad.write(to: url)
        let notebook = try PDFNotebook(item: item, source: library.source(item.id))
        #expect(throws: (any Error).self) { try notebook.pageInk(0) }
        #expect(throws: (any Error).self) { try notebook.export() }
        #expect(try Data(contentsOf: url) == bad)
        #expect(try Data(contentsOf: library.source(item.id)) == source)
    }

    @Test func pdfSearchFindsTextAndHandlesNoMatches() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PDFLibrary(directory: root)
        let item = try library.importPDF(data: pdf(), title: "Textbook")
        let matches = try await PDFTextReader.shared.find("mandarin", at: library.source(item.id))
        #expect(matches.map(\.page) == [0, 1])
        #expect(try await PDFTextReader.shared.find("absent", at: library.source(item.id)).isEmpty)
    }

    @Test func readingModeBlocksInkAndUndoButKeepsNavigation() {
        let canvas = NoteCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        canvas.configureViewport()
        let controller = CanvasController(); controller.attach(canvas)
        let original = SyntheticInk.drawing(writing: "大")
        canvas.setModelDrawing(original)
        canvas.undoManager?.registerUndo(withTarget: canvas) { $0.setModelDrawing(PKDrawing()) }
        controller.setReading(true)
        #expect(!canvas.drawingGestureRecognizer.isEnabled)
        #expect(canvas.undoManager == nil && !canvas.canBecomeFirstResponder)
        #expect(canvas.panGestureRecognizer.isEnabled && canvas.pinchGestureRecognizer?.isEnabled == true)
        controller.undo()
        #expect(PageFlashcards.digest(of: canvas.drawing) == PageFlashcards.digest(of: original))
        controller.setReading(false)
        #expect(canvas.drawingGestureRecognizer.isEnabled)
        #expect(canvas.drawingPolicy == .pencilOnly)
        controller.undo()
        #expect(canvas.drawing.strokes.isEmpty)
    }

    @Test func handwritingIndexRejectsStaleTextAndTagsRemainSearchable() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteStore(directory: root)
        let drawing = SyntheticInk.drawing(writing: "大")
        try store.save(drawing, pageID: "page-1")
        let notebook = NotebookModel(store: store)
        notebook.editPage("page-1", name: "Lesson", summary: "Review", tag: nil, pinned: false, folder: nil, labels: "exam, Week 2, exam")
        #expect(notebook.matchesSearch("exam week", pageID: "page-1"))
        #expect(notebook.info(for: "page-1").labels?.count == 2)
        let date = store.modificationDate(pageID: "page-1")
        let work = notebook.searchIndex.index([("page-1", drawing, date)], reader: SearchFixture()) { _, _ in true }
        await work.value
        #expect(notebook.matchesSearch("你好", pageID: "page-1"))
        #expect(HandwritingSearchIndex(directory: root).text(for: "page-1", savedAt: date).contains("你好"))
        notebook.currentPage?.drawingDidChange(SyntheticInk.drawing(writing: "一"))
        #expect(!notebook.matchesSearch("你好", pageID: "page-1"))
        #expect(notebook.matchesSearch("exam", pageID: "page-1"))
        let stale = notebook.searchIndex.index([("page-2", drawing, date)], reader: SearchFixture()) { _, _ in false }
        await stale.value
        #expect(notebook.searchIndex.entries["page-2"] == nil)
    }

    @Test func lazyCardDigestIsInvalidatedByEverySourceChange() {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let cards = PageFlashcards(pageID: "page-1", store: NoteStore(directory: root))
        let one = SyntheticInk.drawing(writing: "大")
        cards.inkChanged(one)
        let first = cards.currentDigest
        cards.inkChanged(SyntheticInk.drawing(writing: "一"))
        #expect(cards.currentDigest != first)
        cards.inkChanged(one)
        #expect(cards.currentDigest == first)
    }
}

private struct SearchFixture: InkLineReader {
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] { [RecognizedLine(text: "你好 hello", bounds: .zero)] }
}
