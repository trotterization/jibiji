import SwiftUI

/// The notebook's cover. The paper tile floats over a live field made from the notebook's own
/// dot grid: washes in the logo's three colors drift under it, a ripple lays the grid down on
/// launch, and a touch tilts the tile and lenses the dots under the finger. Opening dives through
/// the tile into the page.
///
/// Every moving value is computed from one clock on each display frame, so motion runs at the
/// screen's full refresh rate. Reduce Motion (and disposable UI-test notebooks) keep it still.
struct NotebookCoverView: View {
    /// Keeps the field still, so UI tests can reach an idle app.
    var isStill = false
    let openNotebook: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var start = Date.now
    @State private var appeared = false
    @State private var opening = false
    @State private var openedAt: Date?
    @State private var press = Press()
    @State private var tilt = CGSize.zero
    @State private var tileCenter: CGPoint?

    private static let space = "cover"
    private static let paper = Color(red: 0.93, green: 0.88, blue: 0.79)
    private static let dotColors = [CoverField.gold, CoverField.rose, CoverField.teal]

    private var still: Bool { reduceMotion || isStill }
    private var dark: Bool { colorScheme == .dark }
    /// Text on the cover: near-black on light paper, the logo's paper color in the dark.
    private var ink: Color { dark ? Self.paper : Color(white: 0.11) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(paused: still)) { timeline in
                let now = still ? start.addingTimeInterval(3) : timeline.date
                let time = now.timeIntervalSince(start)
                ZStack {
                    CoverField(frame: fieldFrame(at: now, size: size), dark: dark)
                        .accessibilityHidden(true)
                    content(size: size, time: time)
                }
            }
            .contentShape(Rectangle())
            .gesture(touchGesture(in: size))
        }
        .coordinateSpace(.named(Self.space))
        .ignoresSafeArea()
        .onAppear {
            start = .now
            appeared = true
        }
    }

    // MARK: - Layout

    private func content(size: CGSize, time: Double) -> some View {
        let tileWidth = min(size.width - 64, size.height * 0.36, 340)
        // A slow float while idle; none while pressed or opening.
        let drift = still || opening ? 0 : sin(time * 0.9)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Self.dotColors.indices, id: \.self) { index in
                    Circle().fill(Self.dotColors[index])
                        .scaleEffect(appeared ? 1 : 0)
                        .animation(.spring(duration: 0.5, bounce: 0.45).delay(0.35 + Double(index) * 0.09), value: appeared)
                }
            }
            .frame(width: 42, height: 6)
            .padding(.bottom, 18)
            .leaves(opening)
            Text("A LITTLE SPACE TO LEARN")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(ink.opacity(0.5))
                .rises(after: 0.35, distance: 6)
                .leaves(opening)

            Image("JibijiCoverTile")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: tileWidth)
                .shadow(color: .black.opacity(dark ? 0.55 : 0.10), radius: 3, y: 2)
                .shadow(color: .black.opacity(dark ? 0.5 : 0.16), radius: 34, y: 22 + 4 * drift)
                .rotation3DEffect(
                    .degrees(Double(hypot(tilt.width, tilt.height)) * 11),
                    axis: (x: -tilt.height, y: tilt.width, z: 0),
                    perspective: 0.55
                )
                .rotationEffect(.degrees(0.6 * drift))
                .offset(y: -5 * drift)
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let frame = proxy.frame(in: .named(Self.space))
                    return CGPoint(x: frame.midX, y: frame.midY)
                } action: { tileCenter = $0 }
                // Entrance: tips forward and settles.
                .scaleEffect(appeared ? 1 : 0.84)
                .rotation3DEffect(.degrees(appeared ? 0 : 28), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .offset(y: appeared ? 0 : 46)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(duration: 1.1, bounce: 0.28).delay(0.08), value: appeared)
                // Opening: dives through. It starts moving at once and fades as it passes.
                .animation(.smooth(duration: 0.7)) { $0.scaleEffect(opening ? 2.6 : 1) }
                .animation(.easeIn(duration: 0.4)) { $0.blur(radius: opening ? 14 : 0).opacity(opening ? 0 : 1) }
                .padding(.top, 26)
                .accessibilityLabel("Jibiji logo: a paper J with gold, rose, and teal dots")

            Text("jibiji")
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .tracking(-2)
                .foregroundStyle(ink)
                .padding(.top, 22)
                .rises(after: 0.45)
                .leaves(opening)
            Text("笔记")
                .font(.system(size: 18, weight: .regular, design: .serif))
                .tracking(8)
                .foregroundStyle(ink.opacity(0.62))
                .padding(.top, 3)
                .rises(after: 0.52)
                .leaves(opening)
            Text("Write naturally. Study what you wrote.")
                .font(.system(size: 16))
                .multilineTextAlignment(.center)
                .foregroundStyle(ink.opacity(0.66))
                .padding(.top, 24)
                .padding(.horizontal, 24)
                .rises(after: 0.58)
                .leaves(opening)

            Button(action: open) {
                HStack(spacing: 26) {
                    Text("Open notebook")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(dark ? Color.black : Self.paper)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(ink, in: Capsule())
            }
            .buttonStyle(PressScaleButtonStyle())
            .sensoryFeedback(.impact(weight: .light), trigger: opening) { _, isOpening in isOpening }
            .accessibilityIdentifier("openNotebook")
            .padding(.top, 32)
            .rises(after: 0.66)
            .leaves(opening)

            Text("JIBIJI  /  HANGZHOU, CHINA")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(ink.opacity(0.36))
                .padding(.top, 42)
                .rises(after: 0.76, distance: 0)
                .leaves(opening)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Interaction

    private func open() {
        guard openedAt == nil else { return }
        openedAt = .now
        opening = true
        // Building the notebook (the PencilKit canvas and its page) briefly blocks the main
        // thread, so it starts only once the tile has gone, not halfway through the dive.
        Task {
            try? await Task.sleep(for: .milliseconds(still ? 0 : 420))
            openNotebook()
        }
    }

    private func touchGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard !still, openedAt == nil else { return }
                if !press.isDown {
                    press = Press(location: value.location, downAt: .now, ripple: value.location, rippleAt: .now)
                } else {
                    press.location = value.location
                }
                let center = tileCenter ?? CGPoint(x: size.width / 2, y: size.height / 2)
                let reach = max(size.width, size.height) * 0.5
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.82)) {
                    tilt = CGSize(
                        width: max(-1, min(1, (value.location.x - center.x) / reach)),
                        height: max(-1, min(1, (value.location.y - center.y) / reach))
                    )
                }
            }
            .onEnded { _ in
                press.upAt = .now
                withAnimation(.spring(duration: 0.9, bounce: 0.38)) { tilt = .zero }
            }
    }

    private func fieldFrame(at now: Date, size: CGSize) -> CoverField.Frame {
        let time = now.timeIntervalSince(start)
        var frame = CoverField.Frame(time: time)
        if still { return frame }

        // The launch ripple starts under the tile as it lands; a touch replaces it.
        if let ripple = press.ripple, let at = press.rippleAt {
            frame.ripple = (ripple, now.timeIntervalSince(at))
        } else {
            let center = tileCenter ?? CGPoint(x: size.width / 2, y: size.height / 2)
            frame.ripple = (center, time - 0.3)
        }
        if let location = press.location, let down = press.downAt {
            let rise = min(1, now.timeIntervalSince(down) / 0.22)
            let fall = press.upAt.map { max(0, 1 - now.timeIntervalSince($0) / 0.6) } ?? 1
            frame.lens = (location, smooth(rise) * smooth(fall))
        }
        if let openedAt {
            let progress = min(1, now.timeIntervalSince(openedAt) / 0.6)
            frame.open = progress * progress * progress
        }
        return frame
    }

    private func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private struct Press {
        var location: CGPoint?
        var downAt: Date?
        var upAt: Date?
        var ripple: CGPoint?
        var rippleAt: Date?
        var isDown: Bool { downAt != nil && upAt == nil }
    }
}

