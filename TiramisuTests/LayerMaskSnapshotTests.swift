import XCTest
import SnapshotTesting
import CoreGraphics
import CoreImage
import AppKit
@testable import Tiramisu

/// Visual gallery for v0.4 layer masks. Each test pins a different mask
/// shape against the same cafe.jpg smart object so any drift in the
/// luma→alpha conversion, the apply-order in LayerRenderer, or the
/// drop-shadow-follows-mask behavior shows up as an obvious diff.
@MainActor
final class LayerMaskSnapshotTests: XCTestCase {

    /// Half-canvas vertical hard mask — left half white (reveal), right half
    /// black (hide). The cafe should appear only on the left side of the
    /// canvas; the right side of the layer is fully transparent and the
    /// background shows through.
    func testHardHalfMask() throws {
        try renderMasked(name: "mask-hard-half") { canvas in
            hardHalfMask(size: canvas)
        }
    }

    /// Linear gradient mask — left fully revealing, right fully hiding,
    /// smooth transition. Anti-aliased mask edges prove the luma→alpha
    /// conversion preserves intermediate gray values rather than thresholding.
    func testGradientMask() throws {
        try renderMasked(name: "mask-gradient-linear") { canvas in
            gradientMask(size: canvas)
        }
    }

    /// Drop shadow + mask: a hard half mask with a drop shadow enabled.
    /// The shadow must trace the mask edge (vertical line down the middle of
    /// the cafe), not the layer's full alpha — proves the apply-order in
    /// LayerRenderer.render() (mask runs BEFORE drop shadow).
    func testMaskedDropShadowFollowsMaskEdge() throws {
        try renderMasked(name: "mask-shadow-follows-edge",
                         dropShadow: true) { canvas in
            hardHalfMask(size: canvas)
        }
    }

    /// Identity (all-white) mask — proves a present-but-fully-revealing mask
    /// is a no-op. If this snapshot ever drifts from the baseline-no-mask
    /// rendering it means the apply path is silently mutating pixels even
    /// when the mask is white.
    func testWhiteMaskIsNoOp() throws {
        try renderMasked(name: "mask-white-no-op") { canvas in
            LayerMaskFactory.solidWhite(size: canvas)
        }
    }

    // MARK: - Helpers

    private func renderMasked(
        name: String,
        dropShadow: Bool = false,
        maskFactory: (CGSize) -> CGImage?
    ) throws {
        let store = DocumentStore()
        // Same dimensions as the HSL gallery so masks render at a familiar
        // resolution + the smart object doesn't fill the canvas (catches
        // alpha-bleed bugs per RELEASING.md Step 1b).
        store.canvasSize = CGSize(width: 960, height: 640)
        store.backgroundColor = ColorRGB(r: 0.10, g: 0.10, b: 0.12)
        store.layers = []

        let cafe = try fixture(named: "cafe", ext: "jpg")
        guard let photo = store.placeSmartImage(data: cafe, format: "jpg") else {
            return XCTFail("placeSmartImage failed for cafe fixture")
        }
        // Smart-object masks live in SOURCE pixel space — the renderer
        // pushes them through the same placement transform as the photo.
        // Generate the test mask at the source's actual pixel dimensions
        // so it lines up with the photo regardless of canvas placement.
        let maskSize = CGSize(width: photo.smart?.pixelWidth ?? 0,
                              height: photo.smart?.pixelHeight ?? 0)
        photo.mask = maskFactory(maskSize)
        XCTAssertNotNil(photo.mask, "mask factory returned nil")
        if dropShadow {
            photo.styles.dropShadow.enabled = true
            photo.styles.dropShadow.color = .black
            photo.styles.dropShadow.opacity = 0.8
            photo.styles.dropShadow.distance = 18
            photo.styles.dropShadow.angle = 135
            photo.styles.dropShadow.blur = 14
        }
        store.invalidate()

        let cg = LayerRenderer.composite(store: store)!
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // CIFilter blur drift across macOS minor versions justifies a slight
        // precision relaxation, matching LayerStyleSnapshotTests.
        assertSnapshot(of: img, as: .image(precision: 0.96), named: name)
    }

