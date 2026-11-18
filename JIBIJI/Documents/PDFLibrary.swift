import Foundation
import Observation
import PDFKit
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFItem: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var pageCount: Int
    var text: String
    var searchVersion: Int? = nil
}

struct PDFPageInk: Codable {
    var drawing: Data
    var size: CGSize
}

enum DocumentProblem: Error, LocalizedError {
    case invalidPDF, locked, tooLarge, unreadableInk
    var errorDescription: String? {
        switch self {
        case .invalidPDF: "This file isn't a readable PDF."
        case .locked: "Unlock the PDF before importing it."
        case .tooLarge: "Choose a PDF smaller than 100 MB."
        case .unreadableInk: "Saved annotations couldn't be read. Editing is paused to protect them."
        }
    }
}

/// Coordinate external reads/writes with Files providers. Never retain unscoped URLs.
enum CoordinatedFiles {
    static func read(_ url: URL, limit: Int = 100 * 1024 * 1024) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var failure: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { coordinated in
            result = Result {
                let size = try coordinated.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= limit else { throw DocumentProblem.tooLarge }
                let data = try Data(contentsOf: coordinated)
                guard data.count <= limit else { throw DocumentProblem.tooLarge }
                return data
            }
        }
        if let failure { throw failure }
        return try result.get()
    }
}

@MainActor @Observable
final class PDFLibrary {
    let directory: URL
    let usesTestNotebook: Bool
    private(set) var items: [PDFItem] = []
    var problem: String?
    private(set) var importing = false
    private(set) var indexingSearch = false
    private(set) var searchProgress: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var models: [UUID: PDFNotebook] = [:]
    var hasPendingInk: Bool { models.values.contains { $0.pending } }

    func open(_ item: PDFItem) throws -> PDFNotebook {
        if let existing = models[item.id] { return existing }
        let opened = try PDFNotebook(item: item, source: source(item.id), usesTestNotebook: usesTestNotebook)
        opened.onInkChange = { [weak self] in self?.onChange?() }
        models[item.id] = opened
        return opened
    }
    func close(_ id: UUID) {
        guard let opened = models[id] else { return }
        opened.save()
        if !opened.pending { models[id] = nil }
    }
    func saveAll() { for opened in models.values { opened.save() } }
    func forgetSavedModels() { models = models.filter { $0.value.pending } }

    init(directory: URL, usesTestNotebook: Bool = false) { self.directory = directory; self.usesTestNotebook = usesTestNotebook; reload() }
    func folder(_ id: UUID) -> URL { directory.appending(path: id.uuidString) }
    func source(_ id: UUID) -> URL { folder(id).appending(path: "original.pdf") }

    func reload() {
        do {
            guard FileManager.default.fileExists(atPath: directory.path) else { items = []; return }
            var loaded: [PDFItem] = []
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
                let data = try Data(contentsOf: url.appending(path: "document.json"))
                let item = try JSONDecoder().decode(PDFItem.self, from: data)
                guard item.id == id, item.pageCount > 0 else { throw DocumentProblem.invalidPDF }
                loaded.append(item)
            }
            problem = nil
            items = loaded.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch { problem = "Couldn't read the document library: \(error.localizedDescription)" }
    }

