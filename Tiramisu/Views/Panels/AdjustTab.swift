import SwiftUI

struct AdjustTab: View {
    @Environment(DocumentStore.self) private var store
    @State private var displayedID: UUID?
    private var displayedLayer: PXLayer? {
        store.layers.first(where: { $0.id == displayedID })
    }

    var body: some View {
        let _ = perfMark("AdjustTab.body")
        Group {
            if let layer = displayedLayer {
                VStack(spacing: 0) {
                    InspectorSection("Lighting", defaultOpen: true) {
                        LightingPanel(layer: layer)
                    }
                    InspectorSection("Color (HSL)", defaultOpen: false) {
                        HSLPanel(layer: layer)
                    }
                    if layer.kind == .raster || layer.kind == .text {
                        InspectorSection("Relight", defaultOpen: false) {
                            RelightPanel(layer: layer)
                        }
                    }
                    if layer.kind == .raster {
                        InspectorSection("Skin Retouch", defaultOpen: false) {
                            SkinPanel(layer: layer)
                        }
                    }
                    InspectorSection("Filters", defaultOpen: false) {
                        FiltersPanel(layer: layer)
                    }
                }
            } else {
                Text("Select a layer.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .task(id: store.activeLayerID) {
            await Task.yield()
            displayedID = store.activeLayerID
        }
    }
}

// MARK: - Lighting

private struct LightingPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer
    @AppStorage("world.hanley.tiramisu.adjust.customizeOpen") private var customizeOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Auto Enhance — the one-click "make it look better" path.
            Button {
                store.checkpoint("Auto Enhance")
                layer.adjust = AdjustPreset.auto
                store.invalidate()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text("Auto Enhance")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("One-click universal lift: gentle contrast + saturation + shadow recovery")

            // Preset chip row — horizontal scroll of named looks.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AdjustPreset.library) { preset in
                        PresetChip(preset: preset, isSelected: layer.adjust == preset.target) {
                            store.checkpoint("Apply \(preset.name)")
                            layer.adjust = preset.target
                            store.invalidate()
                        }
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
            .frame(height: 56)

            // Customize disclosure — power-user manual sliders, hidden by default.
            DisclosureGroup(isExpanded: $customizeOpen) {
                VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                    adjRow("Brightness", \.brightness, -1...1)
                    adjRow("Contrast", \.contrast, -1...1)
                    adjRow("Exposure", \.exposure, -2...2)
                    adjRow("Saturation", \.saturation, -1...1)
                    adjRow("Vibrance", \.vibrance, -1...1)
                    adjRow("Warmth", \.warmth, -1...1)
                    adjRow("Shadows", \.shadows, -1...1)
                    adjRow("Highlights", \.highlights, -1...1)

                    // Tone curve — preset picker + intensity. Interactive
                    // graph editor lands in v0.4.
                    InspectorRow("Curve") {
                        Picker("", selection: Binding(
                            get: { layer.adjust.curve },
                            set: { layer.adjust.curve = $0; store.invalidate() }
                        )) {
                            ForEach(CurvePreset.allCases, id: \.self) { p in
                                Text(p.label).tag(p)
                            }
                        }
                        .labelsHidden()
                    }
                    if layer.adjust.curve != .linear {
                        InspectorRow("C. intensity") {
                            InspectorSlider($layer.adjust.curveIntensity, in: 0...1, format: .percent) { store.invalidate() }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Reset") {
                            store.checkpoint("Reset Adjustments")
                            layer.adjust = Adjustments()
                            store.invalidate()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Customize")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func adjRow(_ label: String, _ kp: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double>) -> some View {
        InspectorRow(label) {
            InspectorSlider(
                Binding(
                    get: { layer.adjust[keyPath: kp] },
                    set: { layer.adjust[keyPath: kp] = $0 }
                ),
                in: range,
                format: .decimal(2)
            ) { store.invalidate() }
        }
    }
}

// MARK: - Preset chip

private struct PresetChip: View {
    let preset: AdjustPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // Color-gradient swatch tile. Hint of the preset's vibe.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [preset.accent.0, preset.accent.1],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 44, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.separator.opacity(isSelected ? 0 : 0.4), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)

                Text(preset.name)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }
}

// MARK: - HSL

/// Lightroom-style per-color HSL panel. Three sub-tabs (Hue / Saturation /
/// Luminance); each tab shows 8 colored sliders, one per band. Each slider's
/// track is a gradient that visualizes what that slider does — Hue tracks
/// fade through the band's hue range (e.g., Red Hue's track is magenta→red→
/// orange so you feel which way you're shifting); Sat tracks go gray→full
/// color; Lum tracks go black→band-color→white. Bipolar sliders snap to 0
/// on double-click.
private struct HSLPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer
    @AppStorage("world.hanley.tiramisu.adjust.hsl.tab") private var tab: String = "hue"

    enum HSLChannel { case hue, sat, lum }
    private var activeChannel: HSLChannel {
        switch tab { case "sat": return .sat; case "lum": return .lum; default: return .hue }
    }

    /// Hue centers in degrees match the renderer's band order.
    private struct ColorBand: Identifiable {
        let id: String
        let label: String
        let hueDeg: Double
        let hueKey: WritableKeyPath<HSLAdjustments, Double>
        let satKey: WritableKeyPath<HSLAdjustments, Double>
        let lumKey: WritableKeyPath<HSLAdjustments, Double>
    }

    private static let bands: [ColorBand] = [
        .init(id: "red",     label: "Red",     hueDeg: 0,
              hueKey: \.redHue, satKey: \.redSat, lumKey: \.redLum),
        .init(id: "orange",  label: "Orange",  hueDeg: 30,
              hueKey: \.orangeHue, satKey: \.orangeSat, lumKey: \.orangeLum),
        .init(id: "yellow",  label: "Yellow",  hueDeg: 60,
              hueKey: \.yellowHue, satKey: \.yellowSat, lumKey: \.yellowLum),
        .init(id: "green",   label: "Green",   hueDeg: 120,
              hueKey: \.greenHue, satKey: \.greenSat, lumKey: \.greenLum),
        .init(id: "aqua",    label: "Aqua",    hueDeg: 180,
              hueKey: \.aquaHue, satKey: \.aquaSat, lumKey: \.aquaLum),
        .init(id: "blue",    label: "Blue",    hueDeg: 240,
              hueKey: \.blueHue, satKey: \.blueSat, lumKey: \.blueLum),
        .init(id: "purple",  label: "Purple",  hueDeg: 270,
              hueKey: \.purpleHue, satKey: \.purpleSat, lumKey: \.purpleLum),
        .init(id: "magenta", label: "Magenta", hueDeg: 300,
              hueKey: \.magentaHue, satKey: \.magentaSat, lumKey: \.magentaLum),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("Hue").tag("hue")
                Text("Saturation").tag("sat")
                Text("Luminance").tag("lum")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.bands) { band in
                    HSLBandRow(
                        label: band.label,
                        gradient: HSLPanel.gradient(forBand: band.hueDeg, channel: activeChannel),
                        value: Binding(
                            get: { layer.adjust.hsl[keyPath: keyForActiveTab(band)] },
                            set: { layer.adjust.hsl[keyPath: keyForActiveTab(band)] = $0 }
                        ),
                        onCommit: { store.invalidate() }
                    )
                }
            }

            InspectorFootnote(footnoteForActiveTab)

            HStack {
                Spacer()
                Button("Reset") {
                    store.checkpoint("Reset HSL")
                    layer.adjust.hsl = HSLAdjustments()
                    store.invalidate()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private var footnoteForActiveTab: String {
        switch activeChannel {
        case .hue: return "Rotate each band's hue ±60° toward neighboring colors. Reds → magenta or orange; greens → yellow or aqua. Double-click to reset."
        case .sat: return "Push each band toward gray (-1) or full color (+1) without touching other colors. Double-click to reset."
        case .lum: return "Darken (-1) or brighten (+1) each band's pixels independently. Useful for darkening blue skies or brightening skin (orange / yellow). Double-click to reset."
        }
    }

    private func keyForActiveTab(_ band: ColorBand) -> WritableKeyPath<HSLAdjustments, Double> {
        switch tab {
        case "sat": return band.satKey
        case "lum": return band.lumKey
        default:    return band.hueKey
        }
    }

    /// Build the visual gradient for a slider track. Mirrors the renderer's
    /// effect so the user feels what the slider does just by reading the bar.
    static func gradient(forBand hueDeg: Double, channel: HSLChannel) -> LinearGradient {
        switch channel {
        case .hue:
            // Sweep 60° centered on the band — magenta→red→orange for Red, etc.
            let stops: [Color] = stride(from: -30.0, through: 30.0, by: 15.0).map { d in
                Color(hue: ((hueDeg + d).truncatingRemainder(dividingBy: 360) + 360)
                        .truncatingRemainder(dividingBy: 360) / 360,
                      saturation: 0.85, brightness: 0.85)
            }
            return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
        case .sat:
            // Gray (band desaturated) → full saturation at the band's hue.
            let full = Color(hue: hueDeg / 360, saturation: 0.95, brightness: 0.85)
            return LinearGradient(colors: [Color(white: 0.55), full],
                                  startPoint: .leading, endPoint: .trailing)
        case .lum:
            // Black → band color → white. Band sits at the midpoint.
            let band = Color(hue: hueDeg / 360, saturation: 0.85, brightness: 0.7)
            return LinearGradient(colors: [.black, band, .white],
                                  startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// One row in the HSL panel: a left-aligned label, a colored bipolar slider,
/// and a numeric readout. The slider has a center detent line and resets to
/// 0 on double-click — matches Lightroom muscle memory.
private struct HSLBandRow: View {
    let label: String
    let gradient: LinearGradient
    @Binding var value: Double
    let onCommit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
                .lineLimit(1)
            HSLBandSlider(value: $value, trackGradient: gradient, onCommit: onCommit)
                .frame(maxWidth: .infinity)
            Text(String(format: "%+.2f", value))
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// Custom bipolar slider (-1…1) with a gradient-filled track, a thumb, a
/// center tick mark, and double-click-to-reset behavior. Built from scratch
/// because SwiftUI's stock Slider can't host a colored track or a center
/// detent in a way that looks production-quality.
private struct HSLBandSlider: View {
    @Binding var value: Double
    let trackGradient: LinearGradient
    let onCommit: () -> Void

    private let trackHeight: CGFloat = 8
    private let thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clamped = max(-1, min(1, value))
            let xForValue = CGFloat((clamped + 1) / 2) * w
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(trackGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                            .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    )
                    .frame(height: trackHeight)
                    .frame(maxHeight: .infinity, alignment: .center)

                // Center detent
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 1, height: trackHeight + 4)
                    .blendMode(.overlay)
                    .offset(x: w / 2 - 0.5)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: xForValue - thumbSize / 2)
            }
            .frame(height: max(trackHeight, thumbSize))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let x = max(0, min(w, g.location.x))
                        let v = Double(x / w) * 2 - 1
                        // Snap to 0 within ±0.02 — gives a tactile detent at center.
                        value = abs(v) < 0.02 ? 0 : max(-1, min(1, v))
                        onCommit()
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    value = 0
                    onCommit()
                }
            )
        }
        .frame(height: 16)
    }
}

// MARK: - Relight

private struct RelightPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Toggle("Enable Relight", isOn: $layer.relight.enabled)
                .onChange(of: layer.relight.enabled) { store.invalidate() }

