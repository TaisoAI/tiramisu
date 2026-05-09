import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import Tiramisu

@MainActor
@Suite("Paint engine — pencil + eraser stamp behavior")
struct PaintEngineTests {

    /// A single pencil stamp at the canvas center should color the pixels
    /// under the brush with the foreground color and leave faraway pixels
    /// fully transparent. This is the smallest non-trivial integration test:
    /// it exercises the full path from PaintStroke construction → stamp →
    /// commitToLayer → CGImage readback.
    @Test("pencil stamp paints foreground at the cursor and leaves edges transparent")
    func pencilStampPaintsFg() {
        let canvas = CGSize(width: 200, height: 200)
        let layer = PXLayer(name: "Paint", kind: .raster)
        var brush = BrushSettings()
        brush.size = 40
        brush.feather = 0       // hard edge
        brush.opacity = 1
        brush.flow = 1

        let red = ColorRGB(r: 1, g: 0, b: 0)
        let stroke = PaintStroke(layer: layer,
                                 canvasSize: canvas,
                                 isEraser: false,
                                 color: red,
                                 settings: brush,
                                 selectionPath: nil)
        #expect(stroke != nil, "PaintStroke must initialize for a raster layer")

        // Stamp once at canvas center (doc top-down coords).
        stroke?.addPoint(CGPoint(x: 100, y: 100))
        stroke?.commitToLayer()

        guard let img = layer.raster else {
            Issue.record("layer.raster should be populated after commit")
            return
        }
        // Center pixel should be red and opaque.
        let (cr, cg, cb, ca) = pixel(img, x: 100, y: 100)
        #expect(cr > 0.95 && cg < 0.05 && cb < 0.05 && ca > 0.95,
                "center pixel should read foreground red, got rgba=\(cr),\(cg),\(cb),\(ca)")