    private func hardHalfMask(size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let cs = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        return ctx.makeImage()
    }

    private func gradientMask(size: CGSize) -> CGImage? {
        let extent = CGRect(origin: .zero, size: size)
        let f = CIFilter(name: "CILinearGradient")!
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        f.setValue(CIVector(x: extent.width, y: 0), forKey: "inputPoint1")
        f.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        f.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor1")
        guard let out = f.outputImage else { return nil }
        return LayerRenderer.ciContext.createCGImage(out, from: extent)
    }

    private func fixture(named name: String, ext: String) throws -> Data {
        let bundle = Bundle(for: LayerMaskSnapshotTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw NSError(domain: "LayerMaskSnapshotTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture \(name).\(ext) is not in the test bundle."
            ])
        }
        return try Data(contentsOf: url)
    }
}

/// Algorithmic checks separate from snapshots — pin behavior that's easy to
/// regress in ways the eye misses. Per `feedback_algorithmic_tests.md`.
@MainActor
final class LayerMaskAlgorithmicTests: XCTestCase {

    /// Identity mask must produce pixel-equal output to the no-mask path.
    /// Specifically: a fully-white mask is the renderer's no-op contract.
    func testWhiteMaskMatchesNoMask() throws {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 320, height: 200)
        store.backgroundColor = ColorRGB(r: 0.5, g: 0.5, b: 0.5)
        store.layers = []
        let solid = PXLayer(name: "solid", kind: .solid)
        solid.solid = SolidContent(color: ColorRGB(r: 0.9, g: 0.2, b: 0.2))
        store.layers = [solid]

        let baseline = LayerRenderer.composite(store: store)!
        solid.mask = LayerMaskFactory.solidWhite(size: store.canvasSize)
        store.invalidate()
        let withMask = LayerRenderer.composite(store: store)!

