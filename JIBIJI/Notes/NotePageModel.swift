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

    /// Provisional suggestions and accepted notes for this page, kept apart from the ink.
    let suggestions: PageSuggestionModel

    /// This page's flashcards (one deck per page), kept apart from the ink.
    let flashcards: PageFlashcards

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var hasUnsavedChanges = false
    /// Ink not written to disk yet.
    var hasPendingChanges: Bool { hasUnsavedChanges }

    init(
        pageID: String,
        store: NoteStore,
        autosaveDelay: Duration = .milliseconds(700),
        lineReader: (any InkLineReader)? = nil
    ) {
        let suggestionReader: any InkLineReader
        if let lineReader {
            suggestionReader = lineReader
        } else {
            #if DEBUG
            if store.isTestNotebook && UserDefaults.standard.bool(forKey: "JIBIJIReplacementFixture") {
                suggestionReader = ReplacementFixtureReader()
            } else {
                suggestionReader = PencilInkLineReader(mode: .suggestions)
            }
            #else
            suggestionReader = PencilInkLineReader(mode: .suggestions)
            #endif
        }
        self.pageID = pageID
        self.suggestions = PageSuggestionModel(
            pageID: pageID,
            store: SuggestionStore(directory: store.directory),
            reader: suggestionReader,
            // The app consults the offline CC-CEDICT dictionary; tests that inject a reader keep the small starter list.
            vocabulary: lineReader == nil ? .full : .standard
        )
        self.flashcards = PageFlashcards(
            pageID: pageID,
            store: store,
            reader: lineReader ?? PencilInkLineReader(mode: .primaryOnly)
        )
        self.store = store
        self.autosaveDelay = autosaveDelay
        let opened = Self.open(pageID: pageID, from: store)
        drawing = opened.drawing
        state = opened.state
        notice = opened.notice
        // Seed the digest so saved cards read as current until the ink changes.
        flashcards.inkChanged(opened.drawing)
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
        suggestions.sourceDidChange()
        flashcards.inkChanged(newDrawing)
        hasUnsavedChanges = true
        state = .unsaved
        scheduleAutosave()
    }

    /// Accept a reading as actual, erasable ink in the source region.
    @discardableResult
    func replaceSuggestion(_ id: UUID, with text: String) -> Bool {
        guard isEditable, let item = suggestions.pending.first(where: { $0.id == id }) else { return false }
        // Replace is the student's call; an uncertain reading shows its caveat on the chip and Restore undoes it.
        guard item.allowsInkReplacement else {
            notice = "This reading is uncertain, so your handwriting was not changed. You can add it as a note instead."
            return false
        }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let indices = drawing.strokes.indices.filter { item.sourceStrokeIDs.contains(InkSelection.identity(drawing.strokes[$0])) }
        guard !indices.isEmpty else {
            notice = "Couldn't match this suggestion to the original strokes. Try reading the page again."
            return false
        }
        let originals = indices.map { drawing.strokes[$0] }
        let sourceBounds = originals.dropFirst().reduce(originals[0].renderBounds) { $0.union($1.renderBounds) }
        // Written at the height of the student's handwriting and allowed to run to the right (up to about a page width),
        // so `是 · shì · to be` replacing a short `shì` is not shrunk into that word's box. − and + still resize it.
        guard let replacement = CleanHandwriting.drawing(text: cleanText, in: sourceBounds,
                                                        pen: .matching(originals), maxWidth: 640) else {
            notice = "This replacement couldn't be drawn. Your writing is unchanged."
            return false
        }
        let recovery = InkReplacement(originalInk: PKDrawing(strokes: originals).dataRepresentation(),
                                      originalIndices: indices,
                                      replacementStrokeIDs: Set(replacement.strokes.map(InkSelection.identity)))
        let remaining = suggestions.pending.filter { $0.id != id }
        guard suggestions.acceptReplacement(item, text: cleanText, bounds: sourceBounds, recovery: recovery) else { return false }
        let removed = Set(indices)
        var updated = drawing.strokes.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        updated.insert(contentsOf: replacement.strokes, at: min(indices[0], updated.count))
        drawingDidChange(PKDrawing(strokes: updated))
        suggestions.keepUnchangedPending(remaining, excluding: sourceBounds.union(replacement.bounds))
        saveIfNeeded()
        return true
    }

    /// Recovery works after relaunch and preserves ink added after the replacement.
    @discardableResult
    func restoreOriginal(_ noteID: UUID) -> Bool {
        guard isEditable, let note = suggestions.annotations.first(where: { $0.id == noteID }),
              let recovery = note.replacement,
              let original = try? PKDrawing(data: recovery.originalInk),
              PageSuggestionModel.isVisible(note, in: drawing) else { return false }
        var strokes = drawing.strokes.filter { !recovery.replacementStrokeIDs.contains(InkSelection.identity($0)) }
        for (stroke, index) in zip(original.strokes, recovery.originalIndices) {
            strokes.insert(stroke, at: min(index, strokes.count))
        }
        drawingDidChange(PKDrawing(strokes: strokes))
        saveIfNeeded()
        // Keep the receipt for native redo/recovery; the source IDs determine visibility.
        return true
    }

    func deleteReplacement(_ id: UUID) {
        guard let note = suggestions.annotations.first(where: { $0.id == id }), let replacement = note.replacement else { return }
        drawingDidChange(PKDrawing(strokes: drawing.strokes.filter { !replacement.replacementStrokeIDs.contains(InkSelection.identity($0)) }))
        saveIfNeeded()
    }

    /// Moves or resizes a replacement. Points move; widths stay, so it keeps matching the pen.
    /// Earlier stroke IDs stay on the receipt, so native undo, Restore, and visibility keep working.
    @discardableResult
    func adjustReplacement(_ noteID: UUID, by transform: CGAffineTransform) -> Bool {
        guard isEditable, transform != .identity,
              let note = suggestions.annotations.first(where: { $0.id == noteID }),
              var recovery = note.replacement else { return false }
        let indices = drawing.strokes.indices.filter { recovery.replacementStrokeIDs.contains(InkSelection.identity(drawing.strokes[$0])) }
        guard !indices.isEmpty else { return false }
        let moved = indices.map { index -> PKStroke in
            let stroke = drawing.strokes[index]
            // Older replacements are masked glyph outlines: move those as a whole.
            guard stroke.mask == nil else {
                var copy = stroke
                copy.transform = stroke.transform.concatenating(transform)
                return copy
            }
            let full = stroke.transform.concatenating(transform)
            let points = stroke.path.map { point in
                PKStrokePoint(location: point.location.applying(full), timeOffset: point.timeOffset, size: point.size,
                              opacity: point.opacity, force: point.force, azimuth: point.azimuth, altitude: point.altitude)
            }
            return PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate))
        }
        guard let canonical = try? PKDrawing(data: PKDrawing(strokes: moved).dataRepresentation()),
              canonical.strokes.count == moved.count else { return false }
        recovery.replacementStrokeIDs.formUnion(canonical.strokes.map(InkSelection.identity))
        let bounds = canonical.strokes.dropFirst().reduce(canonical.strokes[0].renderBounds) { $0.union($1.renderBounds) }
        guard suggestions.updateReplacement(noteID, anchor: bounds, recovery: recovery) else { return false }
        var strokes = drawing.strokes
        for (index, stroke) in zip(indices, canonical.strokes) { strokes[index] = stroke }
        drawingDidChange(PKDrawing(strokes: strokes))
        saveIfNeeded()
        return true
    }

    /// Where a replacement's ink is now, in page coordinates.
    func replacementBounds(_ note: AcceptedAnnotation) -> CGRect? {
        guard let ids = note.replacement?.replacementStrokeIDs else { return nil }
        let strokes = drawing.strokes.filter { ids.contains(InkSelection.identity($0)) }
        guard let first = strokes.first else { return nil }
        return strokes.dropFirst().reduce(first.renderBounds) { $0.union($1.renderBounds) }
    }

    var latestVisibleReplacement: AcceptedAnnotation? {
        suggestions.annotations.last { $0.replacement != nil && PageSuggestionModel.isVisible($0, in: drawing) }
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

#if DEBUG
/// Deterministic UI-test provider, restricted to disposable test notebooks.
private struct ReplacementFixtureReader: InkLineReader {
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
        drawing.strokes.isEmpty ? [] : [RecognizedLine(text: "大", bounds: drawing.bounds, readings: ["大", "牛", "我"])]
    }
}
#endif