private extension View {
    /// Fades, drops, and softens the view when the notebook opens.
    func leaves(_ opening: Bool) -> some View {
        opacity(opening ? 0 : 1)
            .offset(y: opening ? 14 : 0)
            .blur(radius: opening ? 6 : 0)
            .animation(.easeOut(duration: 0.22), value: opening)
    }
}

/// The animated backdrop: the notebook's 24 pt dot grid over slow color washes.
private struct CoverField: View {
    struct Frame {
        var time: Double
        var ripple: (center: CGPoint, age: Double)?
        var lens: (center: CGPoint, strength: Double)?
        var open: Double = 0
    }

    static let gold = Color(red: 0.79, green: 0.60, blue: 0.27)
    static let rose = Color(red: 0.69, green: 0.42, blue: 0.38)
    static let teal = Color(red: 0.36, green: 0.52, blue: 0.49)

    let frame: Frame
    let dark: Bool

    private struct Wash {
        let color: Color
        let center: CGPoint
        let radius: CGFloat
    }

    private static let spacing: CGFloat = 24
    /// Dots are batched by opacity, so a frame is a handful of fills rather than thousands.
    private static let levels = 24
    private static let maxDotAlpha = 0.6

    var body: some View {
        Canvas(opaque: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.surface))

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let intro = ease(min(1, frame.time / 1.6))
            let open = frame.open
            let washes = washes(in: size, center: center)

