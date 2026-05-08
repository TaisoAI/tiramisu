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
