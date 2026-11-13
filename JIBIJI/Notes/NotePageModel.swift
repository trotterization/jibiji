import Foundation
import Observation
import OSLog
import PencilKit

/// Owns one note page: its latest ink, autosave, and what the page status line shows.
@MainActor
@Observable
final class NotePageModel {
    enum SaveState: Equatable {
        /// Nothing written yet and nothing on disk.
        case empty
        /// Ink changed since the last save; autosave runs after a short pause.
        case unsaved
        case saved
        case failed(String)
        /// The saved page exists but couldn't be read. Editing stays off so the file is never overwritten.
        case cannotOpen(String)
    }

    static let firstPageID = "page-1"

    let pageID: String
    private(set) var drawing: PKDrawing
    private(set) var state: SaveState
    /// A one-time message, e.g. that an unreadable page file was set aside.
    var notice: String?

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var hasUnsavedChanges = false

    init(pageID: String, store: NoteStore, autosaveDelay: Duration = .milliseconds(700)) {
        self.pageID = pageID
        self.store = store
        self.autosaveDelay = autosaveDelay
        let opened = Self.open(pageID: pageID, from: store)
        drawing = opened.drawing
        state = opened.state
        notice = opened.notice
    }

    var isEditable: Bool {
        if case .cannotOpen = state { false } else { true }
    }

    var strokeCount: Int { drawing.strokes.count }

    /// True for the disposable notebooks UI tests launch with.
    var usesTestNotebook: Bool { store.isTestNotebook }

    var statusText: String {
        let strokes = strokeCount == 1 ? "1 stroke" : "\(strokeCount) strokes"
        return switch state {
        case .empty: "Empty page"
        case .unsaved: "\(strokes) · Not saved yet"
        case .saved: "\(strokes) · Saved"
        case .failed: "\(strokes) · Couldn't save"
        case .cannotOpen: "Can't open this page"
        }
    }

    /// Called by the canvas after every stroke, erase, undo, or redo.
    func drawingDidChange(_ newDrawing: PKDrawing) {
        guard isEditable else { return }
        drawing = newDrawing
        hasUnsavedChanges = true
        state = .unsaved
        scheduleAutosave()
    }

    /// Writes pending ink now. Safe to call at any time; does nothing when there is nothing to save.
    func saveIfNeeded() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard hasUnsavedChanges, isEditable else { return }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try store.save(drawing, pageID: pageID)
            hasUnsavedChanges = false
            state = .saved
            let elapsed = start.duration(to: clock.now)
            Logger.notes.notice("Saved \(self.pageID, privacy: .public): \(self.strokeCount) strokes in \(elapsed, privacy: .public)")
        } catch {
            // Keep the changes marked unsaved so the next stroke or backgrounding retries.
            state = .failed(error.localizedDescription)
            Logger.notes.error("Couldn't save \(self.pageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveIfNeeded()
        }
    }

    private static func open(pageID: String, from store: NoteStore) -> (drawing: PKDrawing, state: SaveState, notice: String?) {
        do {
            if let saved = try store.loadDrawing(pageID: pageID) {
                return (saved, .saved, nil)
            }
            return (PKDrawing(), .empty, nil)
        } catch NoteStoreError.unreadableDrawing {
            // Keep the original bytes: move them aside, then start a blank page in their place.
            do {
                let kept = try store.setAsideUnreadablePage(pageID: pageID)
                Logger.notes.error("Set aside unreadable page \(pageID, privacy: .public) as \(kept.lastPathComponent, privacy: .public)")
                return (
                    PKDrawing(),
                    .empty,
                    "The saved page couldn't be opened. Its file was kept as \(kept.lastPathComponent), and a blank page was started."
                )
            } catch {
                return (PKDrawing(), .cannotOpen(error.localizedDescription), nil)
            }
        } catch {
            return (PKDrawing(), .cannotOpen(error.localizedDescription), nil)
        }
    }
}

extension Logger {
    /// A fixed subsystem, so Console filters work whatever bundle ID prefix a teammate signs with.
    static let notes = Logger(subsystem: "com.trotterization.jibiji", category: "notes")
}
