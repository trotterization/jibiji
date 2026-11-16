import Foundation
import PencilKit
import Testing
@testable import JIBIJI

@MainActor
@Suite("Local notebook")
final class NotebookModelTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "NotebookModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    lazy var store = NoteStore(directory: directory)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A long autosave delay, so only explicit flushes (page switch, saveAll) save.
    private func openNotebook() -> NotebookModel {
        NotebookModel(store: store, autosaveDelay: .seconds(60))
    }

    private func strokePoints(_ drawing: PKDrawing) -> [[CGPoint]] {
        drawing.strokes.map { $0.path.map(\.location) }
    }

    @Test func legacyFirstPageOpensUnchangedWithoutRewritingFiles() throws {
        let original = SyntheticInk.drawing(writing: "大人")
        try store.save(original, pageID: "page-1")
        let bytesBefore = try Data(contentsOf: store.fileURL(forPage: "page-1"))

        let notebook = openNotebook()
        #expect(notebook.pageIDs == ["page-1"])
        #expect(notebook.currentPageID == "page-1")
        #expect(notebook.title(for: "page-1") == "Page 1")
        #expect(notebook.currentPage?.drawing == original)
        notebook.saveAll()

        #expect(try Data(contentsOf: store.fileURL(forPage: "page-1")) == bytesBefore)
        #expect(!FileManager.default.fileExists(atPath: store.pageIndexURL.path))
    }

    @Test func legacyNotebookStillCreatesAPageAndKeepsTheOriginalFile() throws {
        try store.save(SyntheticInk.drawing(writing: "一"), pageID: "page-1")
        let bytesBefore = try Data(contentsOf: store.fileURL(forPage: "page-1"))

        let notebook = openNotebook()
        notebook.createPage()

        #expect(notebook.pageIDs == ["page-1", "page-2"])
        #expect(try Data(contentsOf: store.fileURL(forPage: "page-1")) == bytesBefore)
        #expect(try store.loadPageIDs() == ["page-1", "page-2"])
    }

    @Test func twoPagesKeepSeparateInkAndReopenInOrder() throws {
        let first = SyntheticInk.drawing(writing: "大")
        let second = SyntheticInk.drawing(writing: "二三")

        let notebook = openNotebook()
        notebook.currentPage?.drawingDidChange(first)
        notebook.createPage() // flushes page 1
        #expect(notebook.currentPageID == "page-2")
        #expect(notebook.title(for: "page-2") == "Page 2")
        #expect(notebook.currentPage?.state == .empty)
        notebook.currentPage?.drawingDidChange(second)
        notebook.selectPage("page-1") // flushes page 2
        #expect(notebook.currentPage?.drawing == first)
        notebook.selectPage("page-2")
        #expect(notebook.currentPage?.drawing == second)

        // Relaunch: a new model over the same files.
        let relaunched = openNotebook()
        #expect(relaunched.pageIDs == ["page-1", "page-2"])
        #expect(strokePoints(try #require(relaunched.currentPage).drawing) == strokePoints(first))
        relaunched.selectPage("page-2")
        #expect(strokePoints(try #require(relaunched.currentPage).drawing) == strokePoints(second))
    }

    @Test func aNewBlankPageIsKeptInOrderAcrossRelaunch() throws {
        let notebook = openNotebook()
        notebook.createPage()
        notebook.createPage()
        #expect(notebook.pageIDs == ["page-1", "page-2", "page-3"])
        // Nothing was written on the new pages.
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(forPage: "page-3").path))

        let relaunched = openNotebook()
        #expect(relaunched.pageIDs == ["page-1", "page-2", "page-3"])
        relaunched.selectPage("page-3")
        #expect(relaunched.currentPage?.state == .empty)
    }

    @Test func switchingPagesSavesPendingInkFirst() throws {
        let notebook = openNotebook()
        notebook.createPage()
        notebook.selectPage("page-1")
        notebook.currentPage?.drawingDidChange(SyntheticInk.drawing(writing: "十"))
        #expect(try store.loadDrawing(pageID: "page-1") == nil)

        notebook.selectPage("page-2")

        #expect(try store.loadDrawing(pageID: "page-1")?.strokes.count == 2)
    }

    @Test func aFailedSaveKeepsTheInkAndRetriesAfterSwitching() throws {
        let notebook = openNotebook()
        notebook.createPage() // on page 2, which has now been opened
        notebook.selectPage("page-1")
        let ink = SyntheticInk.drawing(writing: "人")
        notebook.currentPage?.drawingDidChange(ink)

        // Make saving fail: a plain file where the notes folder belongs.
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        notebook.selectPage("page-2")

        #expect(notebook.alert?.contains("Page 1") == true)
        #expect(notebook.currentPageID == "page-2")
        notebook.selectPage("page-1")
        #expect(notebook.currentPage?.drawing == ink)
        guard case .failed = notebook.currentPage?.state else {
            Issue.record("Expected .failed, got \(String(describing: notebook.currentPage?.state))")
            return
        }

        try FileManager.default.removeItem(at: directory)
        notebook.saveAll()
        #expect(notebook.currentPage?.state == .saved)
        #expect(try store.loadDrawing(pageID: "page-1")?.strokes.count == 2)
    }

    @Test func aLateEditFromTheOldPageStaysOnThatPage() throws {
        let notebook = openNotebook()
        notebook.createPage()
        let page2 = try #require(notebook.currentPage)
        notebook.selectPage("page-1")

        // An old canvas calling back after the switch still reports to its own page.
        page2.drawingDidChange(SyntheticInk.drawing(writing: "一"))

        #expect(notebook.currentPage?.strokeCount == 0)
        notebook.saveAll()
        #expect(try store.loadDrawing(pageID: "page-1") == nil)
        #expect(try store.loadDrawing(pageID: "page-2")?.strokes.count == 1)
    }

    @Test func aCorruptPageListIsReportedAndNeverOverwritten() throws {
        try store.save(SyntheticInk.drawing(writing: "大"), pageID: "page-1")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: store.pageIndexURL)
        let pageBytes = try Data(contentsOf: store.fileURL(forPage: "page-1"))

        let notebook = openNotebook()
        guard case .failed(let reason) = notebook.loadState else {
            Issue.record("Expected .failed, got \(notebook.loadState)")
            return
        }
        #expect(reason.contains("notebook.json"))
        #expect(notebook.currentPage == nil)

        notebook.createPage()
        notebook.saveAll()

        #expect(try Data(contentsOf: store.pageIndexURL) == garbage)
        #expect(try Data(contentsOf: store.fileURL(forPage: "page-1")) == pageBytes)

        // Once the file is repaired, retrying opens the notebook.
        try store.savePageIDs(["page-1", "page-2"])
        notebook.reload()
        #expect(notebook.loadState == .ready)
        #expect(notebook.pageIDs == ["page-1", "page-2"])
    }

    @Test func invalidPageListsAreRejected() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bad = [
            #"{"version":1,"pageIDs":[]}"#,
            #"{"version":1,"pageIDs":["page-1","page-1"]}"#,
            #"{"version":1,"pageIDs":["../page-1"]}"#,
            #"{"version":2,"pageIDs":["page-1"]}"#,
        ]
        for json in bad {
            try Data(json.utf8).write(to: store.pageIndexURL)
            #expect(throws: NoteStoreError.self, "\(json)") { try self.store.loadPageIDs() }
        }
    }

    @Test func pageNumbersDoNotReuseIDsOnDisk() throws {
        try store.save(SyntheticInk.drawing(writing: "一"), pageID: "page-4")

        #expect(store.nextPageID(after: ["page-1", "page-2"]) == "page-5")
        // Without an index, pages found on disk are listed in numeric order.
        #expect(try store.loadPageIDs() == ["page-1", "page-4"])
    }
}