            InspectorRow("Intensity") {
                InspectorSlider($layer.relight.intensity, in: 0...2, format: .decimal(2)) { store.invalidate() }
            }
            InspectorRow("Radius") {
                InspectorSlider($layer.relight.radius, in: 0.05...1.5, format: .decimal(2)) { store.invalidate() }
            }
            InspectorRow("Tint") {
                InspectorColorWell(color: Binding(
                    get: { layer.relight.color.swiftUIColor },
                    set: { layer.relight.color = ColorRGB($0.asNSColor); store.invalidate() }
                ))
            }
            InspectorRow("Ambient") {
                InspectorSlider($layer.relight.ambient, in: -1...0.5, format: .decimal(2)) { store.invalidate() }
            }

            Divider().opacity(0.4).padding(.vertical, 4)

            InspectorRow("X") {
                InspectorSlider(
                    Binding(
                        get: { layer.relight.position.x },
                        set: { layer.relight.position.x = $0 }
                    ),
                    in: 0...1,
                    format: .decimal(2)
                ) { store.invalidate() }
            }
            InspectorRow("Y") {
                InspectorSlider(
                    Binding(
                        get: { layer.relight.position.y },
                        set: { layer.relight.position.y = $0 }
                    ),
                    in: 0...1,
                    format: .decimal(2)
                ) { store.invalidate() }
            }

