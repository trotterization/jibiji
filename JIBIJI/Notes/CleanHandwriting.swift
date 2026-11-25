import CoreText
import PencilKit
import UIKit

/// Turns a clean handwriting typeface into editable PencilKit ink, written with the student's own
/// pen: each character becomes thin strokes along the middle of its glyph, at the width of the
/// strokes it replaces. No text stickers, no filled outlines: the eraser and lasso work on it.
@MainActor
enum CleanHandwriting {
    static func font(size: CGFloat) -> UIFont {
        UIFont(name: "LXGWWenKaiTC-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
    }

    /// The pen a replacement is written with.
    struct Pen {
        var inkType: PKInk.InkType = .pen
        var color: UIColor = .black
        var width: CGFloat = 2.4

        /// The ink, color, and typical width of `strokes`, so the replacement sits with them.
        static func matching(_ strokes: [PKStroke]) -> Pen {
            guard let first = strokes.first else { return Pen() }
            let widths = strokes.flatMap { stroke -> [CGFloat] in
                let t = stroke.transform
                let scale = sqrt(abs(t.a * t.d - t.b * t.c))
                return stroke.path.map { $0.size.width * scale }
            }.filter { $0.isFinite && $0 > 0 }.sorted()
            let width = widths.isEmpty ? 2.4 : widths[widths.count / 2]
            let writes: [PKInk.InkType] = [.pen, .monoline, .fountainPen, .pencil]
            return Pen(inkType: writes.contains(first.ink.inkType) ? first.ink.inkType : .pen,
                       color: first.ink.color,
                       width: min(max(width, 1), 8))
        }
    }

    static func drawing(text: String, in target: CGRect, color: UIColor = .black) -> PKDrawing? {
        drawing(text: text, in: target, pen: Pen(color: color))
    }

    /// `maxWidth` nil: the text is fitted inside `target`. Otherwise it is written at `target`'s height, starting at its
    /// left edge and growing to the right as far as `maxWidth`, so a long replacement is not shrunk into a short word's box.
    static func drawing(text: String, in target: CGRect, pen: Pen, maxWidth: CGFloat? = nil) -> PKDrawing? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 200, !text.contains("\n"), !text.contains("\r"),
              target.width > 1, target.height > 1,
              [target.minX, target.minY, target.width, target.height].allSatisfy(\.isFinite) else { return nil }
        let emSize: CGFloat = 64
        let attributed = NSAttributedString(string: text, attributes: [.font: font(size: emSize)])
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
        let scale = maxWidth.map { min(target.height / bounds.height, max($0, target.width) / bounds.width) }
            ?? min(target.width / bounds.width, target.height / bounds.height)
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                         tx: target.minX - bounds.minX * scale,
                                         ty: target.minY + bounds.maxY * scale)
        // About 150 pixels per em: enough detail for dense characters, small enough to be quick.
        let pixelsPerPoint = 150 / (emSize * scale)
        let strokes = paths.flatMap { path -> [PKStroke] in
            guard let mapped = path.copy(using: &transform) else { return [] }
            return GlyphSkeleton.centerlines(of: mapped, pixelsPerUnit: pixelsPerPoint).map { stroke($0, pen: pen) }
        }
        // Canonicalize PencilKit's serialized precision before recording identities.
        return strokes.isEmpty ? nil : try? PKDrawing(data: PKDrawing(strokes: strokes).dataRepresentation())
    }

    private static func stroke(_ points: [CGPoint], pen: Pen) -> PKStroke {
        let samples = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: TimeInterval(index) * 0.008,
                          size: CGSize(width: pen.width, height: pen.width), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        // Synthetic ink is already complete, so all sample timestamps must be
        // in the past. Future timestamps make PencilKit omit it from snapshots.
        return PKStroke(ink: PKInk(pen.inkType, color: pen.color),
                        path: PKStrokePath(controlPoints: samples, creationDate: Date(timeIntervalSince1970: 0)))
    }
}