        let a = sampleCenter(baseline)
        let b = sampleCenter(withMask)
        XCTAssertEqual(a.r, b.r, accuracy: 2, "white mask should not change R")
        XCTAssertEqual(a.g, b.g, accuracy: 2, "white mask should not change G")
        XCTAssertEqual(a.b, b.b, accuracy: 2, "white mask should not change B")
    }

    /// Black mask must hide the layer entirely — center pixel of the
    /// composite should equal the canvas background, not the layer color.
    func testBlackMaskHidesLayer() throws {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 320, height: 200)
        store.backgroundColor = ColorRGB(r: 0.1, g: 0.7, b: 0.1)
        store.layers = []
        let solid = PXLayer(name: "solid", kind: .solid)
        solid.solid = SolidContent(color: ColorRGB(r: 0.9, g: 0.2, b: 0.2))

        // Pure-black mask
        let w = 320, h = 200
        let cs = CGColorSpace(name: CGColorSpace.linearGray)!
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        solid.mask = ctx.makeImage()

        store.layers = [solid]
        let cg = LayerRenderer.composite(store: store)!
        let center = sampleCenter(cg)
        // Should match the green background, not the red layer.
        XCTAssertLessThan(center.r, 60, "black mask should hide red layer (R near bg)")
        XCTAssertGreaterThan(center.g, 150, "black mask should reveal green bg (G high)")
    }

    /// Smart-object mask follows the photo through scale + recenter.
    /// First v0.4 prerelease shipped a bug where the mask was applied at
    /// canvas-coords regardless of the smart-object placement, so scaling
    /// the photo unstuck the mask from the subject and moving via
    /// smart.centerX/Y orphaned the mask in canvas space. The fix routes
    /// smart-object masks through SmartObjectEngine.rasterizeMask using the
    /// same transform as the photo. This test pins that contract: hide the
    /// LEFT half of the source — center pixel of the photo's transformed
    /// footprint should be background-colored after a recenter + scale-down.
    func testSmartObjectMaskFollowsTransform() throws {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 600, height: 400)
        store.backgroundColor = ColorRGB(r: 0, g: 1, b: 0)
        store.layers = []

        let cafe = try fixtureData(named: "cafe", ext: "jpg")
        guard let photo = store.placeSmartImage(data: cafe, format: "jpg"),
              var s = photo.smart else {
            return XCTFail("placeSmartImage failed")
        }
        // Override placement to a known geometry: photo at scale 0.5, center
        // shifted to (350, 200). Source 540×720 ⇒ rendered footprint 270×360
        // spanning canvas x ∈ [215, 485], y ∈ [20, 380]. If the mask were
        // applied in canvas space (the v0.4 prerelease bug), hiding the
        // SOURCE's left half wouldn't move with this recenter; the test
        // sample points around 215..485 specifically exercise that.
        s.scaleX = 0.5; s.scaleY = 0.5
        s.centerX = 350
        s.centerY = 200
        photo.smart = s

        // Source-space hard mask: hide LEFT half of the photo source.
        let w = s.pixelWidth, h = s.pixelHeight
        let cs = CGColorSpace(name: CGColorSpace.linearGray)!
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        photo.mask = ctx.makeImage()

        store.invalidate()
        let cg = LayerRenderer.composite(store: store)!

        // Sample inside the LEFT half of the recentered footprint (hidden) —
        // canvas x in [215, 350]. Should reveal the green canvas background.
        let leftSample = sampleAt(cg, x: 270, y: 200)
        XCTAssertGreaterThan(leftSample.g, 200, "left half of moved photo should be hidden, showing green bg")
        XCTAssertLessThan(leftSample.r, 80, "left half should not show photo content (low R)")

        // Sample inside the RIGHT half (visible) — canvas x in [350, 485].
        // Should show photo content, NOT the green bg.
        let rightSample = sampleAt(cg, x: 430, y: 200)
        XCTAssertLessThan(rightSample.g, 220, "right half should reveal photo content (not pure green bg)")
    }

    private func sampleAt(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let cs = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1,
                            bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG y-axis is bottom-up — convert from top-down logical y.
        let cgY = image.height - y - 1
        ctx.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(cgY),
                                   width: CGFloat(image.width),
                                   height: CGFloat(image.height)))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func fixtureData(named name: String, ext: String) throws -> Data {
        let bundle = Bundle(for: LayerMaskAlgorithmicTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw NSError(domain: "LayerMaskAlgorithmicTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture \(name).\(ext) is not in the test bundle."
            ])
        }
        return try Data(contentsOf: url)
    }

    /// Mask survives doc save → load roundtrip: confirms maskPNG persists in
    /// DocumentSnapshot and decodes back into the layer.
    func testMaskPersistsAcrossSnapshotRoundtrip() throws {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 100, height: 100)
        let layer = PXLayer(name: "m", kind: .solid)
        layer.mask = LayerMaskFactory.solidWhite(size: store.canvasSize)
        store.layers = [layer]

        let snap = store.makeSnapshot()
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(DocumentSnapshot.self, from: data)
        let restored = DocumentStore()
        restored.apply(decoded)
        XCTAssertNotNil(restored.layers.first?.mask, "mask should roundtrip via snapshot encoding")
    }

    /// Backward compat: a snapshot encoded WITHOUT a maskPNG key (i.e. an
    /// old v0.3 file) decodes with mask = nil and no error.
    func testOldDocumentDecodesWithNilMask() throws {
        let json = """
        {
          "version": 1,
          "canvasWidth": 100,
          "canvasHeight": 100,
          "background": {"r":0,"g":0,"b":0,"a":1},
          "layers": [
            {"id":"00000000-0000-0000-0000-000000000001",
             "name":"old","kind":"solid"}
          ]
        }
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(DocumentSnapshot.self, from: json)
        XCTAssertEqual(snap.layers.count, 1)
        XCTAssertNil(snap.layers[0].maskPNG, "v0.3 doc should decode with maskPNG = nil")
    }

    // MARK: - Sampling

    private func sampleCenter(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        let cs = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1,
                            bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cx = CGFloat(image.width) / 2 - 0.5
        let cy = CGFloat(image.height) / 2 - 0.5
        ctx.draw(image, in: CGRect(x: -cx, y: -cy,
                                   width: CGFloat(image.width),
                                   height: CGFloat(image.height)))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
}
