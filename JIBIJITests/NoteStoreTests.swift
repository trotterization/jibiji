import Foundation
import PencilKit
import Testing
@testable import JIBIJI

@Suite("Saving and reopening ink")
final class NoteStoreTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "NoteStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    lazy var store = NoteStore(directory: directory)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func reopensTheOriginalStrokes() throws {
        let original = SyntheticInk.drawing(writing: "大人十")
        try store.save(original, pageID: "page-1")

        // A fresh store stands in for a relaunch: nothing is shared in memory.
        let reopened = try #require(try NoteStore(directory: directory).loadDrawing(pageID: "page-1"))

        #expect(reopened == original)
        #expect(reopened.strokes.count == 7)
        #expect(reopened.strokes.count == original.strokes.count)
        #expect(reopened.bounds == original.bounds)
        for (saved, written) in zip(reopened.strokes, original.strokes) {
            #expect(saved.ink.inkType == written.ink.inkType)
            #expect(saved.ink.color == written.ink.color)
            #expect(saved.path.creationDate == written.path.creationDate)
            #expect(saved.path.map(\.location) == written.path.map(\.location))
            #expect(saved.path.map(\.timeOffset) == written.path.map(\.timeOffset))
        }
    }

    @Test func repeatedSaveAndReopenKeepsTheInk() throws {
        // Every relaunch reopens and later re-saves the page, so ink must not drift over cycles.
        // (PencilKit appends a few bytes of metadata when re-encoding a decoded drawing, so this
        // compares ink rather than file bytes.)
        let original = SyntheticInk.drawing(writing: "三二一")
        try store.save(original, pageID: "page-1")
        for _ in 0..<3 {
            let reopened = try #require(try store.loadDrawing(pageID: "page-1"))
            try store.save(reopened, pageID: "page-1")
        }

        let final = try #require(try store.loadDrawing(pageID: "page-1"))
        #expect(final == original)
        #expect(final.strokes.map { $0.path.map(\.location) } == original.strokes.map { $0.path.map(\.location) })
    }

    @Test func neverSavedPageOpensAsNil() throws {
        #expect(try store.loadDrawing(pageID: "page-1") == nil)
    }

    @Test func latestSaveReplacesThePrevious() throws {
        try store.save(SyntheticInk.drawing(writing: "一"), pageID: "page-1")
        try store.save(SyntheticInk.drawing(writing: "一二"), pageID: "page-1")

        #expect(try store.loadDrawing(pageID: "page-1")?.strokes.count == 3)
    }

    @Test func erasingEverythingSavesAnEmptyPage() throws {
        try store.save(SyntheticInk.drawing(writing: "大"), pageID: "page-1")
        try store.save(PKDrawing(), pageID: "page-1")

        let reopened = try #require(try store.loadDrawing(pageID: "page-1"))
        #expect(reopened.strokes.isEmpty)
    }

    @Test func pagesAreStoredSeparately() throws {
        try store.save(SyntheticInk.drawing(writing: "一"), pageID: "page-1")
        try store.save(SyntheticInk.drawing(writing: "三"), pageID: "page-2")

        #expect(try store.loadDrawing(pageID: "page-1")?.strokes.count == 1)
        #expect(try store.loadDrawing(pageID: "page-2")?.strokes.count == 3)
    }

    @Test func unreadableFileIsReportedNotTreatedAsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a drawing".utf8).write(to: store.fileURL(forPage: "page-1"))

        #expect(throws: NoteStoreError.self) {
            try self.store.loadDrawing(pageID: "page-1")
        }
    }

    @Test func unreadableFileIsSetAsideByteForByte() throws {
        let garbage = Data("not a drawing".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try garbage.write(to: store.fileURL(forPage: "page-1"))

        let kept = try store.setAsideUnreadablePage(pageID: "page-1")

        #expect(try Data(contentsOf: kept) == garbage)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(forPage: "page-1").path))
        #expect(kept.lastPathComponent.hasPrefix("page-1.unreadable-"))
    }

    @Test func fileSystemErrorsAreNotMistakenForUnreadableDrawings() throws {
        // A directory where the page file should be: reading fails, but not because of the drawing format.
        try FileManager.default.createDirectory(at: store.fileURL(forPage: "page-1"), withIntermediateDirectories: true)

        do {
            _ = try store.loadDrawing(pageID: "page-1")
            Issue.record("Expected a file-system error")
        } catch is NoteStoreError {
            Issue.record("A file-system error was reported as an unreadable drawing")
        } catch {
            // Expected.
        }
    }

    @Test func testNotebookNamesMustBePlainIdentifiers() {
        #expect(NoteStore.testNotebook(named: "uitest-relaunch") != nil)
        for name in ["", "page_2", "../Notes", "a b", "x.y", "笔记"] {
            #expect(NoteStore.testNotebook(named: name) == nil, "\(name) should be rejected")
        }
    }

    // These call the launch decision directly instead of `forLaunch(defaults:)`, because launch
    // arguments (e.g. a store name set in the Run scheme) override any UserDefaults suite.

    @Test func launchWithAStoreNameUsesAndResetsADisposableNotebook() throws {
        let name = "unit-launch-check-\(UUID().uuidString.prefix(8))"
        let store = NoteStore.forLaunch(storeName: name, reset: false)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.isTestNotebook)
        #expect(store.directory != NoteStore.standard.directory)
        #expect(store.directory.path().hasSuffix("TestNotebooks/\(name)/"))

        try store.save(SyntheticInk.drawing(writing: "一"), pageID: "page-1")
        #expect(try NoteStore.forLaunch(storeName: name, reset: false).loadDrawing(pageID: "page-1") != nil)
        #expect(try NoteStore.forLaunch(storeName: name, reset: true).loadDrawing(pageID: "page-1") == nil)
    }

    @Test func normalLaunchUsesTheRealNotebook() {
        let store = NoteStore.forLaunch(storeName: nil, reset: true)

        #expect(store.directory == NoteStore.standard.directory)
        #expect(!store.isTestNotebook)
    }

    @available(iOS 27.0, *)
    @Test func strokeIDsSurviveSaveAndReopen() throws {
        // Suggestions and cards will anchor to stroke IDs, so they must be stable on disk.
        let original = SyntheticInk.drawing(writing: "大人")
        try store.save(original, pageID: "page-1")

        let reopened = try #require(try store.loadDrawing(pageID: "page-1"))
        #expect(reopened.strokes.map(\.id) == original.strokes.map(\.id))
        #expect(Set(original.strokes.map(\.id)).count == original.strokes.count)
    }
}
