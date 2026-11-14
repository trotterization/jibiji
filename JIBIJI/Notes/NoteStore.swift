import Foundation
import PencilKit

/// Reads and writes PencilKit pages as files in the app's sandbox.
///
/// Each page is stored as the untouched `PKDrawing.dataRepresentation()`, so the
/// original strokes reopen exactly as written, independent of recognition or AI.
struct NoteStore: Sendable {
    let directory: URL
    /// A disposable Debug-only notebook for UI tests (see ``forLaunch(defaults:)``).
    let isTestNotebook: Bool

    init(directory: URL, isTestNotebook: Bool = false) {
        self.directory = directory
        self.isTestNotebook = isTestNotebook
    }

    /// Notes live in Application Support, which is private to the app and included in device backups.
    static let standard = NoteStore(
        directory: .applicationSupportDirectory.appending(path: "Notes", directoryHint: .isDirectory)
    )

    func fileURL(forPage pageID: String) -> URL {
        directory.appending(path: "\(pageID).drawing", directoryHint: .notDirectory)
    }

    /// Returns `nil` when the page has never been saved.
    ///
    /// Throws ``NoteStoreError/unreadableDrawing(url:underlying:)`` when the file exists but
    /// isn't a drawing, and rethrows file-system errors unchanged so callers can tell the two apart.
    func loadDrawing(pageID: String) throws -> PKDrawing? {
        let url = fileURL(forPage: pageID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        do {
            return try PKDrawing(data: data)
        } catch {
            throw NoteStoreError.unreadableDrawing(url: url, underlying: error)
        }
    }

    /// Writes the page atomically, so a crash mid-save leaves the previous version intact.
    func save(_ drawing: PKDrawing, pageID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try drawing.dataRepresentation().write(
            to: fileURL(forPage: pageID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// Moves an unreadable page file aside so new ink never overwrites it, and returns where it went.
    func setAsideUnreadablePage(pageID: String, date: Date = .now) throws -> URL {
        let stamp = "\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let destination = directory.appending(
            path: "\(pageID).unreadable-\(stamp).drawing",
            directoryHint: .notDirectory
        )
        try FileManager.default.moveItem(at: fileURL(forPage: pageID), to: destination)
        return destination
    }
}

enum NoteStoreError: Error, LocalizedError {
    case unreadableDrawing(url: URL, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .unreadableDrawing(let url, let underlying):
            "\(url.lastPathComponent) isn't a readable drawing (\(underlying.localizedDescription))."
        }
    }
}

extension NoteStore {
    /// The store for this launch.
    ///
    /// Debug builds accept `-JIBIJIStoreName <name>` (ASCII letters, digits, and `-` only) to use a
    /// separate, disposable notebook, plus `-JIBIJIResetStore YES` to empty it first. UI tests use these
    /// so they never touch real notes. An invalid name stops the app instead of falling back to real
    /// notes. Release builds always use ``standard``.
    static func forLaunch(defaults: UserDefaults = .standard) -> NoteStore {
        #if DEBUG
        return forLaunch(
            storeName: defaults.string(forKey: "JIBIJIStoreName"),
            reset: defaults.bool(forKey: "JIBIJIResetStore")
        )
        #else
        return .standard
        #endif
    }

    #if DEBUG
    /// The launch decision without reading launch arguments, so unit tests can call it directly.
    static func forLaunch(storeName: String?, reset: Bool) -> NoteStore {
        guard let storeName else { return .standard }
        guard let store = testNotebook(named: storeName) else {
            preconditionFailure("-JIBIJIStoreName \"\(storeName)\" may only use ASCII letters, digits, and '-'.")
        }
        if reset {
            try? FileManager.default.removeItem(at: store.directory)
        }
        return store
    }

    /// A disposable notebook for tests, or `nil` if `name` isn't a plain identifier.
    static func testNotebook(named name: String) -> NoteStore? {
        let allowed = !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        guard allowed else { return nil }
        return NoteStore(
            directory: .applicationSupportDirectory.appending(path: "TestNotebooks/\(name)", directoryHint: .isDirectory),
            isTestNotebook: true
        )
    }
    #endif
}
