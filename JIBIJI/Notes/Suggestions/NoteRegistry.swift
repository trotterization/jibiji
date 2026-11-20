import CoreGraphics
import Foundation

/// One note on a page: a stable identity, an independent revision, and the exact strokes it is made of.
///
/// A note is a Hanzi / Pinyin / English entry as grouped from the student's own ink. Its revision moves only
/// when *its* strokes change, so editing one note never disturbs another. Stored apart from the ink, per page.
struct NoteRecord: Codable, Identifiable, Equatable {
    var id: UUID
    /// Starts at 1; +1 each time the note's own source strokes change.
    var revision: Int
    /// Content identities of the strokes read for this note, sorted.
    var strokeIDs: [String]
    var bounds: CGRect
    /// Proposals the student rejected for this note at this revision. Cleared when the note's source changes.
    var rejected: [String] = []
}

/// The notes of one page. Matching a fresh reading to a record is by stroke identity, never by recognized text,
/// because OCR text varies between runs but the strokes the student wrote do not.
struct NoteRegistry: Codable, Equatable {
    var version = 1
    var records: [NoteRecord] = []

    /// Smallest share of shared strokes (of all strokes in either) for a reading to still be the same note.
    static let sameNoteOverlap = 0.5
    /// Cap so a long-lived page cannot grow the file without bound; oldest unmatched records go first.
    static let maxRecords = 500

    /// Assigns each source (the strokes of one grouped note) its record, creating or revising as needed.
    /// `kept` are record ids that must not be dropped (referenced by an accepted note).
    mutating func reconcile(_ sources: [(ids: Set<String>, bounds: CGRect)], keeping kept: Set<UUID> = []) -> [NoteRecord?] {
        var used = Set<UUID>()
        var result: [NoteRecord?] = Array(repeating: nil, count: sources.count)
        // Identical sets first, so a note is never taken over by a similar neighbour.
        for (index, source) in sources.enumerated() where !source.ids.isEmpty {
            let sorted = source.ids.sorted()
            if let i = records.firstIndex(where: { $0.strokeIDs == sorted && !used.contains($0.id) }) {
                records[i].bounds = source.bounds
                used.insert(records[i].id)
                result[index] = records[i]
            }
        }
        // Edited notes: the best pairings first, so a record goes to the reading it resembles most, not to the first
        // reading that happens to clear the threshold.
        var pairs: [(source: Int, record: Int, overlap: Double)] = []
        for (index, source) in sources.enumerated() where !source.ids.isEmpty && result[index] == nil {
            for (i, record) in records.enumerated() where !used.contains(record.id) {
                let shared = Set(record.strokeIDs).intersection(source.ids).count
                let union = Set(record.strokeIDs).union(source.ids).count
                let overlap = union == 0 ? 0 : Double(shared) / Double(union)
                if overlap >= Self.sameNoteOverlap { pairs.append((index, i, overlap)) }
            }
        }
        var takenRecords = Set<Int>()
        for pair in pairs.sorted(by: { ($0.overlap, -$0.source) > ($1.overlap, -$1.source) }) {
            guard result[pair.source] == nil, !takenRecords.contains(pair.record) else { continue }
            takenRecords.insert(pair.record)
            // The same note, its source edited: a new revision, and old rejections no longer apply.
            records[pair.record].revision += 1
            records[pair.record].strokeIDs = sources[pair.source].ids.sorted()
            records[pair.record].bounds = sources[pair.source].bounds
            records[pair.record].rejected = []
            used.insert(records[pair.record].id)
            result[pair.source] = records[pair.record]
        }
        for (index, source) in sources.enumerated() where !source.ids.isEmpty && result[index] == nil {
            let record = NoteRecord(id: UUID(), revision: 1, strokeIDs: source.ids.sorted(), bounds: source.bounds)
            records.append(record)
            used.insert(record.id)
            result[index] = record
        }
        if records.count > Self.maxRecords {
            let drop = records.count - Self.maxRecords
            var removed = 0
            records.removeAll { record in
                // Never drop a record that is in use, referenced by an accepted note, or carries a rejection.
                guard removed < drop, !used.contains(record.id), !kept.contains(record.id), record.rejected.isEmpty else { return false }
                removed += 1
                return true
            }
        }
        return result
    }

    func record(_ id: UUID) -> NoteRecord? { records.first { $0.id == id } }

    func isRejected(note id: UUID, revision: Int, key: String) -> Bool {
        guard let record = record(id), record.revision == revision else { return false }
        return record.rejected.contains(key)
    }

    mutating func reject(note id: UUID, revision: Int, key: String) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].revision == revision,
              !records[i].rejected.contains(key) else { return }
        records[i].rejected.append(key)
    }
}

/// Notes as one small JSON file per page, written atomically beside the page's other files.
struct NoteRegistryStore: Sendable {
    let directory: URL

    func fileURL(pageID: String) -> URL {
        directory.appending(path: "\(pageID).notes.json", directoryHint: .notDirectory)
    }

    /// Empty when the page has none. Throws if a file exists but can't be read, so callers don't overwrite it.
    func load(pageID: String) throws -> NoteRegistry {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(pageID: pageID))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return NoteRegistry()
        }
        let registry = try JSONDecoder().decode(NoteRegistry.self, from: data)
        guard registry.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return registry
    }

    func save(_ registry: NoteRegistry, pageID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: fileURL(pageID: pageID),
                                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
