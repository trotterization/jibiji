import Foundation
import Observation
import OSLog

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

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private var models: [String: NotePageModel] = [:]

    /// A disposable Debug-only notebook for UI tests.
    var usesTestNotebook: Bool { store.isTestNotebook }

    init(store: NoteStore, autosaveDelay: Duration = .milliseconds(700)) {
        self.store = store
        self.autosaveDelay = autosaveDelay
        reload()
    }

    /// Reads the page list again (also the retry after a failure). Keeps pages already open.
    func reload() {
        do {
            let ids = try store.loadPageIDs()
            pageIDs = ids
            loadState = .ready
            if !ids.contains(currentPageID) { currentPageID = ids[0] }
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

    /// "Page 1", "Page 2", … by position in the notebook.
    func title(for pageID: String) -> String {
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
        pageIDs.append(newID)
        currentPageID = newID
    }

    /// Saves every page with pending ink (autosave timers, backgrounding).
    func saveAll() {
        for model in models.values { model.saveIfNeeded() }
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
        models[pageID] = created
        return created
    }
}
