import SwiftUI

/// The jibiji pen case: a frosted bar under the page with undo and redo, five tools, the logo's
/// inks plus any the student mixes, and three weights. The selected tool's tip shows the ink it writes with.
///
/// `.quick` is the same set without history or settings, shown where Apple Pencil asks for it.
struct InkToolBar: View {
    enum Style { case bar, quick }

    let controller: CanvasController
    var style: Style = .bar

    @Namespace private var selection
    private var tools: InkTools { controller.tools }

    var body: some View {
        switch style {
        case .bar:
            ViewThatFits(in: .horizontal) {
                bar(compact: false)
                bar(compact: true)
                ScrollView(.horizontal) { bar(compact: true) }.scrollIndicators(.hidden).frame(height: 66)
            }
            .padding(.horizontal, 12)
        case .quick:
            VStack(spacing: 4) {
                HStack(spacing: 2) { toolButtons }
                HStack(spacing: 2) { inkOptions }
            }
            .padding(6)
            .frosted(radius: 22)
        }
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 2) {
            Button("Undo", systemImage: "arrow.uturn.backward", action: controller.undo)
                .disabled(!controller.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward", action: controller.redo)
                .disabled(!controller.canRedo)
            divider
            toolButtons
            divider
            if compact { inkMenu } else { inkOptions }
            divider
            settingsMenu
        }
        .buttonStyle(BarIconButtonStyle())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frosted(radius: 26)
        .fixedSize()
        .animation(Theme.Motion.quick, value: tools.tool)
        .animation(Theme.Motion.quick, value: tools.ink)
        .animation(Theme.Motion.quick, value: tools.palette)
    }

    // MARK: Tools

    private var toolButtons: some View {
        ForEach(InkTools.Tool.allCases) { tool in
            let selected = tools.tool == tool
            Button {
                withAnimation(Theme.Motion.quick) {
                    tools.tool = tool
                    tools.quickPalette = nil
                }
            } label: {
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                            .matchedGeometryEffect(id: "tool", in: selection)
                    }
                    VStack(spacing: 4) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 18, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? tint(for: tool) : Color.primary.opacity(0.55))
                        // The tip: the ink this tool writes with.
                        Capsule()
                            .fill(tint(for: tool))
                            .frame(width: selected ? 14 : 4, height: 3)
                            .opacity(selected ? 1 : 0)
                    }
                    .offset(y: selected ? -1 : 1)
                }
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(scale: 0.88))
            .accessibilityLabel(tool.name)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func tint(for tool: InkTools.Tool) -> Color {
        tool.inks ? tools.ink.color : .primary
    }

    // MARK: Ink

    /// Inks and weights for pens; stroke or partial erasing for the eraser.
    @ViewBuilder
    private var inkOptions: some View {
        if tools.tool == .eraser {
            ForEach(InkTools.EraserMode.allCases) { mode in
                let selected = tools.eraserMode == mode
                Button(mode.name) { tools.eraserMode = mode }
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.primary.opacity(selected ? 0.08 : 0), in: Capsule())
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
            weightButtons(enabled: tools.eraserMode == .partial)
        } else {
            ForEach(tools.palette) { ink in
                let selected = tools.ink == ink
                Button {
                    tools.use(ink, keep: false)
                } label: {
                    swatch(ink, selected: selected)
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.85))
                .contextMenu {
                    if ink != .ink {
                        Button("Remove from Bar", systemImage: "minus.circle", role: .destructive) {
                            withAnimation(Theme.Motion.quick) { tools.remove(ink) }
                        }
                    }
                }
                .accessibilityLabel("\(ink.name) ink")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .transition(.scale.combined(with: .opacity))
            }
            // An ink mixed in the picker but not kept yet: one tap puts it on the bar.
            if !tools.palette.contains(tools.ink) {
                Button {
                    withAnimation(Theme.Motion.quick) { tools.use(tools.ink, keep: true) }
                } label: {
                    swatch(tools.ink, selected: true)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .frame(width: 14, height: 14)
                                .background(Color.primary, in: Circle())
                                .offset(x: -2, y: 6)
                        }
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.85))
                .disabled(!tools.canAddInk)
                .accessibilityLabel("Add \(tools.ink.name) to the bar")
                .accessibilityIdentifier("keepInk")
                .transition(.scale.combined(with: .opacity))
            }
            mixer
            weightButtons(enabled: tools.tool.inks)
        }
    }

    private func swatch(_ ink: InkTools.Ink, selected: Bool) -> some View {
        Circle()
            .fill(ink.color)
            .frame(width: selected ? 20 : 18, height: selected ? 20 : 18)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .padding(4)
            .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.8 : 0), lineWidth: 1.5))
            .frame(width: 34, height: 40)
            .contentShape(Rectangle())
    }

    /// The system color picker: grid, spectrum, sliders, and eyedropper. A mixed ink writes at once;
    /// it goes on the bar only when kept.
    private var mixer: some View {
        ColorPicker("Mix an ink", selection: Binding(
            get: { Color(uiColor: tools.ink.uiColor) },
            set: { tools.use(InkTools.Ink(color: UIColor($0)), keep: false) }
        ), supportsOpacity: false)
        .labelsHidden()
        .frame(width: 34, height: 40)
        .accessibilityIdentifier("mixInk")
    }

    private func weightButtons(enabled: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(InkTools.Weight.allCases) { weight in
                let selected = tools.weight(for: tools.tool) == weight
                Button {
                    tools.setWeight(weight, for: tools.tool)
                } label: {
                    Circle()
                        .fill(Color.primary.opacity(selected ? 0.85 : 0.25))
                        .frame(width: 4 + CGFloat(weight.rawValue) * 3.5, height: 4 + CGFloat(weight.rawValue) * 3.5)
                        .frame(width: 26, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.8))
                .accessibilityLabel(weight.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.leading, 6)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    /// For narrow windows: inks and weights folded into one control.
    private var inkMenu: some View {
        Menu {
            Picker("Ink", selection: Binding(get: { tools.ink }, set: { tools.use($0, keep: false) })) {
                ForEach(tools.palette) { Text($0.name).tag($0) }
                if !tools.palette.contains(tools.ink) { Text(tools.ink.name).tag(tools.ink) }
            }
            Picker("Weight", selection: Binding(
                get: { tools.weight(for: tools.tool) },
                set: { tools.setWeight($0, for: tools.tool) }
            )) {
                ForEach(InkTools.Weight.allCases) { Text($0.name).tag($0) }
            }
        } label: {
            Circle().fill(tools.ink.color).frame(width: 20, height: 20)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Ink and weight")
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("Draw with finger", isOn: Bindable(tools).allowsFingerDrawing)
            Section("Inks") {
                if tools.ink != .ink, tools.palette.contains(tools.ink) {
                    Button("Remove \(tools.ink.name) from Bar", systemImage: "minus.circle", role: .destructive) {
                        withAnimation(Theme.Motion.quick) { tools.remove(tools.ink) }
                    }
                }
                Button("Reset Inks", systemImage: "arrow.counterclockwise") {
                    withAnimation(Theme.Motion.quick) { tools.resetPalette() }
                }
                .disabled(tools.palette == InkTools.Ink.builtIn)
            }
        } label: {
            Label("Pen settings", systemImage: "ellipsis")
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 6)
    }
}

private extension View {
    func frosted(radius: CGFloat) -> some View {
        background(.thinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}
