import Foundation
import Observation
import OSLog
import PencilKit

/// The local notebook: an ordered list of pages and which one is open.
///
/// Each page keeps its own ``NotePageModel`` for the whole session, so switching away flushes
/// its pending save, and unsaved ink survives a failed save and is retried later.
@MainActor
@Observable
final class NotebookModel {
    enum LoadState: Equatable {
        case ready
        /// The page list couldn't be read. Nothing is shown or written until it can be.
        case failed(String)
    }

    private(set) var pageIDs: [String] = []
    private(set) var loadState: LoadState = .ready
    private(set) var currentPageID = NotePageModel.firstPageID
    /// A message to show once, e.g. that a page couldn't be saved while switching.
    var alert: String?
    /// Names, colors, pins, and folders, for the home page.
    private(set) var library = NotebookLibrary()
    let homeAppearance: HomeAppearanceModel
    let searchIndex: HandwritingSearchIndex
    let documents: PDFLibrary
    let sync: FolderSyncModel
    private(set) var localRevision = 0
    var pageIsOpen = false
    var homeEditorIsOpen = false
    var canImportSync: Bool { !pageIsOpen && !homeEditorIsOpen }
    var hasPendingInk: Bool { models.values.contains { $0.hasPendingChanges } || documents.hasPendingInk }
    /// False when library.json exists but can't be read: it is then never overwritten.
    @ObservationIgnored private var canSaveLibrary = true

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private var models: [String: NotePageModel] = [:]

    /// A disposable Debug-only notebook for UI tests.
    var usesTestNotebook: Bool { store.isTestNotebook }

    init(store: NoteStore, autosaveDelay: Duration = .milliseconds(700)) {
        self.store = store
        self.homeAppearance = HomeAppearanceModel(directory: store.directory)
        self.searchIndex = HandwritingSearchIndex(directory: store.directory)
        self.documents = PDFLibrary(directory: store.directory.appending(path: "PDFs"), usesTestNotebook: store.isTestNotebook)
        self.sync = FolderSyncModel(directory: store.directory)
        self.autosaveDelay = autosaveDelay
        documents.onChange = { [weak self] in self?.localRevision += 1 }
        do { try SyncTransaction.recover(store.directory) }
        catch { loadState = .failed("Couldn't recover an interrupted sync. Your files have been kept."); return }
        reload()
        #if DEBUG
        if store.isTestNotebook && UserDefaults.standard.bool(forKey: "JIBIJIPDFFixture") { PDFWorkspaceFixture.install(in: documents) }
        #endif
    }

