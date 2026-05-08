import SwiftUI
import RichTextKit
import AppKit

struct PropertiesTab: View {
    @Environment(DocumentStore.self) private var store
    @State private var displayedID: UUID?

    private var displayedLayer: PXLayer? {
        store.layers.first(where: { $0.id == displayedID })
    }

    var body: some View {
        let _ = perfMark("PropertiesTab.body")
        VStack(spacing: 0) {
            InspectorSection("Document", defaultOpen: true) {
                DocumentPanel()
            }
            if let layer = displayedLayer {
                InspectorSection("Layer", defaultOpen: true) {
                    LayerBasics(layer: layer)
                }
                if layer.kind == .text {
                    InspectorSection("Text", defaultOpen: true) {
                        TextEditorPanel(layer: layer)
                    }
                }
                if layer.kind == .gradient {
                    InspectorSection("Gradient", defaultOpen: true) {
                        GradientEditorPanel(layer: layer)
                    }
                }
                if layer.kind == .solid {
                    InspectorSection("Solid Color", defaultOpen: true) {
                        SolidEditorPanel(layer: layer)
                    }
                }
                if layer.smart != nil {
                    InspectorSection("Smart Object", defaultOpen: true) {
                        SmartObjectPanel(layer: layer)
                    }
                    InspectorSection("Cutout / Background", defaultOpen: true) {
                        CutoutPanel(layer: layer)
                    }
                }
            } else {
                Text("Select a layer to see its properties.")
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

// MARK: - Document

private struct DocumentPanel: View {
    @Environment(DocumentStore.self) private var store
    @State private var widthText: String = ""
    @State private var heightText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Size") {
                HStack(spacing: 4) {
                    TextField("W", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .onSubmit { commitSize() }
                    Text("×").foregroundStyle(.tertiary)
                    TextField("H", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .onSubmit { commitSize() }
                    Text("px").font(.caption).foregroundStyle(.tertiary)
                }
            }
            InspectorRow("Background") {
                InspectorColorWell(
                    color: Binding(
                        get: { store.backgroundColor.swiftUIColor },
                        set: { store.backgroundColor = ColorRGB($0.asNSColor); store.invalidate() }
                    ),
                    help: "Canvas background — shows behind all layers and through transparent areas"
                )
            }
        }
        .onAppear { syncFromStore() }
        .onChange(of: store.canvasSize) { _, _ in syncFromStore() }
    }

    private func syncFromStore() {
        widthText = String(Int(store.canvasSize.width))
        heightText = String(Int(store.canvasSize.height))
    }

    private func commitSize() {
        guard let w = Int(widthText), let h = Int(heightText), w > 0, h > 0 else {
            syncFromStore()
            return
        }
        store.checkpoint("Resize Canvas")
        store.canvasSize = CGSize(width: w, height: h)
        store.invalidate()
    }
}

// MARK: - Layer basics

private struct LayerBasics: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Name") {
                TextField("", text: $layer.name).textFieldStyle(.roundedBorder)
            }
            InspectorRow("Opacity") {
                InspectorSlider($layer.opacity, in: 0...1, format: .percent) { store.invalidate() }
            }
            InspectorRow("Blend") {
                Picker("", selection: $layer.blend) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .onChange(of: layer.blend) { store.invalidate() }
            }
        }
    }
}

// MARK: - Text

/// Box to hold a weak reference to the rich text view for post-action sync.
@MainActor
private final class RichTextViewComponentProxy {
    weak var view: (any RichTextViewComponent)?
}

