import Foundation
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Codable snapshot of a document. Raster images are encoded as base64 PNG.
struct DocumentSnapshot: Codable {
    var version: Int = 1
    var canvasWidth: Double
    var canvasHeight: Double
    var background: ColorRGB
    var activeLayerID: UUID?
    var layers: [LayerSnapshot]
}

struct LayerSnapshot: Codable {
    var id: UUID
    var name: String
    var kind: LayerKind
    var visible: Bool = true
    var opacity: Double = 1
    var blend: BlendMode = .normal
    var offsetX: Double = 0
    var offsetY: Double = 0
    var rasterPNG: Data?
    /// Layer mask, PNG-encoded grayscale. Added in v0.4 — old documents
    /// decode with mask = nil and behave exactly as before.
    var maskPNG: Data?
    var text: TextContent = TextContent()
    var gradient: GradientContent = GradientContent()
    var solid: SolidContent = SolidContent()
    var smart: SmartSource?
    var adjust: Adjustments = Adjustments()
    var filters: Filters = Filters()
    var relight: Relight = Relight()
    var skin: SkinRetouch = SkinRetouch()
    var styles: LayerStyles = LayerStyles()

    // Explicit Codable init that tolerates old project files missing newer keys.
    // Anything absent falls back to the field's default — so files saved before
    // we added `solid`, `smart`, new edge tweaks, etc. still load.
    enum CodingKeys: String, CodingKey {
        case id, name, kind, visible, opacity, blend, offsetX, offsetY, rasterPNG, maskPNG
        case text, gradient, solid, smart, adjust, filters, relight, skin, styles
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer"
        self.kind = try c.decodeIfPresent(LayerKind.self, forKey: .kind) ?? .raster
        self.visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        self.opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        self.blend = try c.decodeIfPresent(BlendMode.self, forKey: .blend) ?? .normal
        self.offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        self.offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        self.rasterPNG = try c.decodeIfPresent(Data.self, forKey: .rasterPNG)
        self.maskPNG = try c.decodeIfPresent(Data.self, forKey: .maskPNG)
        self.text = try c.decodeIfPresent(TextContent.self, forKey: .text) ?? TextContent()
        self.gradient = try c.decodeIfPresent(GradientContent.self, forKey: .gradient) ?? GradientContent()
        self.solid = try c.decodeIfPresent(SolidContent.self, forKey: .solid) ?? SolidContent()
        self.smart = try c.decodeIfPresent(SmartSource.self, forKey: .smart)
        self.adjust = try c.decodeIfPresent(Adjustments.self, forKey: .adjust) ?? Adjustments()
        self.filters = try c.decodeIfPresent(Filters.self, forKey: .filters) ?? Filters()
        self.relight = try c.decodeIfPresent(Relight.self, forKey: .relight) ?? Relight()
        self.skin = try c.decodeIfPresent(SkinRetouch.self, forKey: .skin) ?? SkinRetouch()
        self.styles = try c.decodeIfPresent(LayerStyles.self, forKey: .styles) ?? LayerStyles()
    }

    // Needed because we declared explicit fields with defaults — re-add the
    // memberwise init that other call sites rely on.
    init(id: UUID, name: String, kind: LayerKind) {
        self.id = id; self.name = name; self.kind = kind
    }
}

extension DocumentStore {
    @MainActor
    func makeSnapshot() -> DocumentSnapshot {
        let snap = DocumentSnapshot(
            canvasWidth: Double(canvasSize.width),
            canvasHeight: Double(canvasSize.height),
            background: backgroundColor,
            activeLayerID: activeLayerID,
            layers: layers.map { LayerSnapshot(from: $0) }
        )
        tlog("snapshot canvas = \(snap.canvasWidth) × \(snap.canvasHeight), layers = \(snap.layers.count)")
        return snap
    }

    @MainActor
    func apply(_ snap: DocumentSnapshot) {
        tlog("apply canvas = \(snap.canvasWidth) × \(snap.canvasHeight), layers = \(snap.layers.count)")
        canvasSize = CGSize(width: snap.canvasWidth, height: snap.canvasHeight)
        backgroundColor = snap.background
        layers = snap.layers.map { $0.toLayer() }
        activeLayerID = snap.activeLayerID ?? layers.last?.id
        // Clear dirty AFTER applying (invalidate() flips dirty on)
        invalidate()
        isDirty = false
    }
}

extension LayerSnapshot {
    init(from layer: PXLayer) {
        self.id = layer.id
        self.name = layer.name
        self.kind = layer.kind
        self.visible = layer.visible
        self.opacity = layer.opacity
        self.blend = layer.blend
        self.offsetX = Double(layer.offset.width)
        self.offsetY = Double(layer.offset.height)
        self.rasterPNG = layer.raster.flatMap { LayerSnapshot.encodePNG($0) }
        self.maskPNG = layer.mask.flatMap { LayerSnapshot.encodePNG($0) }
        self.text = layer.text
        self.gradient = layer.gradient
        self.solid = layer.solid
        self.smart = layer.smart
        self.adjust = layer.adjust
        self.filters = layer.filters
        self.relight = layer.relight
        self.skin = layer.skin
        self.styles = layer.styles
    }

    func toLayer() -> PXLayer {
        let L = PXLayer(id: id, name: name, kind: kind)
        L.visible = visible
        L.opacity = opacity
        L.blend = blend
        L.offset = CGSize(width: offsetX, height: offsetY)
        L.text = text
        L.gradient = gradient
        L.solid = solid
        L.smart = smart
        L.adjust = adjust
        L.filters = filters
        L.relight = relight
        L.skin = skin
        L.styles = styles
        if let data = rasterPNG { L.raster = LayerSnapshot.decodePNG(data) }
        if let data = maskPNG { L.mask = LayerSnapshot.decodePNG(data) }
        return L
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
