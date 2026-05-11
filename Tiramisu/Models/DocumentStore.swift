import Foundation
import Observation
import AppKit
import CoreGraphics

@Observable
@MainActor
final class DocumentStore {
    var canvasSize = CGSize(width: 1280, height: 720)
    var backgroundColor: ColorRGB = ColorRGB(r: 0.05, g: 0.07, b: 0.12)
    var layers: [PXLayer] = []
    var activeLayerID: UUID?
    var tool: Tool = .move
    /// When non-nil, the canvas drag handler enters HSL Targeted-Adjustment-Tool
    /// mode: clicking the photo samples the pixel under the cursor, identifies
    /// which 1-2 hue bands it belongs to, and a vertical drag scrubs those
    /// bands' slider for the channel set here. Set from the Adjust → Color
    /// (HSL) panel; cleared by clicking the TAT button again or pressing Esc.
    /// Transient — never persisted to disk.
    var hslTATChannel: HSLTATChannel? = nil
    var foreground: ColorRGB = ColorRGB(r: 1.0, g: 0.8, b: 0.0)
    var brush = BrushSettings()
    /// Magic-wand color-distance tolerance, 0…1 (sRGB Euclidean). Default
    /// 0.12 ≈ 30/255 — picks similar shades but stops at clear color
    /// boundaries. Persists per-session, not to disk.
    var magicWandTolerance: Double = 0.12
    /// True = flood-fill only the contiguous region. False = select all
    /// pixels in the image with a similar color.
    var magicWandContiguous: Bool = true
    var currentFileURL: URL? {
        didSet {
            // Persist the last-opened file path so the next app launch
            // can re-open it. Cleared (nil) when the user starts a new
            // unsaved doc, so we don't try to re-open a non-existent path.
            if let url = currentFileURL {
                UserDefaults.standard.set(url.path, forKey: Self.lastOpenDocKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastOpenDocKey)
            }
        }
    }
    private static let lastOpenDocKey = "world.hanley.tiramisu.lastOpenDoc"
    var isDirty: Bool = false
    var viewportZoom: Double = 1.0     // trackpad pinch / shortcut zoom
    var viewportZoomBase: Double = 1.0
    var viewportPan: CGSize = .zero    // two-finger trackpad pan (logical pixels)
    var recentFiles: [URL] = []
    var showSafeArea: Bool = false
    var showRuleOfThirds: Bool = false
    var showGoldenRatio: Bool = false
    var showYTCornerRadius: Bool = false
    var showYTDurationPill: Bool = false
    var showYTBannerSafeAreas: Bool = false
    var showPFPCircleMask: Bool = false
    var undoStack: [DocumentSnapshot] = []
    var redoStack: [DocumentSnapshot] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private let maxHistory = 50
    private var coalescingName: String? = nil    // when set, consecutive checkpoints with this name fold into the previous one
    private var watchers: [UUID: FileWatcher] = [:]
    private let recentsKey = "world.hanley.tiramisu.recentFiles"
    private let recentsMax = 10
    // Debug / test harness server.
    // - Debug builds: ON by default (so AI agents and ad-hoc testing have a surface).
    // - Release builds: OFF by default (privacy + attack-surface reduction —
    //   we don't ship a public HTTP listener bound to localhost without explicit user opt-in).
    // Toggleable at runtime from Debug → Control Server.
    #if DEBUG
    var controlServerEnabled: Bool = true
    #else
    var controlServerEnabled: Bool = false
    #endif
    var controlServerPort: Int = 7979
    /// Marquee selection in doc (top-down) coords. nil = no selection. Used by
    /// Generative Fill to constrain the regenerated region. For non-rectangular
    /// selections (e.g. lasso) this stores the path's bounding box; the actual
    /// shape lives in `selectionPath`.
    var selectionRect: CGRect?
    /// The canonical selection shape in doc (top-down) coords. Always set to
    /// a closed CGPath when there's an active selection; nil otherwise.
    /// Marquee writes a rect path; lasso writes a free polygon. Paint and
    /// future selection-aware features should clip against this.
    var selectionPath: CGPath?

    /// Set a rectangular selection (marquee tool). Keeps `selectionPath` in
    /// sync with a rect path so downstream consumers can rely on it.
    func setSelection(rect: CGRect) {
        selectionRect = rect
        selectionPath = CGPath(rect: rect, transform: nil)
    }

