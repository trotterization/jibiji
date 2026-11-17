import CoreGraphics
import Foundation
import Observation
import OSLog
import PencilKit

/// A line of ink and what the recognizer read from it. `bounds` are in page (drawing) coordinates.
struct RecognizedLine: Sendable, Equatable {
    var text: String
    var bounds: CGRect
    /// Original PencilKit text, only when `text` was refined by a second pass.
    var sourceText: String? = nil
    /// Image-recognition readings for user confirmation, not dictionary meanings.
    var readings: [String] = []
    var readingNeedsReview = false
    var pinyinReadingConfirmed = false
    /// Another reading confirms the written Pinyin: fix transcription, never the ink.
    var pinyinTranscriptionCorrected = false
    var rawText: String { sourceText ?? text }
}

/// Reads the text of each written line. Injected so tests don't need PencilKit recognition.
protocol InkLineReader: Sendable {
    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine]
}

enum InkLineReaderError: Error, LocalizedError, Equatable {
    case unsupported
    var errorDescription: String? { "On-device handwriting recognition needs iPadOS 27." }
}

/// Prefer native stroke recognition, with a Chinese image fallback where it is unavailable.
struct PencilInkLineReader: InkLineReader {
    enum Mode: Sendable {
        /// Primary text for flashcards; image fallback if Chinese stroke recognition is unavailable.
        case primaryOnly
        /// Suggestions: DEBUG builds may add the bounded Hanzi-prefix Paddle second pass.
        case suggestions
    }

    var mode: Mode = .suggestions

    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
        guard !drawing.strokes.isEmpty else { return [] }
        if UserDefaults.standard.bool(forKey: "JibijiUsePaddlePipeline") {
            let detected = try await PaddleTextPipeline.shared.lines(in: drawing)
            var result: [RecognizedLine] = []
            for var line in detected {
                try Task.checkCancellation()
                let indices = InkSelection.indices(in: drawing, bounds: line.bounds)
                if !indices.isEmpty {
                    let crop = PKDrawing(strokes: indices.map { drawing.strokes[$0] })
                    let readings = (try? await VisionInkReader.shared.lineReadings(in: crop)) ?? []
                    for text in readings where !line.readings.contains(text) { line.readings.append(text) }
                }
                result.append(line)
            }
            try Task.checkCancellation()
            return result
        }
        // The simulator exposes English-only stroke recognition. Read rendered ink in
        // Chinese instead of interpreting Hanzi as English letters. Also works on older OSes.
        guard #available(iOS 27.0, *),
              PKStrokeRecognizer.supportedLanguages.contains(where: { $0.maximalIdentifier.hasPrefix("zh-Hans") }) else {
            return try await VisionInkReader.shared.lines(in: drawing)
        }
        let recognizer = PKStrokeRecognizer(preferredLanguages: RecognitionProbe.preferredLanguages)
        await recognizer.updateDrawing(drawing)
        var result: [RecognizedLine] = []
        for group in InkLineGeometry.lineGroups(in: drawing) where !group.isEmpty {
            try Task.checkCancellation()
            let strokes = group.map { drawing.strokes[$0] }
            let bounds = strokes.dropFirst().reduce(strokes[0].renderBounds) { $0.union($1.renderBounds) }
            guard bounds.minX.isFinite, bounds.maxY.isFinite, bounds.width.isFinite, bounds.height.isFinite else { continue }
            let text = await recognizer.recognizedText(strokeIDs: Set(strokes.map(\.id)))
            if let raw = text, !raw.isEmpty {
                var text = raw
                if mode == .suggestions { text = await HanziPrefixFallback.resolve(primary: raw, strokes: strokes) }
                let readings = (try? await VisionInkReader.shared.lineReadings(in: PKDrawing(strokes: strokes))) ?? []
                try Task.checkCancellation()
                result.append(RecognizedLine(text: text, bounds: bounds, sourceText: text == raw ? nil : raw,
                                             readings: readings)) }
        }
        return result
    }
}

/// A provisional suggestion next to one line of ink. Never part of the ink.
struct PendingSuggestion: Identifiable, Equatable {
    let id = UUID()
    /// Ink revision this was computed from; it is dropped when the ink changes.
    let revision: Int
    var anchor: CGRect
    var recognizedText: String
    /// Original PencilKit text, only when `recognizedText` was refined.
    var sourceText: String? = nil
    var proposal: SuggestionProposal
    var selectedIndex = 0
    var sourceStrokeIDs: Set<String> = []

    var candidate: SuggestionCandidate { proposal.candidates[selectedIndex] }
    var hasAlternatives: Bool { proposal.candidates.count > 1 }

