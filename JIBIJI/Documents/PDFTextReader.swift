import CryptoKit
import Foundation
import PDFKit
import UIKit
import Vision

/// Actor-confined PDF rendering/OCR. Derived search files never modify source PDFs or ink.
actor PDFTextReader {
    static let shared = PDFTextReader()
    static let indexVersion = 2

    struct Match: Sendable, Identifiable {
        var page: Int
        var range: NSRange?
        var bounds: CGRect?
        var id: String
        var isOCR: Bool { bounds != nil }
    }
    struct Token: Codable, Sendable { var range: NSRange; var bounds: CGRect }
    struct Line: Codable, Sendable { var text: String; var bounds: CGRect; var tokens: [Token] }
    struct PageText: Codable, Sendable { var native: String; var lines: [Line]; var ocrApplied: Bool }
    private struct SavedIndex: Codable {
        var version = indexVersion
        var sourceHash: String
    }
    private struct Stamp: Equatable { var modified: Date?; var size: Int }
    private final class Context {
        let url: URL
        let document: PDFDocument
        let stamp: Stamp
        let hash: String
        var pages: [Int: PageText]
        init(url: URL, document: PDFDocument, stamp: Stamp, hash: String, pages: [Int: PageText]) {
            self.url = url; self.document = document; self.stamp = stamp; self.hash = hash; self.pages = pages
        }
    }
    private var contexts: [URL: Context] = [:]
    private struct Work { let id = UUID(); var task: Task<PageText, Error> }
    private var jobs: [String: Work] = [:]

    enum SearchProblem: Error, LocalizedError {
        case sourceChanged, renderingFailed
        var errorDescription: String? {
            switch self {
            case .sourceChanged: "The PDF changed while search was being prepared. Try searching again."
            case .renderingFailed: "A scanned page couldn't be rendered for text recognition."
            }
        }
    }

    private func stamp(_ url: URL) throws -> Stamp {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(modified: values.contentModificationDate, size: values.fileSize ?? 0)
    }
    private func cacheURL(_ url: URL) -> URL { url.deletingLastPathComponent().appending(path: "ocr-search-index") }
    private func sourceHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func context(_ url: URL) throws -> Context {
        let current = try stamp(url)
        if let cached = contexts[url], cached.stamp == current { return cached }
        guard let document = PDFDocument(url: url), !document.isLocked else { throw DocumentProblem.invalidPDF }
        let hash = try sourceHash(url)
        var pages: [Int: PageText] = [:]
        let cache = cacheURL(url)
        if let data = try? Data(contentsOf: cache.appending(path: "source.json")),
           let saved = try? JSONDecoder().decode(SavedIndex.self, from: data),
           saved.version == Self.indexVersion, saved.sourceHash == hash,
           let files = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("page-") && file.pathExtension == "json" {
                guard let index = Int(file.deletingPathExtension().lastPathComponent.dropFirst(5)), index >= 0, index < document.pageCount,
                      let bytes = try? Data(contentsOf: file), let content = try? JSONDecoder().decode(PageText.self, from: bytes), Self.valid(content) else { continue }
                pages[index] = content
            }
        }
        if contexts.count >= 3 { contexts.removeAll() }
        let value = Context(url: url, document: document, stamp: current, hash: hash, pages: pages)
        contexts[url] = value
        return value
    }
    private static func valid(_ page: PageText) -> Bool {
        page.lines.allSatisfy { line in
            [line.bounds.minX, line.bounds.minY, line.bounds.width, line.bounds.height].allSatisfy(\.isFinite)
                && line.bounds.width > 0 && line.bounds.height > 0
                && line.tokens.allSatisfy { $0.range.location >= 0 && $0.range.length > 0 && $0.range.location <= (line.text as NSString).length && $0.range.length <= (line.text as NSString).length - $0.range.location }
        }
    }
    private func persist(_ value: Context, page: Int) throws {
        guard try stamp(value.url) == value.stamp else { throw SearchProblem.sourceChanged }
        // Write one completed page at a time; long textbooks must not rewrite an entire
        // growing index after every OCR operation. Cache I/O failures remain nonfatal.
        do {
            let folder = cacheURL(value.url), header = folder.appending(path: "source.json")
            let saved = (try? Data(contentsOf: header)).flatMap { try? JSONDecoder().decode(SavedIndex.self, from: $0) }
            if saved?.sourceHash != value.hash || saved?.version != Self.indexVersion {
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(SavedIndex(sourceHash: value.hash)).write(to: header, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            if let content = value.pages[page] {
                try JSONEncoder().encode(content).write(to: folder.appending(path: "page-\(page).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } catch { /* Search still works with the in-memory index. */ }
    }

    func reset(at url: URL) throws {
        contexts[url] = nil
        let prefix = url.absoluteString + "|"
        for key in Array(jobs.keys) where key.hasPrefix(prefix) { jobs.removeValue(forKey: key)?.task.cancel() }
        let file = cacheURL(url)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func text(at url: URL, forceOCR: Bool = false) async throws -> String {
        let value = try context(url)
        var output = ""
        for index in 0..<value.document.pageCount {
            try Task.checkCancellation()
            let page = try await pageText(index, in: value, forceOCR: forceOCR)
            if output.count < 2_000_000 {
                output += String(([page.native] + page.lines.map(\.text)).joined(separator: "\n").prefix(2_000_000 - output.count)) + "\n"
            }
        }
        guard try stamp(url) == value.stamp else { throw SearchProblem.sourceChanged }
        return output
    }

    func find(_ query: String, at url: URL) async throws -> [Match] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let value = try context(url)
        var matches: [Match] = []
        for index in 0..<value.document.pageCount {
            try Task.checkCancellation()
            let content = try await pageText(index, in: value, forceOCR: false)
            guard let page = value.document.page(at: index) else { continue }
            var nativeBounds: [CGRect] = []
            for range in Self.ranges(of: query, in: content.native) {
                matches.append(Match(page: index, range: range, bounds: nil, id: "native-\(index)-\(range.location)-\(range.length)"))
                if let bounds = page.selection(for: range)?.bounds(for: page) { nativeBounds.append(bounds) }
                if matches.count == 1000 { break }
            }
            if matches.count == 1000 { break }
            for (lineIndex, line) in content.lines.enumerated() {
                for range in Self.ranges(of: query, in: line.text) {
                    let tokens = line.tokens.filter { NSIntersectionRange($0.range, range).length > 0 }
                    let bounds = tokens.dropFirst().reduce(tokens.first?.bounds ?? line.bounds) { $0.union($1.bounds) }
                    // Avoid counting the same selectable word again after an OCR rebuild.
                    if nativeBounds.contains(where: { Self.overlaps($0, bounds) }) { continue }
                    matches.append(Match(page: index, range: nil, bounds: bounds, id: "ocr-\(index)-\(lineIndex)-\(range.location)-\(range.length)"))
                    if matches.count == 1000 { break }
                }
                if matches.count == 1000 { break }
            }
            if matches.count == 1000 { break }
        }
        try Task.checkCancellation()
        guard try stamp(url) == value.stamp else { throw SearchProblem.sourceChanged }
        return matches
    }

    private static func ranges(of query: String, in text: String) -> [NSRange] {
        let text = text as NSString
        var search = NSRange(location: 0, length: text.length), output: [NSRange] = []
        while search.length > 0, output.count < 1000 {
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            if found.location == NSNotFound { break }
            output.append(found)
            let end = NSMaxRange(found)
            search = NSRange(location: end, length: text.length - end)
        }
        return output
    }
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let intersection = a.intersection(b)
        let area = min(a.width * a.height, b.width * b.height)
        return !intersection.isNull && area > 0 && intersection.width * intersection.height / area > 0.5
    }

    private func pageText(_ index: Int, in value: Context, forceOCR: Bool) async throws -> PageText {
        guard let page = value.document.page(at: index) else { throw DocumentProblem.invalidPDF }
        let native = page.string ?? ""
        // Native text is preferred. Sparse headers/page numbers must not hide a scanned body.
        let needsOCR = forceOCR || native.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count < 24
        if let cached = value.pages[index], cached.ocrApplied || !needsOCR { return cached }
        if !needsOCR {
            let result = PageText(native: native, lines: [], ocrApplied: false)
            value.pages[index] = result; try persist(value, page: index)
            return result
        }
        let key = value.url.absoluteString + "|" + value.hash + "|\(index)"
        let work: Work
        if let pending = jobs[key] { work = pending }
        else {
            work = Work(task: Task { try await self.recognize(page, native: native) })
            jobs[key] = work
        }
        do {
            let result = try await work.task.value
            value.pages[index] = result
            try persist(value, page: index)
            if jobs[key]?.id == work.id { jobs[key] = nil }
            try Task.checkCancellation()
            return result
        } catch {
            if jobs[key]?.id == work.id { jobs[key] = nil }
            throw error
        }
    }

    /// Vision boxes use the rendered image's lower-left origin. Convert through PDFKit's
    /// own crop/rotation transform so matches remain in canonical PDF page coordinates.
    static func pageRect(_ normalized: CGRect, page: PDFPage) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        let displayed = CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                               width: normalized.width * size.width, height: normalized.height * size.height)
        return displayed.applying(page.transform(for: .cropBox).inverted()).intersection(crop)
    }
    private func recognize(_ page: PDFPage, native: String) async throws -> PageText {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0, crop.width.isFinite, crop.height.isFinite else { throw SearchProblem.renderingFailed }
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        let scale = 2048 / max(size.width, size.height)
        guard let image = autoreleasepool(invoking: { page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .cropBox).cgImage }) else { throw SearchProblem.renderingFailed }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant"), Locale.Language(identifier: "en-US")]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        var lines: [Line] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { continue }
            let text = candidate.string
            let box = observation.boundingBox
            let bounds = Self.pageRect(CGRect(x: box.origin.x, y: box.origin.y, width: box.width, height: box.height), page: page)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !bounds.isNull else { continue }
            var tokens: [Token] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
                guard let rectangle = candidate.boundingBox(for: range) else { return }
                let b = rectangle.boundingBox
                let rect = Self.pageRect(CGRect(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height), page: page)
                if !rect.isNull { tokens.append(Token(range: NSRange(range, in: text), bounds: rect)) }
            }
            lines.append(Line(text: text, bounds: bounds, tokens: tokens))
        }
        lines.sort { abs($0.bounds.midY - $1.bounds.midY) < 10 ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY }
        return PageText(native: native, lines: lines, ocrApplied: true)
    }
}
