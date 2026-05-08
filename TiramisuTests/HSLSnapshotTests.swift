import XCTest
import SnapshotTesting
import CoreGraphics
import AppKit
@testable import Tiramisu

/// Visual gallery for the per-color HSL pipeline. Each test pushes a single
/// HSL slider and snapshots the rendered output so that drift in the LUT
/// generator or the CIColorCubeWithColorSpace bridge is immediately visible
/// in the diff. The cafe fixture has umbrella-reds, sky-blues, and people
/// in patio chairs (skin tones in the orange/yellow band) — covers most of
/// the band edge cases in one image.
@MainActor
final class HSLSnapshotTests: XCTestCase {

    func testHSLBaseline() throws {
        // Identity HSL — proves the LUT path doesn't disturb pixels at zero.
        try renderHSL(name: "hsl-baseline", hsl: HSLAdjustments())
    }

    func testRedSatBoost() throws {
        var h = HSLAdjustments(); h.redSat = 1.0
        try renderHSL(name: "hsl-red-sat-up", hsl: h)
    }

    func testRedSatCut() throws {
        // Drives reds toward gray. Skin tones (mostly orange) should stay.
        var h = HSLAdjustments(); h.redSat = -1.0
        try renderHSL(name: "hsl-red-sat-down", hsl: h)
    }

    func testBlueLumDown() throws {
        // Sky should darken; non-blue regions should be unaffected.
        var h = HSLAdjustments(); h.blueLum = -0.7
        try renderHSL(name: "hsl-blue-lum-down", hsl: h)
    }

    func testGreenHueShift() throws {
        // Pushes greens toward yellow.
        var h = HSLAdjustments(); h.greenHue = 0.6
        try renderHSL(name: "hsl-green-hue-shift", hsl: h)
    }

    func testCombinedTeal() throws {
        // Composite move: cool-and-teal preset shape, all sliders engaged.
        var h = HSLAdjustments()
        h.orangeSat = 0.4; h.orangeLum = 0.15
        h.blueHue = -0.3;  h.blueSat = 0.5
        h.aquaSat = 0.6
        try renderHSL(name: "hsl-teal-and-orange", hsl: h)
    }

    // MARK: - Helpers

    private func renderHSL(name: String, hsl: HSLAdjustments) throws {
        let store = DocumentStore()
        store.canvasSize = CGSize(width: 480, height: 320)
        store.backgroundColor = ColorRGB(r: 0.10, g: 0.10, b: 0.12)
        store.layers = []

        let cafe = try fixture(named: "cafe", ext: "jpg")
        guard let photo = store.placeSmartImage(data: cafe, format: "jpg") else {
            return XCTFail("placeSmartImage failed for cafe fixture")
        }
        var adj = Adjustments()
        adj.hsl = hsl
        photo.adjust = adj
        store.invalidate()

        let cg = LayerRenderer.composite(store: store)!
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        assertSnapshot(of: img, as: .image(precision: 0.96), named: name)
    }

    private func fixture(named name: String, ext: String) throws -> Data {
        let bundle = Bundle(for: HSLSnapshotTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw NSError(domain: "HSLSnapshotTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Fixture \(name).\(ext) is not in the test bundle."
            ])
        }
        return try Data(contentsOf: url)
    }
}
