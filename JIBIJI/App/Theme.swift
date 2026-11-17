import SwiftUI
import UIKit

/// The app's visual system: a near-monochrome palette, hairline borders, and a small set of
/// motion curves. Views take their colors and timing from here so the screens read as one app.
enum Theme {
    /// The backdrop behind panels and the notebook page.
    static let surface = Color(uiColor: .jibijiSurface)
    /// Raised panels: cards, rows, sheets' content blocks.
    static let panel = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.115, alpha: 1) : .white })
    /// One-pixel separators and panel outlines.
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.11) : UIColor(white: 0, alpha: 0.09) })
    /// Text and fills that sit on top of `Color.primary`.
    static let onInk = Color(uiColor: .systemBackground)

    static let saved = Color(red: 0.33, green: 0.76, blue: 0.50)
    static let pending = Color(red: 0.93, green: 0.70, blue: 0.27)
    static let problem = Color(red: 0.91, green: 0.36, blue: 0.33)

    static let panelRadius: CGFloat = 16
    static let controlRadius: CGFloat = 11

    enum Motion {
        /// Cover to notebook and back.
        static let screen = Animation.smooth(duration: 0.5)
        /// Rows entering, leaving, and changing section.
        static let list = Animation.snappy(duration: 0.34)
        /// Small state changes: status text, toggled labels.
        static let quick = Animation.snappy(duration: 0.22)
        /// Presses.
        static let press = Animation.spring(duration: 0.22, bounce: 0.2)
    }
}

extension UIColor {
    static let jibijiSurface = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.065, alpha: 1) : UIColor(red: 0.957, green: 0.957, blue: 0.949, alpha: 1) }

    /// The notebook page: the surface color with a quiet dot grid that scrolls with the ink.
    static let jibijiPaper = UIColor { traits in
        traits.userInterfaceStyle == .dark ? PaperTile.dark : PaperTile.light
    }
}

private enum PaperTile {
    static let light = make(.light)
    static let dark = make(.dark)

    private static func make(_ style: UIUserInterfaceStyle) -> UIColor {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let base = UIColor.jibijiSurface.resolvedColor(with: traits)
        let dot = style == .dark ? UIColor(white: 1, alpha: 0.13) : UIColor(white: 0, alpha: 0.15)
        let side: CGFloat = 24
        let tile = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            base.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            dot.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: side / 2 - 0.9, y: side / 2 - 0.9, width: 1.8, height: 1.8))
        }
        return UIColor(patternImage: tile)
    }
}

// MARK: - Surfaces

extension View {
    /// A raised panel with a hairline outline.
    func panel(radius: CGFloat = Theme.panelRadius) -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
    }

    /// Fades and lifts the view into place once, `delay` seconds after it appears.
    func rises(after delay: Double = 0, distance: CGFloat = 12) -> some View {
        modifier(Rise(delay: delay, distance: distance))
    }
}

private struct Rise: ViewModifier {
    let delay: Double
    let distance: CGFloat
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .onAppear {
                withAnimation(.smooth(duration: 0.55).delay(delay)) { shown = true }
            }
    }
}

// MARK: - Buttons

/// The main action in a group: filled with the text color.
struct SolidButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.primary, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Secondary actions: an outline only. Destructive roles are tinted.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(configuration.role == .destructive ? Theme.problem : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.07 : 0),
                in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.hairline))
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Square icon buttons in the notebook bar.
struct BarIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.85 : 0.3))
            .frame(width: 38, height: 38)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Shrinks its label slightly while pressed. For custom-drawn buttons.
struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.Motion.press, value: configuration.isPressed)
    }
}
