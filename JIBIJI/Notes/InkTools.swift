import PencilKit
import SwiftUI
import UIKit

/// The jibiji pen case: which tool, ink, and weight the page writes with. Remembered between
/// launches, except in disposable test notebooks, which always start with the pen.
@MainActor
@Observable
final class InkTools {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, fineliner, highlighter, eraser, lasso

        var id: Self { self }

        var name: String {
            switch self {
            case .pen: "Pen"
            case .fineliner: "Fineliner"
            case .highlighter: "Highlighter"
            case .eraser: "Eraser"
            case .lasso: "Lasso"
            }
        }

        var symbol: String {
            switch self {
            case .pen: "pencil"
            case .fineliner: "scribble"
            case .highlighter: "highlighter"
            case .eraser: "eraser"
            case .lasso: "lasso"
            }
        }

        /// Tools that lay down ink, and so take a color.
        var inks: Bool { self == .pen || self == .fineliner || self == .highlighter }
    }

    /// An ink on the bar: the logo's three colors, plain ink (black on light paper, white in the
    /// dark), or one the student mixed. Custom inks are stored as their hex code.
    struct Ink: Hashable, Identifiable {
        let id: String

        static let ink = Ink(id: "ink")
        static let rose = Ink(id: "rose")
        static let gold = Ink(id: "gold")
        static let teal = Ink(id: "teal")
        static let builtIn: [Ink] = [.ink, .rose, .gold, .teal]
        /// Room on the bar for this many inks.
        static let limit = 10

        private init(id: String) { self.id = id }

        /// A saved ink, or nil if `id` isn't one.
        init?(saved id: String) {
            if Self.builtIn.contains(where: { $0.id == id }) {
                self.id = id
            } else if let rgb = Self.rgb(fromHex: id) {
                self.id = Self.hex(rgb)
            } else {
                return nil
            }
        }

        /// A custom ink. Transparency is dropped: the highlighter adds its own.
        init(color: UIColor) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                var white: CGFloat = 0
                color.getWhite(&white, alpha: &a)
                (r, g, b) = (white, white, white)
            }
            id = Self.hex((r, g, b))
        }

        var isCustom: Bool { id.hasPrefix("#") }

        var name: String {
            switch id {
            case "ink": "Ink"
            case "rose": "Rose"
            case "gold": "Gold"
            case "teal": "Teal"
            default: "Custom \(id)"
            }
        }

        /// PencilKit adapts stored colors to dark mode itself, so black ink shows white there.
        var uiColor: UIColor {
            switch id {
            case "ink": UIColor.black
            case "rose": UIColor(red: 0.72, green: 0.36, blue: 0.32, alpha: 1)
            case "gold": UIColor(red: 0.80, green: 0.58, blue: 0.20, alpha: 1)
            case "teal": UIColor(red: 0.26, green: 0.48, blue: 0.45, alpha: 1)
            default: Self.custom(id)
            }
        }

        /// A concrete color: on the frosted bar, `.primary` would be blended by vibrancy into gray.
        var color: Color { self == .ink ? Color(uiColor: .label) : Color(uiColor: uiColor) }

        private static func custom(_ hex: String) -> UIColor {
            let rgb = rgb(fromHex: hex) ?? (0, 0, 0)
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }

        private static func hex(_ rgb: (CGFloat, CGFloat, CGFloat)) -> String {
            let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", byte(rgb.0), byte(rgb.1), byte(rgb.2))
        }

        private static func rgb(fromHex hex: String) -> (CGFloat, CGFloat, CGFloat)? {
            guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
        }
    }

    enum Weight: Int, CaseIterable, Identifiable {
        case fine, regular, bold

        var id: Self { self }

        var name: String {
            switch self {
            case .fine: "Fine"
            case .regular: "Regular"
            case .bold: "Bold"
            }
        }
    }

    enum EraserMode: String, CaseIterable, Identifiable {
        /// Removes whole strokes it touches.
        case strokes
        /// Rubs out only what it passes over.
        case partial

        var id: Self { self }
        var name: String { self == .strokes ? "Strokes" : "Partial" }
    }

    var tool: Tool = .pen {
        didSet {
            guard tool != oldValue else { return }
            previous = oldValue
            changed()
        }
    }
    /// The tool before the current one, for Apple Pencil's "switch to previous tool".
    private(set) var previous: Tool = .eraser
    var ink: Ink = .ink { didSet { changed() } }
    /// The inks on the bar, in order. Plain ink is always there.
    private(set) var palette: [Ink] = Ink.builtIn
    var eraserMode: EraserMode = .strokes { didSet { changed() } }
    var allowsFingerDrawing = false { didSet { changed() } }
    private var weights: [Tool: Weight] = [:]

    /// Where Apple Pencil asked for the tools (a squeeze, or a tap set to show the palette),
    /// in the canvas's coordinates. `nil` when the quick palette is closed.
    var quickPalette: CGPoint?

    /// Called after any change that affects the canvas's tool or drawing policy.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var persists = false
    @ObservationIgnored private var loaded = false

    func weight(for tool: Tool) -> Weight { weights[tool] ?? .regular }

    /// Writes with `ink`, and keeps it on the bar if `keep` is set and there's room.
    func use(_ ink: Ink, keep: Bool) {
        if keep, !palette.contains(ink), palette.count < Ink.limit { palette.append(ink) }
        self.ink = ink
        if !tool.inks { tool = .pen }
        changed()
    }

    var canAddInk: Bool { palette.count < Ink.limit }

    /// Takes an ink off the bar. Plain ink stays. Writing with it moves on to the ink before it.
    func remove(_ ink: Ink) {
        guard ink != .ink, let index = palette.firstIndex(of: ink) else { return }
        palette.remove(at: index)
        if self.ink == ink { self.ink = palette[max(0, index - 1)] }
        changed()
    }

    func resetPalette() {
        palette = Ink.builtIn
        if !palette.contains(ink) { ink = .ink }
        changed()
    }

    func setWeight(_ weight: Weight, for tool: Tool) {
        weights[tool] = weight
        changed()
    }

    /// Reads the remembered tools once. Test notebooks keep the defaults and never save.
    func load(persisting: Bool) {
        guard !loaded else { return }
        loaded = true
        guard persisting else { return }
        // Saving starts only after everything is read, so loading one value can't overwrite another.
        defer { persists = true }
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Keys.tool), let tool = Tool(rawValue: raw) { self.tool = tool }
        if let saved = defaults.stringArray(forKey: Keys.palette) {
            let inks = saved.compactMap(Ink.init(saved:))
            var unique: [Ink] = [.ink]
            for ink in inks where !unique.contains(ink) && unique.count < Ink.limit { unique.append(ink) }
            palette = unique
        }
        if let raw = defaults.string(forKey: Keys.ink), let ink = Ink(saved: raw) { self.ink = ink }
        if let raw = defaults.string(forKey: Keys.eraser), let mode = EraserMode(rawValue: raw) { eraserMode = mode }
        allowsFingerDrawing = defaults.bool(forKey: Keys.finger)
        for tool in Tool.allCases {
            if let raw = defaults.object(forKey: Keys.weight(tool)) as? Int, let weight = Weight(rawValue: raw) {
                weights[tool] = weight
            }
        }
    }

    var pkTool: PKTool {
        switch tool {
        case .pen: PKInkingTool(.pen, color: ink.uiColor, width: width(for: .pen))
        case .fineliner: PKInkingTool(.monoline, color: ink.uiColor, width: width(for: .fineliner))
        case .highlighter: PKInkingTool(.marker, color: ink.uiColor, width: width(for: .highlighter))
        case .eraser:
            eraserMode == .strokes ? PKEraserTool(.vector) : PKEraserTool(.fixedWidthBitmap, width: width(for: .eraser))
        case .lasso: PKLassoTool()
        }
    }

    private func width(for tool: Tool) -> CGFloat {
        let widths: [CGFloat] = switch tool {
        case .pen: [1.6, 2.6, 4.4]
        case .fineliner: [1.0, 1.6, 2.6]
        case .highlighter: [10, 16, 26]
        case .eraser: [8, 16, 32]
        case .lasso: [1, 1, 1]
        }
        return widths[weight(for: tool).rawValue]
    }

    // MARK: Apple Pencil

    /// A double-tap, done the way the student chose in Settings › Apple Pencil.
    func pencilTap(at location: CGPoint?) {
        perform(UIPencilInteraction.preferredTapAction, at: location)
    }

    /// A squeeze (Apple Pencil Pro), done the way the student chose in Settings › Apple Pencil.
    func pencilSqueeze(at location: CGPoint?) {
        perform(UIPencilInteraction.preferredSqueezeAction, at: location)
    }

    private func perform(_ action: UIPencilPreferredAction, at location: CGPoint?) {
        switch action {
        case .switchEraser:
            tool = tool == .eraser ? previous : .eraser
        case .switchPrevious:
            tool = previous
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            quickPalette = quickPalette == nil ? (location ?? .zero) : nil
        default:
            // Ignore, and system shortcuts, which iPadOS runs itself.
            break
        }
    }

    // MARK: Saving

    private func changed() {
        onChange?()
        guard persists else { return }
        let defaults = UserDefaults.standard
        defaults.set(tool.rawValue, forKey: Keys.tool)
        defaults.set(ink.id, forKey: Keys.ink)
        defaults.set(palette.map(\.id), forKey: Keys.palette)
        defaults.set(eraserMode.rawValue, forKey: Keys.eraser)
        defaults.set(allowsFingerDrawing, forKey: Keys.finger)
        for (tool, weight) in weights {
            defaults.set(weight.rawValue, forKey: Keys.weight(tool))
        }
    }

    private enum Keys {
        static let tool = "ink.tool"
        static let ink = "ink.color"
        static let palette = "ink.palette"
        static let eraser = "ink.eraser"
        static let finger = "ink.fingerDrawing"
        static func weight(_ tool: Tool) -> String { "ink.weight.\(tool.rawValue)" }
    }
}