    @discardableResult
    func importPDF(data: Data, title: String) throws -> PDFItem {
        guard data.count <= 100 * 1024 * 1024 else { throw DocumentProblem.tooLarge }
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw DocumentProblem.invalidPDF }
        guard !document.isLocked else { throw DocumentProblem.locked }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = PDFItem(id: UUID(), title: clean.isEmpty ? "Imported PDF" : String(clean.prefix(120)),
                           pageCount: document.pageCount, text: "")
        let target = folder(item.id)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try data.write(to: source(item.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try save(item)
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        reload(); onChange?()
        return item
    }

    func importPDF(from url: URL) async -> PDFItem? {
        importing = true; defer { importing = false }
        do {
            let data = try await Task.detached { try CoordinatedFiles.read(url) }.value
            let item = try importPDF(data: data, title: url.deletingPathExtension().lastPathComponent)
            do { try await refreshSearch(for: item.id) }
            catch { problem = "The PDF was imported, but search preparation failed: \(error.localizedDescription)" }
            return items.first { $0.id == item.id } ?? item
        } catch { problem = error.localizedDescription; return nil }
    }

    func rename(_ item: PDFItem, title: String) throws {
        var updated = items.first { $0.id == item.id } ?? item
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        updated.title = String(title.prefix(120))
        try save(updated); reload(); onChange?()
    }

    func refreshSearch(for id: UUID, rebuild: Bool = false) async throws {
        let url = source(id)
        if rebuild { try await PDFTextReader.shared.reset(at: url) }
        let text = try await PDFTextReader.shared.text(at: url, forceOCR: rebuild)
        try Task.checkCancellation()
        // A rename during OCR must survive the asynchronous index update.
        guard var current = items.first(where: { $0.id == id }) else { return }
        current.text = text; current.searchVersion = PDFTextReader.indexVersion
        try save(current); reload(); onChange?()
    }

    @discardableResult
    func indexSearchableText() -> Task<Void, Never> {
        if let searchTask, indexingSearch { return searchTask }
        let generation = UUID(); searchGeneration = generation
        indexingSearch = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if searchGeneration == generation { indexingSearch = false; searchProgress = nil } }
            for item in items where item.searchVersion != PDFTextReader.indexVersion {
                if Task.isCancelled { return }
                searchProgress = "Preparing search: " + item.title
                do { try await refreshSearch(for: item.id) }
                catch is CancellationError { return }
                catch { problem = "Couldn't index \(item.title): \(error.localizedDescription)" }
            }
        }
        searchTask = task
        return task
    }
    func cancelSearchIndexing() {
        searchTask?.cancel(); searchTask = nil
        searchGeneration = UUID(); indexingSearch = false; searchProgress = nil
    }

    private func save(_ item: PDFItem) throws {
        try JSONEncoder().encode(item).write(to: folder(item.id).appending(path: "document.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

@MainActor @Observable
final class PDFNotebook {
    let item: PDFItem
    let document: PDFDocument
    let source: URL
    let usesTestNotebook: Bool
    private(set) var annotationStrokeCount = 0
    @ObservationIgnored private var strokeCounts: [Int: Int] = [:]
    @ObservationIgnored var onInkChange: (() -> Void)?
    var problem: String?
    private(set) var pending = false
    private(set) var revision = 0
    @ObservationIgnored private var ink: [Int: PDFPageInk] = [:]
    @ObservationIgnored private var dirty: Set<Int> = []
    @ObservationIgnored private var saveFailed = false
    @ObservationIgnored private var autosave: Task<Void, Never>?

    init(item: PDFItem, source: URL, usesTestNotebook: Bool = false) throws {
        guard let document = PDFDocument(url: source), !document.isLocked else { throw DocumentProblem.invalidPDF }
        self.item = item; self.source = source; self.document = document; self.usesTestNotebook = usesTestNotebook
    }
    private func inkURL(_ index: Int) -> URL { source.deletingLastPathComponent().appending(path: "ink-\(index).json") }
    func pageInk(_ index: Int) throws -> PDFPageInk? {
        if let (drawing, size) = live[index] { return PDFPageInk(drawing: drawing.dataRepresentation(), size: size) }
        if let saved = ink[index] { return saved }
        let url = inkURL(index)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let saved = try JSONDecoder().decode(PDFPageInk.self, from: Data(contentsOf: url))
            guard saved.size.width > 0, saved.size.height > 0, saved.size.width.isFinite, saved.size.height.isFinite else { throw DocumentProblem.unreadableInk }
            let drawing = try PKDrawing(data: saved.drawing)
            strokeCounts[index] = drawing.strokes.count
            annotationStrokeCount = strokeCounts.values.reduce(0, +)
            ink[index] = saved
            return saved
        } catch { throw DocumentProblem.unreadableInk }
    }

    func changed(_ drawing: PKDrawing, page: Int, size: CGSize) {
        // Serialization is deferred until a pause; PencilKit retains the live pressure/geometry.
        live[page] = (drawing, size)
        onInkChange?()
        strokeCounts[page] = drawing.strokes.count
        annotationStrokeCount = strokeCounts.values.reduce(0, +)
        dirty.insert(page); pending = true; revision += 1
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { self?.save() }
        }
    }
    @ObservationIgnored private var live: [Int: (PKDrawing, CGSize)] = [:]

    func save() {
        autosave?.cancel(); autosave = nil
        for index in dirty.sorted() {
            guard let (drawing, size) = live[index] else { continue }
            do {
                let saved = PDFPageInk(drawing: drawing.dataRepresentation(), size: size)
                try JSONEncoder().encode(saved).write(to: inkURL(index), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                ink[index] = saved; dirty.remove(index)
            } catch { saveFailed = true; problem = "Couldn't save annotations: \(error.localizedDescription)" }
        }
        pending = !dirty.isEmpty
        if !pending, saveFailed { problem = nil; saveFailed = false }
    }

    func export() throws -> Data {
        var exportInk = live
        for index in 0..<document.pageCount where exportInk[index] == nil {
            if let saved = try pageInk(index) { exportInk[index] = (try PKDrawing(data: saved.drawing), saved.size) }
        }
        return try PortablePDF.render(document: document, ink: exportInk)
    }
}

enum PortablePDF {
    static func render(document: PDFDocument, ink exportInk: [Int: (PKDrawing, CGSize)]) throws -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        let data = renderer.pdfData { context in
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let raw = page.bounds(for: .cropBox).size
                let rotated = page.rotation % 180 != 0
                let size = rotated ? CGSize(width: raw.height, height: raw.width) : raw
                let bounds = CGRect(origin: .zero, size: size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                let cg = context.cgContext
                cg.saveGState(); cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()
                let drawing: PKDrawing?
                let inkSize: CGSize
                if let current = exportInk[index] { drawing = current.0; inkSize = current.1 }
                else { drawing = nil; inkSize = size }
                if let drawing, inkSize.width > 0, inkSize.height > 0 {
                    drawing.image(from: CGRect(origin: .zero, size: inkSize), scale: min(2, 4096 / max(inkSize.width, inkSize.height))).draw(in: bounds)
                }
            }
        }
        guard let output = PDFDocument(data: data) else { throw DocumentProblem.invalidPDF }
        // Rendering preserves searchable text. Restore link actions onto the flattened output.
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let target = output.page(at: index) else { continue }
            for annotation in page.annotations where annotation.action != nil || annotation.url != nil {
                let copy = PDFAnnotation(bounds: annotation.bounds.applying(page.transform(for: .cropBox)), forType: .link, withProperties: nil)
                if let url = annotation.url { copy.action = PDFActionURL(url: url) }
                else { copy.action = annotation.action }
                if let action = annotation.action as? PDFActionGoTo,
                   let sourcePage = action.destination.page {
                    let destination = action.destination
                    let destinationIndex = document.index(for: sourcePage)
                    if let destinationPage = output.page(at: destinationIndex) {
                        copy.action = PDFActionGoTo(destination: PDFDestination(page: destinationPage, at: destination.point.applying(sourcePage.transform(for: .cropBox))))
                    }
                }
                target.addAnnotation(copy)
            }
        }
        guard let exported = output.dataRepresentation() else { throw DocumentProblem.invalidPDF }
        return exported
    }
}

extension PortablePDF {
    static func note(_ drawing: PKDrawing, title: String) -> Data {
        let bounds = drawing.strokes.isEmpty ? CGRect(x: 0, y: 0, width: 612, height: 792)
            : drawing.bounds.union(CGRect(x: 0, y: 0, width: 612, height: 792)).insetBy(dx: -24, dy: -24)
        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: bounds.size)).pdfData { context in
            context.beginPage()
            title.draw(at: CGPoint(x: 24, y: 12), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
            drawing.image(from: bounds, scale: min(2, 4096 / max(bounds.width, bounds.height))).draw(in: CGRect(x: 0, y: 32, width: bounds.width, height: bounds.height - 32))
        }
    }
}

struct PDFExport: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