        // A pixel well outside the brush radius should be untouched (transparent).
        let (_, _, _, ea) = pixel(img, x: 5, y: 5)
        #expect(ea < 0.05, "edge pixel should be transparent, alpha=\(ea)")
    }

    /// Eraser uses destinationOut: stamping over a fully-painted layer should
    /// drop alpha to zero where the brush lands, while pixels outside the
    /// brush stay opaque.
    @Test("eraser drops alpha where stamped, preserves alpha elsewhere")
    func eraserDropsAlpha() {
        let canvas = CGSize(width: 100, height: 100)
        let layer = PXLayer(name: "Paint", kind: .raster)
        // Seed with a fully-opaque green raster so we have something to erase.
        layer.raster = solidImage(color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                                  size: canvas)

        var brush = BrushSettings()
        brush.size = 30
        brush.feather = 0       // hard
        brush.opacity = 1
        brush.flow = 1

        let stroke = PaintStroke(layer: layer,
                                 canvasSize: canvas,
                                 isEraser: true,
                                 color: .black,    // ignored by eraser
                                 settings: brush,
                                 selectionPath: nil)
        stroke?.addPoint(CGPoint(x: 50, y: 50))
        stroke?.commitToLayer()

        guard let img = layer.raster else {
            Issue.record("erased layer raster missing")
            return
        }
        let (_, _, _, holeAlpha) = pixel(img, x: 50, y: 50)
        #expect(holeAlpha < 0.05, "stamp center should be erased, alpha=\(holeAlpha)")

        let (_, eg, _, edgeAlpha) = pixel(img, x: 5, y: 5)
        #expect(edgeAlpha > 0.95 && eg > 0.95,
                "pixel outside the brush should still be opaque green, got a=\(edgeAlpha) g=\(eg)")
    }

    /// Painting with a selection rect should only deposit paint inside the
    /// selection. A center stamp that overlaps a small bottom-right
    /// selection should only color pixels inside that rect.
    @Test("selection rect clips paint to its bounds")
    func selectionClipsPaint() {
        let canvas = CGSize(width: 200, height: 200)
        let layer = PXLayer(name: "Paint", kind: .raster)
        var brush = BrushSettings()
        brush.size = 80
        brush.feather = 0
        brush.opacity = 1
        brush.flow = 1

        // Selection rect in doc top-down coords — bottom-right quadrant.
        let sel = CGRect(x: 100, y: 100, width: 100, height: 100)
        let selPath = CGPath(rect: sel, transform: nil)

        let stroke = PaintStroke(layer: layer,
                                 canvasSize: canvas,
                                 isEraser: false,
                                 color: ColorRGB(r: 0, g: 0, b: 1),
                                 settings: brush,
                                 selectionPath: selPath)
        // Stamp center is on the boundary of the selection.
        stroke?.addPoint(CGPoint(x: 100, y: 100))
        stroke?.commitToLayer()

        guard let img = layer.raster else {
            Issue.record("layer.raster missing after committed stroke")
            return
        }
        // Inside selection (top-left of the selection rect, doc coords (105,105))
        // should be painted blue.
        let (_, _, ib, ia) = pixel(img, x: 105, y: 105)
        #expect(ib > 0.95 && ia > 0.95,
                "pixel inside selection should be blue+opaque, b=\(ib) a=\(ia)")

        // Outside selection (top-left of canvas) should be untouched.
        let (_, _, _, oa) = pixel(img, x: 50, y: 50)
        #expect(oa < 0.05, "pixel outside selection must remain transparent, a=\(oa)")
    }

    /// A non-rectangular CGPath should clip the brush to its interior.
    /// We trace a 30×30 diamond at the canvas center, paint a stamp big
    /// enough to overflow it, then check the four cardinal points: pixels
    /// inside the diamond are painted, pixels outside (still in the bbox)
    /// are not.
    @Test("free-form path selection clips paint to its actual shape, not bbox")
    func lassoPathClipsPaint() {
        let canvas = CGSize(width: 200, height: 200)
        let layer = PXLayer(name: "Paint", kind: .raster)
        var brush = BrushSettings()
        brush.size = 60
        brush.feather = 0
        brush.opacity = 1
        brush.flow = 1

        // Diamond around (100, 100), radius 30 — corners at (100,70), (130,100),
        // (100,130), (70,100) in doc top-down coords.
        let p = CGMutablePath()
        p.move(to:    CGPoint(x: 100, y:  70))
        p.addLine(to: CGPoint(x: 130, y: 100))
        p.addLine(to: CGPoint(x: 100, y: 130))
        p.addLine(to: CGPoint(x:  70, y: 100))
        p.closeSubpath()

        let stroke = PaintStroke(layer: layer,
                                 canvasSize: canvas,
                                 isEraser: false,
                                 color: ColorRGB(r: 0, g: 1, b: 0),
                                 settings: brush,
                                 selectionPath: p)
        stroke?.addPoint(CGPoint(x: 100, y: 100))
        stroke?.commitToLayer()

        guard let img = layer.raster else {
            Issue.record("layer.raster missing")
            return
        }
        // Inside the diamond — at the very center.
        let (_, ig, _, ia) = pixel(img, x: 100, y: 100)
        #expect(ig > 0.95 && ia > 0.95,
                "diamond center should be green+opaque, g=\(ig) a=\(ia)")

        // Outside the diamond but inside its bounding box — top-left corner
        // of the bbox (75, 75) is well outside the diamond's diagonal edge.
        let (_, _, _, oa) = pixel(img, x: 75, y: 75)
        #expect(oa < 0.05,
                "pixel inside bbox but outside diamond shape must be transparent, a=\(oa)")
    }

    // MARK: - helpers

    /// Read an sRGB premultiplied-alpha pixel as 4 normalized doubles.
    /// `(x, y)` are doc top-down coords — `CGImage.cropping(to:)` uses a
    /// top-left origin so no flip is needed here.
    private func pixel(_ img: CGImage, x: Int, y: Int) -> (Double, Double, Double, Double) {
        let crop = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) ?? img
        var bytes: [UInt8] = [0, 0, 0, 0]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        return bytes.withUnsafeMutableBufferPointer { buf -> (Double, Double, Double, Double) in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return (0, 0, 0, 0)
            }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            // Un-premultiply RGB so the read matches "color of the pixel".
            let a = Double(buf[3]) / 255
            let r = a > 0 ? Double(buf[0]) / 255 / a : 0
            let g = a > 0 ? Double(buf[1]) / 255 / a : 0
            let b = a > 0 ? Double(buf[2]) / 255 / a : 0
            return (r, g, b, a)
        }
    }

    private func solidImage(color: NSColor, size: CGSize) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
}

