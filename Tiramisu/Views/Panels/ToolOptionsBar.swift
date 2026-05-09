import SwiftUI

/// Photoshop-style horizontal options bar that sits above the canvas.
/// Content is contextual to the active tool.
struct ToolOptionsBar: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            switch store.tool {
            case .move:
                MoveToolOptions()
            case .marquee:
                SelectionToolOptions(
                    hint: "Drag to draw a selection · ⌘⇧G to Generative Fill inside it"
                )
            case .lasso:
                SelectionToolOptions(
                    hint: "Drag to trace a free-form selection · the path closes on release"
                )
            case .polygonalLasso:
                SelectionToolOptions(
                    hint: "Click to drop vertices · double-click or click the start point to close"
                )
            case .magicWand:
                MagicWandOptions()
            case .smartSelect:
                SelectionToolOptions(
                    hint: "Click an object · Vision will segment it as a selection"
                )
            case .pencil, .eraser:
                BrushToolOptions(eraser: store.tool == .eraser)
            default:
                Text(store.tool.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Liquid Glass: thin material reads as part of the macOS 26 chrome
        // instead of a flat opaque strip. Falls back to the system bar
        // material on older AppKit if the glass primitive isn't available.
        .background(.bar)
    }
}

private struct MoveToolOptions: View {
    @Environment(DocumentStore.self) private var store

    private var activeKind: LayerKind? { store.activeLayer?.kind }
    private var hasSmart: Bool { store.activeLayer?.smart != nil }

    var body: some View {
        Group {
            // Alignment row — shown whenever the active layer can be aligned
            // (Smart Object or text). Hidden for gradient/solid (those fill
            // the canvas, alignment is meaningless).
            if LayerArrange.canAlign(store) {
                HStack(spacing: 2) {
                    AlignBtn("align.horizontal.left", "Align Left Edge")        { LayerArrange.align(store, to: .middleLeft) }
                    AlignBtn("align.horizontal.center", "Align Horizontal Center") { LayerArrange.align(store, to: .center) }
                    AlignBtn("align.horizontal.right", "Align Right Edge")      { LayerArrange.align(store, to: .middleRight) }
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    AlignBtn("align.vertical.top", "Align Top Edge")            { LayerArrange.align(store, to: .topCenter) }
                    AlignBtn("align.vertical.center", "Align Vertical Center")  { LayerArrange.align(store, to: .center) }
                    AlignBtn("align.vertical.bottom", "Align Bottom Edge")      { LayerArrange.align(store, to: .bottomCenter) }
                }

                Divider().frame(height: 20)
            }

            // Scaling row — swapped based on layer kind. Smart Object gets
            // Fit / Fill / 1:1 (image resampling). Text gets Fit width / Reset
            // size (font scaling). Gradient/solid get nothing.
            if hasSmart {
                Button("Fit")  { LayerArrange.fitToCanvas(store) }
                    .help("Scale to fit inside canvas (⌘⌥F)")
                Button("Fill") { LayerArrange.fillCanvas(store) }
                    .help("Scale to cover canvas (⌘⌥⇧F)")
                Button("1:1")  { LayerArrange.resetScale(store) }
                    .help("Reset scale to 100% (⌘⌥0)")
            } else if activeKind == .text {
                Button("Fit width") { LayerArrange.fitTextWidth(store) }
                    .help("Scale font size so the text spans the canvas width")
                Button("Reset size") { LayerArrange.resetTextSize(store) }
                    .help("Reset font size to default (220pt)")
            }

            Spacer()
        }
        .controlSize(.small)
    }
}

private struct AlignBtn: View {
    let symbol: String
    let tip: String
    let action: () -> Void

    init(_ symbol: String, _ tip: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tip = tip
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(tip)
    }
}

