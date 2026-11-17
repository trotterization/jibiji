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

    // MARK: - Page order

    static let pageIndexFileName = "notebook.json"
    private struct PageIndex: Codable {
        var version: Int
        var pageIDs: [String]
    }

    var pageIndexURL: URL {
        directory.appending(path: Self.pageIndexFileName, directoryHint: .notDirectory)
    }

    /// Page IDs are `page-<number>`, which also keeps them safe to use in file names.
    static func pageNumber(of pageID: String) -> Int? {
        guard pageID.hasPrefix("page-") else { return nil }
        let digits = pageID.dropFirst(5)
        guard !digits.isEmpty, digits.count < 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// The pages in notebook order.
    ///
    /// Reads `notebook.json`. A notebook from before page order was stored (M0: just `page-1.drawing`)
    /// has no index; its pages are discovered from the page files and nothing is rewritten, so the
    /// existing drawing stays byte-for-byte as it was. The index is first written when a page is added.
    ///
    /// Throws ``NoteStoreError/unreadablePageIndex(url:reason:)`` if the index exists but isn't valid.
    /// Callers must not replace an index they couldn't read.
    func loadPageIDs() throws -> [String] {
        let data: Data
        do {
            data = try Data(contentsOf: pageIndexURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return try discoverPageIDs()
        }
        let index: PageIndex
        do {
            index = try JSONDecoder().decode(PageIndex.self, from: data)
        } catch {
            throw NoteStoreError.unreadablePageIndex(url: pageIndexURL, reason: error.localizedDescription)
        }
        guard index.version == 1 else {
            throw NoteStoreError.unreadablePageIndex(url: pageIndexURL, reason: "it was written by a newer version of JIBIJI (format \(index.version))")
        }
        guard !index.pageIDs.isEmpty,
              Set(index.pageIDs).count == index.pageIDs.count,
              index.pageIDs.allSatisfy({ Self.pageNumber(of: $0) != nil })
        else {
            throw NoteStoreError.unreadablePageIndex(url: pageIndexURL, reason: "its page list is empty, repeats a page, or has an invalid page name")
        }
        return index.pageIDs
    }

    /// Pre-index notebooks: `page-1` plus any `page-N.drawing` files, in numeric order.
    private func discoverPageIDs() throws -> [String] {
        var numbers: Set<Int> = [1]
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "drawing" {
                if let number = Self.pageNumber(of: url.deletingPathExtension().lastPathComponent) {
                    numbers.insert(number)
                }
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // No notes folder yet: a new notebook.
        }
        return numbers.sorted().map { "page-\($0)" }
    }

    /// Writes the page order atomically.
    func savePageIDs(_ pageIDs: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(PageIndex(version: 1, pageIDs: pageIDs)).write(
            to: pageIndexURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    /// The next unused page ID: one past the highest number in use, including pages with files on disk.
    func nextPageID(after pageIDs: [String]) -> String {
        var highest = pageIDs.compactMap(Self.pageNumber(of:)).max() ?? 0
        if let onDisk = try? discoverPageIDs().compactMap(Self.pageNumber(of:)).max() {
            highest = max(highest, onDisk)
        }
        return "page-\(highest + 1)"
    }

    /// When a page was last saved, or `nil` if it never was.
    func modificationDate(pageID: String) -> Date? {
        (try? fileURL(forPage: pageID).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Library (names, colors, pins, folders)

    static let libraryFileName = "library.json"

    var libraryURL: URL {
        directory.appending(path: Self.libraryFileName, directoryHint: .notDirectory)
    }

    /// How the student arranged the notebook. Kept apart from the ink and the page order, so a
    /// problem here never touches either. A notebook without the file gets the defaults.
    func loadLibrary() throws -> NotebookLibrary {
        let data: Data
        do {
            data = try Data(contentsOf: libraryURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return NotebookLibrary()
        }
        guard let library = try? JSONDecoder().decode(NotebookLibrary.self, from: data), library.version == 1 else {
            throw NoteStoreError.unreadableLibrary(url: libraryURL)
        }
        return library
    }

    func saveLibrary(_ library: NotebookLibrary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: libraryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

/// Names, colors, pins, and folders for the home page. Folders only group pages: no file moves.
struct NotebookLibrary: Codable, Equatable {
    var version = 1
    var title: String?
    var folders: [String] = []
    var pages: [String: PageInfo] = [:]

    struct PageInfo: Codable, Equatable {
        var name: String?
        var summary: String? = nil
        var tag: PageTag?
        var pinned = false
        var folder: String?

        var isEmpty: Bool { name == nil && summary == nil && tag == nil && !pinned && folder == nil }
    }
}

/// A page's color on the home page: the logo's colors, plus graphite.
enum PageTag: String, Codable, CaseIterable, Identifiable {
    case rose, gold, teal, graphite

    var id: Self { self }
    var name: String { rawValue.capitalized }
}

enum NoteStoreError: Error, LocalizedError {
    case unreadableDrawing(url: URL, underlying: any Error)
    case unreadablePageIndex(url: URL, reason: String)
    case unreadableLibrary(url: URL)

    var errorDescription: String? {
        switch self {
        case .unreadableLibrary(let url):
            "Page names and folders (\(url.lastPathComponent)) can't be read. Your pages are untouched."
        case .unreadablePageIndex(let url, let reason):
            "The page list (\(url.lastPathComponent)) can't be read: \(reason). Your page files are untouched."
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