            InspectorFootnote("Select the Relight tool (☀ in the sidebar) and drag on the canvas to aim the key light.")
        }
    }
}

// MARK: - Skin

private struct SkinPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer
    @State private var showMask: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Toggle("Enable Skin Retouch", isOn: $layer.skin.enabled)
                .onChange(of: layer.skin.enabled) { store.invalidate() }

            InspectorRow("Smooth") {
                InspectorSlider($layer.skin.smooth, in: 0...1, format: .percent) { store.invalidate() }
            }
            InspectorRow("Even tone") {
                InspectorSlider($layer.skin.evenTone, in: 0...1, format: .percent) { store.invalidate() }
            }
            InspectorRow("De-age") {
                InspectorSlider($layer.skin.deage, in: 0...1, format: .percent) { store.invalidate() }
            }
            InspectorRow("Glow") {
                InspectorSlider($layer.skin.glow, in: 0...1, format: .percent) { store.invalidate() }
            }

            Toggle("Debug: show face mask", isOn: $showMask)
                .onChange(of: showMask) {
                    SkinProcessor.debugShowMask = showMask
                    store.invalidate()
                }

            InspectorFootnote("Toggle 'show face mask' to see what the algorithm thinks is skin (red overlay).")
        }
    }
}

// MARK: - Filters

