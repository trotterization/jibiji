import Foundation
import Observation
import PencilKit

/// Derived, on-device search text. A stale entry is never used for matching.
@MainActor @Observable
final class HandwritingSearchIndex {
    struct Entry: Codable { var savedAt: Date?; var text: String }
    private(set) var entries: [String: Entry] = [:]
    private(set) var isIndexing = false
    private(set) var message: String?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    init(directory: URL) {
        url = directory.appending(path: "search-index.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved }
    }

    func text(for id: String, savedAt: Date?) -> String {
        guard let entry = entries[id], entry.savedAt == savedAt else { return "" }
        return entry.text
    }

    @discardableResult
    func index(_ pages: [(id: String, drawing: PKDrawing, savedAt: Date?)],
               reader: any InkLineReader = PencilInkLineReader(mode: .primaryOnly),
               stillCurrent: @escaping (String, Date?) -> Bool) -> Task<Void, Never> {
        task?.cancel()
        isIndexing = true; message = nil
        let work = Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for page in pages {
                if Task.isCancelled { return }
                if let entry = entries[page.id], entry.savedAt == page.savedAt { continue }
                do {
                    let lines = try await reader.lines(in: page.drawing)
                    try Task.checkCancellation()
                    guard stillCurrent(page.id, page.savedAt) else { continue }
                    entries[page.id] = Entry(savedAt: page.savedAt, text: lines.map(\.text).joined(separator: " "))
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch is CancellationError { return }
                catch { failed += 1 }
                await Task.yield()
            }
            isIndexing = false
            message = failed == 0 ? "Handwriting index is up to date. Recognition can miss words." : "Couldn't index \(failed) page(s). You can try again."
        }
        task = work
        return work
    }

    func cancel() { task?.cancel(); task = nil; isIndexing = false }
}