private struct TextEditorPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer
    @State private var attributedText: NSAttributedString = .init(string: "")
    @StateObject private var richContext = RichTextContext()
    @State private var hasLoaded: Bool = false
    @State private var loadedLayerID: UUID?
    @State private var textViewProxy: RichTextViewComponentProxy = .init()
    @State private var inlineColor: Color = .red
    @State private var savedSelection: NSRange = .init(location: 0, length: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            RichTextEditor(text: $attributedText, context: richContext) { view in
                // Capture the underlying NSTextView so we can re-read its
                // attributed string after toolbar actions (which RichTextKit
                // doesn't auto-sync back to the text binding).
                textViewProxy.view = view
            }
                .frame(height: 96)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                .onAppear { loadFromLayer() }
                .onChange(of: layer.id) { _, _ in loadFromLayer() }
                .onChange(of: attributedText) { _, _ in
                    saveToLayer()
                    if let view = textViewProxy.view as? NSTextView {
                        let r = view.selectedRange()
                        if r.length > 0 { savedSelection = r }
                    }
                }
                .onReceive(richContext.actionPublisher) { action in
                    tlog("text action: \(action)")
                    if let view = textViewProxy.view {
                        let r = (view as? NSTextView)?.selectedRange() ?? NSRange(location: 0, length: 0)
                        if r.length > 0 { savedSelection = r }
                    }
                    DispatchQueue.main.async {
                        guard let view = textViewProxy.view else {
                            tlog("text sync: no textView proxy")
                            return
                        }
                        let latest = view.attributedString
                        tlog("text sync: editor has \(latest.length) chars, binding has \(attributedText.length)")
                        if !latest.isEqual(to: attributedText) {
                            attributedText = latest
                            tlog("text sync: pushed latest into binding")
                        }
                    }
                }

            HStack(spacing: 8) {
                ColorPicker("", selection: $inlineColor)
                    .labelsHidden()
                    .help("Color for the selected text")
                    .onChange(of: inlineColor) { _, newColor in
                        applyInlineColor(NSColor(newColor))
                    }
                inlineStyleButton("bold", help: "Bold (⌘B)") {
                    richContext.actionPublisher.send(.toggleStyle(.bold))
                }
                inlineStyleButton("italic", help: "Italic (⌘I)") {
                    richContext.actionPublisher.send(.toggleStyle(.italic))
                }
                inlineStyleButton("underline", help: "Underline (⌘U)") {
                    richContext.actionPublisher.send(.toggleStyle(.underlined))
                }
                inlineStyleButton("strikethrough", help: "Strikethrough") {
                    richContext.actionPublisher.send(.toggleStyle(.strikethrough))
                }
                Spacer()
            }

            InspectorFootnote("Select any part of the text, then pick a color or B/I/U/S to style just that range.")

            Divider().opacity(0.4).padding(.vertical, 4)

            InspectorRow("Font") {
                Picker("", selection: $layer.text.fontName) {
                    Section("System (SF Pro)") {
                        ForEach(TextFontResolver.systemFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    Section("Installed") {
                        ForEach(TextFontResolver.installedFamilies, id: \.self) { Text($0).tag($0) }
                    }
                }
                .labelsHidden()
                .onChange(of: layer.text.fontName) { store.invalidate() }
            }
            InspectorRow("Weight") {
                Picker("", selection: $layer.text.weight) {
                    ForEach(TextFontResolver.weights, id: \.value) { w in
                        Text(w.label).tag(w.value)
                    }
                }
                .labelsHidden()
                .onChange(of: layer.text.weight) { store.invalidate() }
            }
            InspectorRow("Size") {
                InspectorSlider($layer.text.fontSize, in: 8...600, format: .integer) { store.invalidate() }
            }
            InspectorRow("Color") {
                InspectorColorWell(
                    color: Binding(
                        get: { layer.text.color.swiftUIColor },
                        set: { layer.text.color = ColorRGB($0.asNSColor); store.invalidate() }
                    ),
                    help: "Default color for this text layer — overridden by per-character colors set inline"
                )
            }
            InspectorRow("Align") {
                Picker("", selection: $layer.text.alignment) {
                    Text("Left").tag("left"); Text("Center").tag("center"); Text("Right").tag("right")
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: layer.text.alignment) { store.invalidate() }
            }
            InspectorRow("Line ht.") {
                InspectorSlider($layer.text.lineHeight, in: 0.7...1.8, format: .decimal(2)) { store.invalidate() }
            }
            InspectorRow("Tracking") {
                InspectorSlider($layer.text.tracking, in: -20...60, format: .signedInteger) { store.invalidate() }
            }
            InspectorRow("Rotation") {
                InspectorSlider($layer.text.rotation, in: -180...180, format: .degrees) { store.invalidate() }
            }
            InspectorRow("Rotate") {
                HStack(spacing: 6) {
                    Button { rotateTextBy(-90) } label: {
                        Image(systemName: "rotate.left")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Rotate 90° counterclockwise")

                    Button { rotateTextBy(90) } label: {
                        Image(systemName: "rotate.right")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Rotate 90° clockwise")

                    Button("180°") { rotateTextBy(180) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Rotate 180°")
                    Spacer()
                }
            }
        }
    }

    /// Same snap+wrap semantics as the smart-object rotate buttons so the
    /// behavior is predictable across layer kinds.
    private func rotateTextBy(_ delta: Double) {
        store.checkpoint("Rotate Text")
        let current = layer.text.rotation
        var next = ((current + delta).rounded() / 90).rounded() * 90
        if next > 180 { next -= 360 }
        if next <= -180 { next += 360 }
        layer.text.rotation = next
        store.invalidate()
    }

    @ViewBuilder
    private func inlineStyleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    private func loadFromLayer() {
        hasLoaded = false
        let loaded: NSAttributedString
        if let data = layer.text.rtfData, data.count > 0,
           let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil),
           attr.length > 0 {
            loaded = attr
        } else {
            let fallback = layer.text.string.isEmpty ? "Text" : layer.text.string
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.white
            ]
            loaded = NSAttributedString(string: fallback, attributes: attrs)
        }
        attributedText = loaded
        // Push the loaded content INTO the editor. RichTextKit's documentation
        // explicitly states that changing the `text` binding does not update
        // the editor — you have to drive it through the context's action publisher.
        richContext.actionPublisher.send(.setAttributedString(loaded))
        loadedLayerID = layer.id
        DispatchQueue.main.async {
            hasLoaded = true
        }
    }

    private func applyInlineColor(_ nsColor: NSColor) {
        guard let view = textViewProxy.view as? NSTextView,
              let storage = view.textStorage else {
            tlog("applyInlineColor: no text storage")
            return
        }
        var range = view.selectedRange()
        if range.length == 0 { range = savedSelection }
        guard range.length > 0,
              range.location + range.length <= storage.length else {
            tlog("applyInlineColor: no valid selection (view=\(view.selectedRange()), saved=\(savedSelection))")
            return
        }
        storage.addAttribute(.foregroundColor, value: nsColor, range: range)
        let updated = NSAttributedString(attributedString: storage)
        attributedText = updated
        tlog("applyInlineColor: applied \(nsColor.hexString) to range \(range)")
    }

    private func saveToLayer() {
        guard hasLoaded else {
            tlog("saveToLayer: skipped (not loaded yet)")
            return
        }
        guard loadedLayerID == layer.id else {
            tlog("saveToLayer: skipped (layer id mismatch)")
            return
        }
        let plain = attributedText.string
        if plain.isEmpty && !layer.text.string.isEmpty {
            tlog("saveToLayer: skipped (editor empty, layer non-empty)")
            return
        }

        var colorCount = 0
        attributedText.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributedText.length)) { val, _, _ in
            if val != nil { colorCount += 1 }
        }

        let full = NSRange(location: 0, length: attributedText.length)
        if plain != layer.text.string { layer.text.string = plain }
        if let rtf = try? attributedText.data(
            from: full,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            layer.text.rtfData = rtf
            tlog("saveToLayer: \(plain.count) chars, \(colorCount) color runs, \(rtf.count) rtf bytes")
        }
        store.invalidate()
    }
}