private struct FiltersPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Blur") {
                InspectorSlider($layer.filters.blur, in: 0...50, format: .integer) { store.invalidate() }
            }
            InspectorRow("Sharpen") {
                InspectorSlider($layer.filters.sharpen, in: 0...2, format: .decimal(2)) { store.invalidate() }
            }
            InspectorRow("Noise") {
                InspectorSlider($layer.filters.noise, in: 0...1, format: .percent) { store.invalidate() }
            }
            Toggle("Monochrome noise", isOn: $layer.filters.noiseMono)
                .onChange(of: layer.filters.noiseMono) { store.invalidate() }
            InspectorRow("Pixelate") {
                InspectorSlider($layer.filters.pixelate, in: 0...40, format: .integer) { store.invalidate() }
            }
            InspectorRow("Hue shift") {
                InspectorSlider($layer.filters.hueShift, in: -180...180, format: .degrees) { store.invalidate() }
            }
            InspectorRow("Vignette") {
                InspectorSlider($layer.filters.vignette, in: 0...1, format: .percent) { store.invalidate() }
            }
            if layer.filters.vignette > 0.001 {
                InspectorRow("V. falloff") {
                    InspectorSlider($layer.filters.vignetteFalloff, in: 0...1, format: .percent) { store.invalidate() }
                }
            }
            InspectorRow("Grain") {
                InspectorSlider($layer.filters.grain, in: 0...1, format: .percent) { store.invalidate() }
            }
            if layer.filters.grain > 0.001 {
                InspectorRow("Grain size") {
                    InspectorSlider($layer.filters.grainSize, in: 0.5...4, format: .decimal(1)) { store.invalidate() }
                }
            }
        }
    }
}
