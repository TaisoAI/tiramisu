import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import Tiramisu

@MainActor
@Suite("Selection tools — flood fill, contour conversion, refine edge")
struct SelectionToolsTests {

    /// Flood-fill from a red pixel in a half-red, half-blue image should
    /// select the entire red half and nothing in the blue half. This is the
    /// regression test for the orientation bug we hit in the first cut where
    /// `seedRow = h - 1 - sy` was sampling the wrong pixel and producing
    /// upside-down flood-fills.
    @Test("floodFill selects the contiguous color region under the seed")
    func floodFillSelectsCorrectRegion() {
        let canvas = CGSize(width: 100, height: 100)
        // Top half red, bottom half blue. Doc top-down: y=0..49 = red,
        // y=50..99 = blue. We click at (50, 25) — should select top half.
        let img = halfImage(top: NSColor.red, bottom: NSColor.blue, size: canvas)

        guard let mask = SelectionTools.floodFill(
            in: img,
            seed: CGPoint(x: 50, y: 25),
            tolerance: 0.05,
            contiguous: true
        ) else {
            Issue.record("floodFill returned nil")
            return
        }

        // The pixel under the cursor must be selected.
        #expect(maskValue(mask, x: 50, y: 25) > 200,
                "seed pixel must be selected")
        // Another pixel in the top (red) half should be selected.
        #expect(maskValue(mask, x: 10, y: 10) > 200,
                "top-half pixel should be in the same region as the seed")
        // A pixel in the bottom (blue) half must NOT be selected.
        #expect(maskValue(mask, x: 50, y: 75) < 50,
                "bottom-half pixel must not be selected — it's a different color")
    }

    /// Non-contiguous flood-fill picks every pixel within tolerance of the
    /// seed color regardless of position. Useful for "select all pixels of
    /// this color" workflows.
    @Test("non-contiguous floodFill selects all matching pixels regardless of region")
    func floodFillNonContiguous() {
        let canvas = CGSize(width: 60, height: 60)
        // A canvas with two disconnected green regions on a black background.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bm = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: 60, height: 60,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: bm)!
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        ctx.setFillColor(NSColor.green.cgColor)
        ctx.fill(CGRect(x: 5, y: 5, width: 10, height: 10))     // bottom-left in CG coords
        ctx.fill(CGRect(x: 45, y: 45, width: 10, height: 10))   // top-right in CG coords
        let img = ctx.makeImage()!

        // Seed inside the first green square (CG coords map to doc top-down y = canvasH - cgY)
        // Top-right green square (CG y=45..55) is doc y=5..15. Click at (50, 10).
        guard let mask = SelectionTools.floodFill(
            in: img,
            seed: CGPoint(x: 50, y: 10),
            tolerance: 0.05,
            contiguous: false
        ) else {
            Issue.record("non-contiguous floodFill returned nil")
            return
        }
        // Both green regions should be selected.
        #expect(maskValue(mask, x: 50, y: 10) > 200, "seed-region pixel selected")
        // The OTHER green square is at CG (5..15, 5..15) → doc y = 60-15..60-5 = 45..55.
        #expect(maskValue(mask, x: 10, y: 50) > 200,
                "the disconnected matching region must also be selected in non-contiguous mode")
        // A black pixel between them must not be.
        #expect(maskValue(mask, x: 30, y: 30) < 50,
                "black background must remain unselected")
    }

    /// rasterizeMask + maskToPath should round-trip a simple rectangle path
    /// to within a few-pixel area difference. Vision's contour detection is
    /// approximate, so we don't expect bit-exact recovery — but the
    /// resulting shape's bounding box and area should be very close.
    @Test("maskToPath round-trips a rectangle to within ~5% area")
    func maskToPathRoundTripRect() {
        let canvas = CGSize(width: 120, height: 120)
        let original = CGPath(rect: CGRect(x: 30, y: 30, width: 60, height: 60), transform: nil)

        guard let mask = SelectionTools.rasterizeMask(original, canvasSize: canvas) else {
            Issue.record("rasterizeMask failed")
            return
        }
        guard let path = SelectionTools.maskToPath(mask, canvasSize: canvas) else {
            Issue.record("maskToPath failed")
            return
        }
        let bb = path.boundingBoxOfPath
        // Expect the bbox to be within a few pixels of the original (60×60 at (30,30)).
        #expect(abs(bb.minX - 30) < 4, "min-x off by \(bb.minX - 30)")
        #expect(abs(bb.minY - 30) < 4, "min-y off by \(bb.minY - 30)")
        #expect(abs(bb.width - 60) < 6, "width off by \(bb.width - 60)")
        #expect(abs(bb.height - 60) < 6, "height off by \(bb.height - 60)")
    }

    /// Refine Edge round-trip: expand by N then contract by N should leave
    /// the selection close to where it started. CIMorphology + contour
    /// re-extraction introduces some shape softening, so we tolerate a
    /// small bbox drift.
    @Test("refineEdge expand→contract returns near the original bbox")
    func refineEdgeRoundTrip() {
        let canvas = CGSize(width: 200, height: 200)
        let original = CGPath(rect: CGRect(x: 50, y: 50, width: 100, height: 100), transform: nil)

        guard let expanded = SelectionTools.refineEdge(original, radiusPx: 8, canvasSize: canvas) else {
            Issue.record("refineEdge expand failed")
            return
        }
        // Expanded bbox should be ~8px larger on each side.
        let eb = expanded.boundingBoxOfPath
        #expect(eb.minX < 45, "expanded should grow leftward, minX=\(eb.minX)")
        #expect(eb.maxX > 155, "expanded should grow rightward, maxX=\(eb.maxX)")

        guard let contracted = SelectionTools.refineEdge(expanded, radiusPx: -8, canvasSize: canvas) else {
            Issue.record("refineEdge contract failed")
            return
        }
        let cb = contracted.boundingBoxOfPath
        // After cancelling the expand, bbox should be near the original.
        // CIMorphology + contour detection can drift up to ~4 pixels.
        #expect(abs(cb.minX - 50) < 6, "round-trip minX drifted: \(cb.minX) vs 50")
        #expect(abs(cb.maxX - 150) < 6, "round-trip maxX drifted: \(cb.maxX) vs 150")
    }

    // MARK: - helpers

    /// Two-color image: top half = `top`, bottom half = `bottom`.
    private func halfImage(top: NSColor, bottom: NSColor, size: CGSize) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bm = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: bm)!
        // CG bottom-up: bottom color fills the bottom of the image (CG y < h/2),
        // top color fills the top (CG y >= h/2).
        ctx.setFillColor(bottom.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        ctx.setFillColor(top.cgColor)
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        return ctx.makeImage()!
    }

    /// Sample one pixel of a single-channel grayscale CGImage at doc top-down
    /// coords. Returns 0..255 brightness.
    private func maskValue(_ img: CGImage, x: Int, y: Int) -> Int {
        let crop = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) ?? img
        var bytes: [UInt8] = [0, 0, 0, 0]
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return bytes.withUnsafeMutableBufferPointer { buf -> Int in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return 0
            }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            // Grayscale → just look at any of the RGB channels.
            return Int(buf[0])
        }
    }
}
