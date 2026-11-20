import CoreGraphics
import PencilKit

/// Pure, always-compiled layout candidates for Note Analysis. Read-only: it only looks at stroke bounds,
/// never recognizes text and never changes a drawing.
///
/// This is deliberately *not* the final grouping. It proposes rows and cells, and labels every boundary with
/// the evidence behind it. A later step (the note grouping) decides which weak boundaries are real, using the
/// recognized text. Layout never falls back to "one full row" when unsure: the uncertainty stays visible.
enum NoteLayout {
    enum Evidence: Equatable, Sendable {
        /// A wide blank band (the old line/cell rule). Safe to treat as a break.
        case clearGap
        /// Stroke size changes sharply across a small gap: typically Pinyin directly above Hanzi.
        case scaleChange
        /// A blank band with neither: could be a break between entries or just space inside one glyph or word.
        case tightGap
    }

    struct Boundary: Equatable, Sendable {
        /// Blank distance in points between the two sides.
        var gap: CGFloat
        /// Larger over smaller typical stroke size on the two sides (always at least 1).
        var scaleRatio: CGFloat
        var evidence: Evidence
    }

    struct CellCandidate: Equatable, Sendable {
        var strokeIndices: [Int]
        var bounds: CGRect
        /// Zero-based position within the row, left to right.
        var column: Int
        var scale: CGFloat
        /// Nil for the first cell of a row.
        var gapBefore: Boundary?
    }

    struct RowCandidate: Equatable, Sendable {
        var strokeIndices: [Int]
        var bounds: CGRect
        /// Zero-based, top to bottom.
        var row: Int
        var scale: CGFloat
        /// Nil for the first row.
        var boundaryAbove: Boundary?
        var cells: [CellCandidate]
    }

    /// Smallest blank band that proposes a break at all.
    static let minBlank: CGFloat = 2
    /// Sizes differing by at least this factor across a boundary suggest a different kind of writing.
    static let scaleChangeRatio: CGFloat = 1.6
    /// A one-stroke band this small next to a neighbor (and within its width) is a tone mark or dot, not a row.
    static let markScaleFactor: CGFloat = 0.6
    /// A horizontal break is proposed at a gap of at least this share of the row's stroke size (never under 8 pt).
    static let cellGapScaleFactor: CGFloat = 0.4
    static let cellGapFloor: CGFloat = 8

    static func candidates(in drawing: PKDrawing) -> [RowCandidate] {
        candidates(rects: drawing.strokes.map { $0.renderBounds })
    }

    static func candidates(rects: [CGRect]) -> [RowCandidate] {
        guard !rects.isEmpty,
              rects.allSatisfy({ [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) })
        else { return [] }

        let body = rects.indices.filter { size(rects[$0]) >= InkLineGeometry.speckMaxSize }
        guard !body.isEmpty else { return [row(0, Array(rects.indices), nil, rects)] }

        var bands = mergeMarks(verticalBands(of: body, rects: rects), rects: rects)
        for i in rects.indices where !body.contains(i) {
            let nearest = bands.indices.min { distance(rects[i], bands[$0], rects) < distance(rects[i], bands[$1], rects) } ?? 0
            bands[nearest].append(i)
        }
        bands = bands.sorted { bounds($0, rects).minY < bounds($1, rects).minY }

        return bands.enumerated().map { index, members in
            row(index, members.sorted(), index == 0 ? nil : boundary(bands[index - 1], members, rects), rects)
        }
    }

    // MARK: - Rows

    /// Body strokes merged into bands wherever the occupied vertical intervals touch or nearly touch.
    private static func verticalBands(of body: [Int], rects: [CGRect]) -> [[Int]] {
        var bands: [[Int]] = []
        var bottom = -CGFloat.infinity
        for i in body.sorted(by: { rects[$0].minY < rects[$1].minY }) {
            if bands.isEmpty || rects[i].minY - bottom >= minBlank {
                bands.append([i])
                bottom = rects[i].maxY
            } else {
                bands[bands.count - 1].append(i)
                bottom = max(bottom, rects[i].maxY)
            }
        }
        return bands
    }

    /// A lone small stroke sitting over or under a bigger band, within its width, joins that band.
    private static func mergeMarks(_ bands: [[Int]], rects: [CGRect]) -> [[Int]] {
        var bands = bands
        var index = 0
        while index < bands.count, bands.count > 1 {
            let band = bands[index]
            let neighbors = [index - 1, index + 1].filter { bands.indices.contains($0) }
            let target = neighbors
                .filter { neighbor in
                    let other = bands[neighbor]
                    let box = bounds(band, rects)
                    let otherBox = bounds(other, rects)
                    return band.count == 1
                        && size(rects[band[0]]) <= markScaleFactor * scale(of: other, rects)
                        && box.minX >= otherBox.minX - box.width && box.maxX <= otherBox.maxX + box.width
                }
                .min { gapBetween(bands[$0], band, rects) < gapBetween(bands[$1], band, rects) }
            if let target {
                bands[target].append(contentsOf: band)
                bands.remove(at: index)
                index = max(0, index - 1)
            } else {
                index += 1
            }
        }
        return bands
    }

