import Foundation
import PencilKit
import UIKit
import Vision

/// On-device Chinese/English image recognition when stroke recognition lacks Chinese.
/// One request for the page, with region locations and alternative readings preserved.
actor VisionInkReader {
    static let shared = VisionInkReader()
    private var cachedInk: Data?
    private var cachedLines: [RecognizedLine] = []

    private var lineCache: [String: [String]] = [:]

    /// A second opinion on the exact stroke group used by the native recognizer.
    func lineReadings(in drawing: PKDrawing) async throws -> [String] {
        let key = PageFlashcards.digest(of: drawing)
        if let cached = lineCache[key] { return cached }
        let lines = try await readCrop(drawing).sorted { $0.bounds.minX < $1.bounds.minX }
        let primary = lines.map(\.text).joined(separator: " ")
        var readings = primary.isEmpty ? [] : [primary]
        for index in lines.indices {
            for alternative in lines[index].readings {
                var parts = lines.map(\.text)
                parts[index] = alternative
                let text = parts.joined(separator: " ")
                if !readings.contains(text) { readings.append(text) }
            }
        }
        try Task.checkCancellation()
        // One entry per ink cell: a page read as notes has many cells, read again by Suggest and by Cards.
        if lineCache.count >= 512 { lineCache.removeAll() }
        lineCache[key] = readings
        return readings
    }

    func lines(in drawing: PKDrawing) async throws -> [RecognizedLine] {
        try Task.checkCancellation()
        let ink = drawing.dataRepresentation()
        if ink == cachedInk { return cachedLines }
        guard !drawing.strokes.isEmpty else { return [] }
        let regions = Self.regions(in: drawing)
        var output: [RecognizedLine] = []
        for indices in regions {
            try Task.checkCancellation()
            let crop = PKDrawing(strokes: indices.map { drawing.strokes[$0] })
            output += try await readCrop(crop)
        }
        let checked = RecognitionCrossCheck.resolve(output)
        cachedInk = ink
        cachedLines = checked
        return checked
    }

    /// Connected strokes form local writing units. Large blank spaces must not cause
    /// isolated characters to be squeezed into one wide, mostly empty OCR image.
    static func regions(in drawing: PKDrawing) -> [[Int]] {
        var groups: [[Int]] = []
        for index in drawing.strokes.indices {
            let bounds = drawing.strokes[index].renderBounds.insetBy(dx: -12, dy: -12)
            let touching = groups.indices.filter { group in
                groups[group].contains { bounds.intersects(drawing.strokes[$0].renderBounds.insetBy(dx: -12, dy: -12)) }
            }
            var merged = [index]
            for group in touching.reversed() { merged += groups.remove(at: group) }
            groups.append(merged.sorted())
        }
        return groups.sorted {
            let a = drawing.strokes[$0[0]].renderBounds
            let b = drawing.strokes[$1[0]].renderBounds
            return abs(a.minY - b.minY) < 40 ? a.minX < b.minX : a.minY < b.minY
        }
    }

    private func readCrop(_ drawing: PKDrawing) async throws -> [RecognizedLine] {
        let padding = max(12, min(drawing.bounds.width, drawing.bounds.height) * 0.12)
        let rect = drawing.bounds.insetBy(dx: -padding, dy: -padding)
        guard rect.width > 0, rect.height > 0,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return [] }
        // Normalize ink color so white/dark-mode ink remains readable; never modify the drawing.
        let blackInk = PKDrawing(strokes: drawing.strokes.map {
            PKStroke(ink: PKInk($0.ink.inkType, color: .black), path: $0.path, transform: $0.transform, mask: $0.mask)
        })
        let scale = min(2, 2048 / max(rect.width, rect.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: rect.size))
            blackInk.image(from: rect, scale: scale).draw(at: .zero)
        }
        guard let cgImage = image.cgImage else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: cgImage)
        try Task.checkCancellation()
        let lines = observations.compactMap { observation -> RecognizedLine? in
            var readings: [String] = []
            for candidate in observation.topCandidates(3) where candidate.confidence >= 0.1 {
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && !readings.contains(text) { readings.append(text) }
            }
            guard let text = readings.first else { return nil }
            let box = observation.boundingBox
            let bounds = CGRect(x: rect.minX + box.origin.x * rect.width,
                                y: rect.minY + (1 - box.origin.y - box.height) * rect.height,
                                width: box.width * rect.width, height: box.height * rect.height)
            return RecognizedLine(text: text, bounds: bounds, readings: readings)
        }.sorted { $0.bounds.minY < $1.bounds.minY }
        #if DEBUG
        // The optional mobile model is local only. Add its reading as a second opinion;
        // never silently replace the student's ink or pretend a reading is certain.
        let readings = await PinyinOCR.shared.readings(drawing)
        if let reading = readings.first {
            if lines.count == 1 {
                var merged = lines[0]
                for alternative in readings where !merged.readings.contains(alternative) {
                    merged.readings.append(alternative)
                }
                return [merged]
            } else if lines.isEmpty {
                return [RecognizedLine(text: reading, bounds: drawing.bounds, readings: readings)]
            }
        }
        #endif
        return lines
    }
}
