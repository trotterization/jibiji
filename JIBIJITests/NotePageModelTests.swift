import Foundation
import PencilKit
import Testing
@testable import JIBIJI

@MainActor
@Suite("Note page autosave")
final class NotePageModelTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "NotePageModelTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    lazy var store = NoteStore(directory: directory)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(autosaveDelay: Duration = .seconds(60)) -> NotePageModel {
        NotePageModel(pageID: "page-1", store: store, autosaveDelay: autosaveDelay)
    }

    @Test func startsAsAnEmptyPage() {
        let model = makeModel()

        #expect(model.state == .empty)
        #expect(model.strokeCount == 0)
        #expect(model.isEditable)
        #expect(model.statusText == "Empty page")
    }

    @Test func newInkIsMarkedUnsavedUntilSaved() throws {
        let model = makeModel()

        model.drawingDidChange(SyntheticInk.drawing(writing: "十"))
        #expect(model.state == .unsaved)
        #expect(model.statusText == "2 strokes · Not saved yet")
        #expect(try store.loadDrawing(pageID: "page-1") == nil)

        model.saveIfNeeded()
        #expect(model.state == .saved)
        #expect(model.statusText == "2 strokes · Saved")
        #expect(try store.loadDrawing(pageID: "page-1")?.strokes.count == 2)
    }

    @Test func autosavesAfterAWritingPause() async throws {
        let model = makeModel(autosaveDelay: .milliseconds(50))
        model.drawingDidChange(SyntheticInk.drawing(writing: "人"))

        for _ in 0..<100 where model.state != .saved {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.state == .saved)
        #expect(try store.loadDrawing(pageID: "page-1")?.strokes.count == 2)
    }

    @Test func eachNewStrokeRestartsTheAutosavePause() async throws {
        let model = makeModel(autosaveDelay: .milliseconds(300))
        model.drawingDidChange(SyntheticInk.drawing(writing: "一"))
        try await Task.sleep(for: .milliseconds(150))
        model.drawingDidChange(SyntheticInk.drawing(writing: "一二"))
        try await Task.sleep(for: .milliseconds(200))

        // 350 ms after the first stroke but only 200 ms after the second: still waiting.
        #expect(model.state == .unsaved)
        #expect(try store.loadDrawing(pageID: "page-1") == nil)
    }

    @Test func reopensSavedInkOnTheNextLaunch() throws {
        let first = makeModel()
        let ink = SyntheticInk.drawing(writing: "大人")
        first.drawingDidChange(ink)
        first.saveIfNeeded()

        let relaunched = makeModel()

        #expect(relaunched.state == .saved)
        #expect(relaunched.drawing.strokes.count == ink.strokes.count)
        #expect(relaunched.drawing.strokes.map { $0.path.map(\.location) } == ink.strokes.map { $0.path.map(\.location) })
    }

    @Test func saveIfNeededDoesNothingWithoutChanges() throws {
        let model = makeModel()
        model.saveIfNeeded()

        #expect(model.state == .empty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(forPage: "page-1").path))
    }

    @Test func unreadablePageIsKeptAndABlankPageStarts() throws {
        let garbage = Data("not a drawing".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try garbage.write(to: store.fileURL(forPage: "page-1"))

        let model = makeModel()

        #expect(model.state == .empty)
        #expect(model.isEditable)
        let notice = try #require(model.notice)
        let kept = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("page-1.unreadable-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: kept[0]) == garbage)
        #expect(notice.contains(kept[0].lastPathComponent))

        // New writing saves to the page without touching the kept file.
        model.drawingDidChange(SyntheticInk.drawing(writing: "一"))
        model.saveIfNeeded()
        #expect(try store.loadDrawing(pageID: "page-1")?.strokes.count == 1)
        #expect(try Data(contentsOf: kept[0]) == garbage)
    }

    @Test func pageThatCannotBeReadIsNeverOverwritten() throws {
        // A directory in place of the page file makes reading fail for a non-format reason.
        let pageURL = store.fileURL(forPage: "page-1")
        try FileManager.default.createDirectory(at: pageURL, withIntermediateDirectories: true)

        let model = makeModel()
        guard case .cannotOpen = model.state else {
            Issue.record("Expected .cannotOpen, got \(model.state)")
            return
        }
        #expect(!model.isEditable)

        model.drawingDidChange(SyntheticInk.drawing(writing: "一"))
        model.saveIfNeeded()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: pageURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(model.strokeCount == 0)
    }

    @Test func saveFailureIsShownAndRetried() throws {
        let model = makeModel()
        #expect(model.state == .empty)
        // Put a file where the notes folder belongs so saving fails.
        try Data().write(to: directory)
        model.drawingDidChange(SyntheticInk.drawing(writing: "一"))
        model.saveIfNeeded()

        guard case .failed = model.state else {
            Issue.record("Expected .failed, got \(model.state)")
            return
        }
        #expect(model.statusText == "1 stroke · Couldn't save")

        // Once the problem is fixed, the next save writes the pending ink.
        try FileManager.default.removeItem(at: directory)
        model.saveIfNeeded()
        #expect(model.state == .saved)
        #expect(try store.loadDrawing(pageID: "page-1")?.strokes.count == 1)
    }
}
