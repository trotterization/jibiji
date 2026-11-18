import PDFKit
import Testing
import UIKit
@testable import JIBIJI

@MainActor @Suite("Scanned PDF OCR")
struct PDFOCRTests {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }
    private func scan(_ text: String, counterRotated: Bool = false) -> UIImage {
        let size = CGSize(width: 612, height: 792)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            text.draw(at: CGPoint(x: 72, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black])
            "A generated research worksheet".draw(at: CGPoint(x: 72, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
        }
        guard counterRotated else { return image }
        return UIGraphicsImageRenderer(size: CGSize(width: 792, height: 612), format: format).image { context in
            context.cgContext.translateBy(x: 0, y: 612)
            context.cgContext.rotate(by: -.pi / 2)
            image.draw(at: .zero)
        }
    }
    private func pdf(_ images: [UIImage]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        return renderer.pdfData { context in
            for image in images {
                let bounds = CGRect(origin: .zero, size: image.size)
                context.beginPage(withBounds: bounds, pageInfo: [:]); image.draw(in: bounds)
            }
        }
    }
    private func source(_ data: Data, in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "original.pdf"); try data.write(to: url, options: .atomic); return url
    }

    @Test func imageOnlyPDFSearchFindsWordsAndPersistsWithoutChangingSourceOrInk() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = pdf([scan("ORCHID laboratory"), scan("ORCHID field notes"), scan("中文学习 Mandarin")])
        #expect(PDFDocument(data: bytes)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        let url = try source(bytes, in: root)
        let ink = root.appending(path: "ink-0.json"), marker = Data("existing annotations".utf8)
        try marker.write(to: ink)
        let reader = PDFTextReader()
        let matches = try await reader.find("orchid", at: url)
        #expect(matches.map(\.page) == [0, 1])
        #expect(try await reader.find("学习", at: url).map(\.page) == [2])
        #expect(matches.allSatisfy { $0.isOCR && $0.range == nil && ($0.bounds?.width ?? 0) > 0 })
        for match in matches {
            let bounds = try #require(match.bounds)
            #expect(CGRect(x: 55, y: 620, width: 180, height: 70).intersects(bounds))
        }
        let cache = root.appending(path: "ocr-search-index/page-0.json")
        let cached = try Data(contentsOf: cache)
        let modified = try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date
        let reopened = PDFTextReader()
        #expect(try await reopened.find("laboratory", at: url).count == 1)
        #expect(try Data(contentsOf: cache) == cached)
        #expect(try FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date == modified)
        try Data("damaged cache".utf8).write(to: cache)
        #expect(try await PDFTextReader().find("orchid", at: url).count == 2)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try Data(contentsOf: ink) == marker)
    }

    @Test func mixedPDFUsesNativeTextAndOCRWithoutDuplicateMatches() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let document = try #require(PDFDocument(data: pdf([scan("ORCHID scanned lesson")])))
        let native = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            "ORCHID selectable text with enough words to use the native text layer.".draw(at: CGPoint(x: 50, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        document.insert(try #require(PDFDocument(data: native)?.page(at: 0)), at: 0)
        let url = try source(try #require(document.dataRepresentation()), in: root)
        let reader = PDFTextReader()
        let matches = try await reader.find("ORCHID", at: url)
        #expect(matches.count == 2)
        #expect(matches.first?.isOCR == false && matches.last?.isOCR == true)
        _ = try await reader.text(at: url, forceOCR: true)
        #expect(try await reader.find("ORCHID", at: url).count == 2)
    }

    @Test func croppedRotatedScanFindsTheCorrectPDFRegion() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let document = try #require(PDFDocument(data: pdf([scan("ORCHID alignment", counterRotated: true)])))
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 30, width: 740, height: 560), for: .cropBox); page.rotation = 90
        let url = try source(try #require(document.dataRepresentation()), in: root)
        let matches = try await PDFTextReader().find("ORCHID", at: url)
        let bounds = try #require(matches.first?.bounds)
        #expect(matches.count == 1)
        // Known source-image geometry after the independent raster counter-rotation.
        #expect(CGRect(x: 110, y: 60, width: 70, height: 230).contains(CGPoint(x: bounds.midX, y: bounds.midY)))
    }

    @Test func replacingSourceInvalidatesCachedRecognition() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try source(pdf([scan("ORCHID laboratory")]), in: root)
        let reader = PDFTextReader()
        #expect(try await reader.find("orchid", at: url).count == 1)
        try pdf([scan("BIRCH field notes")]).write(to: url, options: .atomic)
        #expect(try await reader.find("orchid", at: url).isEmpty)
        #expect(try await reader.find("birch", at: url).count == 1)
    }

    @Test func libraryIndexesOldScansAndKeepsTheIndexWhenRenamed() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let library = PDFLibrary(directory: root)
        let item = try library.importPDF(data: pdf([scan("ORCHID laboratory")]), title: "Scanned worksheet")
        #expect(item.text.isEmpty)
        await library.indexSearchableText().value
        #expect(library.items.first?.text.localizedStandardContains("orchid") == true)
        #expect(library.items.first?.searchVersion == PDFTextReader.indexVersion)
        try library.rename(item, title: "Renamed worksheet")
        let reopened = PDFLibrary(directory: root)
        #expect(reopened.items.first?.title == "Renamed worksheet")
        #expect(reopened.items.first?.text.localizedStandardContains("orchid") == true)
    }

    @Test func cancellingSearchReturnsNoStaleResults() async throws {
        let root = folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = pdf([scan("ORCHID laboratory"), scan("ORCHID field notes")])
        let url = try source(bytes, in: root), reader = PDFTextReader()
        let work = Task { try await reader.find("orchid", at: url) }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
