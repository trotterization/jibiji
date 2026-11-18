import CryptoKit
import Foundation
import PencilKit
import PDFKit

/// Each device publishes its own manifest. Content-addressed blobs are immutable;
/// vector clocks distinguish newer changes from concurrent edits without wall-clock assumptions.
struct SyncRecord: Codable, Equatable, Sendable {
    var id: String
    var kind: String
    var revision: String
    var clock: [String: Int]
    var files: [String: String]
    var conflict = false

    static func dominates(_ a: Self, _ b: Self) -> Bool {
        Set(a.clock.keys).union(b.clock.keys).allSatisfy { a.clock[$0, default: 0] >= b.clock[$0, default: 0] }
    }
    static func reconcile(_ a: Self, _ b: Self) -> [Self] {
        if a == b { return [a] }
        if dominates(a, b), !dominates(b, a) { return [a] }
        if dominates(b, a), !dominates(a, b) { return [b] }
        var winner = a.revision >= b.revision ? a : b
        let loser = a.revision >= b.revision ? b : a
        for (device, count) in loser.clock { winner.clock[device] = max(winner.clock[device, default: 0], count) }
        guard winner.files != loser.files else { return [winner] }
        var copy = loser
        // The same conflict on two devices produces the same copy ID.
        let hash = Array(SHA256.hash(data: Data((loser.id + loser.revision).utf8)))
        copy.id = UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15])).uuidString
        copy.conflict = true
        return [winner, copy]
    }
}

struct SyncState: Codable, Sendable {
    var version = 1
    var device = UUID().uuidString
    var noteIDs: [String: String] = [:]
    var records: [String: SyncRecord] = [:]
}
struct SyncManifest: Codable, Sendable { var version = 1; var records: [SyncRecord] }
struct SyncWrite: Codable, Sendable { var path: String; var data: Data? }
struct SyncPlan: Sendable { var writes: [SyncWrite]; var imported: Int; var conflicts: Int }