    /// The note to add beside the ink: Hanzi unless already written, then the gloss unless already written.
    var annotationText: String {
        // An alternative is a different word: its note is always complete and never relies on what the
        // primary's Hanzi/gloss flags say is already written.
        if candidate.pinyin.isEmpty && candidate.gloss.isEmpty { return candidate.hanzi }
        if selectedIndex > 0 { return "\(candidate.hanzi) · (\(candidate.pinyin)) · \(candidate.gloss)" }
        var parts: [String] = []
        if !proposal.hanziAlreadyWritten {
            let prefix = proposal.hanziPrefixWritten
            if !prefix.isEmpty, candidate.hanzi.hasPrefix(prefix) {
                parts.append(String(candidate.hanzi.dropFirst(prefix.count)))
            } else {
                parts.append(candidate.hanzi)
            }
        }
        if !proposal.pinyinAlreadyWritten { parts.append("(\(candidate.pinyin))") }
        if !proposal.glossAlreadyWritten { parts.append(candidate.gloss) }
        return parts.joined(separator: " · ")
    }

    /// Acceptance replaces the entire recognized region, including its written Pinyin and English.
    var replacementText: String {
        guard !candidate.pinyin.isEmpty || !candidate.gloss.isEmpty else { return candidate.hanzi }
        let pinyin = selectedIndex == 0 ? proposal.writtenPinyin ?? candidate.pinyin : candidate.pinyin
        let gloss = selectedIndex == 0 ? proposal.writtenGloss ?? candidate.gloss : candidate.gloss
        return [candidate.hanzi, pinyin, gloss].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// An accepted (or edited) note. Stored apart from the ink, per page.
struct AcceptedAnnotation: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var edited: Bool
    var anchor: CGRect
    var recognizedText: String
    /// Structured metadata set at acceptance. Optional so older saved notes (text only) still load.
    var hanzi: String? = nil
    var pinyin: String? = nil
    /// The English the user approved (including their edits). Nil when the note carries none.
    var gloss: String? = nil
    var replacement: InkReplacement? = nil

    /// A note's text split into parts. Parts joined by "·"; Hanzi, pinyin and anything else (gloss).
    struct ParsedText: Equatable {
        var hanzi: String?
        var pinyin: String?
        var glossParts: [String] = []
        var ambiguous = false
    }

    /// `knownPinyin` is the only text accepted as pinyin (parenthesised or bare); everything else non-Hanzi is gloss.
    static func parse(_ text: String, knownPinyin: String?) -> ParsedText {
        var result = ParsedText()
        let target = knownPinyin.map { StarterVocabulary.latinTokens($0).joined() }
        for raw in text.split(separator: "·") {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            let inner = part.hasPrefix("(") && part.hasSuffix(")") ? String(part.dropFirst().dropLast()) : part
            let hanziOnly = !StarterVocabulary.hanzi(in: part).isEmpty
                && StarterVocabulary.hanzi(in: part).count == part.count
            if hanziOnly {
                if result.hanzi != nil { result.ambiguous = true }
                result.hanzi = part
            } else if let target, !target.isEmpty, StarterVocabulary.latinTokens(inner).joined() == target {
                result.pinyin = knownPinyin.map { RecognitionCrossCheck.pinyinAgrees(inner, with: $0) ? $0 : inner }
            } else if !StarterVocabulary.hanzi(in: part).isEmpty {
                result.ambiguous = true
            } else {
                result.glossParts.append(part)
            }
        }
        return result
    }
}

/// Suggestion state for one page: pending results, accepted notes, and one-step-at-a-time undo.
@MainActor
@Observable
final class PageSuggestionModel {
    enum Status: Equatable {
        case idle
        case checking
        /// A calm one-line explanation; writing is never blocked.
        case message(String)
    }