    /// Reads the page list again (also the retry after a failure). Keeps pages already open.
    func reload() {
        do {
            try SyncTransaction.recover(store.directory)
            documents.reload()
            let ids = try store.loadPageIDs()
            pageIDs = ids
            loadState = .ready
            if !ids.contains(currentPageID) { currentPageID = ids[0] }
            loadLibrary()
        } catch {
            pageIDs = []
            loadState = .failed(error.localizedDescription)
            Logger.notes.error("Couldn't read page list: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The open page, or `nil` while the page list can't be read.
    var currentPage: NotePageModel? {
        guard case .ready = loadState, pageIDs.contains(currentPageID) else { return nil }
        return model(for: currentPageID)
    }

    /// The page's name, or "Page 1", "Page 2", … by position in the notebook.
    func title(for pageID: String) -> String {
        library.pages[pageID]?.name ?? defaultTitle(for: pageID)
    }

    func defaultTitle(for pageID: String) -> String {
        "Page \((pageIDs.firstIndex(of: pageID) ?? 0) + 1)"
    }

    func selectPage(_ pageID: String) {
        guard case .ready = loadState, pageIDs.contains(pageID), pageID != currentPageID else { return }
        flushCurrentPage()
        currentPageID = pageID
    }

    /// Adds a blank page after the last one and opens it. The page order is written first, so a page
    /// that fails to be recorded is never shown; the current page is left as it was.
    func createPage() {
        guard case .ready = loadState else { return }
        flushCurrentPage()
        let newID = store.nextPageID(after: pageIDs)
        do {
            try store.savePageIDs(pageIDs + [newID])
        } catch {
            alert = "Couldn't add a page: \(error.localizedDescription)"
            Logger.notes.error("Couldn't add page: \(error.localizedDescription, privacy: .public)")
            return
        }
        localRevision += 1
        pageIDs.append(newID)
        currentPageID = newID
    }

    // MARK: - Home

    var notebookTitle: String { library.title ?? "Notebook" }

    func info(for pageID: String) -> NotebookLibrary.PageInfo {
        library.pages[pageID] ?? NotebookLibrary.PageInfo()
    }

    /// Opens a page from the home page.
    func openPage(_ pageID: String) {
        guard case .ready = loadState, pageIDs.contains(pageID) else { return }
        if pageID != currentPageID { selectPage(pageID) }
    }

    func renameNotebook(_ title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateLibrary { $0.title = clean.isEmpty ? nil : String(clean.prefix(60)) }
    }

    /// An empty name goes back to "Page N".
    func renamePage(_ pageID: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updatePage(pageID) { $0.name = clean.isEmpty ? nil : String(clean.prefix(60)) }
    }

    /// Save the page's home details together; a failed write leaves all fields unchanged.
    func editPage(_ pageID: String, name: String, summary: String, tag: PageTag?, pinned: Bool, folder: String?, labels: String = "") {
        if let folder, !library.folders.contains(folder) { return }
        updatePage(pageID) { info in
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            info.name = title.isEmpty ? nil : String(title.prefix(60))
            info.summary = description.isEmpty ? nil : String(description.prefix(240))
            info.tag = tag
            info.pinned = pinned
            info.folder = folder
            let tags = Array(Set(labels.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }.filter { !$0.isEmpty })).sorted()
            info.labels = tags.isEmpty ? nil : Array(tags.prefix(20))
        }
    }

    func matchesSearch(_ query: String, pageID: String) -> Bool {
        let info = info(for: pageID)
        let ink = models[pageID]?.hasPendingChanges == true ? "" : searchIndex.text(for: pageID, savedAt: store.modificationDate(pageID: pageID))
        let text = [title(for: pageID), info.summary ?? "", info.folder ?? "", info.tag?.name ?? "", (info.labels ?? []).joined(separator: " "), ink].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
    }

    func indexHandwriting() {
        saveAll()
        let pages = pageIDs.compactMap { id -> (id: String, drawing: PKDrawing, savedAt: Date?)? in
            guard models[id]?.hasPendingChanges != true,
                  let drawing = try? store.loadDrawing(pageID: id) else { return nil }
            return (id, drawing, store.modificationDate(pageID: id))
        }
        searchIndex.index(pages) { [weak self] id, date in
            guard let self else { return false }
            return models[id]?.hasPendingChanges != true && store.modificationDate(pageID: id) == date
        }
    }

    func setTag(_ tag: PageTag?, for pageID: String) {
        updatePage(pageID) { $0.tag = tag }
    }

    func togglePin(_ pageID: String) {
        updatePage(pageID) { $0.pinned.toggle() }
    }

    func moveToFolder(_ pageID: String, folder: String?) {
        guard folder == nil || library.folders.contains(folder!) else { return }
        updatePage(pageID) { $0.folder = folder }
    }

    /// Adds a folder, or returns the existing one with that name.
    @discardableResult
    func createFolder(_ name: String) -> String? {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty else { return nil }
        if library.folders.contains(clean) { return clean }
        updateLibrary { $0.folders.append(clean) }
        return library.folders.contains(clean) ? clean : nil
    }

    func renameFolder(_ folder: String, to name: String) {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !clean.isEmpty, clean != folder, !library.folders.contains(clean),
              let index = library.folders.firstIndex(of: folder) else { return }
        updateLibrary { library in
            library.folders[index] = clean
            for (id, info) in library.pages where info.folder == folder { library.pages[id]?.folder = clean }
        }
    }

    /// Removes the folder only. Its pages stay, unfiled.
    func deleteFolder(_ folder: String) {
        updateLibrary { library in
            library.folders.removeAll { $0 == folder }
            for (id, info) in library.pages where info.folder == folder { library.pages[id]?.folder = nil }
        }
    }

    /// Moves a page to `target`'s place in the notebook order. Unnamed pages keep "Page N" by position.
    func movePage(_ pageID: String, to target: String) {
        guard case .ready = loadState, pageID != target,
              let from = pageIDs.firstIndex(of: pageID), let to = pageIDs.firstIndex(of: target) else { return }
        var reordered = pageIDs
        reordered.remove(at: from)
        reordered.insert(pageID, at: to)
        do {
            try store.savePageIDs(reordered)
            pageIDs = reordered
            localRevision += 1
        } catch {
            alert = "Couldn't move the page: \(error.localizedDescription)"
        }
    }

    /// The page's ink for a preview: what's open now, else what's saved.
    func previewDrawing(for pageID: String) -> PKDrawing {
        if let open = models[pageID] { return open.drawing }
        return (try? store.loadDrawing(pageID: pageID)) ?? PKDrawing()
    }

    func lastEdited(_ pageID: String) -> Date? {
        if let open = models[pageID], open.hasPendingChanges { return .now }
        return store.modificationDate(pageID: pageID)
    }

    private func loadLibrary() {
        do {
            library = try store.loadLibrary()
            canSaveLibrary = true
        } catch {
            library = NotebookLibrary()
            canSaveLibrary = false
            Logger.notes.error("Couldn't read library: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updatePage(_ pageID: String, _ change: (inout NotebookLibrary.PageInfo) -> Void) {
        guard pageIDs.contains(pageID) else { return }
        updateLibrary { library in
            var info = library.pages[pageID] ?? NotebookLibrary.PageInfo()
            change(&info)
            library.pages[pageID] = info.isEmpty ? nil : info
        }
    }

    private func updateLibrary(_ change: (inout NotebookLibrary) -> Void) {
        guard canSaveLibrary else {
            alert = "Page names and folders can't be changed right now: their file couldn't be read. Your pages are untouched."
            return
        }
        var updated = library
        change(&updated)
        guard updated != library else { return }
        do {
            try store.saveLibrary(updated)
            library = updated
            localRevision += 1
        } catch {
            alert = "Couldn't save that change: \(error.localizedDescription)"
        }
    }

    /// Saves every page with pending ink (autosave timers, backgrounding).
    func saveAll() {
        for model in models.values { model.saveIfNeeded() }
        documents.saveAll()
    }

    func didImportSync() {
        searchIndex.cancel()
        for page in models.values { page.suggestions.cancelPending() }
        models.removeAll()
        documents.forgetSavedModels()
        localRevision += 1
        reload()
        documents.reload()
    }

    private func flushCurrentPage() {
        guard let page = models[currentPageID] else { return }
        page.saveIfNeeded()
        if case .failed = page.state {
            alert = "\(title(for: page.pageID)) couldn't be saved. Your writing is kept and will be saved again when possible."
        }
    }

    private func model(for pageID: String) -> NotePageModel {
        if let existing = models[pageID] { return existing }
        let created = NotePageModel(pageID: pageID, store: store, autosaveDelay: autosaveDelay)
        created.onInkChange = { [weak self] in self?.localRevision += 1 }
        models[pageID] = created
        return created
    }
}