            let strength = (dark ? 0.26 : 0.24) * intro * (1 + 0.6 * open)
            for wash in washes {
                let r = wash.radius
                context.fill(
                    Path(ellipseIn: CGRect(x: wash.center.x - r, y: wash.center.y - r, width: 2 * r, height: 2 * r)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: wash.color.opacity(strength), location: 0),
                            .init(color: wash.color.opacity(strength * 0.62), location: 0.3),
                            .init(color: wash.color.opacity(strength * 0.22), location: 0.62),
                            .init(color: wash.color.opacity(0), location: 1),
                        ]),
                        center: wash.center, startRadius: 0, endRadius: r
                    )
                )
            }

            var batches = Array(repeating: Path(), count: Self.levels)
            let baseAlpha = dark ? 0.14 : 0.16
            let revealFront = frame.time * 1150 - 80
            let zoom = 1 + 2.6 * open * open
            let spacing = Self.spacing

            var y = spacing / 2
            while y < size.height + spacing {
                var x = spacing / 2
                while x < size.width + spacing {
                    var px = x, py = y
                    var radius = 0.9
                    var alpha = baseAlpha

                    var field = 0.0
                    for wash in washes {
                        let dx = x - wash.center.x, dy = y - wash.center.y
                        field += exp(-(dx * dx + dy * dy) / (wash.radius * wash.radius * 0.2))
                    }
                    field = min(field, 1)
                    radius += 0.45 * field
                    alpha += 0.05 * field

                    if let ripple = frame.ripple, ripple.age > 0 {
                        let dx = x - ripple.center.x, dy = y - ripple.center.y
                        let distance = max((dx * dx + dy * dy).squareRoot(), 0.001)
                        let offset = (distance - ripple.age * 640) / 64
                        let ring = exp(-offset * offset) * exp(-ripple.age * 1.25)
                        if ring > 0.002 {
                            px += dx / distance * ring * 9
                            py += dy / distance * ring * 9
                            radius += 1.4 * ring
                            alpha += 0.16 * ring
                        }
                    }

                    if let lens = frame.lens, lens.strength > 0.001 {
                        let dx = x - lens.center.x, dy = y - lens.center.y
                        let l = lens.strength * exp(-(dx * dx + dy * dy) / (150 * 150))
                        px += dx * 0.26 * l
                        py += dy * 0.26 * l
                        radius += 1.1 * l
                        alpha += 0.22 * l
                    }

                    if open > 0 {
                        px = center.x + (px - center.x) * zoom
                        py = center.y + (py - center.y) * zoom
                        radius *= 1 + open
                    }

                    let fromCenter = ((x - center.x) * (x - center.x) + (y - center.y) * (y - center.y)).squareRoot()
                    alpha *= max(0, min(1, (revealFront - fromCenter) / 160)) * (1 - open)

                    if alpha > 0.004 {
                        let level = min(Self.levels - 1, Int(alpha / Self.maxDotAlpha * Double(Self.levels)))
                        batches[level].addEllipse(in: CGRect(x: px - radius, y: py - radius, width: 2 * radius, height: 2 * radius))
                    }
                    x += spacing
                }
                y += spacing
            }

            let dot = dark ? Color.white : Color.black
            for (level, path) in batches.enumerated() where !path.isEmpty {
                let alpha = (Double(level) + 0.5) / Double(Self.levels) * Self.maxDotAlpha
                context.fill(path, with: .color(dot.opacity(alpha)))
            }
        }
    }

    /// Three washes on slow, unrelated orbits (about half a minute each), so they never line up the same way twice.
    private func washes(in size: CGSize, center: CGPoint) -> [Wash] {
        let unit = min(size.width, size.height)
        let t = frame.time * 0.16
        let radius = unit * (0.62 + 0.35 * frame.open)
        return [
            Wash(color: Self.gold, center: CGPoint(x: center.x + unit * 0.34 * sin(t * 1.3 + 0.4), y: center.y - unit * 0.2 + unit * 0.26 * cos(t * 0.9)), radius: radius),
            Wash(color: Self.rose, center: CGPoint(x: center.x + unit * 0.3 * cos(t * 1.1 + 2.1), y: center.y + unit * 0.3 * sin(t * 1.25 + 1.0)), radius: radius * 0.9),
            Wash(color: Self.teal, center: CGPoint(x: center.x + unit * 0.32 * sin(t * 0.8 + 4.0), y: center.y + unit * 0.22 + unit * 0.24 * cos(t * 1.4 + 3.0)), radius: radius),
        ]
    }

    private func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}
