import SwiftUI

struct LayersPanel: View {
    @Environment(DocumentStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Layers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Menu {
                    Button("Paint") { store.addLayer(PXLayer(name: "Paint", kind: .raster)) }
                    Button("Text") { store.addLayer(PXLayer(name: "Text", kind: .text)) }
                    Button("Gradient") { store.addLayer(PXLayer(name: "Gradient", kind: .gradient)) }
                    Button("Solid Color") { store.addLayer(PXLayer(name: "Solid", kind: .solid)) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a new layer")

                Button { store.duplicateActive() } label: {
                    Image(systemName: "square.on.square")
                }
                .buttonStyle(.borderless)
                .help("Duplicate active layer (⌘J)")

                Button { store.removeActive() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete active layer")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider().opacity(0.4)

            List(selection: Binding(
                get: { store.activeLayerID },
                set: { newID in
                    let t0 = CFAbsoluteTimeGetCurrent()
                    store.activeLayerID = newID
                    DispatchQueue.main.async {
                        let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                        tlog("perf: select set→nextRunloop \(String(format: "%.1f", dt))ms id=\(newID?.uuidString.prefix(8) ?? "nil")")
                    }
                }
            )) {
                ForEach(Array(store.layers.reversed()), id: \.id) { layer in
                    LayerRow(layer: layer)
                        .tag(layer.id as UUID?)
                }
                .onMove { indices, newOffset in
                    var displayed = Array(store.layers.reversed())
                    displayed.move(fromOffsets: indices, toOffset: newOffset)
                    store.checkpoint("Reorder Layers")
                    store.layers = displayed.reversed()
                    store.invalidate()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onDeleteCommand {
                guard store.activeLayerID != nil else { return }
                store.removeActive()
            }
        }
    }
}

struct LayerRow: View {
    @Environment(DocumentStore.self) private var store
    let layer: PXLayer
    @State private var isEditing: Bool = false
    @State private var draftName: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .font(.system(size: 10))
                .frame(width: 14, height: 22)
                .help("Drag to reorder")

            Button(action: {
                layer.visible.toggle(); store.invalidate()
            }) {
                Image(systemName: layer.visible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.visible ? .primary : .secondary)
            }
            .buttonStyle(.plain)

            LayerThumbnail(layer: layer)
                .frame(width: 36, height: 22)
                .cornerRadius(3)
                .contentShape(Rectangle())
                .onTapGesture { store.activeLayerID = layer.id }

            Group {
                if isEditing {
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($nameFocused)
                        .onSubmit { commitEdit() }
                        .onExitCommand { isEditing = false }
                        .task { nameFocused = true }
                } else {
                    Text(layer.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        // Order matters: register double-tap FIRST so SwiftUI
                        // disambiguates. Single tap selects, double tap renames.
                        .onTapGesture(count: 2) { beginEdit() }
                        .onTapGesture(count: 1) { store.activeLayerID = layer.id }
                }
            }

            Spacer()
            Text(kindBadge).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") { beginEdit() }
                .keyboardShortcut(.return, modifiers: [])
            Button("Duplicate") {
                store.activeLayerID = layer.id
                store.duplicateActive()
            }.keyboardShortcut("d", modifiers: [.command])
            Divider()
            Button(layer.visible ? "Hide" : "Show") {
                layer.visible.toggle(); store.invalidate()
            }
            Button("Bring to Front") { store.moveToFront(layer.id) }
            Button("Bring Forward") { store.moveForward(layer.id) }
            Button("Send Backward") { store.moveBackward(layer.id) }
            Button("Send to Back") { store.moveToBack(layer.id) }
            Divider()
            Button("Delete", role: .destructive) {
                store.activeLayerID = layer.id
                store.removeActive()
            }.keyboardShortcut(.delete, modifiers: [.command])
        }
    }

    private func beginEdit() {
        draftName = layer.name
        isEditing = true
    }
    private func commitEdit() {
        if !draftName.isEmpty && draftName != layer.name {
            store.checkpoint("Rename Layer")
            layer.name = draftName
        }
        isEditing = false
    }

    private var kindBadge: String {
        switch layer.kind {
        case .raster: return "R"
        case .text: return "T"
        case .gradient: return "G"
        case .solid: return "S"
        }
    }
}

private struct LayerThumbnail: View {
    let layer: PXLayer

    var body: some View {
        ZStack {
            // Tiny checkerboard so transparent areas read as transparent
            // (matches the canvas background language).
            Rectangle().fill(Color(white: 0.10))
            Rectangle().fill(Color(white: 0.13))
                .mask(
                    Canvas { ctx, size in
                        let sq: CGFloat = 4
                        let cols = Int(size.width / sq) + 1
                        let rows = Int(size.height / sq) + 1
                        for r in 0..<rows {
                            for c in 0..<cols where (r + c) % 2 == 0 {
                                let rect = CGRect(x: CGFloat(c) * sq, y: CGFloat(r) * sq, width: sq, height: sq)
                                ctx.fill(Path(rect), with: .color(.white))
                            }
                        }
                    }
                )

            // Type-specific content on top.
            content
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch layer.kind {
        case .solid:
            Rectangle().fill(layer.solid.color.swiftUIColor)
        case .gradient:
            gradientPreview
        case .text:
            // Text-style placeholder: a stylized "T" in the layer's color.
            Text("T")
                .font(.system(size: 13, weight: .heavy, design: .default))
                .foregroundStyle(layer.text.color.swiftUIColor)
        case .raster:
            if let cg = LayerThumbnailCache.image(for: layer) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                // No source loaded yet (e.g. smart object whose file isn't
                // accessible). Fall back to a glyph rather than empty space.
                Image(systemName: layer.smart != nil ? "photo" : "paintbrush")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gradientPreview: some View {
        let g = layer.gradient
        let c1 = g.c1.swiftUIColor
        let c2 = g.c2.swiftUIColor
        let angle = Angle(degrees: g.angle - 90)  // SwiftUI 0° = up; doc 0° = right
        return Group {
            if g.kind == "radial" {
                RadialGradient(colors: [c1, c2], center: .center, startRadius: 1, endRadius: 22)
            } else {
                LinearGradient(
                    colors: [c1, c2],
                    startPoint: UnitPoint(
                        x: 0.5 - 0.5 * cos(angle.radians),
                        y: 0.5 - 0.5 * sin(angle.radians)
                    ),
                    endPoint: UnitPoint(
                        x: 0.5 + 0.5 * cos(angle.radians),
                        y: 0.5 + 0.5 * sin(angle.radians)
                    )
                )
            }
        }
    }
}

// MARK: - Thumbnail cache

/// Memoizes the source CGImage used for raster/smart-object layer previews
/// so the layers panel doesn't re-decode the source bytes on every SwiftUI
/// redraw. Keyed by layer ID; invalidated when the layer's content
/// fingerprint changes (raster pointer identity, or smart bytes count).
@MainActor
private enum LayerThumbnailCache {
    private static var entries: [UUID: Entry] = [:]

    private struct Entry {
        let fingerprint: Int
        let image: CGImage
    }

    static func image(for layer: PXLayer) -> CGImage? {
        let fp = fingerprint(for: layer)
        if let entry = entries[layer.id], entry.fingerprint == fp {
            return entry.image
        }
        guard let cg = resolve(layer: layer) else {
            entries.removeValue(forKey: layer.id)
            return nil
        }
        entries[layer.id] = Entry(fingerprint: fp, image: cg)
        return cg
    }

    private static func resolve(layer: PXLayer) -> CGImage? {
        if let smart = layer.smart {
            return SmartObjectEngine.loadSource(smart)
        }
        return layer.raster
    }

    private static func fingerprint(for layer: PXLayer) -> Int {
        var h = Hasher()
        if let smart = layer.smart {
            h.combine(smart.sourceBytes?.count ?? 0)
            h.combine(smart.sourcePath ?? "")
            h.combine(smart.sourceFormat ?? "")
        } else if let cg = layer.raster {
            h.combine(ObjectIdentifier(cg))
        } else {
            h.combine(0)
        }
        return h.finalize()
    }
}