private struct BrushToolOptions: View {
    @Environment(DocumentStore.self) private var store
    let eraser: Bool

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 14) {
            BrushSlider(label: "Size",      value: $store.brush.size,       range: 1...400, step: 1, suffix: "px")
            BrushSlider(label: "Hardness",  value: hardnessBinding,         range: 0...1,   step: 0.01, asPercent: true)
            BrushSlider(label: "Opacity",   value: $store.brush.opacity,    range: 0...1,   step: 0.01, asPercent: true)
            BrushSlider(label: "Flow",      value: $store.brush.flow,       range: 0...1,   step: 0.01, asPercent: true)
            BrushSlider(label: "Smoothing", value: $store.brush.smoothing,  range: 0...0.97, step: 0.01, asPercent: true)
            if !eraser {
                ColorWell()
            }
            Spacer()
        }
        .controlSize(.small)
    }

    /// Hardness is the inverse of BrushSettings.feather (0=soft … 1=hard).
    /// Bind through this projection so the slider reads the way users expect.
    private var hardnessBinding: Binding<Double> {
        @Bindable var s = store
        return Binding(
            get: { 1.0 - s.brush.feather },
            set: { s.brush.feather = max(0, min(1, 1.0 - $0)) }
        )
    }
}

private struct ColorWell: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 6) {
            Text("Color").font(.caption).foregroundStyle(.secondary)
            ColorPicker("", selection: Binding(
                get: { Color(store.foreground.nsColor) },
                set: { store.foreground = ColorRGB(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 32)
        }
    }
}

private struct BrushSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var suffix: String = ""
    var asPercent: Bool = false

    @FocusState private var fieldFocused: Bool
    @State private var draft: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: range, step: step)
                .frame(width: 90)
            // Editable readout — accepts a precise typed number. Useful for
            // small-number cases (Size = 3 px) where dragging a slider over
            // a 1…400 range can't land on an integer reliably.
            TextField("", text: $draft)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .focused($fieldFocused)
                .onAppear { draft = readout(value) }
                .onChange(of: value) { _, new in
                    if !fieldFocused { draft = readout(new) }
                }
                .onSubmit { commitDraft() }
                .onChange(of: fieldFocused) { _, focused in
                    if !focused { commitDraft() }
                }
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
        }
    }

    private func readout(_ v: Double) -> String {
        if asPercent { return "\(Int((v * 100).rounded()))%" }
        if !suffix.isEmpty { return "\(Int(v.rounded()))\(suffix)" }
        return String(format: "%.2f", v)
    }

    /// Parse the text in the field, clamp to `range`, and update the binding.
    /// Accepts plain numbers or numbers with our display suffix ("px", "%").
    private func commitDraft() {
        var s = draft.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("%") { s.removeLast() }
        if s.hasSuffix(suffix), !suffix.isEmpty { s.removeLast(suffix.count) }
        s = s.trimmingCharacters(in: .whitespaces)
        guard let raw = Double(s) else {
            draft = readout(value)   // reject + redraw the existing value
            return
        }
        let parsed = asPercent ? raw / 100.0 : raw
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        value = clamped
        draft = readout(clamped)
    }
}

private struct MagicWandOptions: View {
    @Environment(DocumentStore.self) private var store
    var body: some View {
        @Bindable var store = store
        HStack(spacing: 14) {
            Text("Click a pixel · similar neighbors become a selection")
                .font(.caption).foregroundStyle(.secondary)
            Divider().frame(height: 16)
            BrushSlider(label: "Tolerance", value: $store.magicWandTolerance,
                        range: 0...0.5, step: 0.005, asPercent: true)
            Toggle("Contiguous", isOn: $store.magicWandContiguous)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Spacer()
            if store.selectionPath != nil {
                Button("Deselect") {
                    store.clearSelection(); store.invalidate()
                }
                .controlSize(.small)
            }
        }
        .controlSize(.small)
    }
}

private struct SelectionToolOptions: View {
    @Environment(DocumentStore.self) private var store
    let hint: String

    var body: some View {
        Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
        Spacer()
        if store.selectionPath != nil {
            Button("Deselect") {
                store.clearSelection()
                store.invalidate()
            }
            .controlSize(.small)
        }
    }
}
