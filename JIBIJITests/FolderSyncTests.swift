import Foundation
import PDFKit
import PencilKit
import Testing
@testable import JIBIJI

@MainActor @Suite("Folder sync and conflict recovery")
struct FolderSyncTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }
    private func seed(_ store: NoteStore, glyph: String, name: String = "Lesson") throws {
        try store.save(SyntheticInk.drawing(writing: glyph), pageID: "page-1")
        var library = NotebookLibrary()
        library.pages["page-1"] = .init(name: name)
        try store.saveLibrary(library)
    }
    private func apply(_ plan: SyncPlan, _ store: NoteStore) throws {
        if !plan.writes.isEmpty { try SyncTransaction.apply(plan.writes, to: store.directory) }
    }
    private func digests(_ store: NoteStore) throws -> Set<String> {
        try Set(store.loadPageIDs().compactMap { try store.loadDrawing(pageID: $0).map(PageFlashcards.digest) })
    }

    @Test func twoReplicasConvergeAndConcurrentInkBecomesExactlyOneConflictCopy() async throws {
        let a = NoteStore(directory: folder()), b = NoteStore(directory: folder()), cloud = folder()
        defer { for url in [a.directory, b.directory, cloud] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try seed(a, glyph: "大")
        let first = FolderSyncEngine(directory: a.directory), second = FolderSyncEngine(directory: b.directory)
        try apply(await first.exchange(folder: cloud, allowsPull: true), a)
        try apply(await second.exchange(folder: cloud, allowsPull: true), b)
        #expect(try digests(a) == digests(b))
        try apply(await second.exchange(folder: cloud, allowsPull: true), b)
        try seed(a, glyph: "一"); try seed(b, glyph: "十")
        let expected = try digests(a).union(digests(b))
        try apply(await first.exchange(folder: cloud, allowsPull: true), a)
        for _ in 0..<4 {
            try apply(await second.exchange(folder: cloud, allowsPull: true), b)
            try apply(await first.exchange(folder: cloud, allowsPull: true), a)
        }
        #expect(try a.loadPageIDs().count == 2)
        #expect(try b.loadPageIDs().count == 2)
        #expect(try digests(a) == expected && digests(b) == expected)
        #expect(try a.loadLibrary().pages.values.filter { $0.name?.hasSuffix(" (conflict copy)") == true }.count == 1)
        let readable = cloud.appending(path: "Jibiji Sync/Readable PDFs")
        let pdfs = try FileManager.default.contentsOfDirectory(at: readable, includingPropertiesForKeys: nil).filter { $0.pathExtension == "pdf" }
        #expect(pdfs.count == 2)
        #expect(pdfs.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
    }

    @Test func pdfAnnotationsAndCardsSyncAcrossDifferentLocalPageNumbers() async throws {
        let a = NoteStore(directory: folder()), b = NoteStore(directory: folder()), cloud = folder()
        defer { for url in [a.directory, b.directory, cloud] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try seed(a, glyph: "大", name: "Incoming"); try seed(b, glyph: "十", name: "Local")
        try JSONEncoder().encode(PageFlashcardFile(pageID: "page-1", cards: [])).write(to: a.directory.appending(path: "page-1.flashcards.json"))
        let library = PDFLibrary(directory: a.directory.appending(path: "PDFs"))
        let original = PortablePDF.note(PKDrawing(), title: "Planner")
        let item = try library.importPDF(data: original, title: "Planner")
        let pdf = try PDFNotebook(item: item, source: library.source(item.id))
        let ink = SyntheticInk.drawing(writing: "一")
        pdf.changed(ink, page: 0, size: CGSize(width: 612, height: 792)); pdf.save()
        let first = FolderSyncEngine(directory: a.directory), second = FolderSyncEngine(directory: b.directory)
        try apply(await first.exchange(folder: cloud, allowsPull: true), a)
        for _ in 0..<3 {
            try apply(await second.exchange(folder: cloud, allowsPull: true), b)
            try apply(await first.exchange(folder: cloud, allowsPull: true), a)
        }
        #expect(try a.loadPageIDs().count == 2 && b.loadPageIDs().count == 2)
        let cards = try JSONDecoder().decode(PageFlashcardFile.self, from: Data(contentsOf: b.directory.appending(path: "page-2.flashcards.json")))
        #expect(cards.pageID == "page-2")
        let destination = PDFLibrary(directory: b.directory.appending(path: "PDFs"))
        #expect(destination.items.count == 1)
        #expect(try Data(contentsOf: destination.source(item.id)) == original)
        let opened = try PDFNotebook(item: item, source: destination.source(item.id))
        let saved = try #require(try opened.pageInk(0))
        #expect(PageFlashcards.digest(of: try PKDrawing(data: saved.drawing)) == PageFlashcards.digest(of: ink))
        let aState = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: a.directory.appending(path: FolderSyncEngine.stateFile)))
        let bState = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: b.directory.appending(path: FolderSyncEngine.stateFile)))
        #expect(aState.records.mapValues(\.files) == bState.records.mapValues(\.files))
    }

    @Test func reconnectAfterReinstallRestoresTheSameWritersCloudNotes() async throws {
        let store = NoteStore(directory: folder()), cloud = folder(), device = UUID().uuidString
        defer { for url in [store.directory, cloud] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try seed(store, glyph: "大")
        let expected = try digests(store)
        _ = try await FolderSyncEngine(directory: store.directory, deviceID: device).exchange(folder: cloud, allowsPull: false)
        // Simulate uninstall: the app container is gone, but the non-migrating Keychain ID remains.
        try FileManager.default.removeItem(at: store.directory)
        let reinstalled = FolderSyncEngine(directory: store.directory, deviceID: device)
        let plan = try await reinstalled.exchange(folder: cloud, allowsPull: true)
        #expect(plan.imported == 1)
        try apply(plan, store)
        #expect(try digests(store) == expected)
        #expect(try store.loadLibrary().pages["page-1"]?.name == "Lesson")
    }

    @Test func corruptCloudBlobIsRejectedBeforeAnyLocalNoteChanges() async throws {
        let a = NoteStore(directory: folder()), b = NoteStore(directory: folder()), cloud = folder()
        defer { for url in [a.directory, b.directory, cloud] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try seed(a, glyph: "大")
        let first = FolderSyncEngine(directory: a.directory)
        _ = try await first.exchange(folder: cloud, allowsPull: false)
        let state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: a.directory.appending(path: FolderSyncEngine.stateFile)))
        let hash = try #require(state.records.values.first?.files["drawing"])
        try Data("broken download".utf8).write(to: cloud.appending(path: "Jibiji Sync/blobs/\(hash)"))
        let second = FolderSyncEngine(directory: b.directory)
        await #expect(throws: (any Error).self) { try await second.exchange(folder: cloud, allowsPull: true) }
        #expect(!FileManager.default.fileExists(atPath: b.fileURL(forPage: "page-1").path))
        #expect(try b.loadPageIDs() == ["page-1"])
    }

    @Test func interruptedImportRecoversPreviousFilesAndTraversalIsRejected() throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("original".utf8), replacement = Data("remote".utf8)
        let url = root.appending(path: "page-1.drawing")
        try original.write(to: url)
        let journal = [SyncWrite(path: "page-1.drawing", data: original)]
        try JSONEncoder().encode(journal).write(to: root.appending(path: SyncTransaction.journal))
        try replacement.write(to: url)
        try SyncTransaction.recover(root)
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: SyncTransaction.journal).path))
        try Data("block".utf8).write(to: root.appending(path: "blocked"))
        #expect(throws: (any Error).self) {
            try SyncTransaction.apply([.init(path: "page-1.drawing", data: replacement), .init(path: "blocked/child", data: replacement)], to: root)
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: SyncTransaction.journal).path))
        #expect(throws: (any Error).self) { try SyncTransaction.apply([.init(path: "../escape", data: replacement)], to: root) }
    }

    @Test func uploadsNeverApplyRemoteInkWhileThePageIsBeingEdited() async throws {
        let a = NoteStore(directory: folder()), b = NoteStore(directory: folder()), cloud = folder()
        defer { for url in [a.directory, b.directory, cloud] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try seed(a, glyph: "大")
        _ = try await FolderSyncEngine(directory: a.directory).exchange(folder: cloud, allowsPull: false)
        let second = FolderSyncEngine(directory: b.directory)
        let plan = try await second.exchange(folder: cloud, allowsPull: false)
        #expect(plan.writes.isEmpty)
        #expect(try b.loadDrawing(pageID: "page-1") == nil)
        try apply(await second.exchange(folder: cloud, allowsPull: true), b)
        #expect(try digests(a) == digests(b))
    }
}
