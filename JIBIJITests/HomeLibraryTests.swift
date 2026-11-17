import Foundation
import PencilKit
import Testing
@testable import JIBIJI

@MainActor
@Suite("Notebook home")
final class HomeLibraryTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "HomeLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    lazy var store = NoteStore(directory: directory)

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func openNotebook() -> NotebookModel { NotebookModel(store: store, autosaveDelay: .seconds(60)) }

    @Test func namesColorsPinsAndFoldersPersistWithoutTouchingInk() throws {
        try store.save(SyntheticInk.drawing(writing: "大"), pageID: "page-1")
        let inkBefore = try Data(contentsOf: store.fileURL(forPage: "page-1"))
        let notebook = openNotebook()
        notebook.createPage()
        notebook.renameNotebook("  HSK 4  ")
        notebook.renamePage("page-2", to: "Lesson 5")
        notebook.setTag(.teal, for: "page-2")
        notebook.togglePin("page-2")
        let folder = try #require(notebook.createFolder("Grammar"))
        notebook.moveToFolder("page-1", folder: folder)
        notebook.moveToFolder("page-1", folder: "Missing")

        let reopened = openNotebook()
        #expect(reopened.notebookTitle == "HSK 4")
        #expect(reopened.title(for: "page-2") == "Lesson 5")
        #expect(reopened.title(for: "page-1") == "Page 1")
        #expect(reopened.info(for: "page-2").tag == .teal)
        #expect(reopened.info(for: "page-2").pinned)
        #expect(reopened.info(for: "page-1").folder == "Grammar")
        #expect(try Data(contentsOf: store.fileURL(forPage: "page-1")) == inkBefore)

        // Renaming a folder carries its pages; deleting it only ungroups them.
        reopened.renameFolder("Grammar", to: "Grammar notes")
        #expect(reopened.info(for: "page-1").folder == "Grammar notes")
        reopened.deleteFolder("Grammar notes")
        #expect(reopened.library.folders.isEmpty)
        #expect(reopened.info(for: "page-1").folder == nil)
        #expect(reopened.pageIDs == ["page-1", "page-2"])

        // An empty name goes back to the default.
        reopened.renamePage("page-2", to: "   ")
        #expect(reopened.title(for: "page-2") == "Page 2")
    }

    @Test func movingAPageRewritesOnlyTheOrder() throws {
        let notebook = openNotebook()
        notebook.createPage()
        notebook.createPage()
        notebook.renamePage("page-3", to: "Idioms")
        notebook.movePage("page-3", to: "page-1")
        #expect(notebook.pageIDs == ["page-3", "page-1", "page-2"])
        #expect(notebook.title(for: "page-1") == "Page 2", "Unnamed pages are numbered by position")
        #expect(openNotebook().pageIDs == ["page-3", "page-1", "page-2"])
    }

    @Test func unreadableLibraryIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.libraryURL)
        let notebook = openNotebook()
        #expect(notebook.title(for: "page-1") == "Page 1")
        notebook.renamePage("page-1", to: "Lesson 1")
        #expect(notebook.alert != nil)
        #expect(try Data(contentsOf: store.libraryURL) == Data("not json".utf8))
    }

    @Test func previewUsesOpenInkBeforeItIsSaved() {
        let notebook = openNotebook()
        let ink = SyntheticInk.drawing(writing: "十")
        notebook.currentPage?.drawingDidChange(ink)
        #expect(notebook.previewDrawing(for: "page-1").strokes.count == ink.strokes.count)
        #expect(notebook.lastEdited("page-1") != nil)
    }
}
