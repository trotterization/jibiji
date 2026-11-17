import CoreText
import PencilKit
import UIKit

/// Turns a clean handwriting typeface into editable PencilKit ink.
/// No text stickers: the ordinary eraser and lasso work on it.
@MainActor
enum CleanHandwriting {
    static func font(size: CGFloat) -> UIFont {
        UIFont(name: "LXGWWenKaiTC-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
    }

    static func drawing(text: String, in target: CGRect, color: UIColor = .black) -> PKDrawing? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 200, !text.contains("\n"), !text.contains("\r"),
              target.width > 1, target.height > 1,
              [target.minX, target.minY, target.width, target.height].allSatisfy(\.isFinite) else { return nil }
        let attributed = NSAttributedString(string: text, attributes: [.font: font(size: 64)])
        let line = CTLineCreateWithAttributedString(attributed)
        var paths: [CGPath] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attrs[kCTFontAttributeName] else { return nil }
            let ctFont = runFont as! CTFont
            for i in 0..<count {
                guard let path = CTFontCreatePathForGlyph(ctFont, glyphs[i], nil) else { continue }
                var translation = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                if let moved = path.copy(using: &translation) { paths.append(moved) }
            }
        }
        guard let first = paths.first else { return nil }
        let bounds = paths.dropFirst().reduce(first.boundingBoxOfPath) { $0.union($1.boundingBoxOfPath) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                         tx: target.minX - bounds.minX * scale,
                                         ty: target.minY + bounds.maxY * scale)
        let strokes = paths.compactMap { path -> PKStroke? in
            guard let mapped = path.copy(using: &transform) else { return nil }
            let box = mapped.boundingBoxOfPath
            let diameter = max(box.height * 2, 4)
            let count = max(4, Int(box.width / 2))
            let points = (0...count).map { index -> PKStrokePoint in
                let progress = CGFloat(index) / CGFloat(count)
                return PKStrokePoint(location: CGPoint(x: box.minX + box.width * progress, y: box.midY),
                                     timeOffset: TimeInterval(progress) * 0.2,
                                     size: CGSize(width: diameter, height: diameter), opacity: 1, force: 1,
                                     azimuth: 0, altitude: .pi / 2)
            }
            // Synthetic ink is already complete, so all sample timestamps must be
            // in the past. Future timestamps make PencilKit omit it from snapshots.
            return PKStroke(ink: PKInk(.pen, color: color),
                            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)),
                            mask: UIBezierPath(cgPath: mapped))
        }
        // Canonicalize PencilKit's serialized precision before recording identities.
        return strokes.isEmpty ? nil : try? PKDrawing(data: PKDrawing(strokes: strokes).dataRepresentation())
    }
}

/// Select only strokes belonging mostly to the recognized region, not arrows
/// or strokes that merely cross it. Exact stroke identities are retained for acceptance.
enum InkSelection {
    static func identity(_ stroke: PKStroke) -> String {
        PageFlashcards.digest(of: PKDrawing(strokes: [stroke]))
    }

    static func indices(in drawing: PKDrawing, bounds: CGRect) -> [Int] {
        let region = bounds.insetBy(dx: -3, dy: -3)
        return drawing.strokes.indices.filter { index in
            let stroke = drawing.strokes[index]
            guard stroke.renderBounds.intersects(region), !stroke.path.isEmpty else { return false }
            let points = stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(stroke.transform) }
            guard !points.isEmpty else { return region.contains(stroke.renderBounds) }
            return Double(points.filter { region.contains($0) }.count) / Double(points.count) >= 0.6
        }
    }
}

/// Kept with the accepted metadata before removing original ink. It survives
/// relaunch, and identifies only this replacement so later writing is preserved.
struct InkReplacement: Codable, Equatable {
    var originalInk: Data
    var originalIndices: [Int]
    var replacementStrokeIDs: Set<String>
}