    private static func boundary(_ above: [Int], _ below: [Int], _ rects: [CGRect]) -> Boundary {
        let gap = max(0, bounds(below, rects).minY - bounds(above, rects).maxY)
        let a = scale(of: above, rects), b = scale(of: below, rects)
        let ratio = ratio(a, b)
        let clear = max(InkLineGeometry.speckMinGap, InkLineGeometry.lineGapFactor * median(above + below, rects) { $0.height })
        let evidence: Evidence = gap >= clear ? .clearGap : (ratio >= scaleChangeRatio ? .scaleChange : .tightGap)
        return Boundary(gap: gap, scaleRatio: ratio, evidence: evidence)
    }

    // MARK: - Cells

    private static func row(_ index: Int, _ members: [Int], _ above: Boundary?, _ rects: [CGRect]) -> RowCandidate {
        RowCandidate(
            strokeIndices: members,
            bounds: bounds(members, rects),
            row: index,
            scale: scale(of: members, rects),
            boundaryAbove: above,
            cells: cells(of: members, rects)
        )
    }

    private static func cells(of members: [Int], _ rects: [CGRect]) -> [CellCandidate] {
        let body = members.filter { size(rects[$0]) >= InkLineGeometry.speckMaxSize }
        guard !body.isEmpty else { return [cell(members, 0, nil, rects)] }
        let cut = max(cellGapFloor, cellGapScaleFactor * scale(of: members, rects))

        var groups: [[Int]] = []
        var right = -CGFloat.infinity
        for i in body.sorted(by: { rects[$0].minX < rects[$1].minX }) {
            if groups.isEmpty || rects[i].minX - right >= cut {
                groups.append([i])
                right = rects[i].maxX
            } else {
                groups[groups.count - 1].append(i)
                right = max(right, rects[i].maxX)
            }
        }
        for i in members where !body.contains(i) {
            let nearest = groups.indices.min { distance(rects[i], groups[$0], rects) < distance(rects[i], groups[$1], rects) } ?? 0
            groups[nearest].append(i)
        }
        groups.sort { bounds($0, rects).minX < bounds($1, rects).minX }

        // A horizontal break is only convincing on its own with about a stroke-length of blank space.
        let clear = max(InkLineGeometry.speckMinGap, scale(of: members, rects))
        return groups.enumerated().map { column, group in
            var before: Boundary?
            if column > 0 {
                let gap = max(0, bounds(group, rects).minX - bounds(groups[column - 1], rects).maxX)
                let ratio = ratio(scale(of: groups[column - 1], rects), scale(of: group, rects))
                before = Boundary(gap: gap, scaleRatio: ratio, evidence: gap >= clear ? .clearGap : .tightGap)
            }
            return cell(group.sorted(), column, before, rects)
        }
    }

    private static func cell(_ members: [Int], _ column: Int, _ before: Boundary?, _ rects: [CGRect]) -> CellCandidate {
        CellCandidate(strokeIndices: members, bounds: bounds(members, rects), column: column,
                      scale: scale(of: members, rects), gapBefore: before)
    }

    // MARK: - Measurements

    private static func size(_ rect: CGRect) -> CGFloat { max(rect.width, rect.height) }

    private static func bounds(_ members: [Int], _ rects: [CGRect]) -> CGRect {
        members.dropFirst().reduce(rects[members[0]]) { $0.union(rects[$1]) }
    }

    /// Typical stroke size: the upper quartile of the body strokes' longest sides (so short dots don't drag it down).
    private static func scale(of members: [Int], _ rects: [CGRect]) -> CGFloat {
        let sizes = members.map { size(rects[$0]) }.filter { $0 >= InkLineGeometry.speckMaxSize }.sorted()
        guard !sizes.isEmpty else { return members.map { size(rects[$0]) }.max() ?? 0 }
        return sizes[min(sizes.count - 1, sizes.count * 3 / 4)]
    }

    private static func median(_ members: [Int], _ rects: [CGRect], _ value: (CGRect) -> CGFloat) -> CGFloat {
        let values = members.map { value(rects[$0]) }.sorted()
        return values.isEmpty ? 0 : values[values.count / 2]
    }

    private static func ratio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        guard a > 0, b > 0 else { return 1 }
        return max(a, b) / min(a, b)
    }

    private static func distance(_ rect: CGRect, _ members: [Int], _ rects: [CGRect]) -> CGFloat {
        members.map { InkLineGeometry.gap(rect, rects[$0]) }.min() ?? .infinity
    }

    private static func gapBetween(_ a: [Int], _ b: [Int], _ rects: [CGRect]) -> CGFloat {
        InkLineGeometry.gap(bounds(a, rects), bounds(b, rects))
    }
}