@MainActor
@Suite("Rasterize Layer — bake non-destructive state into pixels")
struct RasterizeLayerTests {

    /// Rasterizing a gradient layer should produce a flat raster layer whose
    /// composite output matches the original gradient layer's composite
    /// output, modulo small floating-point delta from the CG pipeline.
    @Test("rasterize preserves visible composite output")
    func rasterizePreservesComposite() {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 128, height: 128)
        store.backgroundColor = ColorRGB(r: 0, g: 0, b: 0)
        store.layers = []

        let g = PXLayer(name: "Gradient", kind: .gradient)
        g.gradient = GradientContent(
            kind: "linear",
            c1: ColorRGB(r: 1, g: 0, b: 0), s1: 0,
            c2: ColorRGB(r: 0, g: 0, b: 1), s2: 1,
            angle: 0, center: .init(x: 0.5, y: 0.5), radius: 0.7
        )
        store.layers = [g]
        store.activeLayerID = g.id

        guard let before = LayerRenderer.composite(store: store) else {
            Issue.record("baseline composite failed")
            return
        }

        #expect(store.rasterizeLayer(g.id))
        let L = store.layers.first!
        #expect(L.kind == .raster)
        #expect(L.raster != nil)
        #expect(L.smart == nil)

        guard let after = LayerRenderer.composite(store: store) else {
            Issue.record("post-rasterize composite failed")
            return
        }
        #expect(meanAbsDiff(before, after) < 0.02,
                "rasterized output should match the original within 2% per-channel")
    }

    /// After rasterize, the layer should no longer carry adjustments — the
    /// brightness boost is baked into pixels, so resetting `adjust` would
    /// not visually change anything.
    @Test("rasterize clears adjustments since they're baked into pixels")
    func rasterizeClearsAdjustments() {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 64, height: 64)
        store.layers = []

        let s = PXLayer(name: "Solid", kind: .solid)
        s.solid = SolidContent(color: ColorRGB(r: 0.5, g: 0.5, b: 0.5))
        s.adjust.brightness = 0.4
        store.layers = [s]

        #expect(store.rasterizeLayer(s.id))
        let L = store.layers.first!
        #expect(L.adjust.brightness == 0)
        #expect(L.kind == .raster)
        #expect(L.raster != nil)
    }

    private func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
        precondition(a.width == b.width && a.height == b.height,
                     "comparison images must have matching dimensions")
        let w = a.width, h = a.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var bufA = [UInt8](repeating: 0, count: w * h * 4)
        var bufB = [UInt8](repeating: 0, count: w * h * 4)
        let bmInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctxA = CGContext(data: &bufA, width: w, height: h,
                             bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: cs, bitmapInfo: bmInfo)!
        let ctxB = CGContext(data: &bufB, width: w, height: h,
                             bitsPerComponent: 8, bytesPerRow: w * 4,
                             space: cs, bitmapInfo: bmInfo)!
        ctxA.draw(a, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctxB.draw(b, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in 0..<(w * h * 4) {
            sum += abs(Double(bufA[i]) - Double(bufB[i]))
        }
        return sum / Double(w * h * 4) / 255.0
    }
}