/// The middle lines of a filled glyph: rasterize, thin to one pixel (Zhang–Suen), trim the short
/// spurs a brush-style font leaves at stroke ends, then trace and smooth polylines.
enum GlyphSkeleton {
    static func centerlines(of path: CGPath, pixelsPerUnit k: CGFloat) -> [[CGPoint]] {
        let box = path.boundingBoxOfPath
        guard box.width > 0, box.height > 0, k.isFinite, k > 0 else { return [] }
        let pad = 3
        let w = Int((box.width * k).rounded(.up)) + pad * 2
        let h = Int((box.height * k).rounded(.up)) + pad * 2
        guard w > pad * 2, h > pad * 2, w * h < 1_500_000 else { return [] }

        // 1. Rasterize. Memory row 0 is the top of the bitmap, i.e. the largest y in the context.
        var raster = [UInt8](repeating: 0, count: w * h)
        let drawn = raster.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.translateBy(x: CGFloat(pad), y: CGFloat(pad))
            context.scaleBy(x: k, y: k)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.addPath(path)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
            return true
        }
        guard drawn else { return [] }
        var image = raster.map { $0 > 127 ? UInt8(1) : 0 }
        let filled = image.reduce(0) { $0 + Int($1) }
        guard filled > 0 else { return [] }

        // 2. Thin.
        thin(&image, w, h)
        let skeleton = image.reduce(0) { $0 + Int($1) }
        guard skeleton > 0 else { return [] }

        // 3. Trim spurs shorter than about the glyph's stroke thickness.
        let thickness = Double(filled) / Double(skeleton)
        prune(&image, w, h, length: max(2, Int(thickness * 0.8)))