    /// Set a free-form selection (lasso). Updates `selectionRect` to the
    /// path's bounding box for callers that only understand rects.
    func setSelection(path: CGPath) {
        selectionPath = path
        selectionRect = path.boundingBoxOfPath
    }

    func clearSelection() {
        selectionRect = nil
        selectionPath = nil
    }
    /// Generative-fill progress message — non-nil while a fill is in flight.
    var generativeProgress: String?

    // re-render ticker — bumped whenever a change should trigger recomposite
    private(set) var renderTick: Int = 0

    init() {
        // Empty document by default — the user reaches for the layer they
        // actually want from the Layer menu (or drops in an image). The
        // earlier "EPIC TITLE on a gradient" demo content got in the way
        // of the v0.5 paint workflow and showed up in every screenshot.
        self.layers = []
        self.activeLayerID = nil
        self.recentFiles = loadRecents()
    }

    /// If the last session ended with a `.tira` file open, return its URL
    /// so the app can auto-reload on launch. Nil when:
    /// - no last doc was tracked (fresh install / user closed an unsaved doc)
    /// - the file has been moved or deleted since (we don't lie about its
    ///   existence; caller falls back to the empty welcome state).
    static func pendingRestoreURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: lastOpenDocKey),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Clear the persisted last-doc reference. Called when the user
    /// explicitly chose New Document — we don't want to overwrite that
    /// intent with the previous file on the next launch.
    static func clearPendingRestore() {
        UserDefaults.standard.removeObject(forKey: lastOpenDocKey)
    }

    private func loadRecents() -> [URL] {
        guard let raw = UserDefaults.standard.array(forKey: recentsKey) as? [String] else { return [] }
        return raw.compactMap { path in
            let u = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }
    private func persistRecents() {
        UserDefaults.standard.set(recentFiles.map(\.path), forKey: recentsKey)
    }
    func recordRecent(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > recentsMax { recentFiles.removeLast(recentFiles.count - recentsMax) }
        persistRecents()
    }
    func removeRecent(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        persistRecents()
    }
    func clearRecents() {
        recentFiles.removeAll()
        persistRecents()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    var activeLayer: PXLayer? {
        layers.first(where: { $0.id == activeLayerID })
    }

    func invalidate() { renderTick &+= 1; isDirty = true }

    // MARK: - Undo / Redo
    //
    // Snapshot-based history. Call `checkpoint(name:)` BEFORE a mutation that should
    // be undoable. Pass `coalesceWith:` to merge with the previous checkpoint (for
    // continuous gestures like slider drags) — only the first state in a run is kept.

    func checkpoint(_ name: String, coalesceWith: String? = nil) {
        if let coalesce = coalesceWith, coalescingName == coalesce {
            return // already have the pre-state
        }
        undoStack.append(makeSnapshot())
        if undoStack.count > maxHistory { undoStack.removeFirst(undoStack.count - maxHistory) }
        redoStack.removeAll()
        coalescingName = coalesceWith
    }

    func endCoalescing() { coalescingName = nil }

    func performUndo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(makeSnapshot())
        apply(snap)
        tlog("undo → restored snapshot")
    }

    func performRedo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(makeSnapshot())
        apply(snap)
        tlog("redo → reapplied snapshot")
    }

    func addLayer(_ layer: PXLayer) {
        checkpoint("Add Layer")
        layers.append(layer)
        activeLayerID = layer.id
        if layer.smart != nil { startWatching(layer) }
        invalidate()
    }

    /// Create a Smart Object layer from an image on disk. Lossless — keeps source.
    @discardableResult
    func placeSmartImage(from url: URL) -> PXLayer? {
        guard let loaded = SmartImageLoader.load(from: url) else { return nil }
        let sw = CGFloat(loaded.cgImage.width), sh = CGFloat(loaded.cgImage.height)
        let fit = SmartObjectEngine.initialTransform(sourceSize: CGSize(width: sw, height: sh), canvas: canvasSize)
        var smart = SmartSource(
            sourcePath: url.path,
            sourceBytes: loaded.data,
            sourceFormat: loaded.format,
            pixelWidth: loaded.cgImage.width,
            pixelHeight: loaded.cgImage.height,
            centerX: fit.cx,
            centerY: fit.cy,
            scaleX: fit.scale,
            scaleY: fit.scale
        )
        // Try to capture a security-scoped bookmark so we can re-read after sandbox restart.
        if let bm = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            smart.sourceURLBookmark = bm
        }
        let name = url.deletingPathExtension().lastPathComponent
        let L = PXLayer(name: name, kind: .raster)
        L.smart = smart
        addLayer(L)
        return L
    }

    /// Create a Smart Object from in-memory image bytes (for pasted / dropped data
    /// without a backing file). Embeds the bytes; no external editing available.
    @discardableResult
    func placeSmartImage(data: Data, format: String) -> PXLayer? {
        guard let cg = SmartObjectEngine.decode(data) else { return nil }
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        let fit = SmartObjectEngine.initialTransform(sourceSize: CGSize(width: sw, height: sh), canvas: canvasSize)
        let smart = SmartSource(
            sourcePath: nil,
            sourceBytes: data,
            sourceFormat: format,
            pixelWidth: cg.width,
            pixelHeight: cg.height,
            centerX: fit.cx,
            centerY: fit.cy,
            scaleX: fit.scale,
            scaleY: fit.scale
        )
        let L = PXLayer(name: "Smart Image", kind: .raster)
        L.smart = smart
        addLayer(L)
        return L
    }

    private func startWatching(_ layer: PXLayer) {
        guard let path = layer.smart?.sourcePath else { return }
        let id = layer.id
        let watcher = FileWatcher(path: path) { [weak self, weak layer] in
            guard let self, let layer else { return }
            // Re-read source bytes so we pick up external edits.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                layer.smart?.sourceBytes = data
                self.invalidate()
            }
            _ = id
        }
        watchers[id] = watcher
    }

    func stopWatching(_ id: UUID) {
        watchers[id] = nil
    }

    /// Open the smart layer's source file in the OS default app. If only embedded bytes
    /// are available, writes them to a user-visible temp file and opens that; the watcher
    /// will auto-reload when the editor saves.
    func openSmartLayerInExternalEditor(_ layer: PXLayer) {
        guard let smart = layer.smart else { return }
        if let path = smart.sourcePath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        guard let bytes = smart.sourceBytes else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Tiramisu-Smart", isDirectory: true)
        let url = dir.appendingPathComponent("\(layer.id.uuidString).\(smart.sourceFormat)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        } catch {
            tlog("openSmartLayerInExternalEditor write failed: \(error.localizedDescription)")
            let a = NSAlert()
            a.messageText = "Couldn't open this smart layer in an external editor"
            a.informativeText = "Failed to write a temporary copy: \(error.localizedDescription)"
            a.alertStyle = .warning
            a.runModal()
            return
        }
        layer.smart?.sourcePath = url.path
        startWatching(layer)
        NSWorkspace.shared.open(url)
    }

    func removeActive() {
        guard let id = activeLayerID, let ix = layers.firstIndex(where: { $0.id == id }) else { return }
        checkpoint("Delete Layer")
        layers.remove(at: ix)
        activeLayerID = layers.last?.id
        invalidate()
    }

    func duplicateActive() {
        guard let src = activeLayer else { return }
        let copy = PXLayer(name: src.name + " copy", kind: src.kind)
        copy.visible = src.visible
        copy.opacity = src.opacity
        copy.blend = src.blend
        copy.offset = src.offset
        copy.raster = src.raster
        copy.text = src.text
        copy.gradient = src.gradient
        copy.solid = src.solid
        copy.adjust = src.adjust
        copy.filters = src.filters
        copy.relight = src.relight
        copy.skin = src.skin
        copy.styles = src.styles
        copy.offset = CGSize(width: src.offset.width + 12, height: src.offset.height + 12)
        addLayer(copy)
    }

    /// Bake a layer's full appearance — content + filters + adjustments + mask
    /// + styles + composite-time text transforms — into a flat raster layer.
    /// `offset` / `opacity` / `blend` are preserved so the layer's relationship
    /// to the rest of the doc is unchanged. Idempotent: rasterizing an
    /// already-flat raster layer just re-bakes the same pixels.
    @discardableResult
    func rasterizeLayer(_ id: UUID) -> Bool {
        guard let L = layers.first(where: { $0.id == id }) else { return false }
        guard let baked = LayerRenderer.bakedImage(layer: L, canvasSize: canvasSize) else {
            tlog("rasterizeLayer: bakedImage failed for '\(L.name)'")
            return false
        }
        checkpoint("Rasterize Layer")
        L.kind = .raster
        L.raster = baked
        L.smart = nil
        L.mask = nil
        L.adjust = Adjustments()
        L.filters = Filters()
        L.styles = LayerStyles()
        L.skin = SkinRetouch()
        L.relight = Relight()
        L.studioRelight = StudioRelight()
        L.text = TextContent()
        L.gradient = GradientContent()
        L.solid = SolidContent()
        invalidate()
        return true
    }

    func move(_ id: UUID, to newIndex: Int) {
        guard let ix = layers.firstIndex(where: { $0.id == id }) else { return }
        let layer = layers.remove(at: ix)
        let target = min(max(newIndex, 0), layers.count)
        layers.insert(layer, at: target)
        invalidate()
    }

    // Z-order helpers — "front" in UI / composite terms means the LAST item in
    // layers (composited on top). "Back" = index 0.
    func moveToFront(_ id: UUID) {
        guard let ix = layers.firstIndex(where: { $0.id == id }), ix < layers.count - 1 else { return }
        checkpoint("Bring to Front")
        let layer = layers.remove(at: ix)
        layers.append(layer)
        invalidate()
    }
    func moveForward(_ id: UUID) {
        guard let ix = layers.firstIndex(where: { $0.id == id }), ix < layers.count - 1 else { return }
        checkpoint("Bring Forward")
        layers.swapAt(ix, ix + 1)
        invalidate()
    }
    func moveBackward(_ id: UUID) {
        guard let ix = layers.firstIndex(where: { $0.id == id }), ix > 0 else { return }
        checkpoint("Send Backward")
        layers.swapAt(ix, ix - 1)
        invalidate()
    }
    func moveToBack(_ id: UUID) {
        guard let ix = layers.firstIndex(where: { $0.id == id }), ix > 0 else { return }
        checkpoint("Send to Back")
        let layer = layers.remove(at: ix)
        layers.insert(layer, at: 0)
        invalidate()
    }
}

