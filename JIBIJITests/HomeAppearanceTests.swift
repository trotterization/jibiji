import Foundation
import PencilKit
import Testing
import UIKit
@testable import JIBIJI

@MainActor
@Suite("Home personalization")
struct HomeAppearanceTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "HomeAppearance-\(UUID().uuidString)")
    }

    private func photo() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
    }

    @Test func photoAndManualAdjustmentsSurviveReopenWithoutTouchingInk() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(directory: folder)
        try store.save(SyntheticInk.drawing(writing: "大"), pageID: "page-1")
        let before = try Data(contentsOf: store.fileURL(forPage: "page-1"))
        let appearance = HomeAppearanceModel(directory: folder)
        #expect(appearance.adjustments.automatic)
        let settings = HomeBackgroundAdjustments(automatic: false, blur: 8, dimming: 0.3, visibility: 0.7)
        #expect(appearance.save(settings, photo: .replace(photo())))
        let reopened = HomeAppearanceModel(directory: folder)
        #expect(reopened.image != nil)
        #expect(reopened.adjustments == settings)
        #expect(reopened.problem == nil)
        #expect(try Data(contentsOf: store.fileURL(forPage: "page-1")) == before)
        #expect(reopened.save(HomeBackgroundAdjustments(), photo: .remove))
        #expect(HomeAppearanceModel(directory: folder).image == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix("home-background-") })
    }

    @Test func automaticAppearanceAdaptsToLightAndDarkAndClampsManualValues() {
        let automatic = HomeBackgroundAdjustments()
        #expect(automatic.resolved(dark: true, brightness: 1).dimming > automatic.resolved(dark: true, brightness: 0).dimming)
        #expect(automatic.resolved(dark: false, brightness: 1).visibility < automatic.resolved(dark: true, brightness: 1).visibility)
        let manual = HomeBackgroundAdjustments(automatic: false, blur: .infinity, dimming: -1, visibility: 3).clamped
        #expect(manual.blur.isFinite && manual.dimming == 0 && manual.visibility == 1)
    }

    @Test func unreadableSettingsAndFailedSavesKeepExistingFiles() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "home-appearance.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        let unreadable = HomeAppearanceModel(directory: folder)
        #expect(unreadable.problem != nil)
        #expect(!unreadable.save(HomeBackgroundAdjustments(), photo: .replace(photo())))
        #expect(try Data(contentsOf: url) == corrupt)
        try FileManager.default.removeItem(at: url)
        let model = HomeAppearanceModel(directory: folder)
        #expect(model.save(HomeBackgroundAdjustments(), photo: .replace(photo())))
        let oldPhoto = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "jpg" })
        let oldBytes = try Data(contentsOf: oldPhoto)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(!model.save(HomeBackgroundAdjustments(), photo: .replace(photo())))
        #expect(try Data(contentsOf: oldPhoto) == oldBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".jpg") }.count == 1)
    }

    @Test func legacyLibraryLoadsAndPageDetailsAreSavedTogether() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(directory: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":1,"folders":[],"pages":{"page-1":{"name":"Old lesson","pinned":false}}}"#.utf8).write(to: store.libraryURL)
        let notebook = NotebookModel(store: store)
        #expect(notebook.title(for: "page-1") == "Old lesson")
        #expect(notebook.info(for: "page-1").summary == nil)
        let folderName = try #require(notebook.createFolder("Vocabulary"))
        notebook.editPage("page-1", name: "  Lesson 8  ", summary: " Travel words ", tag: .teal, pinned: true, folder: folderName)
        let reopened = NotebookModel(store: store)
        #expect(reopened.title(for: "page-1") == "Lesson 8")
        #expect(reopened.info(for: "page-1").summary == "Travel words")
        #expect(reopened.info(for: "page-1").pinned && reopened.info(for: "page-1").tag == .teal)
        #expect(reopened.info(for: "page-1").folder == folderName)
        reopened.editPage("page-1", name: "", summary: "", tag: nil, pinned: false, folder: nil)
        #expect(reopened.title(for: "page-1") == "Page 1")
        #expect(reopened.info(for: "page-1").isEmpty)
    }

    @Test func importedImageIsDownsampledAndInvalidDataIsRejected() throws {
        let large = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let decoded = try HomePhoto.decode(try #require(large.jpegData(compressionQuality: 0.8)))
        #expect(decoded.size.width == 2048 && decoded.size.height == 1024)
        #expect(HomePhoto.brightness(decoded) > 0.9)
        #expect(throws: (any Error).self) { try HomePhoto.decode(Data("not a photo".utf8)) }
    }
}