// MARK: - Smart Object

private struct SmartObjectPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer

    /// Bumps the layer's rotation by `delta` and snaps the result to the
    /// nearest 90° step, then wraps to (-180, 180]. Snapping protects against
    /// drift if the slider has been nudged off a clean 90° boundary; clicking
    /// "+90" twice from any angle still lands you on a square multiple.
    private func rotateBy(_ delta: Double) {
        store.checkpoint("Rotate Layer")
        let current = layer.smart?.rotationDeg ?? 0
        var next = ((current + delta).rounded() / 90).rounded() * 90
        if next > 180 { next -= 360 }
        if next <= -180 { next += 360 }
        layer.smart?.rotationDeg = next
        store.invalidate()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            if let smart = layer.smart {
                InspectorRow("Source") {
                    Text(smart.sourcePath ?? "<embedded>")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                InspectorRow("Pixels") {
                    HStack {
                        Text("\(smart.pixelWidth) × \(smart.pixelHeight)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit in…") { store.openSmartLayerInExternalEditor(layer) }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            InspectorRow("Scale X") {
                InspectorSlider(
                    Binding(
                        get: { layer.smart?.scaleX ?? 1 },
                        set: { layer.smart?.scaleX = $0 }
                    ),
                    in: 0.05...8,
                    format: .decimal(2)
                ) { store.invalidate() }
            }
            InspectorRow("Scale Y") {
                InspectorSlider(
                    Binding(
                        get: { layer.smart?.scaleY ?? 1 },
                        set: { layer.smart?.scaleY = $0 }
                    ),
                    in: 0.05...8,
                    format: .decimal(2)
                ) { store.invalidate() }
            }
            InspectorRow("Rotation") {
                InspectorSlider(
                    Binding(
                        get: { layer.smart?.rotationDeg ?? 0 },
                        set: { layer.smart?.rotationDeg = $0 }
                    ),
                    in: -180...180,
                    format: .degrees
                ) { store.invalidate() }
            }
            InspectorRow("Rotate") {
                HStack(spacing: 6) {
                    Button { rotateBy(-90) } label: {
                        Image(systemName: "rotate.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Rotate 90° counterclockwise")

                    Button { rotateBy(90) } label: {
                        Image(systemName: "rotate.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Rotate 90° clockwise")

                    Button("180°") { rotateBy(180) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Rotate 180°")
                    Spacer()
                }
            }
            InspectorRow("Flip") {
                HStack(spacing: 6) {
                    Toggle("H", isOn: Binding(
                        get: { layer.smart?.flipH ?? false },
                        set: { layer.smart?.flipH = $0; store.invalidate() }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    Toggle("V", isOn: Binding(
                        get: { layer.smart?.flipV ?? false },
                        set: { layer.smart?.flipV = $0; store.invalidate() }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
            InspectorFootnote("Double-click the canvas to open the source in its default editor. Saving there updates this layer live.")
        }
    }
}

// MARK: - Cutout

private struct CutoutPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer
    @State private var isRemovingBG: Bool = false

    @MainActor
    private func removeBG() async {
        guard let smart = layer.smart, let cg = SmartObjectEngine.loadSource(smart) else {
            NSSound.beep(); return
        }
        isRemovingBG = true
        defer { isRemovingBG = false }
        do {
            store.checkpoint("Remove Background")
            // v0.4: non-destructive — set layer.mask, leave the source alone.
            let mask = try BackgroundRemover.mask(from: cg)
            layer.mask = mask
            store.invalidate()
        } catch {
            NSSound.beep()
            terr("Cutout Remove BG failed: \(error)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            HStack {
                Button {
                    Task { @MainActor in await removeBG() }
                } label: {
                    Label("Remove Background", systemImage: "person.crop.rectangle.stack")
                }
                .controlSize(.small)
                .disabled(isRemovingBG)
                if isRemovingBG { ProgressView().controlSize(.small) }
                Spacer()
            }
            InspectorFootnote("On-device Vision segmentation. Run it, then fine-tune the edges below.")

            Divider().opacity(0.4).padding(.vertical, 4)

            InspectorRow("Edge offset") {
                InspectorSlider(
                    Binding(
                        get: { layer.smart?.edgeOffset ?? 0 },
                        set: { layer.smart?.edgeOffset = $0 }
                    ),
                    in: -20...20,
                    format: .signedInteger
                ) { store.invalidate() }
            }
            InspectorRow("Feather") {
                InspectorSlider(
                    Binding(
                        get: { layer.smart?.edgeFeather ?? 0 },
                        set: { layer.smart?.edgeFeather = $0 }
                    ),
                    in: 0...20,
                    format: .decimal(1)
                ) { store.invalidate() }
            }
            InspectorRow("Threshold") {
                InspectorSlider(
                    Binding(
                        get: { layer.smart?.edgeThreshold ?? 0 },
                        set: { layer.smart?.edgeThreshold = $0 }
                    ),
                    in: 0...1,
                    format: .percent
                ) { store.invalidate() }
            }
            InspectorFootnote("Offset grows (+) / shrinks (−) the subject. Feather softens the outline. Threshold hardens the fringe.")

            HStack {
                Spacer()
                Button("Reset Edges") {
                    store.checkpoint("Reset Edge Cleanup")
                    layer.smart?.edgeOffset = 0
                    layer.smart?.edgeFeather = 0
                    layer.smart?.edgeThreshold = 0
                    store.invalidate()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }
}

// MARK: - Solid

private struct SolidEditorPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Color") {
                InspectorColorWell(
                    color: Binding(
                        get: { layer.solid.color.swiftUIColor },
                        set: { layer.solid.color = ColorRGB($0.asNSColor); store.invalidate() }
                    ),
                    help: "Fill color for this Solid Color layer"
                )
            }
            InspectorFootnote("Set layer Blend (in Layer) to Multiply for a vignette or Screen for a warm color cast.")
        }
    }
}

// MARK: - Gradient

private struct GradientEditorPanel: View {
    @Environment(DocumentStore.self) private var store
    @Bindable var layer: PXLayer

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            InspectorRow("Type") {
                Picker("", selection: $layer.gradient.kind) {
                    Text("Linear").tag("linear"); Text("Radial").tag("radial")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: layer.gradient.kind) { store.invalidate() }
            }
            InspectorRow("Color 1") {
                InspectorColorWell(color: Binding(
                    get: { layer.gradient.c1.swiftUIColor },
                    set: { layer.gradient.c1 = ColorRGB($0.asNSColor); store.invalidate() }
                ))
            }
            InspectorRow("Color 2") {
                InspectorColorWell(color: Binding(
                    get: { layer.gradient.c2.swiftUIColor },
                    set: { layer.gradient.c2 = ColorRGB($0.asNSColor); store.invalidate() }
                ))
            }
            InspectorRow("Angle") {
                InspectorSlider($layer.gradient.angle, in: 0...360, format: .degrees) { store.invalidate() }
            }
            if layer.gradient.kind == "radial" {
                InspectorRow("Radius") {
                    InspectorSlider($layer.gradient.radius, in: 0.05...2, format: .decimal(2)) { store.invalidate() }
                }
            }
        }
    }
}
