import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// Machine-drawn "handwriting" for tests. Synthetic only: never real class notes.
enum SyntheticInk {
    /// Stroke polylines for a few simple characters in a unit square (y grows downward), in stroke order.
    static let glyphs: [Character: [[CGPoint]]] = [
        "一": [[p(0.08, 0.50), p(0.92, 0.50)]],
        "二": [[p(0.20, 0.30), p(0.80, 0.30)], [p(0.08, 0.75), p(0.92, 0.75)]],
        "三": [[p(0.20, 0.20), p(0.80, 0.20)], [p(0.26, 0.50), p(0.74, 0.50)], [p(0.08, 0.82), p(0.92, 0.82)]],
        "十": [[p(0.08, 0.45), p(0.92, 0.45)], [p(0.50, 0.06), p(0.50, 0.96)]],
        "人": [[p(0.50, 0.08), p(0.46, 0.45), p(0.10, 0.94)], [p(0.48, 0.40), p(0.92, 0.94)]],
        "大": [
            [p(0.10, 0.36), p(0.90, 0.36)],
            [p(0.50, 0.06), p(0.47, 0.50), p(0.10, 0.94)],
            [p(0.50, 0.50), p(0.92, 0.94)],
        ],
    ]

    /// Fixed so drawings built in different tests compare equal.
    static let creationDate = Date(timeIntervalSince1970: 1_790_000_000)

    /// Writes `text` left to right. Characters without a glyph leave a gap, like a space.
    static func drawing(
        writing text: String,
        origin: CGPoint = CGPoint(x: 80, y: 160),
        glyphSize: CGFloat = 96,
        spacing: CGFloat = 24
    ) -> PKDrawing {
        var strokes: [PKStroke] = []
        var x = origin.x
        for character in text {
            for polyline in glyphs[character] ?? [] {
                strokes.append(stroke(through: polyline.map {
                    CGPoint(x: x + $0.x * glyphSize, y: origin.y + $0.y * glyphSize)
                }))
            }
            x += glyphSize + spacing
        }
        return PKDrawing(strokes: strokes)
    }

    /// A pen stroke sampled every few points along `polyline` at a steady writing speed.
    static func stroke(through polyline: [CGPoint], width: CGFloat = 4) -> PKStroke {
        precondition(!polyline.isEmpty)
        let speed: CGFloat = 400 // points per second
        var samples: [PKStrokePoint] = []
        var time: TimeInterval = 0
        for (from, to) in zip(polyline, polyline.dropFirst()) {
            let length = hypot(to.x - from.x, to.y - from.y)
            let steps = max(1, Int(length / 3))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                samples.append(point(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), time, width))
                time += TimeInterval(length / CGFloat(steps) / speed)
            }
        }
        samples.append(point(polyline[polyline.count - 1], time, width))
        let path = PKStrokePath(controlPoints: samples, creationDate: creationDate)
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    private static func point(_ location: CGPoint, _ time: TimeInterval, _ width: CGFloat) -> PKStrokePoint {
        PKStrokePoint(
            location: location,
            timeOffset: time,
            size: CGSize(width: width, height: width),
            opacity: 1,
            force: 1,
            azimuth: 0,
            altitude: .pi / 2
        )
    }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}