        // 4. Trace, smooth, and map back. Pixel centers go back to the path's coordinates.
        let toPath = { (p: CGPoint) -> CGPoint in
            CGPoint(x: (p.x - CGFloat(pad)) / k + box.minX,
                    y: (CGFloat(h) - p.y - CGFloat(pad)) / k + box.minY)
        }
        return trace(image, w, h, minLength: max(3, Int(thickness))).map { smooth($0).map(toPath) }
    }

    private static let offsets8 = [(0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1)]

    private static func neighbors(_ image: [UInt8], _ w: Int, _ i: Int) -> Int {
        let x = i % w, y = i / w
        return offsets8.reduce(0) { $0 + Int(image[(y + $1.1) * w + x + $1.0]) }
    }

    private static func thin(_ image: inout [UInt8], _ w: Int, _ h: Int) {
        var changed = true
        while changed {
            changed = false
            for step in 0..<2 {
                var remove: [Int] = []
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let i = y * w + x
                        guard image[i] == 1 else { continue }
                        // p2 (north) clockwise to p9 (north-west).
                        let p = offsets8.map { Int(image[(y + $0.1) * w + x + $0.0]) }
                        let count = p.reduce(0, +)
                        guard (2...6).contains(count) else { continue }
                        var transitions = 0
                        for j in 0..<8 where p[j] == 0 && p[(j + 1) % 8] == 1 { transitions += 1 }
                        guard transitions == 1 else { continue }
                        let (p2, p4, p6, p8) = (p[0], p[2], p[4], p[6])
                        if step == 0 {
                            guard p2 * p4 * p6 == 0, p4 * p6 * p8 == 0 else { continue }
                        } else {
                            guard p2 * p4 * p8 == 0, p2 * p6 * p8 == 0 else { continue }
                        }
                        remove.append(i)
                    }
                }
                for i in remove { image[i] = 0 }
                if !remove.isEmpty { changed = true }
            }
        }
    }

    /// Removes branches that end within `length` pixels of a junction. Whole small pieces (a dot,
    /// a tone mark) are kept.
    private static func prune(_ image: inout [UInt8], _ w: Int, _ h: Int, length: Int) {
        let original = image
        var trimmed = image
        for _ in 0..<length {
            let ends = trimmed.indices.filter { trimmed[$0] == 1 && neighbors(trimmed, w, $0) == 1 }
            if ends.isEmpty { break }
            for i in ends { trimmed[i] = 0 }
        }
        // Grow the surviving branch ends back along the original skeleton.
        var frontier = trimmed.indices.filter { trimmed[$0] == 1 && neighbors(trimmed, w, $0) <= 1 }
        for _ in 0..<length {
            var next: [Int] = []
            for i in frontier {
                let x = i % w, y = i / w
                for (dx, dy) in offsets8 {
                    let j = (y + dy) * w + x + dx
                    if original[j] == 1, trimmed[j] == 0 { trimmed[j] = 1; next.append(j) }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        // Pieces that pruning erased entirely were small marks, not spurs: keep them.
        var seen = [Bool](repeating: false, count: original.count)
        for start in original.indices where original[start] == 1 && !seen[start] {
            var component: [Int] = []
            var stack = [start]
            seen[start] = true
            while let i = stack.popLast() {
                component.append(i)
                let x = i % w, y = i / w
                for (dx, dy) in offsets8 {
                    let j = (y + dy) * w + x + dx
                    if original[j] == 1, !seen[j] { seen[j] = true; stack.append(j) }
                }
            }
            if !component.contains(where: { trimmed[$0] == 1 }) {
                for i in component { trimmed[i] = 1 }
            }
        }
        image = trimmed
    }

    /// Walks the skeleton into polylines, starting from loose ends (top-left first) and going as
    /// straight as it can through junctions. A line that stops beside another ends on it, so the
    /// strokes meet.
    private static func trace(_ image: [UInt8], _ w: Int, _ h: Int, minLength: Int) -> [[CGPoint]] {
        var visited = [Bool](repeating: false, count: image.count)
        let on = image.indices.filter { image[$0] == 1 }
        let ends = on.filter { neighbors(image, w, $0) == 1 }.sorted { ($0 / w, $0 % w) < ($1 / w, $1 % w) }
        var lines: [[CGPoint]] = []
        func point(_ i: Int) -> CGPoint { CGPoint(x: CGFloat(i % w) + 0.5, y: CGFloat(i / w) + 0.5) }

        func walk(from start: Int) {
            var path = [start]
            visited[start] = true
            var current = start
            var direction: (Int, Int)?
            while true {
                let x = current % w, y = current / w
                var best: (index: Int, offset: (Int, Int), score: Int)?
                for (dx, dy) in offsets8 {
                    let j = (y + dy) * w + x + dx
                    guard image[j] == 1, !visited[j] else { continue }
                    // Prefer going straight, then side steps (4-neighbors) over diagonals.
                    var score = (dx == 0 || dy == 0) ? 0 : 1
                    if let d = direction { score += 4 - (d.0 * dx + d.1 * dy) * 2 }
                    if best == nil || score < best!.score { best = (j, (dx, dy), score) }
                }
                guard let next = best else { break }
                visited[next.index] = true
                path.append(next.index)
                direction = next.offset
                current = next.index
            }
            // Touch a neighboring line at each end, if there is one, so strokes meet.
            func neighbor(of i: Int) -> Int? {
                let x = i % w, y = i / w
                return offsets8.map { (y + $0.1) * w + x + $0.0 }.first { image[$0] == 1 && visited[$0] && !path.contains($0) }
            }
            let head = neighbor(of: start), tail = neighbor(of: current)
            // A short piece hanging off other lines is what's left of a junction, not a stroke.
            if path.count < minLength, head != nil || tail != nil { return }
            if let tail { path.append(tail) }
            if let head { path.insert(head, at: 0) }
            if path.count >= 2 { lines.append(path.map(point)) } else { lines.append([point(start), point(start)]) }
        }

        for start in ends where !visited[start] { walk(from: start) }
        // Closed loops have no ends.
        for start in on where !visited[start] { walk(from: start) }
        return lines
    }

    /// A short moving average, so pixel stairs become smooth ink, then every other point.
    private static func smooth(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 4 else { return points }
        let radius = 2
        let averaged = points.indices.map { i -> CGPoint in
            let range = max(0, i - radius)...min(points.count - 1, i + radius)
            let sum = range.reduce(CGPoint.zero) { CGPoint(x: $0.x + points[$1].x, y: $0.y + points[$1].y) }
            return CGPoint(x: sum.x / CGFloat(range.count), y: sum.y / CGFloat(range.count))
        }
        // Keep the true ends so strokes still reach their tips and junctions.
        var result = [points[0]]
        result += stride(from: 2, to: averaged.count - 1, by: 2).map { averaged[$0] }
        result.append(points[points.count - 1])
        return result
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