/// Which HSL channel the Targeted Adjustment Tool is currently scrubbing.
enum HSLTATChannel: String, Sendable { case hue, sat, lum }

enum Tool: String, CaseIterable, Sendable {
    case move, marquee, lasso, polygonalLasso, magicWand, smartSelect
    case pencil, pen, eraser, text, eyedropper, relight
    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .marquee: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .polygonalLasso: return "lasso.badge.sparkles"   // visually distinct from free-form lasso
        case .magicWand: return "wand.and.stars"
        case .smartSelect: return "sparkles.rectangle.stack"  // AI-driven object selection
        case .pencil: return "pencil.tip"
        case .pen: return "scribble.variable"
        case .eraser: return "eraser"
        case .text: return "textformat"
        case .eyedropper: return "eyedropper"
        case .relight: return "sun.max"
        }
    }
    var label: String {
        switch self {
        case .move: return "Move"; case .marquee: return "Marquee"; case .lasso: return "Lasso"
        case .polygonalLasso: return "Polygonal Lasso"
        case .magicWand: return "Magic Wand"
        case .smartSelect: return "Smart Select"
        case .pencil: return "Pencil"; case .pen: return "Pen"
        case .eraser: return "Eraser"; case .text: return "Text"; case .eyedropper: return "Eyedropper"
        case .relight: return "Relight"
        }
    }

    /// True if the tool has a real canvas-interaction handler today.
    /// False = placeholder button shown disabled with a "coming soon" tooltip.
    /// Source-of-truth so ToolSidebar + any future palette display agree.
    var isImplemented: Bool {
        switch self {
        case .move, .marquee, .lasso, .polygonalLasso, .magicWand, .smartSelect,
             .text, .eyedropper, .relight, .pencil, .eraser: return true
        case .pen: return false  // vector paths — later milestone
        }
    }

    /// Roadmap milestone for placeholder tools (used in tooltips).
    var plannedFor: String? {
        switch self {
        case .pen: return "later (vector paths)"
        default:   return nil
        }
    }

    /// Combined hover tooltip — label + roadmap note when placeholder.
    var tooltip: String {
        if let planned = plannedFor {
            return "\(label) — coming in \(planned)"
        }
        return label
    }
}

struct BrushSettings: Sendable {
    var size: Double = 40
    var feather: Double = 0.6     // 0...1
    var opacity: Double = 1
    var flow: Double = 1
    var smoothing: Double = 0.4
}