/// A recoverable transaction for remote imports: interruption rolls back on next launch.
enum SyncTransaction {
    static let journal = "sync-recovery.json"
    static func safe(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    static func apply(_ writes: [SyncWrite], to directory: URL) throws {
        guard writes.allSatisfy({ safe($0.path) && $0.path != journal }) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = try writes.map { write -> SyncWrite in
            let url = directory.appending(path: write.path)
            return SyncWrite(path: write.path, data: FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
        }
        try JSONEncoder().encode(old).write(to: directory.appending(path: journal), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try write(writes, to: directory)
            try FileManager.default.removeItem(at: directory.appending(path: journal))
        } catch {
            try recover(directory)
            throw error
        }
    }
    static func recover(_ directory: URL) throws {
        let url = directory.appending(path: journal)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let writes = try JSONDecoder().decode([SyncWrite].self, from: Data(contentsOf: url))
        guard writes.allSatisfy({ safe($0.path) && $0.path != journal }) else { throw CocoaError(.fileReadCorruptFile) }
        try write(writes, to: directory)
        for entry in writes where entry.data == nil {
            var parent = directory.appending(path: entry.path).deletingLastPathComponent()
            while parent.standardizedFileURL.path != directory.standardizedFileURL.path {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path), contents.isEmpty else { break }
                try FileManager.default.removeItem(at: parent)
                parent.deleteLastPathComponent()
            }
        }
        try FileManager.default.removeItem(at: url)
    }
    private static func write(_ writes: [SyncWrite], to directory: URL) throws {
        for write in writes {
            let url = directory.appending(path: write.path)
            if let data = write.data {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}

actor FolderSyncEngine {
    static let stateFile = "sync-state.json"
    let directory: URL
    private let deviceID: String?
    private var verifiedBlobs: [URL: Date] = [:]
    init(directory: URL, deviceID: String? = nil) { self.directory = directory; self.deviceID = deviceID }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }

    func exchange(folder: URL, allowsPull: Bool) throws -> SyncPlan {
        try SyncTransaction.recover(directory)
        let stateURL = directory.appending(path: Self.stateFile)
        var state = FileManager.default.fileExists(atPath: stateURL.path)
            ? try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL)) : SyncState()
        if let deviceID { state.device = deviceID }
        guard state.version == 1, UUID(uuidString: state.device) != nil,
              state.noteIDs.allSatisfy({ NoteStore.pageNumber(of: $0.key) != nil && UUID(uuidString: $0.value) != nil }),
              state.records.allSatisfy({ $0.key == $0.value.id }) else { throw CocoaError(.fileReadCorruptFile) }
        for record in state.records.values { try Self.validate(record) }
        let store = NoteStore(directory: directory)
        var pageIDs = try store.loadPageIDs()
        var library = try store.loadLibrary()
        var blobs: [String: Data] = [:]
        func track(id: String, kind: String, files: [String: Data]) {
            let hashes = files.mapValues { data in
                let hash = Self.hash(data); blobs[hash] = data; return hash
            }
            if state.records[id]?.files != hashes {
                var clock = state.records[id]?.clock ?? [:]
                clock[state.device, default: 0] += 1
                state.records[id] = SyncRecord(id: id, kind: kind, revision: UUID().uuidString, clock: clock, files: hashes,
                                               conflict: state.records[id]?.conflict ?? false)
            }
        }
        for page in pageIDs {
            var files = ["details.json": try encode(library.pages[page] ?? NotebookLibrary.PageInfo())]
            for suffix in ["drawing", "annotations.json", "flashcards.json"] {
                let url = directory.appending(path: "\(page).\(suffix)")
                if FileManager.default.fileExists(atPath: url.path) {
                    let data = try Data(contentsOf: url)
                    if suffix == "flashcards.json" {
                        var cards = try JSONDecoder().decode(PageFlashcardFile.self, from: data)
                        cards.pageID = ""
                        files[suffix] = try encode(cards)
                    } else { files[suffix] = data }
                }
            }
            if files.count == 1, (library.pages[page]?.isEmpty ?? true), pageIDs.count == 1, state.noteIDs[page] == nil { continue }
            let id = state.noteIDs[page] ?? UUID().uuidString
            state.noteIDs[page] = id
            track(id: id, kind: "note", files: files)
        }
        let pdfRoot = directory.appending(path: "PDFs")
        if FileManager.default.fileExists(atPath: pdfRoot.path) {
            for folder in try FileManager.default.contentsOfDirectory(at: pdfRoot, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: folder.lastPathComponent)?.uuidString else { continue }
                var files: [String: Data] = [:]
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where Self.allowedPDFFile(file.lastPathComponent) {
                    files[file.lastPathComponent] = try Data(contentsOf: file)
                }
                guard files["document.json"] != nil, files["original.pdf"] != nil else { throw CocoaError(.fileReadCorruptFile) }
                track(id: id, kind: "pdf", files: files)
            }
        }
        // Persist stable IDs before publishing, so a retry cannot duplicate local notes.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encode(state).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let local = state
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<SyncPlan, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(writingItemAt: folder, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let root = coordinated.appending(path: "Jibiji Sync")
                let blobRoot = root.appending(path: "blobs")
                let manifests = root.appending(path: "devices")
                try FileManager.default.createDirectory(at: blobRoot, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
                for (hash, data) in blobs {
                    let target = blobRoot.appending(path: hash)
                    let date = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if date == nil || verifiedBlobs[target] != date {
                        let needsWrite: Bool
                        if FileManager.default.fileExists(atPath: target.path) { needsWrite = try Self.hash(Data(contentsOf: target)) != hash }
                        else { needsWrite = true }
                        if needsWrite { try data.write(to: target, options: .atomic) }
                        verifiedBlobs[target] = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    }
                }
                let ownManifest = manifests.appending(path: local.device + ".json")
                var outgoing = local.records
                // A Keychain writer ID survives reinstall. Read its previous manifest before
                // publishing, so a fresh local store cannot erase that device's cloud record.
                if FileManager.default.fileExists(atPath: ownManifest.path) {
                    let data = try Data(contentsOf: ownManifest)
                    guard data.count <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    let prior = try JSONDecoder().decode(SyncManifest.self, from: data)
                    guard prior.version == 1, prior.records.count <= 10_000 else { throw CocoaError(.fileReadCorruptFile) }
                    for record in prior.records {
                        try Self.validate(record)
                        if let current = outgoing[record.id] {
                            for merged in SyncRecord.reconcile(current, record) { outgoing[merged.id] = merged }
                        } else { outgoing[record.id] = record }
                    }
                }
                let manifestData = try encode(SyncManifest(records: outgoing.values.sorted { $0.id < $1.id }))
                if (try? Data(contentsOf: ownManifest)) != manifestData { try manifestData.write(to: ownManifest, options: .atomic) }
                // Standard PDFs can be opened through the same cloud folder on Mac, PC, or phone.
                let readable = root.appending(path: "Readable PDFs")
                try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
                for record in local.records.values {
                    let signature = record.files.keys.sorted().map { $0 + ":" + (record.files[$0] ?? "") }.joined(separator: "|")
                    let marker = readable.appending(path: record.id + ".version")
                    if (try? String(contentsOf: marker, encoding: .utf8)) == signature { continue }
                    let data: Data
                    if record.kind == "note" {
                        guard let hash = record.files["details.json"], let details = blobs[hash] else { throw CocoaError(.fileReadCorruptFile) }
                        let info = try JSONDecoder().decode(NotebookLibrary.PageInfo.self, from: details)
                        let drawing: PKDrawing
                        if let hash = record.files["drawing"] {
                            guard let bytes = blobs[hash] else { throw CocoaError(.fileReadCorruptFile) }
                            drawing = try PKDrawing(data: bytes)
                        } else { drawing = PKDrawing() }
                        data = PortablePDF.note(drawing, title: info.name ?? "Jibiji page")
                    } else {
                        guard let hash = record.files["original.pdf"], let bytes = blobs[hash], let document = PDFDocument(data: bytes) else { throw CocoaError(.fileReadCorruptFile) }
                        var ink: [Int: (PKDrawing, CGSize)] = [:]
                        for (name, hash) in record.files where name.hasPrefix("ink-") {
                            guard let index = Int(name.dropFirst(4).dropLast(5)), let bytes = blobs[hash] else { continue }
                            let saved = try JSONDecoder().decode(PDFPageInk.self, from: bytes)
                            ink[index] = (try PKDrawing(data: saved.drawing), saved.size)
                        }
                        data = try PortablePDF.render(document: document, ink: ink)
                    }
                    try data.write(to: readable.appending(path: record.id + ".pdf"), options: .atomic)
                    try Data(signature.utf8).write(to: marker, options: .atomic)
                }
                func escaped(_ value: String) -> String {
                    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                }
                var links: [(String, String)] = []
                for record in local.records.values {
                    let name: String
                    if record.kind == "note", let hash = record.files["details.json"], let bytes = blobs[hash] {
                        name = try JSONDecoder().decode(NotebookLibrary.PageInfo.self, from: bytes).name ?? "Jibiji page"
                    } else if let hash = record.files["document.json"], let bytes = blobs[hash] {
                        name = try JSONDecoder().decode(PDFItem.self, from: bytes).title
                    } else { continue }
                    links.append((name, record.id))
                }
                let rows = links.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }.map { "<li><a href=\"" + $0.1 + ".pdf\">" + escaped($0.0) + "</a></li>" }.joined()
                let html = Data(("<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Jibiji notes</title><style>body{font:18px system-ui;max-width:48rem;margin:3rem auto;padding:1rem}li{margin:1rem 0}</style><h1>Jibiji notes</h1><p>Open a PDF to read your notes. Connect this folder in Jibiji to edit the original ink.</p><ul>" + rows + "</ul>").utf8)
                let index = readable.appending(path: "Browse.html")
                if (try? Data(contentsOf: index)) != html { try html.write(to: index, options: .atomic) }
                guard allowsPull else { return SyncPlan(writes: [], imported: 0, conflicts: 0) }
                var merged = local.records
                for file in try FileManager.default.contentsOfDirectory(at: manifests, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                    let data = try Data(contentsOf: file)
                    guard data.count <= 20 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    let manifest = try JSONDecoder().decode(SyncManifest.self, from: data)
                    guard manifest.version == 1, manifest.records.count <= 10_000 else { throw CocoaError(.fileReadCorruptFile) }
                    for incoming in manifest.records {
                        try Self.validate(incoming)
                        if let existing = merged[incoming.id] {
                            for record in SyncRecord.reconcile(existing, incoming) { merged[record.id] = record }
                        } else { merged[incoming.id] = incoming }
                    }
                }
                var writes: [SyncWrite] = []
                var imported = 0; var conflicts = 0
                var candidate = local
                for record in merged.values.sorted(by: { $0.id < $1.id }) {
                    if local.records[record.id]?.files == record.files { continue }
                    var files: [String: Data] = [:]
                    for (name, hash) in record.files {
                        let blobURL = blobRoot.appending(path: hash)
                        if blobs[hash] == nil {
                            let size = try blobURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= 100 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                        }
                        let data = try blobs[hash] ?? Data(contentsOf: blobURL)
                        guard Self.hash(data) == hash else { throw CocoaError(.fileReadCorruptFile) }
                        files[name] = data
                    }
                    if record.kind == "note" {
                        let page: String
                        if let existing = candidate.noteIDs.first(where: { $0.value == record.id })?.key { page = existing }
                        else {
                            if pageIDs.count == 1, let first = pageIDs.first, candidate.noteIDs[first] == nil,
                               !FileManager.default.fileExists(atPath: store.fileURL(forPage: first).path), library.pages[first]?.isEmpty ?? true {
                                page = first
                            } else { page = store.nextPageID(after: pageIDs); pageIDs.append(page) }
                            candidate.noteIDs[page] = record.id
                        }
                        var info = try JSONDecoder().decode(NotebookLibrary.PageInfo.self, from: files["details.json"] ?? Data())
                        if record.conflict, !(info.name ?? "").hasSuffix(" (conflict copy)") { info.name = (info.name ?? "Page") + " (conflict copy)" }
                        library.pages[page] = info
                        if let folder = info.folder, !library.folders.contains(folder) { library.folders.append(folder) }
                        for suffix in ["drawing", "annotations.json", "flashcards.json"] {
                            var data = files[suffix]
                            if let drawing = data, suffix == "drawing" { _ = try PKDrawing(data: drawing) }
                            if let bytes = data, suffix == "flashcards.json" {
                                var cards = try JSONDecoder().decode(PageFlashcardFile.self, from: bytes)
                                guard cards.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                                cards.pageID = page; data = try encode(cards)
                            }
                            writes.append(SyncWrite(path: "\(page).\(suffix)", data: data))
                        }
                    } else {
                        guard let bytes = files["document.json"], let pdf = files["original.pdf"],
                              let document = PDFDocument(data: pdf), !document.isLocked, document.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
                        var item = try JSONDecoder().decode(PDFItem.self, from: bytes)
                        guard let id = UUID(uuidString: record.id) else { throw CocoaError(.fileReadCorruptFile) }
                        item.id = id
                        if record.conflict, !item.title.hasSuffix(" (conflict copy)") { item.title += " (conflict copy)" }
                        files["document.json"] = try encode(item)
                        let existingFolder = directory.appending(path: "PDFs/\(record.id)")
                        if FileManager.default.fileExists(atPath: existingFolder.path) {
                            for existing in try FileManager.default.contentsOfDirectory(at: existingFolder, includingPropertiesForKeys: nil)
                            where Self.allowedPDFFile(existing.lastPathComponent) && files[existing.lastPathComponent] == nil {
                                writes.append(SyncWrite(path: "PDFs/\(record.id)/\(existing.lastPathComponent)", data: nil))
                            }
                        }
                        for (name, data) in files {
                            if name.hasPrefix("ink-") {
                                let saved = try JSONDecoder().decode(PDFPageInk.self, from: data)
                                guard let index = Int(name.dropFirst(4).dropLast(5)), index < document.pageCount,
                                      saved.size.width > 0, saved.size.height > 0, saved.size.width.isFinite, saved.size.height.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                                _ = try PKDrawing(data: saved.drawing)
                            }
                            writes.append(SyncWrite(path: "PDFs/\(record.id)/\(name)", data: data))
                        }
                    }
                    imported += 1
                    if record.conflict { conflicts += 1 }
                }
                candidate.records = merged
                guard imported > 0 || candidate.records != local.records else { return SyncPlan(writes: [], imported: 0, conflicts: 0) }
                writes.append(SyncWrite(path: "library.json", data: try encode(library)))
                writes.append(SyncWrite(path: "notebook.json", data: try encode(PageList(version: 1, pageIDs: pageIDs))))
                writes.append(SyncWrite(path: Self.stateFile, data: try encode(candidate)))
                return SyncPlan(writes: writes, imported: imported, conflicts: conflicts)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
    private struct PageList: Codable { var version: Int; var pageIDs: [String] }
    private static func allowedPDFFile(_ name: String) -> Bool {
        if name == "original.pdf" || name == "document.json" { return true }
        guard name.hasPrefix("ink-"), name.hasSuffix(".json") else { return false }
        return Int(name.dropFirst(4).dropLast(5)).map { $0 >= 0 } ?? false
    }
    private static func validate(_ record: SyncRecord) throws {
        guard UUID(uuidString: record.id) != nil, UUID(uuidString: record.revision) != nil,
              ["note", "pdf"].contains(record.kind), record.clock.count <= 1000,
              record.clock.allSatisfy({ UUID(uuidString: $0.key) != nil && (0...1_000_000_000_000).contains($0.value) }),
              record.files.count <= 20_000,
              record.files.allSatisfy({ name, hash in
                  let allowed = record.kind == "note" ? ["details.json", "drawing", "annotations.json", "flashcards.json"].contains(name) : allowedPDFFile(name)
                  return allowed && hash.count == 64 && hash.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
              }) else { throw CocoaError(.fileReadCorruptFile) }
    }
}
