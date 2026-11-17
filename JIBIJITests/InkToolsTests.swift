import Testing
import UIKit
@testable import JIBIJI

@Suite("Ink palette")
@MainActor
struct InkToolsTests {
    @Test func mixedInkIsSavedAsHexAndReadBack() throws {
        let ink = InkTools.Ink(color: UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.5))
        #expect(ink.id == "#3366CC")
        #expect(ink.isCustom)
        #expect(InkTools.Ink(saved: "#3366CC") == ink)
        #expect(InkTools.Ink(saved: "rose") == .rose)
        #expect(InkTools.Ink(saved: "#XYZ") == nil)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ink.uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(b - 0.8) < 0.01 && a == 1)
    }

    @Test func inksCanBeKeptRemovedAndReset() {
        let tools = InkTools()
        let blue = InkTools.Ink(color: .blue)
        tools.use(blue, keep: false)
        #expect(tools.ink == blue && !tools.palette.contains(blue))
        tools.use(blue, keep: true)
        #expect(tools.palette.last == blue)
        tools.remove(blue)
        #expect(!tools.palette.contains(blue))
        #expect(tools.ink == .teal, "Writing moves on to the ink before the removed one")
        tools.remove(.ink)
        #expect(tools.palette.first == .ink, "Plain ink always stays")
        for step in 0..<20 { tools.use(InkTools.Ink(color: UIColor(white: CGFloat(step) / 20, alpha: 1)), keep: true) }
        #expect(tools.palette.count == InkTools.Ink.limit)
        tools.resetPalette()
        #expect(tools.palette == InkTools.Ink.builtIn)
    }
}
