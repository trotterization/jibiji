import CoreGraphics
import PencilKit

/// Pure, always-compiled pen geometry shared by the Debug recognition probes and the Release suggestion flow.
enum InkLineGeometry {
    /// A stroke is a tiny speck/accent if its rendered size is under this many points.
    static let speckMaxSize: CGFloat = 4
    /// Minimum blank band (points) between two lines.
    static let speckMinGap: CGFloat = 24
    /// A line break needs a blank horizontal band at least this many times the typical (median) body stroke height.
    static let lineGapFactor: CGFloat = 1.5

    /// Rectangle-to-rectangle distance (0 when they touch or overlap).
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(max(0, max(b.minX - a.maxX, a.minX - b.maxX)), max(0, max(b.minY - a.maxY, a.minY - b.maxY)))
    }

    /// Stroke indices (ascending, so source order is kept) per horizontal line, top to bottom. The pen geometry
    /// is the line detector: occupied vertical intervals of the non-tiny strokes' rendered bounds are merged,
    /// and a new line starts only across a blank band of at least ``lineGapFactor`` × the median body stroke
    /// height (never under ``speckMinGap``), so detached accents and dots stay with their letters. Tiny strokes
    /// join the line whose ink is closest. Falls back to a single group of every stroke whenever unsure: fewer
    /// than two lines, a line with fewer than two body strokes, or non-finite bounds.
    static func lineGroups(in drawing: PKDrawing) -> [[Int]] {
        lineGroups(rects: drawing.strokes.map { $0.renderBounds })
    }

    static func lineGroups(rects: [CGRect]) -> [[Int]] {
        let everything = [Array(rects.indices)]
        guard rects.count > 1, rects.allSatisfy({ [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }) else {
            return everything
        }
        let body = rects.indices.filter { max(rects[$0].width, rects[$0].height) >= speckMaxSize }
        guard body.count >= 4 else { return everything }
        let heights = body.map { rects[$0].height }.sorted()
        let median = heights[heights.count / 2]
        let threshold = max(speckMinGap, lineGapFactor * median)

        var groups: [[Int]] = []
        var bottom = -CGFloat.infinity
        for i in body.sorted(by: { rects[$0].minY < rects[$1].minY }) {
            if groups.isEmpty || rects[i].minY - bottom > threshold {
                groups.append([i])
                bottom = rects[i].maxY
            } else {
                groups[groups.count - 1].append(i)
                bottom = max(bottom, rects[i].maxY)
            }
        }
        guard groups.count > 1, groups.allSatisfy({ $0.count >= 2 }) else { return everything }

        for i in rects.indices where !body.contains(i) {
            var best = 0
            var bestGap = CGFloat.infinity
            for (g, members) in groups.enumerated() {
                let d = members.map { gap(rects[i], rects[$0]) }.min() ?? .infinity
                if d < bestGap { best = g; bestGap = d }
            }
            groups[best].append(i)
        }
        return groups.map { $0.sorted() }
    }
}