    private(set) var pending: [PendingSuggestion] = []
    private(set) var annotations: [AcceptedAnnotation]
    private(set) var status: Status = .idle
    /// Accepted annotations, newest last, that Undo can remove.
    private(set) var undoStack: [UUID] = []
    /// Why accepted notes aren't saved (nil when fine).
    private(set) var storageProblem: String?

    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private let reader: any InkLineReader
    @ObservationIgnored private let vocabulary: StarterVocabulary
    @ObservationIgnored private let store: SuggestionStore
    @ObservationIgnored private let pageID: String
    @ObservationIgnored private var canSave = true
    /// Exposed so tests can wait for a request.
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    init(
        pageID: String,
        store: SuggestionStore,
        reader: any InkLineReader = PencilInkLineReader(),
        vocabulary: StarterVocabulary = .standard
    ) {
        self.pageID = pageID
        self.store = store
        self.reader = reader
        self.vocabulary = vocabulary
        do {
            annotations = try store.load(pageID: pageID)
        } catch {
            // Keep the unreadable file untouched: never write over it.
            annotations = []
            canSave = false
            storageProblem = "Saved suggestions couldn't be read, so new ones won't be saved on this page."
            Logger.notes.error("Couldn't read annotations for \(pageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: - Source changes

    /// The ink changed (stroke, erase, undo, redo): any pending result or running request is stale.
    ///
    /// Accepted notes are never removed or saved because of ink changes; see `isVisible(_:in:)`.
    func sourceDidChange() {
        revision += 1
        task?.cancel()
        task = nil
        pending = []
        status = .idle
    }

    /// Whether a note's source ink is currently present. Derived from the current drawing, so erasing
    /// hides the note and undoing the erase (or redrawing there) shows it again. Nothing is persisted.
    static func isVisible(_ note: AcceptedAnnotation, in drawing: PKDrawing) -> Bool {
        if let replacement = note.replacement {
            return drawing.strokes.contains { replacement.replacementStrokeIDs.contains(InkSelection.identity($0)) && !$0.renderBounds.isEmpty }
        }
        return drawing.strokes.contains { $0.renderBounds.intersects(note.anchor) }
    }

    /// The page is no longer shown: drop pending suggestions and any running request. Accepted notes stay.
    func cancelPending() {
        revision += 1
        task?.cancel()
        task = nil
        pending = []
        status = .idle
    }

    /// Lowest page y (just past the last chip) that notes need, so the canvas can scroll to them.
    var noteBottom: CGFloat? {
        let accepted = annotations.filter { $0.replacement == nil }.map { $0.anchor.maxY + 6 + 36 }
        let provisional = pending.map { item in
            item.anchor.maxY
        }
        return (accepted + provisional).max()
    }

    // MARK: - Requests

    /// Explicit request. Reads the page's lines on a task and shows results only if the ink is unchanged.
    func request(for drawing: PKDrawing) {
        task?.cancel()
        pending = []
        guard !drawing.strokes.isEmpty else {
            status = .message("Write something first, then ask for a suggestion.")
            return
        }
        status = .checking
        let requested = revision
        let reader = reader
        task = Task { [weak self] in
            let outcome: Result<[RecognizedLine], any Error>
            do { outcome = .success(try await reader.lines(in: drawing)) } catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled, self.revision == requested else { return }
            self.finish(outcome, revision: requested, drawing: drawing)
        }
    }

    private func finish(_ outcome: Result<[RecognizedLine], any Error>, revision: Int, drawing: PKDrawing) {
        switch outcome {
        case .failure(let error):
            // Recognition trouble never blocks writing or touches strokes.
            status = .message(error is InkLineReaderError ? error.localizedDescription : "Suggestions aren't available right now. Keep writing.")
        case .success(let recognized):
            let lines = RecognitionCrossCheck.resolve(recognized, vocabulary: vocabulary)
            pending = lines.compactMap { line in
                let proposal: SuggestionProposal
                var seen = Set<String>()
                let readings = ([line.text] + line.readings).filter { !$0.isEmpty && seen.insert($0).inserted }
                if let known = vocabulary.proposal(forRecognizedText: line.text) {
                    proposal = known
                } else if !line.pinyinReadingConfirmed, !line.readings.isEmpty,
                          readings.contains(where: { !StarterVocabulary.hanzi(in: $0).isEmpty }),
                          readings.count > 1 || StarterVocabulary.hanzi(in: line.text).count == 1 {
                    proposal = SuggestionProposal(
                        candidates: readings.map { SuggestionCandidate(hanzi: $0, pinyin: "", gloss: "") },
                        hanziAlreadyWritten: false, glossAlreadyWritten: true)
                } else { return nil }
                let alreadyAccepted = annotations.contains { note in
                    note.recognizedText == line.rawText && note.anchor.intersects(line.bounds) && Self.isVisible(note, in: drawing)
                }
                if alreadyAccepted { return nil }
                return PendingSuggestion(revision: revision, anchor: line.bounds, recognizedText: line.text,
                                         sourceText: line.sourceText, proposal: proposal,
                                         sourceStrokeIDs: Set(InkSelection.indices(in: drawing, bounds: line.bounds).map { InkSelection.identity(drawing.strokes[$0]) }))
            }
            status = pending.isEmpty ? .message("No clear reading found. Try a smaller group of words or clearer spacing. Your ink is unchanged.") : .idle
        }
    }

    // MARK: - Actions

    func select(_ index: Int, for id: UUID) {
        guard let i = pending.firstIndex(where: { $0.id == id }), pending[i].proposal.candidates.indices.contains(index) else { return }
        pending[i].selectedIndex = index
    }

    func dismiss(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    /// Accepts the pending suggestion, or the user's edited text. Ignored if the ink changed since it was computed.
    func accept(_ id: UUID, editedText: String? = nil) {
        guard let suggestion = pending.first(where: { $0.id == id }), suggestion.revision == revision else { return }
        let edited = editedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (edited?.isEmpty == false ? edited : nil) ?? suggestion.annotationText
        guard !text.isEmpty else { return }
        // The accepted gloss comes from the final text (so user edits win), never from the candidate's own English.
        let parsed = AcceptedAnnotation.parse(text, knownPinyin: suggestion.candidate.pinyin)
        let gloss = parsed.ambiguous || parsed.glossParts.isEmpty ? nil : parsed.glossParts.joined(separator: " · ")
        let annotation = AcceptedAnnotation(
            id: UUID(),
            text: text,
            edited: edited?.isEmpty == false && edited != suggestion.annotationText,
            anchor: suggestion.anchor,
            recognizedText: suggestion.sourceText ?? suggestion.recognizedText,
            hanzi: suggestion.candidate.hanzi,
            pinyin: suggestion.candidate.pinyin,
            gloss: gloss
        )
        annotations.append(annotation)
        undoStack.append(annotation.id)
        pending.removeAll { $0.id == id }
        persist()
    }

    /// Persist recovery information before the page is changed. A failed metadata
    /// write must never result in deleting the original handwritten strokes.
    func acceptReplacement(_ item: PendingSuggestion, text: String, bounds: CGRect, recovery: InkReplacement) -> Bool {
        guard canSave, item.revision == revision, pending.contains(where: { $0.id == item.id }) else { return false }
        let sameCandidate = text == item.candidate.hanzi
        let parsed = AcceptedAnnotation.parse(text, knownPinyin: item.candidate.pinyin)
        let parsedGloss = parsed.ambiguous || parsed.glossParts.isEmpty ? nil : parsed.glossParts.joined(separator: " · ")
        let note = AcceptedAnnotation(id: UUID(), text: text, edited: !sameCandidate && text != item.replacementText, anchor: bounds,
                                      recognizedText: item.sourceText ?? item.recognizedText,
                                      hanzi: parsed.ambiguous ? nil : parsed.hanzi,
                                      pinyin: parsed.pinyin ?? (sameCandidate && !item.candidate.pinyin.isEmpty ? item.candidate.pinyin : nil),
                                      gloss: parsedGloss ?? (sameCandidate && !item.candidate.gloss.isEmpty ? item.candidate.gloss : nil),
                                      replacement: recovery)
        do {
            try store.save(annotations + [note], pageID: pageID)
            annotations.append(note)
            undoStack.append(note.id)
            pending.removeAll { $0.id == item.id }
            storageProblem = nil
            return true
        } catch {
            storageProblem = "The replacement couldn't be saved. Your original writing is unchanged."
            return false
        }
    }

    func keepUnchangedPending(_ items: [PendingSuggestion], excluding bounds: CGRect) {
        pending = items.filter { !$0.anchor.intersects(bounds) }.map { item in
            return PendingSuggestion(revision: revision, anchor: item.anchor, recognizedText: item.recognizedText,
                                        sourceText: item.sourceText, proposal: item.proposal,
                                        selectedIndex: item.selectedIndex, sourceStrokeIDs: item.sourceStrokeIDs)
        }
    }

    /// Removes the most recently accepted note.
    func undoLastAccept() {
        guard let id = undoStack.popLast() else { return }
        annotations.removeAll { $0.id == id }
        persist()
    }

    func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        undoStack.removeAll { $0 == id }
        persist()
    }

    private func persist() {
        guard canSave else { return }
        do {
            try store.save(annotations, pageID: pageID)
            storageProblem = nil
        } catch {
            storageProblem = "Suggestions couldn't be saved: \(error.localizedDescription)"
            Logger.notes.error("Couldn't save annotations for \(self.pageID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Accepted annotations as one small JSON file per page, written atomically beside the page's ink file.
struct SuggestionStore: Sendable {
    let directory: URL

    private struct File: Codable {
        var version: Int
        var annotations: [AcceptedAnnotation]
    }

    func fileURL(pageID: String) -> URL {
        directory.appending(path: "\(pageID).annotations.json", directoryHint: .notDirectory)
    }

    /// Empty when the page has none. Throws if a file exists but can't be read, so callers don't overwrite it.
    func load(pageID: String) throws -> [AcceptedAnnotation] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(pageID: pageID))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return file.annotations
    }

    func save(_ annotations: [AcceptedAnnotation], pageID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(version: 1, annotations: annotations)).write(
            to: fileURL(pageID: pageID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
